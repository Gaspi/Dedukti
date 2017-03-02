open Basic
open Term
open Rule
open Format


let allow_non_linear = ref false

type dtree_error =
  | BoundVariableExpected of pattern
  | VariableBoundOutsideTheGuard of term
  | NotEnoughArguments of loc * ident * int * int * int
  | HeadSymbolMismatch of loc * ident * ident
  | ArityMismatch of loc * ident
  | UnboundVariable of loc * ident * pattern
  | AVariableIsNotAPattern of loc * ident
  | DistinctBoundVariablesExpected of loc * ident
  | NonLinearRule of typed_rule

exception DtreeExn of dtree_error

(* TODO : rename this type *)
type rule2 =
    { loc:loc ; pats:linear_pattern array ; right:term ;
      constraints:constr list ; esize:int ; }


type case =
  | CConst of int*ident*ident
  | CDB    of int*int
  | CLam

type abstract_pb = { position2:int (*c*) ; dbs:int LList.t (*(k_i)_{i<=n}*) ; depth2:int }
type pos = { position:int; depth:int }

type pre_context =
  | Syntactic of pos LList.t
  | MillerPattern of abstract_pb LList.t

let pp_pre_context fmt pre_context =
  match pre_context with
  | Syntactic _ -> fprintf fmt "Sy"
  | MillerPattern _ -> fprintf fmt "Mi"


type dtree =
  | Switch  of int * (case*dtree) list * dtree option
  | Test    of pre_context * constr list * term * dtree option


let rec pp_dtree t fmt dtree =
  let tab = String.make (t*4) ' ' in
  match dtree with
  | Test (pc,[],te,None)   -> fprintf fmt "(%a) %a" pp_pre_context pc pp_term te
  | Test (_,[],_,def)      -> assert false
  | Test (pc,lst,te,def)  ->
    let aux out = function
      | Linearity (i,j) -> fprintf out "%d =l %d" i j
      | Bracket (i,j) -> fprintf out "%a =b %a" pp_term (mk_DB dloc dmark i) pp_term j
    in
    fprintf fmt "\n%sif %a then (%a) %a\n%selse (%a) %a" tab (pp_list " and " aux) lst
      pp_pre_context pc pp_term te tab pp_pre_context pc (pp_def (t+1)) def
  | Switch (i,cases,def)->
    let pp_case out = function
      | CConst (_,m,v), g ->
        fprintf out "\n%sif $%i=%a.%a then %a" tab i pp_ident m pp_ident v (pp_dtree (t+1)) g
      | CLam, g -> fprintf out "\n%sif $%i=Lambda then %a" tab i (pp_dtree (t+1)) g
      | CDB (_,n), g -> fprintf out "\n%sif $%i=DB[%i] then %a" tab i n (pp_dtree (t+1)) g
    in
    fprintf fmt "%a\n%sdefault: %a" (pp_list "" pp_case)
      cases tab (pp_def (t+1)) def

and pp_def t fmt def =
  match def with
  | None        -> fprintf fmt "FAIL"
  | Some g      -> pp_dtree t fmt g

let pp_dtree fmt dtree = pp_dtree 0 fmt dtree

type rw = ident * ident * int * dtree

let pp_rw fmt (m,v,i,g) =
  fprintf fmt "GDT for '%a.%a' with %i argument(s): %a"
    pp_ident m pp_ident v i pp_dtree g






(* ************************************************************************** *)

let fold_map (f:'b->'a->('c*'b)) (b0:'b) (alst:'a list) : ('c list*'b) =
  let (clst,b2) =
    List.fold_left (fun (accu,b1) a -> let (c,b2) = f b1 a in (c::accu,b2))
      ([],b0) alst in
    ( List.rev clst , b2 )

(* ************************************************************************** *)

module IntSet = Set.Make(struct type t=int let compare=(-) end)

type lin_ty = { cstr:constr list; fvar:int ; seen:IntSet.t }

let br = hstring "{_}"

let extract_db k = function
  | Var (_,_,n,[]) when n<k -> n
  | p -> raise (DtreeExn (BoundVariableExpected p))

let rec all_distinct = function
  | [] -> true
  | hd::tl -> if List.mem hd tl then false else all_distinct tl

(* This function extracts non-linearity and bracket constraints from a list
 * of patterns. *)
(* TODO : this should be inside Rule module *)
let linearize (esize:int) (lst:pattern list) : int * linear_pattern list * constr list =
  let rec aux k (s:lin_ty) = function
  | Lambda (l,x,p) ->
      let (p2,s2) = (aux (k+1) s p) in
        ( LLambda (x,p2) , s2 )
  | Var (l,x,n,args) when n<k ->
      let (args2,s2) = fold_map (aux k) s args in
        ( LBoundVar (x,n,Array.of_list args2) , s2 )
  | Var (l,x,n,args) (* n>=k *) ->
    let args2 = List.map (extract_db k) args in
    (* to keep a most general unifier, all arguments applied to higher-order should be distincts.
       eg : (x => F x x) =?= (x => x) implies that F is either (x => y => x) or (x => y => y) *)
    if all_distinct args2 then
      begin
        if IntSet.mem (n-k) (s.seen) then
          ( LVar(x,s.fvar+k,args2),
            { s with fvar=(s.fvar+1);
                     cstr= (Linearity (s.fvar,n-k))::(s.cstr) ; } )
        else
          ( LVar(x,n,args2) , { s with seen=IntSet.add (n-k) s.seen; } )
      end
    else
      raise (DtreeExn (DistinctBoundVariablesExpected (l,x)))
    | Brackets t ->
      begin
        try
          ( LVar(br,s.fvar+k,[]),
            { s with fvar=(s.fvar+1);
                     cstr=(Bracket (s.fvar,Subst.unshift k t))::(s.cstr) ;} )
        with
        | Subst.UnshiftExn -> raise (DtreeExn (VariableBoundOutsideTheGuard t))
      end
    | Pattern (_,m,v,args) ->
        let (args2,s2) = (fold_map (aux k) s args) in
          ( LPattern(m,v,Array.of_list args2) , s2 )
  in
  let (lst,r) = fold_map (aux 0) { fvar=esize; cstr=[]; seen=IntSet.empty; } lst in
    ( r.fvar , lst , r.cstr )

(* For each matching variable count the number of arguments *)
let get_nb_args (esize:int) (p:pattern) : int array =
  let arr = Array.make esize (-1) in (* -1 means +inf *)
  let min a b =
    if a = -1 then b
    else if a<b then a else b
  in
  let rec aux k = function
    | Brackets _ -> ()
    | Var (_,_,n,args) when n<k -> List.iter (aux k) args
    | Var (_,id,n,args) -> arr.(n-k) <- min (arr.(n-k)) (List.length args)
    | Lambda (_,_,pp) -> aux (k+1) pp
    | Pattern (_,_,_,args) -> List.iter (aux k) args
  in
    ( aux 0 p ; arr )

(* Checks that the variables are applied to enough arguments *)
let check_nb_args (nb_args:int array) (te:term) : unit =
  let rec aux k = function
    | Kind | Type _ | Const _ -> ()
    | DB (l,id,n) ->
        if n>=k && nb_args.(n-k)>0 then
          raise (DtreeExn (NotEnoughArguments (l,id,n,0,nb_args.(n-k))))
    | App(DB(l,id,n),a1,args) when n>=k ->
      let min_nb_args = nb_args.(n-k) in
      let nb_args = List.length args + 1 in
        if ( min_nb_args > nb_args  ) then
          raise (DtreeExn (NotEnoughArguments (l,id,n,nb_args,min_nb_args)))
        else List.iter (aux k) (a1::args)
    | App (f,a1,args) -> List.iter (aux k) (f::a1::args)
    | Lam (_,_,None,b) -> aux (k+1) b
    | Lam (_,_,Some a,b) | Pi (_,_,a,b) -> (aux k a;  aux (k+1) b)
  in
    aux 0 te

let check_vars esize ctx p =
  let seen = Array.make esize false in
  let rec aux q = function
    | Pattern (_,_,_,args) -> List.iter (aux q) args
    | Var (_,_,n,args) ->
        begin
          ( if n-q >= 0 then seen.(n-q) <- true );
          List.iter (aux q) args
        end
    | Lambda (_,_,t) -> aux (q+1) t
    | Brackets _ -> ()
  in
    aux 0 p;
    Array.iteri (
      fun i b ->
        if (not b) then
          let (l,x,_) = List.nth ctx i in
            raise (DtreeExn (UnboundVariable (l,x,p)))
    ) seen

let rec is_linear = function
  | [] -> true
  | (Bracket _)::tl -> is_linear tl
  | (Linearity _)::tl -> false

let to_rule_infos (r:Rule.typed_rule) : (rule_infos,dtree_error) error =
  try
    begin
      let (ctx,lhs,rhs) = r in
      let esize = List.length ctx in
      let (l,md,id,args) = match lhs with
        | Pattern (l,md,id,args) ->
            begin
              check_vars esize ctx lhs;
              (l,md,id,args)
            end
        | Var (l,x,_,_) -> raise (DtreeExn (AVariableIsNotAPattern (l,x)))
        | Lambda _ | Brackets _ -> assert false
      in
      let nb_args = get_nb_args esize lhs in
      let _ = check_nb_args nb_args rhs in
      let (esize2,pats2,cstr) = linearize esize args in
      let is_nl = not (is_linear cstr) in
      if is_nl && (not !allow_non_linear) then
        Err (NonLinearRule r)
      else
        let () = if is_nl then debug 1 "Non-linear Rewrite Rule detected" in
        OK { l ; ctx ; md ; id ; args ; rhs ;
             esize = esize2 ;
             l_args = Array.of_list pats2 ;
             constraints = cstr ; }
    end
  with
      DtreeExn e -> Err e

(* ************************************************************************** *)

type matrix =
    { col_depth: int array;
      first:rule2 ;
      others:rule2 list ; }

(*
 * col_depth:    [ (n_0,p_0)     (n_1,p_1)       ...     (n_k,p_k) ]
 * first:       [ pats.(0)      pats.(1)        ...     pats.(k)  ]
 * others:      [ pats.(0)      pats.(1)        ...     pats.(k)  ]
 *                      ...
 *              [ pats.(0)      pats.(1)        ...     pats.(k)  ]
 *
 *              n_i is a pointeur to the stack
 *              k_i records the depth of the column (number of binders under which it stands)
 *)

let to_rule2 (r:rule_infos) : rule2 =
  { loc = r.l ;
    pats = r.l_args ;
    right = r.rhs ;
    constraints = r.constraints ;
    esize = r.esize ; }

(* mk_matrix lst builds a matrix out of the non-empty list of rules [lst]
*  It is checked that all rules have the same head symbol and arity.
* *)
let mk_matrix : rule_infos list -> matrix = function
  | [] -> assert false
  | r1::rs ->
      let f = to_rule2 r1 in
      let n = Array.length f.pats in
      let o = List.map (
        fun r2 ->
          if not (ident_eq r1.id r2.id) then
            raise (DtreeExn (HeadSymbolMismatch (r2.l,r1.id,r2.id)))
          else
            let r2' = to_rule2 r2 in
              if n != Array.length r2'.pats then
                raise (DtreeExn (ArityMismatch (r2.l,r1.id)))
              else r2'
      ) rs in
        { first=f; others=o; col_depth=Array.make (Array.length f.pats) 0 ;}

let pop mx =
  match mx.others with
    | [] -> None
    | f::o -> Some { mx with first=f; others=o; }

let width mx = Array.length mx.first.pats

let get_first_term mx = mx.first.right
let get_first_constraints mx = mx.first.constraints

(* ***************************** *)

let filter (f:rule2 -> bool) (mx:matrix) : matrix option =
  match List.filter f (mx.first::mx.others) with
    | [] -> None
    | f::o -> Some { mx with first=f; others=o; }

(* Keeps only the rules with a lambda on column [c] *)
let filter_l c r =
  match r.pats.(c) with
    | LLambda _ | LJoker | LVar _ -> true
    | _ -> false

(* Keeps only the rules with a bound variable of index [n] on column [c] *)
let filter_bv c n r =
  match r.pats.(c) with
    | LBoundVar (_,m,_) when n==m -> true
    | LVar _ | LJoker -> true
    | _ -> false

(* Keeps only the rules with a pattern head by [m].[v] on column [c] *)
let filter_p c m v r =
  match r.pats.(c) with
    | LPattern (m',v',_) when ident_eq v v' && ident_eq m m' -> true
    | LVar _ | LJoker -> true
    | _ -> false

(* Keeps only the rules with a joker or a variable on column [c] *)
let default (mx:matrix) (c:int) : matrix option =
  filter (
    fun r -> match r.pats.(c) with
      | LVar _ | LJoker -> true
      | LLambda _ | LPattern _ | LBoundVar _ -> false
  ) mx

(* ***************************** *)

(* Specialize the rule [r] on column [c]
 * i.e. remove colum [c] and append [nargs] new column at the end.
 * These new columns contain
 * - the arguments if column [c] is a pattern
 * - or the body if column [c] is a lambda
 * - or Jokers otherwise
* *)
let specialize_rule (c:int) (nargs:int) (r:rule2) : rule2 =
  let size = Array.length r.pats in
  let aux i =
    if i < size then
      if i==c then
        match r.pats.(c) with
          | LVar _ as v -> v
          | _ -> LJoker
      else r.pats.(i)
    else (* size <= i < size+nargs *)
      match r.pats.(c) with
        | LJoker | LVar _ -> LJoker
        | LPattern (_,_,pats2) | LBoundVar (_,_,pats2) ->
            ( assert ( Array.length pats2 == nargs );
              pats2.( i - size ) )
        | LLambda (_,p) -> ( assert ( nargs == 1); p )
  in
    { r with pats = Array.init (size+nargs) aux }

(* Specialize the col_infos field of a matrix.
 * Invalid for specialization by lambda. *)
let spec_col_depth (c:int) (nargs:int) (col_depth: int array) : int array =
  let size = Array.length col_depth in
  let aux i =
    if i < size then col_depth.(i)
    else (* < size+nargs *) col_depth.(c)
  in
    Array.init (size+nargs) aux

(* Specialize the col_infos field of a matrix: the lambda case. *)
let spec_col_depth_l (c:int) (col_depth: int array) : int array =
  let size = Array.length col_depth in
  let aux i =
    if i < size then col_depth.(i)
    else (*i == size *) col_depth.(c) + 1
  in
    Array.init (size+1) aux

(* Specialize the matrix [mx] on column [c] *)
let specialize mx c case : matrix =
  let (mx_opt,nargs) = match case with
    | CLam -> ( filter (filter_l c) mx , 1 )
    | CDB (nargs,n) -> ( filter (filter_bv c n) mx , nargs )
    | CConst (nargs,m,v) -> ( filter (filter_p c m v) mx , nargs )
  in
  let new_cn = match case with
    | CLam -> spec_col_depth_l c mx.col_depth
    | _ ->    spec_col_depth c nargs mx.col_depth
  in
    match mx_opt with
      | None -> assert false
      | Some mx2 ->
          { first = specialize_rule c nargs mx2.first;
            others = List.map (specialize_rule c nargs) mx2.others;
            col_depth = new_cn;
          }

(* ***************************** *)

(* Give the index of the first non variable column *)
let choose_column mx =
  let rec aux i =
    if i < Array.length mx.first.pats then
      ( match mx.first.pats.(i) with
        | LPattern _ | LLambda _ | LBoundVar _ -> Some i
        | LVar _ | LJoker -> aux (i+1) )
    else None
  in aux 0

let eq a b =
  match a, b with
    | CLam, CLam -> true
    | CDB (_,n), CDB (_,n') when n==n' -> true
    | CConst (_,m,v), CConst (_,m',v') when (ident_eq v v' && ident_eq m m') -> true
    | _, _ -> false

let partition mx c =
  let aux lst li =
    let add h = if List.exists (eq h) lst then lst else h::lst in
      match li.pats.(c) with
        | LPattern (m,v,pats)  -> add (CConst (Array.length pats,m,v))
        | LBoundVar (_,n,pats) -> add (CDB (Array.length pats,n))
        | LLambda _ -> add CLam
        | LVar _ | LJoker -> lst
  in
    List.fold_left aux [] (mx.first::mx.others)

(* ***************************** *)

let array_to_llist arr =
  LList.make_unsafe (Array.length arr) (Array.to_list arr)

(* Extracts the pre_context from the first line. *)
let get_first_pre_context mx =
  let esize = mx.first.esize in
  let dummy = { position=(-1); depth=0; } in
  let dummy2 = { position2=(-1); depth2=0; dbs=LList.nil; } in
  let arr1 = Array.make esize dummy in
  let arr2 = Array.make esize dummy2 in
  let mp = ref false in
    Array.iteri
      (fun i p -> match p with
         | LJoker -> ()
         | LVar (_,n,lst) ->
             begin
               let k = mx.col_depth.(i) in
                 assert( 0 <= n-k ) ;
                 assert(n-k < esize ) ;
                 arr1.(n-k) <- { position=i; depth=mx.col_depth.(i); };
                 if lst=[] then
                   arr2.(n-k) <- { position2=i; dbs=LList.nil; depth2=mx.col_depth.(i); }
                 else (
                   mp := true ;
                   arr2.(n-k) <- { position2=i; dbs=LList.of_list lst; depth2=mx.col_depth.(i); } )
             end
         | _ -> assert false
      ) mx.first.pats ;
    ( Array.iter ( fun r -> assert (r.position >= 0 ) ) arr1 );
    if !mp then MillerPattern (array_to_llist arr2)
    else Syntactic (array_to_llist arr1)

(******************************************************************************)

(* Construct a decision tree out of a matrix *)
let rec to_dtree (mx:matrix) : dtree =
  match choose_column mx with
    (* There are only variables on the first line of the matrix *)
    | None   -> Test ( get_first_pre_context mx,
                       get_first_constraints mx,
                       get_first_term mx,
                       map_opt to_dtree (pop mx) )
    (* Pattern on the first line at column c *)
    | Some c ->
        let cases = partition mx c in
        let aux ca = ( ca , to_dtree (specialize mx c ca) ) in
          Switch (c, List.map aux cases, map_opt to_dtree (default mx c) )

(******************************************************************************)


let of_rules (rs:rule_infos list) : (int*dtree,dtree_error) error =
  try
    let mx = mk_matrix rs in OK ( Array.length mx.first.pats , to_dtree mx )
  with DtreeExn e -> Err e
