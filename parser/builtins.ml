open Basics
open Preterm
open Term
open Printf

let modname = hstring "builtins"

(* Constructors *)
let _0 = hstring "0"
let _S = hstring "S"
let _char_of_nat = hstring "char_of_nat"
let _string_nil = hstring "string_nil"
let _string_cons = hstring "string_cons"
let _nil = hstring "nil"
let _cons = hstring "cons"

let rec mk_num_from_int l = function
    | 0 -> PreQId(l, modname, _0)
    | n -> PreApp(PreQId(l, modname, _S), mk_num_from_int l (n - 1), [])

let mk_num (l, s) = mk_num_from_int l (int_of_string s)

let mk_char (l, c) =
  PreApp(PreQId(l, modname, _char_of_nat), mk_num_from_int l (int_of_char c), [])

let rec mk_string (l, s) =
  if String.length s = 0 then
    PreQId(l, modname, _string_nil)
  else
    PreApp(PreQId(l, modname, _string_cons), mk_char (l, s.[0]), [mk_string (l, String.sub s 1 (String.length s - 1))])

(* Exception raised when trying to print a non-atomic value *)
exception Not_atomic_builtin

let rec term_to_int = function
  | Const (_, m, v)
       when ident_eq m modname &&
              ident_eq v _0 -> 0
  | App (Const (_, m, v), a, [])
       when ident_eq m modname &&
              ident_eq v _S -> term_to_int a + 1
  | _ -> raise Not_atomic_builtin

let term_to_char = function
  | App (Const (_, m, v), a, [])
       when ident_eq m modname &&
              ident_eq v _char_of_nat ->
     begin
       try
         char_of_int (term_to_int a)
       with Invalid_argument "char_of_int" ->
         raise Not_atomic_builtin
     end
  | _ -> raise Not_atomic_builtin

let rec term_to_string = function
  | Const (_, m, v)
       when ident_eq m modname &&
              ident_eq v _string_nil -> ""
  | App (Const (_, m, v), a, [b])
       when ident_eq m modname &&
              ident_eq v _string_cons ->
     Printf.sprintf "%c%s" (term_to_char a) (term_to_string b)
  | _ -> raise Not_atomic_builtin

let pp_term out t =
  (* try to print the term as a numeral *)
  try
    fprintf out "%d" (term_to_int t)
  with Not_atomic_builtin ->
       (* try to print as a character *)
       try
         fprintf out "\'%c\'" (term_to_char t)
       with Not_atomic_builtin ->
         (* try to print as a string *)
         fprintf out "\"%s\"" (term_to_string t)

let print_term out t =
  (* try to print the term as a numeral *)
  try
    Format.fprintf out "%d" (term_to_int t)
  with Not_atomic_builtin ->
       (* try to print as a character *)
       try
         Format.fprintf out "\'%c\'" (term_to_char t)
       with Not_atomic_builtin ->
         (* try to print as a string *)
         Format.fprintf out "\"%s\"" (term_to_string t)
