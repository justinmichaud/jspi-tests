(* bench/await: JSPI as an async bridge. OCaml code waits for JS promises.

   Variants (variant=all runs every one that applies to the build):
     direct     jspi builds only. Direct-style code on the root promising
                stack; each await is one WebAssembly.Suspending call (lib/jspi).
     fiber      Direct-style code in a Fiber (lib/fiber): each await is an
                effect. jspi: JSPI fiber switches; native: WasmFX; cps: CPS.
     callback   No stack switching at all: the loop is written by hand in
                continuation-passing style over Promise.then, as monadic
                Lwt/JS code is. The pure-JS-style baseline.
     nosuspend  Same work and the same promise creation, without waiting
                (only where the value is known without waiting).

   Tests (test=all or one):
     resolved    n awaits of already-resolved promises
     micro       n awaits of promises resolved from a microtask
     macro       n/10 awaits of promises resolved from a macrotask
     depth       n awaits made `depth` OCaml frames deep
     fanout      n awaits spread over `width` concurrent workers
     webapi      per document: crypto.subtle.digest, Response.text,
                 Blob.arrayBuffer (browser / node only)
     module-load m compiles of a large Wasm module (WebAssembly.compile vs the
                 synchronous new WebAssembly.Module)

   Knobs: n (20000), depth (200), width (16), m (5), work (0 hash rounds per
   await), docs, warmup (2), iters (10). *)

open Js_of_ocaml

let n = Bench.int_param "n" 20000
let depth = Bench.int_param "depth" 200
let width = Bench.int_param "width" 16
let m = Bench.int_param "m" 5
let warmup = Bench.int_param "warmup" 2
let iters = Bench.int_param "iters" 10
let work_rounds = Bench.int_param "work" 0
let has_web_apis = Js.to_bool (Js.Unsafe.coerce (Bench.helper "hasWebApis"))

let spin h =
  let h = ref h in
  for _ = 1 to work_rounds do
    h := Hash.int !h 0x1bd1e995
  done;
  !h

let num i = Js.Unsafe.inject (Js.number_of_float (float i))
let to_int (v : Js.Unsafe.any) = int_of_float (Js.float_of_number (Js.Unsafe.coerce v))
let call name (arg : Js.Unsafe.any) : Js.Unsafe.any = Js.Unsafe.fun_call (Bench.helper name) [| arg |]

let js_docs : Js.Unsafe.any array =
  let a : Js.Unsafe.any Js.js_array Js.t = Js.Unsafe.coerce (Bench.get Bench.env "docs") in
  Js.to_array a

(* ---- the tests, as promise factories plus a fold ---- *)

(* A test is a sequence of [count] steps. Step i makes a promise; the result
   of awaiting it is folded into the checksum. *)
type test = {
  name : string;
  count : unit -> int;
  make : int -> Js.Unsafe.any;
  known : (int -> int) option;  (** the value, when known without waiting *)
}

let simple name helper count =
  { name; count; make = (fun i -> call helper (num i)); known = Some (fun i -> i) }

let webapi_steps = [| "digest"; "responseText"; "blobBytes" |]

let tests () =
  [
    simple "resolved" "resolved" (fun () -> n);
    simple "micro" "micro" (fun () -> n);
    simple "macro" "macro" (fun () -> max 1 (n / 10));
    { (simple "depth" "resolved" (fun () -> n)) with name = "depth" };
    { (simple "fanout" "resolved" (fun () -> n)) with name = "fanout" };
    {
      name = "webapi";
      count = (fun () -> 3 * Array.length js_docs);
      make = (fun i -> call webapi_steps.(i mod 3) js_docs.(i / 3 mod Array.length js_docs));
      known = None;
    };
    {
      name = "module-load";
      count = (fun () -> m);
      make = (fun _ -> call "wasmCompile" (Bench.helper "wasmBytes"));
      known = None;
    };
  ]

let applicable t =
  match t.name with
  | "webapi" -> has_web_apis
  | "module-load" -> Js.Opt.test (Obj.magic (Bench.helper "wasmBytes") : _ Js.Opt.t)
  | _ -> true

let step h v = spin (Hash.int h v)

(* ---- direct style, parameterised by how to await ---- *)

(* Not a tail call: the await happens with [d] OCaml frames on the stack. *)
let rec at_depth d f =
  if d = 0 then f ()
  else
    let r = at_depth (d - 1) f in
    Sys.opaque_identity r

let direct_body ~await t =
  match t.name with
  | "depth" ->
      let h = ref 0 in
      for i = 1 to t.count () do
        h := step !h (at_depth depth (fun () -> to_int (await (t.make i))))
      done;
      !h
  | _ ->
      let h = ref 0 in
      for i = 1 to t.count () do
        h := step !h (to_int (await (t.make i)))
      done;
      !h

(* fanout under fibers: width workers share the steps; the checksum is a sum
   so it does not depend on interleaving. *)
let fiber_body t =
  match t.name with
  | "fanout" ->
      let total = ref 0 and next = ref 1 and finished = ref 0 in
      let count = t.count () in
      let all_done = Fiber.Chan.create 1 in
      for _ = 1 to width do
        Fiber.spawn (fun () ->
            let h = ref 0 in
            while !next <= count do
              let i = !next in
              incr next;
              h := !h + step 0 (to_int (Fiber.await (t.make i)))
            done;
            total := !total + !h;
            incr finished;
            if !finished = width then Fiber.Chan.send all_done ())
      done;
      Fiber.Chan.recv all_done;
      !total land 0x3fffffff
  | _ -> direct_body ~await:Fiber.await t

let direct_fanout t =
  (* No concurrency without effects: the closest direct-style equivalent is
     awaiting batches with Promise.all. *)
  let count = t.count () in
  let total = ref 0 and i = ref 1 in
  let promise = Js.Unsafe.pure_js_expr "Promise" in
  while !i <= count do
    let batch = Array.init (min width (count - !i + 1)) (fun j -> t.make (!i + j)) in
    i := !i + Array.length batch;
    let arr : Js.Unsafe.any Js.js_array Js.t =
      Js.Unsafe.coerce
        (Jspi.await_any
           (Js.Unsafe.meth_call promise "all" [| Js.Unsafe.inject (Js.array batch) |]))
    in
    Array.iter (fun v -> total := !total + step 0 (to_int v)) (Js.to_array arr)
  done;
  !total land 0x3fffffff

(* ---- callback style (no stack switching) ---- *)

let then_ (p : Js.Unsafe.any) (f : Js.Unsafe.any -> unit) =
  ignore (Js.Unsafe.meth_call p "then" [| Js.Unsafe.inject (Js.wrap_callback f) |])

let callback_body t (k : int -> unit) =
  let count = t.count () in
  match t.name with
  | "fanout" ->
      let total = ref 0 and next = ref 1 and finished = ref 0 in
      for _ = 1 to width do
        let rec go h =
          if !next > count then (
            total := !total + h;
            incr finished;
            if !finished = width then k (!total land 0x3fffffff))
          else
            let i = !next in
            incr next;
            then_ (t.make i) (fun v -> go (h + step 0 (to_int v)))
        in
        go 0
      done
  | _ ->
      let rec go i h =
        if i > count then k h else then_ (t.make i) (fun v -> go (i + 1) (step h (to_int v)))
      in
      go 1 0

let nosuspend_body t =
  match t.known with
  | None -> None
  | Some value ->
      Some
        (fun () ->
          match t.name with
          | "fanout" ->
              let h = ref 0 in
              for i = 1 to t.count () do
                ignore (t.make i);
                h := !h + step 0 (value i)
              done;
              !h land 0x3fffffff
          | _ ->
              let h = ref 0 in
              for i = 1 to t.count () do
                ignore (t.make i);
                h := step !h (value i)
              done;
              !h)

let module_load_sync () =
  let h = ref 0 in
  for _ = 1 to m do
    h := step !h (to_int (call "wasmCompileSync" (Bench.helper "wasmBytes")))
  done;
  !h

(* ---- driver ---- *)

let counters t () = [ "awaits", t.count () ]

let measure_async ~test ~variant body k =
  let samples = ref [] and check = ref None in
  let rec run i =
    if i = warmup + iters then
      k
        {
          Bench.test;
          variant;
          samples = List.rev !samples;
          checksum = Option.get !check;
          counters = [];
        }
    else
      let t0 = Bench.now () in
      body (fun c ->
          let t1 = Bench.now () in
          let dt = t1 -. t0 in
          if i >= warmup then Bench.signpost (test ^ "/" ^ variant) t0 t1;
          (match !check with
          | None -> check := Some c
          | Some c' when c' = c -> ()
          | Some c' -> failwith (Printf.sprintf "%s/%s: checksum changed %d -> %d" test variant c' c));
          if i >= warmup then samples := dt :: !samples;
          run (i + 1))
  in
  run 0

let () =
  Bench.guard @@ fun () ->
  let want_test = Bench.param "test" "all" and want = Bench.param "variant" "all" in
  let tests =
    List.filter (fun t -> applicable t && (want_test = "all" || t.name = want_test)) (tests ())
  in
  let enabled v =
    (want = "all" || want = v)
    && (v <> "direct" || Mode.effects = Mode.Jspi)
    && (v <> "fiber" || Mode.has_effects)
  in
  let results = ref [] in
  let add r = results := r :: !results in
  (* Order matters under JSPI: direct awaits must run on the root promising
     stack, so they go first, before anything continues from a callback. *)
  if enabled "direct" then
    List.iter
      (fun t ->
        let body =
          match t.name with
          | "fanout" -> fun () -> direct_fanout t
          | _ -> fun () -> direct_body ~await:Jspi.await_any t
        in
        add (Bench.measure ~test:t.name ~variant:"direct" ~warmup ~iters ~counters:(counters t) body))
      tests;
  if enabled "nosuspend" then
    List.iter
      (fun t ->
        match nosuspend_body t with
        | Some body ->
            add (Bench.measure ~test:t.name ~variant:"nosuspend" ~warmup ~iters ~counters:(counters t) body)
        | None ->
            if t.name = "module-load" then
              add
                (Bench.measure ~test:t.name ~variant:"sync" ~warmup ~iters ~counters:(counters t)
                   module_load_sync))
      tests;
  let finish () =
    let rs = List.rev !results in
    (* every variant of a test must agree *)
    List.iter
      (fun t ->
        match List.filter (fun r -> r.Bench.test = t.name) rs with
        | [] -> ()
        | r :: rest ->
            List.iter
              (fun r' ->
                if r'.Bench.checksum <> r.Bench.checksum then
                  failwith
                    (Printf.sprintf "%s: %s/%s checksum mismatch %d vs %d" t.name r.variant
                       r'.variant r.checksum r'.checksum))
              rest)
      tests;
    Bench.report ~workload:"await" rs
  in
  let rec callbacks = function
    | [] -> finish ()
    | t :: rest ->
        measure_async ~test:t.name ~variant:"callback" (callback_body t) (fun r ->
            add { r with counters = counters t () };
            callbacks rest)
  in
  let after_fibers () = if enabled "callback" then Bench.guard (fun () -> callbacks tests) else finish () in
  if enabled "fiber" then
    Fiber.run (fun () ->
        Bench.guard (fun () ->
            List.iter
              (fun t ->
                Fiber.reset_counters ();
                let r =
                  Bench.measure ~test:t.name ~variant:"fiber" ~warmup ~iters ~counters:(counters t) (fun () ->
                      fiber_body t)
                in
                add { r with counters = r.counters @ [ "idle_waits", !Fiber.idle_waits ] })
              tests;
            after_fibers ()))
  else after_fibers ()
