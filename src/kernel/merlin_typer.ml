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

let caught catch =
  let caught = !catch in
  catch := [];
  caught

let rec last_env t =
  let rec last candidate = function
    | [] -> candidate
    | x :: xs ->
      last (if Lexing.compare_pos
               x.BrowseT.t_loc.Location.loc_start
               candidate.BrowseT.t_loc.Location.loc_start
               > 0
            then x
            else candidate)
        xs
  in
  let t' = last t (Lazy.force t.BrowseT.t_children) in
  if t == t' then
    t'
  else
    last_env t'

module P = struct

  open Raw_parser

  type st = Extension.set * exn list ref

  type t = {
    raw        : Raw_typer.t;
    snapshot   : Btype.snapshot;
    env        : Env.t;
    contents   : [`Str of Typedtree.structure | `Sg of Typedtree.signature] list;
    exns       : exn list;
  }

  let empty (extensions,catch) =
    let env = Raw_typer.fresh_env () in
    let env = Env.open_pers_signature "Pervasives" env in
    let env = Extension.register extensions env in
    let raw = Raw_typer.empty in
    let exns = caught catch in
    let snapshot = Btype.snapshot () in
    { raw; snapshot; env; contents = []; exns }

  let validate _ t = Btype.is_valid t.snapshot

  let append catch loc item t =
    try
      Btype.backtrack t.snapshot;
      let env, contents =
        match item with
        | `str str ->
          let structure,_,env = Typemod.type_structure t.env str loc in
          env, `Str structure :: t.contents
        | `sg sg ->
          let sg = Typemod.transl_signature t.env sg in
          sg.Typedtree.sig_final_env, `Sg sg :: t.contents
        | `fake str ->
          let structure,_,_ =
            Parsing_aux.catch_warnings (ref [])
              (fun () -> Typemod.type_structure t.env str loc)
          in
          let browse =
            BrowseT.of_node ~loc ~env:t.env (BrowseT.Structure structure)
          in
          (last_env browse).BrowseT.t_env, `Str structure :: t.contents
        | `none -> t.env, t.contents
      in
      Typecore.reset_delayed_checks ();
      {env; contents; snapshot = Btype.snapshot (); raw = t.raw;
       exns = caught catch @ t.exns}
    with exn ->
      Typecore.reset_delayed_checks ();
      let snapshot = Btype.snapshot () in
      {t with snapshot; exns = exn :: caught catch @ t.exns}

  let rewrite_raw loc = function
    | Raw_typer.Functor_argument (id,mty) ->
      let mexpr = Ast_helper.Mod.structure ~loc [] in
      let mexpr = Ast_helper.Mod.functor_ ~loc id mty mexpr in
      let mb = Ast_helper.Mb.mk (Location.mknoloc "") mexpr in
      `fake (Ast_helper.Str.module_ ~loc mb)
    | Raw_typer.Pattern (l,o,p) ->
      let expr = Ast_helper.Exp.constant ~loc (Asttypes.Const_int 0) in
      let expr = Ast_helper.Exp.fun_ ~loc l o p expr in
      `fake (Ast_helper.Str.eval ~loc expr)
    | Raw_typer.Newtype s ->
      let expr = Ast_helper.Exp.constant (Asttypes.Const_int 0) in
      let patt = Ast_helper.Pat.any () in
      let expr = Ast_helper.Exp.fun_ "" None patt expr in
      let expr = Ast_helper.Exp.newtype ~loc s expr in
      `fake (Ast_helper.Str.eval ~loc expr)
    | Raw_typer.Bindings (rec_,e) ->
      `str [Ast_helper.Str.value ~loc rec_ e]
    | Raw_typer.Open (override,name) ->
      let od = Ast_helper.Opn.mk ~override name in
      `str [Ast_helper.Str.open_ ~loc od]
    | Raw_typer.Eval e ->
      `str [Ast_helper.Str.eval ~loc e]
    | Raw_typer.Structure str ->
      `str str
    | Raw_typer.Signature sg ->
      `sg sg

  let rewrite_ppx = function
    | `str str -> `str (Pparse.apply_rewriters_str ~tool_name:"merlin" str)
    | `sg sg -> `sg (Pparse.apply_rewriters_sig ~tool_name:"merlin" sg)
    | `fake str -> `str (Pparse.apply_rewriters_str ~tool_name:"merlin" [str])

  let rewrite loc raw = rewrite_ppx (rewrite_raw loc raw)

  let frame (_,catch) f t =
    let module Frame = Merlin_parser.Frame in
    let loc = Frame.location f in
    let raw = Raw_typer.step (Frame.value f) t.raw in
    let t = {t with raw} in
    let items = Raw_typer.observe t.raw in
    let items = List.map ~f:(rewrite loc) items in
    let t = List.fold_left' ~f:(append catch loc) items ~init:t in
    t

  let delta st f t ~old:_ = frame st f t

  let evict st _ = ()

end

module I = Merlin_parser.Integrate (P)

type state = {
  btype_cache : Btype.cache;
  env_cache   : Env.cache;
  ast_cache   : Ast_mapper.cache; (* PPX cookies *)
  extensions  : Extension.set;
  stamp : bool ref list;
}

type t = {
  state : state;
  typer : I.t;
}

let fluid_btype = Fluid.from_ref Btype.cache
let fluid_env = Fluid.from_ref Env.cache
let fluid_ast = Fluid.from_ref Ast_mapper.cache

let protect_typer ~btype_cache ~env_cache ~ast_cache f =
  let caught = ref [] in
  let (>>=) f x = f x in
  Fluid.let' fluid_btype btype_cache >>= fun () ->
  Fluid.let' fluid_env env_cache >>= fun () ->
  Fluid.let' fluid_ast ast_cache >>= fun () ->
  Either.join (Parsing_aux.catch_warnings caught >>= fun () ->
               Typing_aux.catch_errors caught >>= fun () ->
               f caught)

let fresh ~unit_name ~stamp extensions =
  let btype_cache = Btype.new_cache () in
  let env_cache = Env.new_cache ~unit_name in
  let ast_cache = Ast_mapper.new_cache () in
  let result = protect_typer ~btype_cache ~env_cache ~ast_cache
      (fun exns -> Either.try' (fun () -> I.empty (extensions,exns))) in
  let state = { stamp; extensions; env_cache; btype_cache; ast_cache } in
  { state; typer = Either.get result; }

let get_incremental _state x = x
let get_value = I.value

let update parser t =
  let result =
    let {btype_cache; env_cache; ast_cache; extensions} = t.state in
    protect_typer ~btype_cache ~env_cache ~ast_cache
      (fun exns ->
         Either.try' (fun () ->
             let state = (extensions,exns) in
             I.update' state parser (get_incremental state t.typer)))
  in
  {t with typer = Either.get result}

let env t = (get_value t.typer).P.env
let contents t = (get_value t.typer).P.contents
let exns t = (get_value t.typer).P.exns
let extensions t = t.state.extensions

let is_valid {state = {stamp; btype_cache; env_cache; ast_cache}} =
  List.for_all ~f:(!) stamp &&
  match protect_typer ~btype_cache ~env_cache ~ast_cache
          (fun _ -> Either.try' Env.check_cache_consistency)
  with
  | Either.L _exn -> false
  | Either.R result -> result

let dump ppf t =
  let ls = t.typer :: List.unfold I.previous t.typer in
  let ts = List.map ~f:I.value ls in
  let ts = List.map ts ~f:(fun x -> x.P.raw) in
  List.iter (Raw_typer.dump ppf) ts

let with_typer t f =
  let {btype_cache; env_cache; ast_cache} = t.state in
  Fluid.let' fluid_btype btype_cache (fun () ->
  Fluid.let' fluid_env env_cache (fun () ->
  Fluid.let' fluid_ast ast_cache (fun () ->
  f t)))
