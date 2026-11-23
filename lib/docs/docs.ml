(* The real work every workload does per document: CommonMark parsing and
   HTML rendering with cmarkit, tokenizing, and inverted indexing. All of it
   is deterministic, so checksums match across modes and engines. *)

open Cmarkit

let parse s = Doc.of_string ~strict:false s
let render doc = Cmarkit_html.of_doc ~safe:true doc

(* One integer per AST node: constructor tag, plus text length for leaves.
   Used by the generator benchmark and for checksums. *)
let block_tag : Block.t -> int = function
  | Block.Blank_line _ -> 1
  | Block.Block_quote _ -> 2
  | Block.Blocks _ -> 3
  | Block.Code_block (c, _) ->
      4 + (16 * List.length (Block.Code_block.code c))
  | Block.Heading (h, _) -> 5 + (16 * Block.Heading.level h)
  | Block.Html_block (l, _) -> 6 + (16 * List.length l)
  | Block.Link_reference_definition _ -> 7
  | Block.List _ -> 8
  | Block.Paragraph _ -> 10
  | Block.Thematic_break _ -> 11
  | _ -> 12

let inline_tag : Inline.t -> int = function
  | Inline.Autolink _ -> 1
  | Inline.Break _ -> 2
  | Inline.Code_span _ -> 3
  | Inline.Emphasis _ -> 4
  | Inline.Image _ -> 5
  | Inline.Inlines _ -> 6
  | Inline.Link _ -> 7
  | Inline.Raw_html _ -> 8
  | Inline.Strong_emphasis _ -> 9
  | Inline.Text (s, _) -> 10 + (16 * String.length s)
  | _ -> 11

(* Call [f] on every node in document order. *)
let iter_nodes f doc =
  let folder =
    Folder.make
      ~block:(fun _ () b ->
        f (block_tag b);
        Folder.default)
      ~inline:(fun _ () i ->
        f (inline_tag i);
        Folder.default)
      ()
  in
  Folder.fold_doc folder () doc

(* Plain text of a document, for indexing. *)
let text doc =
  let b = Buffer.create 1024 in
  let folder =
    Folder.make
      ~inline:(fun _ () -> function
        | Inline.Text (s, _) ->
            Buffer.add_string b s;
            Buffer.add_char b ' ';
            Folder.default
        | _ -> Folder.default)
      ()
  in
  Folder.fold_doc folder () doc;
  Buffer.contents b

(* Lowercased ASCII alphanumeric tokens of length >= 2. *)
let iter_tokens f s =
  let n = String.length s in
  let b = Buffer.create 32 in
  let flush () =
    if Buffer.length b >= 2 then f (Buffer.contents b);
    Buffer.clear b
  in
  for i = 0 to n - 1 do
    match String.unsafe_get s i with
    | ('a' .. 'z' | '0' .. '9') as c -> Buffer.add_char b c
    | 'A' .. 'Z' as c -> Buffer.add_char b (Char.lowercase_ascii c)
    | _ -> flush ()
  done;
  flush ()

module Index = struct
  type t = { postings : (string, int list) Hashtbl.t; mutable docs : int }

  let create () = { postings = Hashtbl.create 4096; docs = 0 }

  let add t ~id text =
    t.docs <- t.docs + 1;
    iter_tokens
      (fun tok ->
        match Hashtbl.find_opt t.postings tok with
        | Some (id' :: _) when id' = id -> ()
        | Some l -> Hashtbl.replace t.postings tok (id :: l)
        | None -> Hashtbl.add t.postings tok [ id ])
      text

  (* Documents containing every query token, ascending. *)
  let query t q =
    let lists = ref [] in
    iter_tokens
      (fun tok ->
        lists := (try Hashtbl.find t.postings tok with Not_found -> []) :: !lists)
      q;
    match !lists with
    | [] -> []
    | l :: rest ->
        List.filter (fun id -> List.for_all (List.mem id) rest) (List.sort_uniq compare l)

  (* Order-independent: the same set of postings gives the same value. *)
  let checksum t =
    Hashtbl.fold
      (fun tok ids acc ->
        let h = List.fold_left Hash.int (Hash.string Hash.init tok) (List.sort compare ids) in
        acc + h)
      t.postings 0
    land 0x3fffffff
end

(* Everything the app and the pipeline do to one document. Returns a checksum
   of the rendered HTML. *)
let process ~index ~id src =
  let doc = parse src in
  let html = render doc in
  Index.add index ~id (text doc);
  Hash.string Hash.init html
