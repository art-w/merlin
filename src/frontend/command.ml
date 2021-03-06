(* {{{ COPYING *(

  This file is part of Merlin, an helper for ocaml editors

  Copyright (C) 2013 - 2014  Frédéric Bour  <frederic.bour(_)lakaban.net>
                             Thomas Refis  <refis.thomas(_)gmail.com>
                             Simon Castellan  <simon.castellan(_)iuwt.fr>

  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the "Software"),
  to deal in the Software without restriction, including without limitation the
  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
  sell copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall
  the authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising
  from, out of or in connection with the software or the use or other dealings
  in the Software.

)* }}} *)

open Std
open Misc

open Protocol
open Merlin_lib

type state = {
  mutable buffer : Buffer.t;
  mutable lexer : Lexer.t option;
}

let new_state () =
  let buffer = Buffer.create Parser.implementation in
  {buffer; lexer = None}

let with_typer state f =
  Typer.with_typer (Buffer.typer state.buffer) f

let cursor_state state =
  let cursor, marker =
    match state.lexer with
    | None ->
      Lexer.item_end (snd (History.focused (Buffer.lexer state.buffer))),
      false
    | Some lexer ->
      Lexer.position lexer,
      Buffer.has_mark state.buffer (Lexer.get_mark lexer)
  in
  { cursor; marker }

let verbosity_last = ref None and verbosity_counter = ref 0

let track_verbosity =
  let classify (type a) (request : a request) =
    let obj = Some (Obj.repr request) in
    match request with
    | Type_expr _ -> obj
    | Type_enclosing _ -> obj
    | Enclosing _ -> obj
    | Complete_prefix _ -> obj
    | _ -> None in
  fun (type a) (request : a request) ->
    match classify request with
    | None -> 0
    | value when !verbosity_last = value ->
      incr verbosity_counter; !verbosity_counter
    | value ->
      verbosity_last := value; verbosity_counter := 0; 0

let buffer_changed state =
  state.lexer <- None

let buffer_update state items =
  if Buffer.update state.buffer items = `Updated then
    verbosity_last := None

let buffer_freeze state items =
  buffer_update state items;
  buffer_changed state

module Printtyp = Type_utils.Printtyp

let dispatch (state : state) =
  fun (type a) (request : a request) ->
  let verbosity = track_verbosity request in
  (match request with
  | (Tell (`Start pos) : a request) ->
    let lexer = Buffer.start_lexing ?pos state.buffer in
    state.lexer <- Some lexer;
    buffer_update state (Lexer.history lexer);
    cursor_state state

  | (Tell (`File _ | `Source _ | `Eof as source) : a request) ->
    let source = match source with
      | `Eof -> Some ""
      | `Source "" -> None
      | `Source source -> Some source
      | `File path ->
        match Misc.file_contents path with
        | "" -> None
        | source -> Some source
    in
    begin match source with
      | None -> cursor_state state
      | Some source ->
        let lexer = match state.lexer with
          | Some lexer ->
            assert (not (Lexer.eof lexer));
            lexer
          | None ->
            let lexer = Buffer.start_lexing state.buffer in
            state.lexer <- Some lexer; lexer in
        assert (Lexer.feed lexer source);
        buffer_update state (Lexer.history lexer);
        (* Stop lexer on EOF *)
        if Lexer.eof lexer then state.lexer <- None;
        cursor_state state
    end

  | (Tell `Marker : a request) ->
    let lexer = match state.lexer with
      | Some lexer ->
        assert (not (Lexer.eof lexer));
        lexer
      | None ->
        let lexer = Buffer.start_lexing state.buffer in
        state.lexer <- Some lexer; lexer
    in
    Lexer.put_mark lexer (Buffer.get_mark state.buffer);
    cursor_state state

  | (Type_expr (source, pos) : a request) ->
    with_typer state (
      fun typer ->
        let env = match pos with
          | None -> Typer.env typer
          | Some pos -> (Completion.node_at typer pos).BrowseT.t_env
        in
        let ppf, to_string = Format.to_string () in
        ignore (Type_utils.type_in_env ~verbosity env ppf source : bool);
        to_string ()
    )

  | (Type_enclosing (expro, pos) : a request) ->
    let (@@) f x = f x in
    let open BrowseT in
    let open Typedtree in
    let open Override in
    with_typer state @@ fun typer ->
    let structures = Typer.contents typer in
    let structures = Browse.of_typer_contents structures in
    let path = Browse.enclosing pos structures in
    let path = Browse.annotate_tail_calls_from_leaf path in
    let aux (t,tail) =
      let { t_loc ; t_env ; t_node ; _ } = t in
      match t_node with
      | Expression {exp_type = t}
      | Pattern {pat_type = t}
      | Core_type {ctyp_type = t}
      | Value_description { val_desc = { ctyp_type = t } } ->
        let ppf, to_string = Format.to_string () in
        Printtyp.wrap_printing_env t_env verbosity
          (fun () -> Printtyp.type_scheme t_env ppf t);
        Some (t_loc, to_string (), tail)

      | Type_declaration { typ_id = id; typ_type = t} ->
        let ppf, to_string = Format.to_string () in
        Printtyp.wrap_printing_env t_env verbosity
          (fun () -> Printtyp.type_declaration t_env id ppf t);
        Some (t_loc, to_string (), tail)

      | Module_expr {mod_type = m}
      | Module_type {mty_type = m}
      | Module_binding {mb_expr = {mod_type = m}}
      | Module_declaration {md_type = {mty_type = m}}
      | Module_type_declaration {mtd_type = Some {mty_type = m}}
      | Module_binding_name {mb_expr = {mod_type = m}}
      | Module_declaration_name {md_type = {mty_type = m}}
      | Module_type_declaration_name {mtd_type = Some {mty_type = m}} ->
        let ppf, to_string = Format.to_string () in
        Printtyp.wrap_printing_env t_env verbosity
          (fun () -> Printtyp.modtype t_env ppf m);
        Some (t_loc, to_string (), tail)

      | _ -> None
    in
    let result = List.filter_map ~f:aux path in
    (* enclosings of cursor in given expression *)
    let exprs =
      match expro with
      | None ->
        let lexer = Buffer.lexer state.buffer in
        let lexer =
          History.seek_backward
            (fun (_,item) -> Lexing.compare_pos pos (Lexer.item_start item) < 0)
            lexer
        in
        let path = Lexer.reconstruct_identifier lexer in
        let path = Lexer.identifier_suffix path in
        begin match path with
          | [] -> []
          | base :: tail ->
            [List.fold_left' ~f:(fun {Location. txt = dot; loc = dl}
                                  {Location. txt = base; loc = bl} ->
                                  let loc = Parsing_aux.location_union bl dl in
                                  let txt = base ^ "." ^ dot in
                                  Location.mkloc txt loc)
               ~init:base tail]
        end
      | Some (expr, offset) ->
        let loc_start =
          let l, c = Lexing.split_pos pos in
          Lexing.make_pos (l, c - offset)
        in
        let shift loc int =
          let l, c = Lexing.split_pos loc in
          Lexing.make_pos (l, c + int)
        in
        let add_loc source =
          let loc =
            { Location.
              loc_start ;
              loc_end = shift loc_start (String.length source) ;
              loc_ghost = false ;
            } in
          Location.mkloc source loc
        in
        let len = String.length expr in
        let rec aux acc i =
          if i >= len then
            List.rev_map ~f:add_loc (expr :: acc)
          else if expr.[i] = '.' then
            aux (String.sub expr ~pos:0 ~len:i :: acc) (succ i)
          else
            aux acc (succ i) in
        aux [] offset
    in
    let small_enclosings =
      let node = Completion.node_at typer pos in
      let env = node.BrowseT.t_env in
      let include_lident = match node.BrowseT.t_node with
        | BrowseT.Pattern _ -> false
        | _ -> true
      in
      let include_uident = match node.BrowseT.t_node with
        | BrowseT.Module_binding _
        | BrowseT.Module_binding_name _
        | BrowseT.Module_declaration _
        | BrowseT.Module_declaration_name _
        | BrowseT.Module_type_declaration _
        | BrowseT.Module_type_declaration_name _
          -> false
        | _ -> true
      in
      List.filter_map exprs ~f:(fun {Location. txt = source; loc} ->
          match source with
          | "" -> None
          | source when not include_lident && Char.is_lowercase source.[0] ->
            None
          | source when not include_uident && Char.is_uppercase source.[0] ->
            None
          | source ->
            try
              let ppf, to_string = Format.to_string () in
              if Type_utils.type_in_env ~verbosity env ppf source then
                Some (loc, to_string (), `No)
              else
                None
            with _ ->
              None
        )
    in
    let normalize ({Location. loc_start; loc_end}, text, _tail) =
        Lexing.split_pos loc_start, Lexing.split_pos loc_end, text in
    List.merge_cons
      ~f:(fun a b ->
          (* Tail position is computed only on result, and result comes last
             As an approximation, when two items are similar, we returns the
             rightmost one *)
          if normalize a = normalize b then Some b else None)
      (small_enclosings @ result)

  | (Enclosing pos : a request) ->
    with_typer state (
      fun typer ->
        let open BrowseT in
        let structures = Typer.contents typer in
        let structures = Browse.of_typer_contents structures in
        let path = Browse.enclosing pos structures in
        List.map (fun t -> t.BrowseT.t_loc) path
    )

  | (Complete_prefix (prefix, pos) : a request) ->
    with_typer state (
      fun typer ->
        let node = Completion.node_at typer pos in
        let compl = Completion.node_complete state.buffer node prefix in
        List.rev compl
    )

  | (Locate (patho, ml_or_mli, opt_pos) : a request) ->
    let env, local_defs =
      with_typer state (
        fun typer ->
          match opt_pos with
          | None     -> Typer.env typer, []
          | Some pos ->
            let node = Completion.node_at typer pos in
            node.BrowseT.t_env, Typer.contents typer
      )
    in
    let path =
      match patho, opt_pos with
      | None, None -> failwith "invalid arguments"
      | None, Some pos ->
        let lexer = Buffer.lexer state.buffer in
        let lexer =
          History.seek_backward (fun (_,item) ->
            Lexing.compare_pos pos (Lexer.item_start item) < 0) lexer
        in
        let path = Lexer.reconstruct_identifier ~for_locate:true lexer in
        let path = Lexer.identifier_suffix path in
        let path = List.map ~f:(fun {Location. txt} -> txt) path in
        let path = String.concat ~sep:"." path in
        path
      | Some path, _ -> path
    in
    let is_implementation = Buffer.is_implementation state.buffer in
    let project = Buffer.project state.buffer in
    begin match
      Track_definition.from_string ~project ~env ~local_defs ~is_implementation
        ?pos:opt_pos ml_or_mli path
    with
    | `Found (file, pos) ->
      Logger.info (Track_definition.section)
        (Option.value ~default:"<local buffer>" file);
      `Found (file, pos)
    | otherwise -> otherwise
    end

  | (Outline : a request) ->
    with_typer state (fun typer ->
      let typed_tree = Typer.contents typer in
      Outline.get (Browse.of_typer_contents typed_tree)
    )

  | (Drop : a request) ->
    let lexer = Buffer.lexer state.buffer in
    buffer_update state (History.drop_tail lexer);
    buffer_changed state;
    cursor_state state

  | (Seek `Position : a request) ->
    cursor_state state

  | (Seek (`Before pos) : a request) ->
    let items = Buffer.lexer state.buffer in
    (* true while i is before pos *)
    let until_after pos (_,i) =
      Lexing.compare_pos (Lexer.item_start i) pos < 0 in
    (* true while i is after pos *)
    let until_before pos (_,i) =
      Lexing.compare_pos (Lexer.item_start i) pos >= 0 in
    let items = History.seek_forward (until_after pos) items in
    let items = History.seek_backward (until_before pos) items in
    buffer_freeze state items;
    cursor_state state

  | (Seek (`Exact pos) : a request) ->
    let items = Buffer.lexer state.buffer in
    (* true while i is before pos *)
    let until_after pos (_,i) =
      Lexing.compare_pos (Lexer.item_start i) pos < 0 in
    (* true while i is after pos *)
    let until_before pos (_,i) =
      Lexing.compare_pos (Lexer.item_end i) pos > 0 in
    let items = History.seek_forward (until_after pos) items in
    let items = History.seek_backward (until_before pos) items in
    buffer_freeze state items;
    cursor_state state

  | (Seek `End : a request) ->
    let items = Buffer.lexer state.buffer in
    let items = History.seek_forward (fun _ -> true) items in
    buffer_freeze state items;
    cursor_state state

  | (Seek `Marker : a request) ->
    begin match Option.bind state.lexer ~f:Lexer.get_mark with
    | None -> ()
    | Some mark ->
      let recoveries = Buffer.recover_history state.buffer in
      let diff = ref None in
      let check_item (lex_item,recovery) =
        let parser = Recover.parser recovery in
        let result = Parser.has_marker ?diff:!diff parser mark in
        diff := Some (parser,result);
        not result
      in
      if check_item (History.focused recoveries) then
        let recoveries = History.move (-1) recoveries in
        let recoveries = History.seek_backward check_item recoveries in
        let recoveries = History.move 1 recoveries in
        let item, _ = History.focused recoveries in
        let items = Buffer.lexer state.buffer in
        let items = History.seek_backward (fun (_,item') -> item' != item) items in
        buffer_freeze state items;
    end;
    cursor_state state

  | (Boundary (dir,pos) : a request) ->
    let get_enclosing_str_item pos browses =
      let enclosings = Browse.enclosing pos browses in
      match
        List.drop_while enclosings ~f:(fun t ->
          match t.BrowseT.t_node with
          | BrowseT.Structure_item _
          | BrowseT.Signature_item _ -> false
          | _ -> true
        )
      with
      | [] -> None
      | item :: _ -> Some item
    in
    with_typer state (fun typer ->
      let browses  = Browse.of_typer_contents (Typer.contents typer) in
      Option.bind (get_enclosing_str_item pos browses) ~f:(fun item ->
        match dir with
        | `Current -> Some item.BrowseT.t_loc
        | `Prev ->
          let pos = item.BrowseT.t_loc.Location.loc_start in
          let pos = Lexing.({ pos with pos_cnum = pos.pos_cnum - 1 }) in
          let item= get_enclosing_str_item pos browses in
          Option.map item ~f:(fun i -> i.BrowseT.t_loc)
        | `Next ->
          let pos = item.BrowseT.t_loc.Location.loc_end in
          let pos = Lexing.({ pos with pos_cnum = pos.pos_cnum + 1 }) in
          let item= get_enclosing_str_item pos browses in
          Option.map item ~f:(fun i -> i.BrowseT.t_loc)
      )
    )

  | (Reset (ml,path) : a request) ->
    let parser = match ml, path with
      | `ML, _  -> Raw_parser.implementation_state
      | `MLI, _ -> Raw_parser.interface_state
      | `Auto, Some path when Filename.check_suffix path ".mli" ->
        Raw_parser.interface_state
      | `Auto, _ -> Raw_parser.implementation_state
    in
    let buffer = Buffer.create ?path parser in
    buffer_changed state;
    state.buffer <- buffer;
    cursor_state state

  | (Refresh : a request) ->
    Project.invalidate ~flush:true (Buffer.project state.buffer)

  | (Errors : a request) ->
    begin try
        let cmp (l1,_) (l2,_) =
          Lexing.compare_pos l1.Location.loc_start l2.Location.loc_start in
        let err exns =
          List.sort_uniq ~cmp (List.map ~f:Error_report.of_exn exns)
        in
        let err_lexer  = err (Buffer.lexer_errors state.buffer) in
        let err_parser = err (Buffer.parser_errors state.buffer) in
        let err_typer  =
          (* When there is a cmi error, we will have a lot of meaningless errors,
           * there is no need to report them. *)
          let exns = Typer.exns (Buffer.typer state.buffer) in
          let exns =
            let cmi_error = function Cmi_format.Error _ -> true | _ -> false in
            try [ List.find exns ~f:cmi_error ]
            with Not_found -> exns
          in
          err exns
        in
        (* Return parsing warnings & first parsing error,
           or type errors if no parsing errors *)
        let rec extract_warnings acc = function
          | (_,{Error_report. where = "warning"; _ }) as err :: errs ->
            extract_warnings (err :: acc) errs
          | err :: _ ->
            List.rev (err :: acc),
            List.take_while ~f:(fun err' -> cmp err' err < 0) err_typer
          | [] ->
            List.rev acc, err_typer in
        let err_parser, err_typer = extract_warnings [] err_parser in
        List.(map ~f:snd (merge ~cmp err_lexer (merge ~cmp err_parser err_typer)))
      with exn -> match Error_report.strict_of_exn exn with
        | None -> raise exn
        | Some (_loc, err) -> [err]
    end

  | (Dump `Parser : a request) ->
    Merlin_recover.dump (Buffer.recover state.buffer);

  | (Dump `Typer_input : a request) ->
    with_typer state (fun typer ->
      let ppf, to_string = Format.to_string () in
      Typer.dump ppf typer;
      `String (to_string ())
    )

  | (Dump `Recover : a request) ->
    Merlin_recover.dump_recoverable (Buffer.recover state.buffer);

  | (Dump (`Env (kind, pos)) : a request) ->
    let (@@) f x = f x in
    with_typer state @@ fun typer ->
    let env = match pos with
      | None -> Typer.env typer
      | Some pos -> (Completion.node_at typer pos).BrowseT.t_env
    in
    let sg = Browse_misc.signature_of_env ~ignore_extensions:(kind = `Normal) env in
    let aux item =
      let ppf, to_string = Format.to_string () in
      Printtyp.signature ppf [item];
      let content = to_string () in
      let ppf, to_string = Format.to_string () in
      match Merlin_types_custom.signature_loc item with
      | Some loc ->
        Location.print_loc ppf loc;
        let loc = to_string () in
        `List [`String loc ; `String content]
      | None -> `String content
    in
    `List (List.map ~f:aux sg)

  | (Dump `Browse : a request) ->
    with_typer state (fun typer ->
      let structures = Typer.contents typer in
      let structures = Browse.of_typer_contents structures in
      Browse_misc.dump_ts structures
    )

  | (Dump `Tokens : a request) ->
    let tokens = Buffer.lexer state.buffer in
    let tokens = History.seek_backward (fun _ -> true) tokens in
    let tokens = History.tail tokens in
    `List (List.filter_map tokens
             ~f:(fun (_exns,item) -> match item with
             | Lexer.Error _ -> None
             | Lexer.Valid (s,t,e) ->
               let t = Raw_parser_values.symbol_of_token t in
               let t = Raw_parser_values.class_of_symbol t in
               let t = Raw_parser_values.string_of_class t in
               Some (`Assoc [
                   "start", Lexing.json_of_position s;
                   "end", Lexing.json_of_position e;
                   "token", `String t;
                 ])
             )
          )

  | (Dump _ : a request) ->
    failwith "TODO"

  | (Which_path xs : a request) ->
    begin
      let project = Buffer.project state.buffer in
      let rec aux = function
        | [] -> raise Not_found
        | x :: xs ->
          try
            find_in_path_uncap (Project.source_path project) x
          with Not_found -> try
            find_in_path_uncap (Project.build_path project) x
          with Not_found ->
            aux xs
      in
      aux xs
    end

  | (Which_with_ext exts : a request) ->
    let project = Buffer.project state.buffer in
    let path = Path_list.to_strict_list (Project.source_path project) in
    let with_ext ext = modules_in_path ~ext path in
    List.concat_map ~f:with_ext exts

  | (Flags (`Add flags) : a request) ->
    let project = Buffer.project state.buffer in
    Merlin_lib.Project.User.add_flags project flags

  | (Flags `Clear : a request) ->
    let project = Buffer.project state.buffer in
    Merlin_lib.Project.User.clear_flags project

  | (Project_get : a request) ->
    let project = Buffer.project state.buffer in
    (List.map ~f:fst (Project.get_dot_merlins project),
     match Project.get_dot_merlins_failure project with
     | [] -> `Ok
     | failures -> `Failures failures)

  | (Findlib_list : a request) ->
    Fl_package_base.list_packages ()

  | (Findlib_use packages : a request) ->
    let project = Buffer.project state.buffer in
    Project.User.load_packages project packages

  | (Extension_list kind : a request) ->
    let project = Buffer.project state.buffer in
    let enabled = Project.extensions project in
    let set = match kind with
      | `All -> Extension.all
      | `Enabled -> enabled
      | `Disabled -> String.Set.diff Extension.all enabled
    in
    String.Set.to_list set

  | (Extension_set (action,exts) : a request) ->
    let enabled = match action with
      | `Enabled  -> true
      | `Disabled -> false
    in
    let project = Buffer.project state.buffer in
    begin match
      List.filter_map exts ~f:(Project.User.set_extension project ~enabled)
    with
    | [] -> `Ok
    | lst -> `Failures lst
    end

  | (Path (var,action,pathes) : a request) ->
    let project = Buffer.project state.buffer in
    List.iter pathes
      ~f:(Project.User.path project ~action ~var ?cwd:None)

  | (Path_list `Build : a request) ->
    let project = Buffer.project state.buffer in
    Path_list.to_strict_list (Project.build_path project)

  | (Path_list `Source : a request) ->
    let project = Buffer.project state.buffer in
    Path_list.to_strict_list (Project.source_path project)

  | (Path_reset : a request) ->
    let project = Buffer.project state.buffer in
    Project.User.reset project

  | (Occurrences (`Ident_at pos) : a request) ->
    let (@@) f x = f x in
    with_typer state @@ fun typer ->
    let str = Typer.contents typer in
    let str = Browse.of_typer_contents str in
    let node = match Browse.enclosing pos str with
      | node :: _ -> node
      | [] -> BrowseT.dummy
    in
    let get_loc {Location.txt = _; loc} = loc in
    let ident_occurrence () =
      let paths =
        match node.BrowseT.t_node with
        | BrowseT.Expression e -> BrowseT.expression_paths e
        | BrowseT.Pattern p -> BrowseT.pattern_paths p
        | _ -> []
      in
      let under_cursor p = Parsing_aux.compare_pos pos (get_loc p) = 0 in
      Logger.infojf (Logger.section "occurences") ~title:"Occurrences paths"
        (fun paths ->
          let dump_path ({Location.txt; loc} as p) =
            let ppf, to_string = Format.to_string () in
            Printtyp.path ppf txt;
            `Assoc [
              "start", Lexing.json_of_position loc.Location.loc_start;
              "end", Lexing.json_of_position loc.Location.loc_end;
              "under_cursor", `Bool (under_cursor p);
              "path", `String (to_string ())
            ]
          in
          `List (List.map ~f:dump_path paths)
        ) paths;
      match List.filter paths ~f:under_cursor with
      | [] -> []
      | (path :: _) ->
        let path = path.Location.txt in
        let ts = List.concat_map ~f:(Browse.all_occurrences path) str in
        let loc (_t,paths) = List.map ~f:get_loc paths in
        List.concat_map ~f:loc ts

    and constructor_occurrence d =
      let ts = List.concat_map str
          ~f:(Browse.all_constructor_occurrences (node,d)) in
      List.map ~f:get_loc ts

    in
    let locs = match BrowseT.is_constructor node with
      | Some d -> constructor_occurrence d.Location.txt
      | None -> ident_occurrence ()
    in
    let loc_start l = l.Location.loc_start in
    let cmp l1 l2 = Lexing.compare_pos (loc_start l1) (loc_start l2) in
    List.sort ~cmp locs

  | (Version : a request) ->
    Main_args.version_spec

  : a)
