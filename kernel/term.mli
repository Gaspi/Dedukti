open Basics

(** {2 Terms} *)

type term = private
  | Kind                                (* Kind *)
  | Type  of loc                        (* Type *)
  | DB    of loc*ident*int              (* deBruijn *)
  | Const of loc*ident*ident            (* Global variable *)
  | App   of term * term * term list    (* f a1 [ a2 ; ... an ] , f not an App *)
  | Lam   of loc*ident*term option*term        (* Lambda abstraction *)
  | Pi    of loc*ident*term*term                (* Pi abstraction *)
  | Let   of loc*ident*term*term        (* let x=a in b *)

type context = ( loc * ident * term ) list

val get_loc : term -> loc

val mk_Kind     : term
val mk_Type     : loc -> term
val mk_DB       : loc -> ident -> int -> term
val mk_Const    : loc -> ident -> ident -> term
val mk_Lam      : loc -> ident -> term option -> term -> term
val mk_App      : term -> term -> term list -> term
val mk_Pi       : loc -> ident -> term -> term -> term
val mk_Let      : loc -> ident -> term -> term -> term
val mk_Arrow    : loc -> term -> term -> term

(* Syntactic equality / Alpha-equivalence *)
val term_eq : term -> term -> bool

(** {2 Let-bindings}

partial mapping from bound vars to terms+env *)

module LetCtx : sig
  type t = private {
    env : (term * t) option LList.t;
  }

  val empty : t
  val is_empty : t -> bool
  val cons : (term * t) -> t -> t
  val cons_none : t -> t
  val nth : t -> int -> (term * t) option
  val lst : t -> (term*t) option list
  val len : t -> int

  val mem : t -> int -> bool
  (** Is there a definition for the given DeBruijn index? *)

  val get : t -> int -> (term * t) option

  val has_bindings : t -> bool
  (** Is there at least one bound variable? *)
end

