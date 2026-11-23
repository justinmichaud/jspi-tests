(* bench/switch: OCaml effects as core control flow, with no real async.

   In a jspi build every switch below is a Suspending call, a Promise and a
   microtask; in a native build it is a WasmFX suspend/resume; in a cps build
   it is closure allocation and indirect calls. Each test has a [direct] twin
   that does the same work without effects, and both must produce the same
   checksum. The difference is the cost of the switches.

   Knobs (URL params or shell k=v args):
     test     generator | pipeline | fibers | deep | all     (default all)
     variant  effects | direct | both                        (default both)
     docs     number of corpus documents                     (default 200)
     warmup / iters                                          (default 3 / 10)
     work     extra hash rounds per switch, to dilute        (default 0)
     chunk    pipeline: split docs into ~chunk-byte items, 0 = whole docs
     q        pipeline: Eio.Stream capacity, 0 = rendezvous (default 0)
     fibers / yields   fibers test                           (default 1000 / 100)
     depth / performs  deep test                             (default 20 / 20000) *)

open Effect
open Effect.Deep

let work_rounds = Bench.int_param "work" 0

let spin h =
  let h = ref h in
  for _ = 1 to work_rounds do
    h := Hash.int !h 0x1bd1e995
  done;
  !h

(* ---- generator: zip two documents' node streams (needs inversion of
   control: two iterators advanced in lock step). ---- *)

type _ Effect.t += Node : int -> unit Effect.t

let seq_of_doc doc : int Seq.t =
 fun () ->
  match_with
    (fun () -> Docs.iter_nodes (fun t -> perform (Node t)) doc)
    ()
    {
      retc = (fun () -> Seq.Nil);
      exnc = raise;
      effc =
        (fun (type a) (e : a Effect.t) ->
          match e with
          | Node t -> Some (fun (k : (a, int Seq.node) continuation) -> Seq.Cons (t, fun () -> continue k ()))
          | _ -> None);
    }

let array_of_doc doc =
  let l = ref [] in
  Docs.iter_nodes (fun t -> l := t :: !l) doc;
  Array.of_list (List.rev !l)

(* Structural similarity of a and b: hash of positions whose node tags agree,
   plus the length difference. *)
let zip_score_seq a b =
  let rec go h i sa sb =
    match sa (), sb () with
    | Seq.Cons (x, sa'), Seq.Cons (y, sb') ->
        let h = spin (if x = y then Hash.int h i else h) in
        go h (i + 1) sa' sb'
    | Seq.Nil, Seq.Nil -> Hash.int h i
    | Seq.Nil, Seq.Cons _ | Seq.Cons _, Seq.Nil -> Hash.int h (-i)
  in
  go Hash.init 0 a b

let zip_score_arrays a b =
  let n = min (Array.length a) (Array.length b) in
  let h = ref Hash.init in
  for i = 0 to n - 1 do
    h := spin (if a.(i) = b.(i) then Hash.int !h i else !h)
  done;
  if Array.length a = Array.length b then Hash.int !h n else Hash.int !h (-n)

let generator ~variant parsed =
  let n = Array.length parsed in
  let nodes = Array.fold_left (fun acc d -> acc + Array.length (array_of_doc d)) 0 parsed in
  let f =
    match variant with
    | `Effects ->
        fun () ->
          let h = ref 0 in
          for i = 0 to n - 1 do
            h := !h + zip_score_seq (seq_of_doc parsed.(i)) (seq_of_doc parsed.((i + 1) mod n))
          done;
          !h land 0x3fffffff
    | `Direct ->
        fun () ->
          let h = ref 0 in
          for i = 0 to n - 1 do
            h := !h + zip_score_arrays (array_of_doc parsed.(i)) (array_of_doc parsed.((i + 1) mod n))
          done;
          !h land 0x3fffffff
  in
  (* each node of each doc is visited twice; one perform + one continue each *)
  f, [ "nodes", nodes; "switches", 2 * 2 * nodes ]

(* ---- pipeline: parse -> render -> index stages as Eio fibers. ---- *)

let chunks ~chunk docs =
  if chunk <= 0 then docs
  else
    Array.of_list
      (List.concat_map
         (fun d ->
           (* split at blank lines, then pack paragraphs up to ~chunk bytes *)
           let paras = String.split_on_char '\n' d in
           let acc = ref [] and cur = Buffer.create chunk in
           List.iter
             (fun line ->
               Buffer.add_string cur line;
               Buffer.add_char cur '\n';
               if line = "" && Buffer.length cur >= chunk then (
                 acc := Buffer.contents cur :: !acc;
                 Buffer.clear cur))
             paras;
           if Buffer.length cur > 0 then acc := Buffer.contents cur :: !acc;
           List.rev !acc)
         (Array.to_list docs))

let pipeline ~variant items =
  let q = Bench.int_param "q" 0 in
  let n = Array.length items in
  let f =
    match variant with
    | `Effects ->
        fun () ->
          Eio_mock.Backend.run @@ fun () ->
          Eio.Switch.run @@ fun sw ->
          let s1 = Eio.Stream.create q and s2 = Eio.Stream.create q and s3 = Eio.Stream.create q in
          Eio.Fiber.fork ~sw (fun () ->
              Array.iteri (fun i src -> Eio.Stream.add s1 (Some (i, src))) items;
              Eio.Stream.add s1 None);
          Eio.Fiber.fork ~sw (fun () ->
              let rec loop () =
                match Eio.Stream.take s1 with
                | None -> Eio.Stream.add s2 None
                | Some (i, src) ->
                    Eio.Stream.add s2 (Some (i, Docs.parse src));
                    loop ()
              in
              loop ());
          Eio.Fiber.fork ~sw (fun () ->
              let rec loop () =
                match Eio.Stream.take s2 with
                | None -> Eio.Stream.add s3 None
                | Some (i, doc) ->
                    let html = Docs.render doc in
                    Eio.Stream.add s3 (Some (i, spin (Hash.string Hash.init html), Docs.text doc));
                    loop ()
              in
              loop ());
          let index = Docs.Index.create () in
          let rec loop h =
            match Eio.Stream.take s3 with
            | None -> h
            | Some (i, hh, text) ->
                Docs.Index.add index ~id:i text;
                loop (h + hh)
          in
          let h = loop 0 in
          (h + Docs.Index.checksum index) land 0x3fffffff
    | `Direct ->
        fun () ->
          let index = Docs.Index.create () in
          let h = ref 0 in
          Array.iteri
            (fun i src ->
              let doc = Docs.parse src in
              let html = Docs.render doc in
              let hh = spin (Hash.string Hash.init html) in
              Docs.Index.add index ~id:i (Docs.text doc);
              h := !h + hh)
            items;
          (!h + Docs.Index.checksum index) land 0x3fffffff
  in
  f, [ "items", n; "stages", 4; "q", q ]

(* ---- fibers: many short-lived fibers that yield often. ---- *)

let fibers ~variant () =
  let nf = Bench.int_param "fibers" 1000 and ny = Bench.int_param "yields" 100 in
  let body id step = spin (Hash.int (Hash.int Hash.init id) step) in
  let f =
    match variant with
    | `Effects ->
        fun () ->
          Eio_mock.Backend.run @@ fun () ->
          let total = ref 0 in
          Eio.Switch.run (fun sw ->
              for id = 1 to nf do
                Eio.Fiber.fork ~sw (fun () ->
                    let h = ref 0 in
                    for step = 1 to ny do
                      h := !h + body id step;
                      Eio.Fiber.yield ()
                    done;
                    total := !total + !h)
              done);
          !total land 0x3fffffff
    | `Direct ->
        fun () ->
          let total = ref 0 in
          for id = 1 to nf do
            let h = ref 0 in
            for step = 1 to ny do
              h := !h + body id step
            done;
            total := !total + !h
          done;
          !total land 0x3fffffff
  in
  f, [ "fibers", nf; "yields", nf * ny ]

(* ---- deep: performs handled many handlers up (reperform at each level). ---- *)

type _ Effect.t += Ask : int -> int Effect.t

let deep ~variant () =
  let depth = Bench.int_param "depth" 20 and performs = Bench.int_param "performs" 20000 in
  let value lvl = (lvl * 7) + 1 in
  let body () =
    let h = ref 0 in
    for i = 1 to performs do
      (* alternate between the outermost and the middle handler *)
      let lvl = if i land 1 = 0 then 0 else depth / 2 in
      h := spin (Hash.int !h (perform (Ask lvl)))
    done;
    !h
  in
  let rec nest lvl =
    if lvl = depth then body ()
    else
      try_with nest (lvl + 1)
        {
          effc =
            (fun (type a) (e : a Effect.t) ->
              match e with
              | Ask l when l = lvl -> Some (fun (k : (a, _) continuation) -> continue k (value lvl))
              | _ -> None);
        }
  in
  let f =
    match variant with
    | `Effects -> fun () -> nest 0
    | `Direct ->
        fun () ->
          let h = ref 0 in
          for i = 1 to performs do
            let lvl = if i land 1 = 0 then 0 else depth / 2 in
            h := spin (Hash.int !h (value lvl))
          done;
          !h
  in
  f, [ "depth", depth; "performs", performs ]

let () =
  Bench.guard @@ fun () ->
  let docs = Lazy.force Bench.docs in
  let test = Bench.param "test" "all" and variant = Bench.param "variant" "both" in
  let warmup = Bench.int_param "warmup" 3 and iters = Bench.int_param "iters" 10 in
  let parsed = lazy (Array.map Docs.parse docs) in
  let items = lazy (chunks ~chunk:(Bench.int_param "chunk" 0) docs) in
  let tests =
    [
      ("generator", fun variant -> generator ~variant (Lazy.force parsed));
      ("pipeline", fun variant -> pipeline ~variant (Lazy.force items));
      ("fibers", fun variant -> fibers ~variant ());
      ("deep", fun variant -> deep ~variant ());
    ]
  in
  let tests = if test = "all" then tests else List.filter (fun (n, _) -> n = test) tests in
  if tests = [] then failwith ("unknown test " ^ test);
  let variants =
    match variant with
    | "both" when not Mode.has_effects -> [ `Direct ]  (* --effects=disabled build *)
    | "both" -> [ `Effects; `Direct ]
    | "effects" -> [ `Effects ]
    | "direct" -> [ `Direct ]
    | v -> failwith ("unknown variant " ^ v)
  in
  let results =
    List.concat_map
      (fun (name, mk) ->
        List.map
          (fun v ->
            let f, counters = mk v in
            let variant = match v with `Effects -> "effects" | `Direct -> "direct" in
            Bench.measure ~test:name ~variant ~warmup ~iters ~counters:(fun () -> counters) f)
          variants)
      tests
  in
  (* the effects and direct twins must agree *)
  List.iter
    (fun (name, _) ->
      match List.filter (fun r -> r.Bench.test = name) results with
      | [ a; b ] when a.Bench.checksum <> b.Bench.checksum ->
          failwith (Printf.sprintf "%s: effects/direct checksum mismatch %d vs %d" name a.checksum b.checksum)
      | _ -> ())
    tests;
  Bench.report ~workload:"switch" results
