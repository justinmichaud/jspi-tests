(* A minimal single-threaded fiber scheduler on OCaml 5 effects, integrated
   with the JavaScript event loop.

   Fibers perform [Await p] to wait for a JS promise, and [Yield] to let other
   fibers run. JS promise callbacks never resume a continuation themselves;
   they only queue a completion, because how a suspended fiber gets resumed
   depends on the effects backend:

   - jspi:   every fiber is a JSPI stack, and switching fibers suspends a
             promising stack. A JS callback is not on a promising stack, so
             resuming from it would throw SuspendError. The scheduler loop
             therefore runs on the root (_initialize) promising stack, and when
             it is idle it blocks that stack with a direct JSPI await on a
             "wakeup" promise ([Block]).
   - cps / native: the root cannot block. When idle the loop returns to the
             event loop, and the next completion callback re-enters it
             ([Reenter]). Native stack switching allows resuming from a
             callback, and so does CPS.

   This split is the reason the scheduler is here rather than using
   Lwt_direct: Lwt wakes continuations from promise callbacks, which a JSPI
   effects build cannot do. See spike/ for the demonstration. *)

open Effect
open Effect.Deep
open Js_of_ocaml

type _ Effect.t +=
  | Await : Js.Unsafe.any -> Js.Unsafe.any Effect.t
  | Yield : unit Effect.t
  | Suspend : ((unit -> unit) -> unit) -> unit Effect.t
        (** Park the fiber; the argument receives the function that wakes it. *)

exception Rejected of Js.Unsafe.any

type strategy = Block | Reenter

let strategy =
  match Mode.effects with Mode.Jspi -> Block | Mode.Cps | Mode.Native | Mode.None_ -> Reenter

(* Counters, reported by the benchmarks. *)
let awaits = ref 0
let yields = ref 0
let spawns = ref 0
let idle_waits = ref 0

let reset_counters () =
  awaits := 0;
  yields := 0;
  spawns := 0;
  idle_waits := 0

let ready : (unit -> unit) Queue.t = Queue.create ()

(* Filled by JS callbacks. Moved to [ready] by the loop. *)
let completions : (unit -> unit) Queue.t = Queue.create ()
let pending = ref 0
let running = ref false
let failure : exn option ref = ref None
let wake : Js.Unsafe.any option ref = ref None

let resolve_wake () =
  match !wake with
  | None -> ()
  | Some resolve ->
      wake := None;
      ignore (Js.Unsafe.fun_call resolve [||])

let rec notify () =
  match strategy with
  | Block -> resolve_wake ()
  | Reenter -> if not !running then loop ()

and loop () =
  running := true;
  let go = ref true in
  while !go do
    Queue.transfer completions ready;
    match Queue.take_opt ready with
    | Some thunk -> thunk ()
    | None ->
        if !pending > 0 then (
          match strategy with
          | Block ->
              incr idle_waits;
              let p =
                Js.Unsafe.new_obj
                  (Js.Unsafe.pure_js_expr "Promise")
                  [|
                    Js.Unsafe.inject
                      (Js.wrap_callback (fun resolve _reject -> wake := Some resolve));
                  |]
              in
              ignore (Jspi.await_any p)
          | Reenter -> go := false)
        else go := false
  done;
  running := false

let on_settle p ~ok ~err =
  ignore
    (Js.Unsafe.meth_call p "then"
       [|
         Js.Unsafe.inject (Js.wrap_callback ok); Js.Unsafe.inject (Js.wrap_callback err);
       |])

let run_fiber f =
  incr spawns;
  match_with f ()
    {
      retc = (fun () -> ());
      exnc = (fun e -> if !failure = None then failure := Some e);
      effc =
        (fun (type a) (e : a Effect.t) ->
          match e with
          | Yield ->
              Some
                (fun (k : (a, unit) continuation) ->
                  incr yields;
                  Queue.push (fun () -> continue k ()) ready)
          | Suspend register ->
              Some
                (fun (k : (a, unit) continuation) ->
                  register (fun () -> Queue.push (fun () -> continue k ()) ready))
          | Await p ->
              Some
                (fun (k : (a, unit) continuation) ->
                  incr awaits;
                  incr pending;
                  on_settle p
                    ~ok:(fun v ->
                      decr pending;
                      Queue.push (fun () -> continue k v) completions;
                      notify ())
                    ~err:(fun e ->
                      decr pending;
                      Queue.push (fun () -> discontinue k (Rejected e)) completions;
                      notify ()))
          | _ -> None);
    }

let spawn f = Queue.push (fun () -> run_fiber f) ready
let await p = perform (Await (Js.Unsafe.inject p))
let yield () = perform Yield

(* Run [main] as the first fiber. Under [Block] this returns once everything
   has finished. Under [Reenter] it may return early, and [main] must signal
   completion itself (the benchmarks report from inside [main]). *)
let run main =
  spawn main;
  if not !running then loop ();
  match !failure with
  | Some e ->
      failure := None;
      raise e
  | None -> ()

(* An unbuffered or bounded channel between fibers. *)
module Chan = struct
  type 'a t = {
    items : 'a Queue.t;
    capacity : int;
    readers : ('a -> unit) Queue.t;
    writers : (unit -> unit) Queue.t;
  }

  let create capacity =
    { items = Queue.create (); capacity; readers = Queue.create (); writers = Queue.create () }

  let suspend register = perform (Suspend register)

  let rec send c v =
    match Queue.take_opt c.readers with
    | Some r -> r v
    | None ->
        if Queue.length c.items < c.capacity then Queue.push v c.items
        else (
          suspend (fun wake -> Queue.push wake c.writers);
          send c v)

  let rec recv c =
    match Queue.take_opt c.items with
    | Some v ->
        (match Queue.take_opt c.writers with Some w -> w () | None -> ());
        v
    | None -> (
        match Queue.take_opt c.writers with
        | Some w ->
            w ();
            recv c
        | None ->
            let slot = ref None in
            suspend (fun wake ->
                Queue.push
                  (fun v ->
                    slot := Some v;
                    wake ())
                  c.readers);
            Option.get !slot)
end

(* Hand work to the scheduler from a JS callback (a DOM event listener, say)
   without resuming anything inside the callback itself. *)
let post thunk =
  Queue.push thunk completions;
  notify ()
