(* Phase 0: verify the JSPI/effects behaviours the design depends on.
   Prints one line per check. Run under each mode with runner/node.sh. *)

open Js_of_ocaml
open Effect
open Effect.Deep

let log s = ignore (Js.Unsafe.meth_call (Js.Unsafe.get Js.Unsafe.global "console") "log" [| Js.Unsafe.inject (Js.string s) |])
let mode = Mode.effects_name Mode.effects

type _ Effect.t += E : int Effect.t

let resolved (v : int) : Js.Unsafe.any =
  Js.Unsafe.fun_call
    (Js.Unsafe.pure_js_expr "(v) => Promise.resolve(v)")
    [| Js.Unsafe.inject (Js.number_of_float (float v)) |]

let to_int (v : Js.Unsafe.any) = int_of_float (Js.float_of_number (Js.Unsafe.coerce v))

(* 1. Direct JSPI await from top-level code (jspi only). *)
let () =
  if Mode.effects = Mode.Jspi then
    match Jspi.await_any (resolved 41) with
    | v -> log (Printf.sprintf "[%s] direct await at toplevel: ok (%d)" mode (to_int v + 1))
    | exception e -> log (Printf.sprintf "[%s] direct await at toplevel: FAILED %s" mode (Printexc.to_string e))

(* 2. Plain effect handler, perform + continue on the same stack. *)
let () =
  let r = try_with (fun () -> perform E + perform E) () {
    effc = (fun (type a) (e : a Effect.t) -> match e with
      | E -> Some (fun (k : (a, _) continuation) -> continue k 21)
      | _ -> None) } in
  log (Printf.sprintf "[%s] perform/continue: ok (%d)" mode r)

(* 3. Resume a continuation from a JS promise callback (what Lwt_direct does). *)
let () =
  let saved = ref None in
  match_with (fun () -> perform E) ()
    { retc = (fun v -> log (Printf.sprintf "[%s] resume from callback: ok (%d)" mode v));
      exnc = (fun e -> log (Printf.sprintf "[%s] resume from callback: fiber raised %s" mode (Printexc.to_string e)));
      effc = (fun (type a) (e : a Effect.t) -> match e with
        | E -> Some (fun (k : (a, _) continuation) -> saved := Some (Obj.magic k : (int, unit) continuation))
        | _ -> None) };
  let p = resolved 0 in
  ignore (Js.Unsafe.meth_call p "then" [| Js.Unsafe.inject (Js.wrap_callback (fun _ ->
    match continue (Option.get !saved) 7 with
    | () -> ()
    | exception e -> log (Printf.sprintf "[%s] resume from callback: FAILED %s" mode (Printexc.to_string e)))) |])

(* 4. The Fiber scheduler: two fibers awaiting promises and yielding. *)
let () =
  let out = ref [] in
  Fiber.run (fun () ->
    Fiber.spawn (fun () ->
      for i = 1 to 3 do
        let v = to_int (Fiber.await (resolved i)) in
        out := (10 * v) :: !out;
        Fiber.yield ()
      done);
    for i = 1 to 3 do
      let v = to_int (Fiber.await (resolved i)) in
      out := v :: !out
    done;
    Fiber.yield (); Fiber.yield (); Fiber.yield (); Fiber.yield ();
    let c = Fiber.Chan.create 0 in
    Fiber.spawn (fun () -> for i = 1 to 3 do Fiber.Chan.send c i done);
    let s = Fiber.Chan.recv c + Fiber.Chan.recv c + Fiber.Chan.recv c in
    log (Printf.sprintf "[%s] fiber scheduler: ok (%s; chan sum %d; awaits=%d idle_waits=%d)" mode
      (String.concat "," (List.rev_map string_of_int !out)) s !Fiber.awaits !Fiber.idle_waits))
