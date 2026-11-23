(* bench/micro: one minimal case per row of the results table.

   No real work, no libraries beyond the effect and JSPI primitives: each
   test does nothing but the operation its row is about, next to a baseline
   that does the same bookkeeping without it. The realistic versions of the
   same rows are bench/switch, bench/await and app/.

   test            variants (baseline first)    the operation
   generator       direct | effects             perform+continue: an iterator
                                                inverted with an effect
   fibers          direct | effects             yield between `fibers` fibers
                                                (round-robin scheduler)
   deep            direct | effects             perform handled `depth`
                                                handlers up (reperform chain)
   pipeline        direct | effects             rendezvous handoff between a
                                                producer and a consumer fiber
   await-resolved  nosuspend | direct | fiber | callback
                                                await Promise.resolve(i)
   await-micro     nosuspend | fiber            await a queueMicrotask-resolved
                                                promise
   await-fanout    nosuspend | fiber            16 fibers awaiting concurrently
   module-load     sync | fiber                 compile the largest app module

   direct (await) needs a jspi build; effects/fiber need any build but `none`.
   Knobs: n (ops per iteration), fibers (100), depth (20), width (16), m (3),
   warmup, iters, test=<name>|all. *)

open Effect
open Effect.Deep
open Js_of_ocaml

let n = Bench.int_param "n" 200000
let n_fibers = Bench.int_param "fibers" 100
let depth = Bench.int_param "depth" 20
let width = Bench.int_param "width" 16
let m = Bench.int_param "m" 3
let warmup = Bench.int_param "warmup" 3
let iters = Bench.int_param "iters" 10

(* ---- generator ---- *)

type _ Effect.t += Next : int -> unit Effect.t

let gen_seq count : int Seq.t =
 fun () ->
  match_with
    (fun () ->
      for i = 0 to count - 1 do
        perform (Next i)
      done)
    ()
    {
      retc = (fun () -> Seq.Nil);
      exnc = raise;
      effc =
        (fun (type a) (e : a Effect.t) ->
          match e with
          | Next i -> Some (fun (k : (a, int Seq.node) continuation) -> Seq.Cons (i, fun () -> continue k ()))
          | _ -> None);
    }

let generator = function
  | `Effects -> fun () -> Seq.fold_left (fun h i -> Hash.int h i) 0 (gen_seq n)
  | `Direct ->
      fun () ->
        let h = ref 0 in
        for i = 0 to n - 1 do
          h := Hash.int !h i
        done;
        !h

(* ---- a minimal round-robin scheduler, for fibers and pipeline ---- *)

type _ Effect.t += Yield : unit Effect.t | Park : ((unit -> unit) -> unit) -> unit Effect.t

let run_fibers (fs : (unit -> unit) list) =
  let q = Queue.create () in
  let spawn f =
    match_with f ()
      {
        retc = (fun () -> ());
        exnc = raise;
        effc =
          (fun (type a) (e : a Effect.t) ->
            match e with
            | Yield -> Some (fun (k : (a, unit) continuation) -> Queue.push (fun () -> continue k ()) q)
            | Park register ->
                Some (fun (k : (a, unit) continuation) -> register (fun () -> Queue.push (fun () -> continue k ()) q))
            | _ -> None);
      }
  in
  List.iter (fun f -> Queue.push (fun () -> spawn f) q) fs;
  while not (Queue.is_empty q) do
    (Queue.take q) ()
  done

let fibers = function
  | `Effects ->
      fun () ->
        let total = ref 0 in
        let per = n / n_fibers in
        run_fibers
          (List.init n_fibers (fun id () ->
               for step = 1 to per do
                 total := Hash.int !total (id + step);
                 perform Yield
               done));
        !total
  | `Direct ->
      fun () ->
        (* same interleaving order as the scheduler: round-robin *)
        let total = ref 0 in
        let per = n / n_fibers in
        for step = 1 to per do
          for id = 0 to n_fibers - 1 do
            total := Hash.int !total (id + step)
          done
        done;
        !total

(* ---- deep ---- *)

type _ Effect.t += Ask : int -> int Effect.t

let deep = function
  | `Effects ->
      fun () ->
        let rec nest lvl =
          if lvl = depth then (
            let h = ref 0 in
            for _ = 1 to n / 10 do
              h := Hash.int !h (perform (Ask 0))
            done;
            !h)
          else
            try_with nest (lvl + 1)
              {
                effc =
                  (fun (type a) (e : a Effect.t) ->
                    match e with
                    | Ask l when l = lvl -> Some (fun (k : (a, _) continuation) -> continue k (lvl + 1))
                    | _ -> None);
              }
        in
        nest 0
  | `Direct ->
      fun () ->
        let h = ref 0 in
        for _ = 1 to n / 10 do
          h := Hash.int !h (Sys.opaque_identity 1)
        done;
        !h

(* ---- pipeline: rendezvous channel ---- *)

let pipeline = function
  | `Effects ->
      fun () ->
        let readers = Queue.create () and writers = Queue.create () in
        let send v =
          match Queue.take_opt readers with
          | Some r -> r v
          | None -> perform (Park (fun wake -> Queue.push (v, wake) writers))
        in
        let recv () =
          match Queue.take_opt writers with
          | Some (v, wake) ->
              wake ();
              v
          | None ->
              let slot = ref 0 in
              perform
                (Park
                   (fun wake ->
                     Queue.push
                       (fun v ->
                         slot := v;
                         wake ())
                       readers));
              !slot
        in
        let items = n / 2 and h = ref 0 in
        run_fibers
          [
            (fun () ->
              for i = 1 to items do
                send i
              done);
            (fun () ->
              for _ = 1 to items do
                h := Hash.int !h (recv ())
              done);
          ];
        !h
  | `Direct ->
      fun () ->
        let h = ref 0 in
        for i = 1 to n / 2 do
          h := Hash.int !h (Sys.opaque_identity i)
        done;
        !h

(* ---- awaits ---- *)

let num i = Js.Unsafe.inject (Js.number_of_float (float i))
let to_int (v : Js.Unsafe.any) = int_of_float (Js.float_of_number (Js.Unsafe.coerce v))
let resolved i : Js.Unsafe.any = Js.Unsafe.fun_call (Bench.helper "resolved") [| num i |]
let micro i : Js.Unsafe.any = Js.Unsafe.fun_call (Bench.helper "micro") [| num i |]
let awaits = n / 4

let await_loop await make () =
  let h = ref 0 in
  for i = 1 to awaits do
    h := Hash.int !h (to_int (await (make i)))
  done;
  !h

let nosuspend make () =
  let h = ref 0 in
  for i = 1 to awaits do
    ignore (Sys.opaque_identity (make i));
    h := Hash.int !h i
  done;
  !h

(* fanout: a sum, so it does not depend on interleaving *)
let fanout_fiber () =
  let total = ref 0 and next = ref 1 and finished = ref 0 in
  let all_done = Fiber.Chan.create 1 in
  for _ = 1 to width do
    Fiber.spawn (fun () ->
        while !next <= awaits do
          let i = !next in
          incr next;
          total := !total + to_int (Fiber.await (resolved i))
        done;
        incr finished;
        if !finished = width then Fiber.Chan.send all_done ())
  done;
  Fiber.Chan.recv all_done;
  !total land 0x3fffffff

let fanout_nosuspend () =
  let total = ref 0 in
  for i = 1 to awaits do
    ignore (Sys.opaque_identity (resolved i));
    total := !total + i
  done;
  !total land 0x3fffffff

let callback_loop k =
  let rec go i h =
    if i > awaits then k h
    else
      ignore
        (Js.Unsafe.meth_call (resolved i) "then"
           [| Js.Unsafe.inject (Js.wrap_callback (fun v -> go (i + 1) (Hash.int h (to_int v)))) |])
  in
  go 1 0

let wasm_bytes () = Bench.helper "wasmBytes"
let has_module () = Js.Opt.test (Obj.magic (wasm_bytes ()) : _ Js.Opt.t)

let module_load await_compile () =
  let h = ref 0 in
  for _ = 1 to m do
    h := Hash.int !h (to_int (await_compile ()))
  done;
  !h

let compile_sync () = Js.Unsafe.fun_call (Bench.helper "wasmCompileSync") [| wasm_bytes () |]
let compile_async () : Js.Unsafe.any = Js.Unsafe.fun_call (Bench.helper "wasmCompile") [| wasm_bytes () |]

(* ---- driver ---- *)

let () =
  Bench.guard @@ fun () ->
  let want = Bench.param "test" "all" in
  let on t = want = "all" || want = t in
  let effects = Mode.has_effects and jspi = Mode.effects = Mode.Jspi in
  let results = ref [] in
  let add r = results := r :: !results in
  let measure test variant ops f =
    add (Bench.measure ~test ~variant ~warmup ~iters ~counters:(fun () -> [ "ops", ops ]) f)
  in
  (* 1. synchronous tests, on the root (promising) stack *)
  List.iter
    (fun (test, f, ops) ->
      if on test then (
        measure test "direct" ops (f `Direct);
        if effects then measure test "effects" ops (f `Effects)))
    [
      ("generator", generator, 2 * n);
      ("fibers", fibers, n / n_fibers * n_fibers);
      ("deep", deep, n / 10);
      ("pipeline", pipeline, n / 2);
    ];
  if on "await-resolved" then (
    measure "await-resolved" "nosuspend" awaits (nosuspend resolved);
    if jspi then measure "await-resolved" "direct" awaits (await_loop Jspi.await_any resolved));
  if on "await-micro" then measure "await-micro" "nosuspend" awaits (nosuspend micro);
  if on "await-fanout" then measure "await-fanout" "nosuspend" awaits fanout_nosuspend;
  if on "module-load" && has_module () then measure "module-load" "sync" m (module_load compile_sync);
  let finish () =
    let rs = List.rev !results in
    (* all variants of a test must agree *)
    List.iter
      (fun r ->
        List.iter
          (fun r' ->
            if r.Bench.test = r'.Bench.test && r.checksum <> r'.checksum then
              failwith (Printf.sprintf "%s: %s/%s checksum mismatch" r.test r.variant r'.variant))
          rs)
      rs;
    Bench.report ~workload:"micro" rs
  in
  (* 3. callback variants last: they continue from JS callbacks *)
  let callbacks () =
    if on "await-resolved" then
      Bench.measure_async ~test:"await-resolved" ~variant:"callback" ~warmup ~iters
        ~counters:(fun () -> [ "ops", awaits ])
        callback_loop
        (fun r ->
          add r;
          finish ())
    else finish ()
  in
  (* 2. fiber variants through the scheduler *)
  if effects then
    Fiber.run (fun () ->
        Bench.guard (fun () ->
            if on "await-resolved" then measure "await-resolved" "fiber" awaits (await_loop Fiber.await resolved);
            if on "await-micro" then measure "await-micro" "fiber" awaits (await_loop Fiber.await micro);
            if on "await-fanout" then measure "await-fanout" "fiber" awaits fanout_fiber;
            if on "module-load" && has_module () then
              measure "module-load" "fiber" m (module_load (fun () -> Fiber.await (compile_async ())));
            callbacks ()))
  else callbacks ()
