(* Docs reader: the holistic workload. An offline-capable Markdown
   documentation reader with search, written as direct-style OCaml on fibers.

   Per page load:
     boot     script inserted -> first OCaml line (fetch, compile, instantiate,
              _initialize: the app's own large Wasm module)
     plugin   lazy-load the search plugin (a second, larger wasm_of_ocaml
              program with Unicode tables) and await its readiness
   Per iteration (warmup + iters):
     sync     fetch manifest (yojson), then for each document with
              `concurrency` workers: crypto.subtle.digest -> Cache Storage
              lookup -> on a miss fetch + Response.text + cache.put
     render   cmarkit parse + HTML render into an offscreen container
     index    hand every document's text to the search plugin
     replay   scripted user session: type a query (a real DOM input event),
              show the result list, open the top hit; one macrotask between
              steps, like real input

   Knobs: docs (200), concurrency (8), cache (cold|warm), queries (50),
   warmup (1), iters (5). *)

open Js_of_ocaml

let docs_n = Bench.int_param "docs" 200
let concurrency = Bench.int_param "concurrency" 8
let cache_mode = Bench.param "cache" "cold"
let queries_n = Bench.int_param "queries" 50
let warmup = Bench.int_param "warmup" 1
let iters = Bench.int_param "iters" 5
let profile = Bench.param "profile" Mode.profile
let root = "../"
let g : Js.Unsafe.any = Js.Unsafe.inject Js.Unsafe.global
let str s = Js.Unsafe.inject (Js.string s)
let get (o : Js.Unsafe.any) k : Js.Unsafe.any = Js.Unsafe.get o k
let meth (o : Js.Unsafe.any) m args : Js.Unsafe.any = Js.Unsafe.meth_call o m args
let to_s (v : Js.Unsafe.any) = Js.to_string (Js.Unsafe.coerce v)
let to_int (v : Js.Unsafe.any) = int_of_float (Js.float_of_number (Js.Unsafe.coerce v))
let defined (v : Js.Unsafe.any) = Js.Optdef.test (Obj.magic v : _ Js.Optdef.t)
let await = Fiber.await
let document = get g "document"
let fetch url = Js.Unsafe.fun_call (get g "fetch") [| str url |]
let fetch_text url = to_s (await (meth (await (fetch url)) "text" [||]))

(* ---- sync: manifest, digest, Cache Storage, fetch ---- *)

type entry = { path : string; sha : string }

let manifest () =
  let j = Yojson.Safe.from_string (fetch_text (root ^ "corpus/manifest.json")) in
  let open Yojson.Safe.Util in
  j |> member "docs" |> to_list
  |> List.map (fun d -> { path = d |> member "path" |> to_string; sha = d |> member "sha256" |> to_string })
  |> Array.of_list

let encoder = Js.Unsafe.new_obj (get g "TextEncoder") [||]

let digest_key s =
  let buf =
    await
      (meth (get (get g "crypto") "subtle") "digest"
         [| str "SHA-256"; meth encoder "encode" [| str s |] |])
  in
  let a : Typed_array.uint8Array Js.t = Js.Unsafe.new_obj (get g "Uint8Array") [| buf |] in
  let b = Buffer.create 40 in
  Buffer.add_string b "/__docs_cache/";
  for i = 0 to 15 do
    Buffer.add_string b (Printf.sprintf "%02x" (Typed_array.unsafe_get a i))
  done;
  Buffer.contents b

let response_of_string s = Js.Unsafe.new_obj (get g "Response") [| str s |]
let cache_name = str "jspi-docs-reader"
let caches () = get g "caches"

let sync_doc cache e =
  let key = digest_key (e.path ^ e.sha) in
  let hit = await (meth cache "match" [| str key |]) in
  if defined hit then to_s (await (meth hit "text" [||]))
  else
    let text = fetch_text (root ^ "corpus/" ^ e.path) in
    ignore (await (meth cache "put" [| str key; response_of_string text |]));
    text

(* [concurrency] workers over the entries; results land in order. *)
let sync entries =
  let cache = await (meth (caches ()) "open" [| cache_name |]) in
  let n = Array.length entries in
  let out = Array.make n "" and next = ref 0 and finished = ref 0 in
  let done_ = Fiber.Chan.create 1 in
  for _ = 1 to concurrency do
    Fiber.spawn (fun () ->
        while !next < n do
          let i = !next in
          incr next;
          out.(i) <- sync_doc cache entries.(i)
        done;
        incr finished;
        if !finished = concurrency then Fiber.Chan.send done_ ())
  done;
  Fiber.Chan.recv done_;
  out

(* ---- render ---- *)

let el tag = meth document "createElement" [| str tag |]
let set o k v = Js.Unsafe.set o k v

let view =
  let v = el "div" in
  set v "id" (str "view");
  (* offscreen, fixed size, contained: no effect on the rest of the page *)
  set (get v "style") "cssText"
    (str "position:absolute;left:-10000px;top:0;width:800px;height:600px;overflow:hidden;contain:strict");
  ignore (meth (get document "body") "appendChild" [| v |]);
  v

let show_html html = set view "innerHTML" (str html)

let render sources =
  Array.mapi
    (fun _ src ->
      let doc = Docs.parse src in
      let html = Docs.render doc in
      show_html html;
      Hash.string Hash.init html, Docs.text doc)
    sources

(* ---- search plugin (lazy) ---- *)

let search = ref None

let load_plugin () =
  let p =
    Js.Unsafe.new_obj (get g "Promise")
      [| Js.Unsafe.inject (Js.wrap_callback (fun resolve _ -> set g "__searchReady" resolve)) |]
  in
  let s = el "script" in
  set s "src" (str (Printf.sprintf "%sdist/%s/search/main.bc.wasm.js" root profile));
  ignore (meth (get document "body") "appendChild" [| s |]);
  ignore (await p);
  search := Some (get g "__search")

let plugin () = Option.get !search

let index texts =
  let s = plugin () in
  ignore (meth s "reset" [||]);
  Array.iteri (fun i t -> ignore (meth s "add" [| Js.Unsafe.inject (Js.number_of_float (float i)); str t |])) texts;
  to_int (meth s "count" [||])

(* ---- replay: a scripted session through real DOM events ---- *)

let input =
  let i = el "input" in
  ignore (meth view "appendChild" [| i |]);
  i

let results_list = el "ul"

let queries texts =
  (* deterministic: the 3rd and 7th terms of every k-th document *)
  let k = max 1 (Array.length texts / max 1 queries_n) in
  Array.init queries_n (fun q ->
      let words = ref [] in
      Docs.iter_tokens (fun w -> words := w :: !words) texts.((q * k) mod Array.length texts);
      let words = Array.of_list (List.rev !words) in
      let pick j = if Array.length words > j then words.(j) else "javascript" in
      pick 3 ^ " " ^ pick 7)

let replay entries sources texts =
  let events = Fiber.Chan.create 16 and idle = Fiber.Chan.create 1 in
  let listener =
    Js.wrap_callback (fun _ev ->
        let q = to_s (get input "value") in
        (* never resume a fiber from a callback: post to the scheduler *)
        Fiber.post (fun () -> Fiber.Chan.send events (Some q)))
  in
  ignore (meth input "addEventListener" [| str "input"; Js.Unsafe.inject listener |]);
  let h = ref 0 in
  (* the app's UI fiber *)
  Fiber.spawn (fun () ->
      let rec loop () =
        match Fiber.Chan.recv events with
        | None -> ()
        | Some q ->
            let ids : Js.Unsafe.any Js.js_array Js.t = Js.Unsafe.coerce (meth (plugin ()) "query" [| str q |]) in
            let ids = Array.map to_int (Js.to_array ids) in
            set results_list "innerHTML" (str "");
            Array.iter
              (fun id ->
                let li = el "li" in
                set li "textContent" (str entries.(id).path);
                ignore (meth results_list "appendChild" [| li |]))
              ids;
            h := Array.fold_left Hash.int !h ids;
            (* open the top hit: re-render it from source *)
            (if Array.length ids > 0 then
               let html = Docs.render (Docs.parse sources.(ids.(0))) in
               show_html html;
               h := Hash.string !h html);
            Fiber.Chan.send idle ();
            loop ()
      in
      loop ());
  (* the "user" *)
  let ev = get g "Event" in
  Array.iter
    (fun q ->
      set input "value" (str q);
      ignore (meth input "dispatchEvent" [| Js.Unsafe.new_obj ev [| str "input" |] |]);
      Fiber.Chan.recv idle;
      ignore (await (Js.Unsafe.fun_call (Bench.helper "macro") [| Js.Unsafe.inject 0 |])))
    (queries texts);
  Fiber.Chan.send events None;
  ignore (meth input "removeEventListener" [| str "input"; Js.Unsafe.inject listener |]);
  !h

(* ---- driver ---- *)

let main () =
  let boot = Bench.now () -. Js.float_of_number (Js.Unsafe.coerce (get Bench.env "bootStart")) in
  let entries = Array.sub (manifest ()) 0 docs_n in
  let samples = Hashtbl.create 8 in
  let record phase dt =
    Hashtbl.replace samples phase (dt :: (try Hashtbl.find samples phase with Not_found -> []))
  in
  let timed phase f =
    let t0 = Bench.now () in
    let r = f () in
    let t1 = Bench.now () in
    Bench.signpost ("app/" ^ phase) t0 t1;
    record phase (t1 -. t0);
    r
  in
  let clear_cache () = ignore (await (meth (caches ()) "delete" [| cache_name |])) in
  clear_cache ();
  let t0 = Bench.now () in
  load_plugin ();
  let plugin_ms = Bench.now () -. t0 in
  let check = ref None in
  for it = 1 to warmup + iters do
    if cache_mode = "cold" then clear_cache ();
    let keep = it > warmup in
    let timed phase f = if keep then timed phase f else f () in
    Fiber.reset_counters ();
    let t_all = Bench.now () in
    let sources = timed "sync" (fun () -> sync entries) in
    let rendered = timed "render" (fun () -> render sources) in
    let texts = Array.map snd rendered in
    let terms = timed "index" (fun () -> index texts) in
    let h = timed "replay" (fun () -> replay entries sources texts) in
    if keep then record "total" (Bench.now () -. t_all);
    let c = Array.fold_left (fun acc (hh, _) -> acc + hh) (h + terms) rendered land 0x3fffffff in
    (match !check with
    | None -> check := Some c
    | Some c' when c' = c -> ()
    | Some c' -> failwith (Printf.sprintf "app: checksum changed %d -> %d" c' c));
    if it = warmup + iters then
      record "counters"
        (float !Fiber.awaits)
  done;
  let checksum = Option.get !check in
  let result test samples counters =
    { Bench.test; variant = "fiber"; samples; checksum; counters }
  in
  let get_s p = List.rev (try Hashtbl.find samples p with Not_found -> []) in
  let awaits = match Hashtbl.find_opt samples "counters" with Some (a :: _) -> int_of_float a | _ -> 0 in
  Bench.report ~workload:"app"
    ([ result "boot" [ boot ] []; result "plugin-load" [ plugin_ms ] [] ]
    @ List.map
        (fun p -> result p (get_s p) (if p = "total" then [ "awaits_per_iter", awaits; "docs", docs_n ] else []))
        [ "sync"; "render"; "index"; "replay"; "total" ])

let () = Fiber.run (fun () -> Bench.guard main)
