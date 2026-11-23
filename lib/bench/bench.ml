(* Interface to the JS harness (runner/harness.js or runner/shell.js), which
   sets globalThis.__bench before the Wasm program starts:

     params    : { [name]: string }       workload knobs
     docs      : string[]                 corpus documents (already loaded)
     now()     : number (ms)              high-resolution clock
     report(s) : void                     receives the JSON result string
     helpers   : promise factories used by bench/await

   Loading the corpus and the Wasm happens before the program starts, so it
   is never inside a timed region. *)

open Js_of_ocaml

let env : Js.Unsafe.any = Js.Unsafe.get Js.Unsafe.global "__bench"
let get o k : Js.Unsafe.any = Js.Unsafe.get o (Js.string k)

let param name default =
  let v : Js.js_string Js.t Js.Optdef.t = Obj.magic (get (get env "params") name) in
  Js.Optdef.case v (fun () -> default) Js.to_string

let int_param name default = int_of_string (param name (string_of_int default))

let now () : float =
  Js.float_of_number (Js.Unsafe.coerce (Js.Unsafe.fun_call (get env "now") [||]))

let docs =
  lazy
    (let a : Js.js_string Js.t Js.js_array Js.t = Js.Unsafe.coerce (get env "docs") in
     Array.map Js.to_string (Js.to_array a))

let helper name = get (get env "helpers") name

(* Signpost: the span [t0, t1] (in [now] ms) was the named work. The harness
   keeps the spans (converted to epoch time) in the result, and the profiler
   keeps only samples inside them (tools/profile.py). *)
let signpost name t0 t1 =
  ignore
    (Js.Unsafe.fun_call (get env "span")
       [|
         Js.Unsafe.inject (Js.string name);
         Js.Unsafe.inject (Js.number_of_float t0);
         Js.Unsafe.inject (Js.number_of_float t1);
       |])

type result = {
  test : string;
  variant : string;
  samples : float list;  (** ms per timed iteration *)
  checksum : int;
  counters : (string * int) list;
}

(* Run [f] [warmup] times untimed, then [iters] times timed. Every iteration
   must return the same checksum. *)
let measure ~test ~variant ~warmup ~iters ?(counters = fun () -> []) f =
  let check = ref None in
  let run () =
    let c = f () in
    match !check with
    | None -> check := Some c
    | Some c' when c' = c -> ()
    | Some c' ->
        failwith (Printf.sprintf "%s/%s: checksum changed %d -> %d" test variant c' c)
  in
  for _ = 1 to warmup do
    run ()
  done;
  let name = test ^ "/" ^ variant in
  let samples =
    List.init iters (fun _ ->
        let t0 = now () in
        run ();
        let t1 = now () in
        signpost name t0 t1;
        t1 -. t0)
  in
  { test; variant; samples; checksum = Option.get !check; counters = counters () }

let json_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let result_json r =
  Printf.sprintf
    "{\"test\":%s,\"variant\":%s,\"checksum\":%d,\"samples_ms\":[%s],\"counters\":{%s}}"
    (json_string r.test) (json_string r.variant) r.checksum
    (String.concat "," (List.map (Printf.sprintf "%.4f") r.samples))
    (String.concat ","
       (List.map (fun (k, v) -> Printf.sprintf "%s:%d" (json_string k) v) r.counters))

let report ~workload (results : result list) =
  let s =
    Printf.sprintf "{\"workload\":%s,\"profile\":%s,\"effects\":%s,\"results\":[%s]}"
      (json_string workload) (json_string Mode.profile)
      (json_string (Mode.effects_name Mode.effects))
      (String.concat "," (List.map result_json results))
  in
  ignore (Js.Unsafe.fun_call (get env "report") [| Js.Unsafe.inject (Js.string s) |])

let fail msg =
  ignore (Js.Unsafe.fun_call (get env "fail") [| Js.Unsafe.inject (Js.string msg) |])

(* Report any exception to the harness instead of losing it in a callback. *)
let guard f = try f () with e -> fail (Printexc.to_string e ^ "\n" ^ Printexc.get_backtrace ())

(* [measure] for continuation-passing bodies (Promise.then chains): [body k]
   must call [k checksum] once its work is done. *)
let measure_async ~test ~variant ~warmup ~iters ?(counters = fun () -> []) body k =
  let samples = ref [] and check = ref None in
  let name = test ^ "/" ^ variant in
  let rec run i =
    if i = warmup + iters then
      k { test; variant; samples = List.rev !samples; checksum = Option.get !check; counters = counters () }
    else
      let t0 = now () in
      body (fun c ->
          let t1 = now () in
          (match !check with
          | None -> check := Some c
          | Some c' when c' = c -> ()
          | Some c' -> failwith (Printf.sprintf "%s: checksum changed %d -> %d" name c' c));
          if i >= warmup then (
            signpost name t0 t1;
            samples := (t1 -. t0) :: !samples);
          run (i + 1))
  in
  run 0
