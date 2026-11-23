(* The docs reader's search plugin: a separately compiled wasm_of_ocaml
   program that the app loads lazily on first search (code splitting). It is
   deliberately the big one: Unicode-correct search pulls in uucp's property
   tables and uunf's normalization data.

   API installed on globalThis.__search:
     add(id, text)   index a document
     query(q)        JS array of matching ids, ascending
     count()         number of distinct terms
   and globalThis.__searchReady() is called once it is installed. *)

open Js_of_ocaml

(* NFKC_Casefold (Unicode's recommended identifier/search folding), with
   terms split at anything that is not a letter, mark or number by
   general category. Input is NFC-normalized first. *)
let is_term_char u =
  match Uucp.Gc.general_category u with
  | `Lu | `Ll | `Lt | `Lm | `Lo | `Mn | `Mc | `Me | `Nd | `Nl | `No -> true
  | _ -> false

let iter_terms f s =
  let s = Uunf_string.normalize_utf_8 `NFC s in
  let b = Buffer.create 32 in
  let flush () =
    if Buffer.length b >= 2 then f (Buffer.contents b);
    Buffer.clear b
  in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let d = String.get_utf_8_uchar s !i in
    let u = Uchar.utf_decode_uchar d in
    i := !i + Uchar.utf_decode_length d;
    if is_term_char u then
      match Uucp.Case.Nfkc_fold.fold u with
      | `Self -> Buffer.add_utf_8_uchar b u
      | `Uchars us -> List.iter (Buffer.add_utf_8_uchar b) us
    else flush ()
  done;
  flush ()

let postings : (string, int list) Hashtbl.t = Hashtbl.create 65536

let add id text =
  iter_terms
    (fun t ->
      match Hashtbl.find_opt postings t with
      | Some (id' :: _) when id' = id -> ()
      | Some l -> Hashtbl.replace postings t (id :: l)
      | None -> Hashtbl.add postings t [ id ])
    text

let query q =
  let lists = ref [] in
  iter_terms (fun t -> lists := (try Hashtbl.find postings t with Not_found -> []) :: !lists) q;
  match !lists with
  | [] -> []
  | l :: rest -> List.filter (fun id -> List.for_all (List.mem id) rest) (List.sort_uniq compare l)

let () =
  let num i = Js.number_of_float (float i) in
  let api =
    Js.Unsafe.obj
      [|
        ( "add",
          Js.Unsafe.inject
            (Js.wrap_callback (fun id text ->
                 add (int_of_float (Js.float_of_number id)) (Js.to_string text))) );
        ( "query",
          Js.Unsafe.inject
            (Js.wrap_callback (fun q ->
                 Js.array (Array.of_list (List.map num (query (Js.to_string q)))))) );
        ("count", Js.Unsafe.inject (Js.wrap_callback (fun () -> num (Hashtbl.length postings))));
        ("reset", Js.Unsafe.inject (Js.wrap_callback (fun () -> Hashtbl.reset postings)));
      |]
  in
  Js.Unsafe.set Js.Unsafe.global "__search" api;
  let ready = Js.Unsafe.get Js.Unsafe.global "__searchReady" in
  if Js.Optdef.test (Obj.magic ready : _ Js.Optdef.t) then ignore (Js.Unsafe.fun_call ready [||])
