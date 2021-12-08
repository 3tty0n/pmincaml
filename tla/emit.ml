open MinCaml
open Asm
open Bytecodes

exception NoImplementedError of string

(* generate a unique label id *)
let gen_label, reset =
  let counter = ref 0 in
  ( (fun () ->
      let l = !counter in
      counter := !counter + 1;
      "$" ^ string_of_int l)
  , fun () -> counter := 0 )
;;

(* compilation environment maps local variable names to local variable
   numbers *)
let lookup env var =
  fst (List.find (fun (_, v) -> var = v) (List.mapi (fun idx v -> idx, v) env))
;;

let extend_env env var = var :: env
let shift_env env = extend_env env "*dummy*"
let downshift_env env = List.tl env
let return_address_marker = "$ret_addr"
let build_arg_env args = return_address_marker :: List.rev args

(* computes the number of arguments to this frame. The stack has a shape like
   [...local vars...][ret addr][..args...], the return address position from the
   top indicates the number of local variables on top of the return address. *)
let arity_of_env env =
  let num_local_vars = lookup env return_address_marker in
  List.length env - num_local_vars - 1, num_local_vars
;;

let compile_id_or_imm env = function
  | C n -> [ CONST_INT; Literal n ]
  | V x -> [ DUP; Literal (lookup env x) ]
;;

let rec compile_t fname env =
  let open Asm in
  function
  | Ans (CallDir (Id.L fname', args, fargs) as e) -> compile_exp fname env e
  | Ans e -> compile_exp fname env e
  | Let ((x, _), exp, t) ->
    let newenv = extend_env env x in
    compile_exp fname env exp @ compile_t fname newenv t @ [ POP ]

and compile_exp fname env = function
  | Nop -> []
  | Set i -> compile_id_or_imm env (C i)
  | Mov var -> compile_id_or_imm env (V var)
  | Add (x, y) ->
    compile_id_or_imm env (V x) @ compile_id_or_imm (shift_env env) y @ [ ADD ]
  | Sub (x, y) ->
    compile_id_or_imm env (V x) @ compile_id_or_imm (shift_env env) y @ [ SUB ]
  | Mul (x, y) ->
    compile_id_or_imm env (V x) @ compile_id_or_imm (shift_env env) y @ [ MUL ]
  | Div (x, y) ->
    compile_id_or_imm env (V x) @ compile_id_or_imm (shift_env env) y @ [ DIV ]
  | Mod (x, y) ->
    compile_id_or_imm env (V x) @ compile_id_or_imm (shift_env env) y @ [ MOD ]
  | IfEq (x, y, then_exp, else_exp) ->
    let l2, l1 = gen_label (), gen_label () in
    compile_id_or_imm env (V x)
    @ compile_id_or_imm (shift_env env) y
    @ [ EQ ]
    @ [ JUMP_IF; Lref l1 ]
    @ compile_t fname env then_exp
    @ [ JUMP; Lref l2 ]
    @ [ Ldef l1 ]
    @ compile_t fname env else_exp
    @ [ Ldef l2 ]
  | IfLE (x, y, then_exp, else_exp) ->
    let l2, l1 = gen_label (), gen_label () in
    compile_id_or_imm env (V x)
    @ compile_id_or_imm (shift_env env) y
    @ [ LT ]
    @ [ JUMP_IF; Lref l1 ]
    @ compile_t fname env then_exp
    @ [ JUMP; Lref l2 ]
    @ [ Ldef l1 ]
    @ compile_t fname env else_exp
    @ [ Ldef l2 ]
  | CallDir (Id.L "min_caml_print_int", args, _) -> []
  | CallDir (Id.L var, args, _) ->
    (args
    |> List.fold_left
         (fun (rev_code_list, env) v ->
           compile_id_or_imm env (V v) :: rev_code_list, shift_env env)
         ([], env)
    |> fst
    |> List.rev
    |> List.flatten)
    @ [ CALL; Lref var; ]
  | exp ->
    raise
      (NoImplementedError
         (Printf.sprintf "un matched pattern: %s" (Asm.show_exp exp)))
;;

(* [...;Ldef a;...] -> [...;a,i;...] where i is the index of the next
   instruction of Ldef a in the list all Ldefs are removed e.g., [_;Ldef
   8;_;Ldef 7;_] ==> [8,1; 7,2] *)
let make_label_env instrs =
  snd
    (List.fold_left
       (fun (addr, env) -> function
         | Ldef n -> addr, (Lref n, Literal addr) :: env
         | _ -> addr + 1, env)
       (0, [])
       instrs)
;;

let assoc_if subst elm = try List.assoc elm subst with Not_found -> elm

let resolve_labels instrs =
  let lenv = make_label_env instrs in
  instrs
  |> List.map (assoc_if lenv)
  |> List.filter (function Ldef _ -> false | _ -> true)
;;

let compile_fun_body fenv name arity annot exp env =
  [ Ldef name ]
  @ compile_t name env exp
  @ if name = "main" then [ EXIT ] else [ RET; Literal arity ]
;;

let compile_fun
    (fenv : Id.l -> Asm.fundef)
    { name = Id.L name; args; body; annot }
  =
  compile_fun_body fenv name (List.length args) annot body (build_arg_env args)
;;

let compile_funs fundefs =
  (* let fenv name = fst(List.find (fun (_,{name=n}) -> name=n)
   *                       (List.mapi (fun idx fdef -> (idx,fdef))
   *                          fundefs)) in *)
  let fenv name = List.find (fun Asm.{ name = n } -> n = name) fundefs in
  Array.of_list
    (resolve_labels (List.flatten (List.map (compile_fun fenv) fundefs)))
;;

let f (Asm.Prog (_, fundefs, main)) =
  let main =
    { name = Id.L "main"
    ; args = []
    ; fargs = []
    ; ret = Type.Int
    ; body = main
    ; annot = None
    }
  in
  compile_funs (main :: fundefs)
;;
