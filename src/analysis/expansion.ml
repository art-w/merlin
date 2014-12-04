open Std

type t = Trie of (string * Longident.t * t list lazy_t)

let rec explore_node lident env =
  let add_module name _ _ l =
    let lident = Longident.Ldot (lident, name) in
    Trie (name, lident, lazy (explore_node lident env)) :: l
  in
  Env.fold_modules add_module (Some lident) env []

let explore env =
  let add_module name _ _ l =
    let lident = Longident.Lident name in
    Trie (name, lident, lazy (explore_node lident env)) :: l
  in
  Env.fold_modules add_module None env []

let regex_of_path_prefix pattern =
  let buf = Buffer.create 16 in
  let tmp = String.create 1 in
  Buffer.add_char buf '^';
  for i = 0 to String.length pattern - 1 do
    match pattern.[i] with
    | '*' -> Buffer.add_string buf ".*"
    | '_' -> Buffer.add_string buf ".*_"
    | c when Char.is_strictly_uppercase c && i > 0 &&
             Char.is_strictly_uppercase pattern.[i-1] ->
      Buffer.add_string buf ".*";
      Buffer.add_char buf c
    | c when Char.is_strictly_uppercase c || Char.is_strictly_lowercase c ->
      Buffer.add_char buf c
    | c ->
      tmp.[0] <- c;
      Buffer.add_string buf (Str.quote tmp)
  done;
  Buffer.contents buf

(*let regex_of_path_pattern pattern =
  regex_of_path_prefix pattern ^ "$"*)

let filter path ts =
  let path = List.map regex_of_path_prefix path in
  let path = List.map Str.regexp path in
  let rec aux_ts ts = function
    | [] -> []
    | p0 :: ps -> List.filter_map ~f:(aux_t p0 ps) ts
  and aux_t p0 ps (Trie (name, ident, ts)) =
    if Str.string_match p0 name 0 then
      Some (Trie (name, ident, lazy (aux_ts (Lazy.force ts) ps)))
    else
      None
  in
  aux_ts ts path

let rec to_lidents acc = function
  | Trie (_, lident, lazy []) :: ts ->
    to_lidents (lident :: acc) ts
  | Trie (_, _, lazy ts') :: ts ->
    to_lidents (to_lidents acc ts') ts
  | [] -> acc

let to_lidents ts = to_lidents [] ts

let get_lidents env path =
  let open Longident in
  let lident = parse path in
  let lident, last = match lident with
    | Ldot (l, id) -> l, id
    | Lident id -> Lident "", id
    | Lapply _ -> assert false
  in
  let rec components acc = function
    | Lident "" -> acc
    | Lident id -> id :: acc
    | Lapply _ -> assert false
    | Ldot (l, id) -> components (id :: acc) l
  in
  let components = components [] lident in
  let ts = explore env in
  let ts = filter components ts in
  let lidents = match to_lidents ts with
    | [] -> [None]
    | xs -> List.map (fun x -> Some x) xs
  in
  lidents, last
