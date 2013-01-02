open Ast
open Common
open Type
open Typecore

type con_def =
	| CEnum of tenum * tenum_field
	| CConst of tconstant
	| CType of module_type
	| CArray of int
	| CFields of int * (string * tclass_field) list
	| CExpr of texpr

and con = {
	c_def : con_def;
	c_type : t;
	c_pos : pos;
}

type st_def =
	| SVar of tvar
	| SField of st * string
	| SEnum of st * string * int
	| SArray of st * int
	| STuple of st * int * int

and st = {
	st_def : st_def;
	st_type : t;
	st_pos : pos;
}

type pat_def =
	| PAny
	| PVar of tvar
	| PCon of con * pat list
	| POr of pat * pat
	| PBind of tvar * pat

and pat = {
	p_def : pat_def;
	p_type : t;
	p_pos : pos;
}

type out = {
	o_expr : texpr;
	o_guard : texpr option;
	o_pos : pos;
	mutable o_num_paths : int;
	mutable o_bindings : (tvar * st) list;
}

type pat_vec = pat array * out
type pat_matrix = pat_vec list

type pvar = tvar * pos

type pattern_ctx = {
	mutable pc_locals : (string, pvar) PMap.t;
	mutable pc_sub_vars : (string, pvar) PMap.t option;
}

type dt =
	| Bind of out * dt option
	| Switch of st * (con * dt) list
	| Goto of int

type matcher = {
	ctx : typer;
	stl : st list;
	need_val : bool;
	v_lookup : (string,tvar) Hashtbl.t;
	mutable outcomes : (pat list,out) PMap.t;
	mutable subtree_index : (st list * pat_matrix,int) Hashtbl.t;
	mutable subtrees : (int,dt) Hashtbl.t;
	mutable num_subtrees : int;
}

exception Not_exhaustive of pat * st

let arity con = match con.c_def with
	| CEnum (_,{ef_type = TFun(args,_)}) -> List.length args
	| CEnum _ -> 0
	| CConst _ -> 0
	| CType mt -> 0
	| CArray i -> i
	| CFields (i,_) -> i
	| CExpr _ -> 0

let mk_st def t p = {
	st_def = def;
	st_type = t;
	st_pos = p;
}

let mk_out mctx e eg pl p =
	let out = {
		o_expr = e;
		o_guard = eg;
		o_pos = p;
		o_num_paths = 0;
		o_bindings = [];
	} in
	mctx.outcomes <- PMap.add pl out mctx.outcomes;
	out

let clone_out mctx out pl p =
	try PMap.find pl mctx.outcomes
	with Not_found ->
		let out = {out with o_pos = p} in
		mctx.outcomes <- PMap.add pl out mctx.outcomes;
		out

let bind_st out st v =
	if not (List.mem_assq v out.o_bindings) then out.o_bindings <- (v,st) :: out.o_bindings

let mk_pat pdef t p = {
	p_def = pdef;
	p_type = t;
	p_pos = p;
}

let mk_con cdef t p = {
	c_def = cdef;
	c_type = t;
	c_pos = p;
}

let mk_con_pat cdef pl t p = {
	p_def = PCon(mk_con cdef t p,pl);
	p_type = t;
	p_pos = p;
}

let mk_any t p = {
	p_def = PAny;
	p_type = t;
	p_pos = p;
}

let any = mk_any t_dynamic Ast.null_pos

let mk_subs st con = match con.c_def with
	| CFields (_,fl) -> List.map (fun (s,cf) -> mk_st (SField(st,s)) cf.cf_type st.st_pos) fl
	| CEnum (en,({ef_type = TFun _} as ef)) ->
		let pl = match follow con.c_type with TEnum(_,pl) -> pl | _ -> assert false in
		begin match apply_params en.e_types pl (monomorphs ef.ef_params ef.ef_type) with
			| TFun(args,r) ->
				ExtList.List.mapi (fun i (_,_,t) ->
					mk_st (SEnum(st,ef.ef_name,i)) t st.st_pos
				) args
			| _ ->
				assert false
		end
	| CArray 0 -> []
	| CArray i ->
		let t = match follow con.c_type with TInst({cl_path=[],"Array"},[t]) -> t | _ -> assert false in
		ExtList.List.init i (fun i -> mk_st (SArray(st,i)) t st.st_pos)
	| CEnum _ | CConst _ | CType _ | CExpr _ ->
		[]

(* Printing *)

let s_type = s_type (print_context())

let rec s_expr_small e = match e.eexpr with
	| TLocal v -> v.v_name
	| TField (e,s) -> s_expr_small e ^ "." ^ field_name s
	| TBlock [] -> "{}"
	| _ -> s_expr (s_type) e

let s_const = function
	| TInt i -> Int32.to_string i
	| TFloat s -> s ^ "f"
	| TString s -> Printf.sprintf "\"%s\"" (Ast.s_escape s)
	| TBool b -> if b then "true" else "false"
	| TNull -> "null"
	| TThis -> "this"
	| TSuper -> "super"

let s_con con = match con.c_def with
	| CEnum(_,ef) -> ef.ef_name
	| CConst TNull -> "_"
	| CConst c -> s_const c
	| CType mt -> s_type_path (t_path mt)
	| CArray i -> "[" ^(string_of_int i) ^ "]"
	| CFields (_,fl) -> String.concat "," (List.map (fun (s,_) -> s) fl)
	| CExpr e -> s_expr s_type e

let rec s_pat pat = match pat.p_def with
	| PVar v -> v.v_name
	| PCon (c,[]) -> s_con c
	| PCon (c,pl) -> s_con c ^ "(" ^ (String.concat "," (List.map s_pat pl)) ^ ")"
	| POr (pat1,pat2) -> s_pat pat1 ^ " | " ^ s_pat pat2
	| PAny -> "_"
	| PBind(v,pat) -> v.v_name ^ "=" ^ s_pat pat

let st_args l r v =
	(if l > 0 then (String.concat "," (ExtList.List.make l "_")) ^ "," else "")
	^ v ^
	(if r > 0 then "," ^ (String.concat "," (ExtList.List.make r "_")) else "")

let rec s_st st = (match st.st_def with
	| SVar v -> v.v_name
	| SEnum (st,n,i) -> s_st st ^ "." ^ n ^ "." ^ (string_of_int i)
	| SArray (st,i) -> s_st st ^ "[" ^ (string_of_int i) ^ "]"
	| STuple (st,i,a) -> "(" ^ (st_args i (a - i - 1) (s_st st)) ^ ")"
	| SField (st,n) -> s_st st ^ "." ^ n)
	(* ^ ":" ^ (s_type st.st_type) *)

let rec s_pat_vec pl =
	String.concat " " (Array.to_list (Array.map s_pat pl))

let s_out out =
	"var " ^ (String.concat "," (List.map (fun (v,st) -> v.v_name ^ "=" ^ (s_st st)) out.o_bindings)) ^ ";"
	(* ^ s_expr_small out.o_expr *)

let rec s_pat_matrix pmat =
	String.concat "\n" (List.map (fun (pl,out) -> (s_pat_vec pl) ^ "->" ^ (s_out out)) pmat)

let rec s_dt tabs tree = tabs ^ match tree with
	| Bind (out,None)->
		s_out out;
	| Bind (out,Some dt) ->
		"if (" ^ (s_expr_small (match out.o_guard with Some e -> e | None -> assert false)) ^ ") " ^ (s_out out) ^ " else " ^ s_dt tabs dt
	| Switch (st, cl) ->
		"switch(" ^ (s_st st) ^ ") { \n" ^ tabs
		^ (String.concat ("\n" ^ tabs) (List.map (fun (c,dt) ->
			"case " ^ (s_con c) ^ ":\n" ^ (s_dt (tabs ^ "\t") dt)
		) cl))
		^ "\n" ^ (if String.length tabs = 0 then "" else (String.sub tabs 0 (String.length tabs - 1))) ^ "}"
	| Goto i ->
		"goto " ^ (string_of_int i)

(* Pattern parsing *)

let unify_enum_field en pl ef t =
	let t2 = match follow ef.ef_type with
		| TFun(_,r) -> r
		| t2 -> t2
	in
	let t2 = (apply_params en.e_types pl (monomorphs ef.ef_params t2)) in
	Type.unify t2 t

let unify ctx a b p =
	try unify_raise ctx a b p with Error (Unify l,p) -> error (error_msg (Unify l)) p

let to_pattern mctx e st =
	let ctx = mctx.ctx in
	let perror p = error "Unrecognized pattern" p in
	let verror n p = error ("Variable " ^ n ^ " must appear exactly once in each sub-pattern") p in
	let mk_var tctx s t p =
		let v = match tctx.pc_sub_vars with
			| Some vmap -> fst (try PMap.find s vmap with Not_found -> verror s p)
			| None -> alloc_var s t
		in
		unify mctx.ctx t v.v_type p;
		if PMap.mem s tctx.pc_locals then verror s p;
		tctx.pc_locals <- PMap.add s (v,p) tctx.pc_locals;
		v
	in
	let rec loop pctx e st =
		let p = pos e in
		match fst e with
		| EConst(Ident "null") ->
			error "null-patterns are not allowed" p
		| EParenthesis e ->
			loop pctx e st
		| ECast(e1,None) ->
			loop pctx e1 st
		| EConst((Ident ("false" | "true") | Int _ | String _ | Float _) as c) ->
			let e = Codegen.type_constant ctx.com c p in
			unify ctx e.etype st.st_type p;
			let c = match e.eexpr with TConst c -> c | _ -> assert false in
			mk_con_pat (CConst c) [] st.st_type p
		| EField _ ->
			let e = type_expr_with_type ctx e (Some st.st_type) false in
			let e = match Optimizer.make_constant_expression ctx e with Some e -> e | None -> e in
			(match e.eexpr with
			| TConst c -> mk_con_pat (CConst c) [] st.st_type p
			| TTypeExpr mt -> mk_con_pat (CType mt) [] st.st_type p
			| TField(_, FStatic(_,cf)) when is_value_type cf.cf_type ->
				mk_con_pat (CExpr e) [] cf.cf_type p
			| TField(_, FEnum(en,ef)) ->
				let tc = monomorphs ctx.type_params (st.st_type) in
				unify_enum_field en (List.map (fun _ -> mk_mono()) en.e_types) ef tc;
				mk_con_pat (CEnum(en,ef)) [] st.st_type p
			| _ -> error "Constant expression expected" p)
		| ECall(ec,el) ->
			let tc = monomorphs ctx.type_params (st.st_type) in
			let ec = type_expr_with_type ctx ec (Some tc) false in
			(match follow ec.etype with
			| TEnum(en,pl)
			| TFun(_,TEnum(en,pl)) ->
				let ef = match ec.eexpr with
					| TField (_,FEnum (_,f)) -> f
					| _ -> error ("Expected constructor for enum " ^ (s_type_path en.e_path)) p
				in
				let mono_map,monos,tpl = List.fold_left (fun (mm,ml,tpl) (n,t) ->
					let mono = mk_mono() in
					(n,mono) :: mm, mono :: ml, t :: tpl) ([],[],[]) ef.ef_params
				in
				let tl = match apply_params en.e_types pl (apply_params ef.ef_params monos ef.ef_type) with
					| TFun(args,r) ->
						unify ctx r tc p;
						List.map (fun (n,_,t) ->
							let tf = apply_params mono_map tpl (follow t) in
							if is_null t then ctx.t.tnull tf else tf
						) args
					| _ -> error "Arguments expected" p
				in
				let rec loop2 i el tl = match el,tl with
					| (EConst(Ident "_"),pany) :: [], t :: tl ->
						let pat = mk_pat PAny t_dynamic pany in
						(ExtList.List.make ((List.length tl) + 1) pat)
					| e :: el, t :: tl ->
						let st = mk_st (SEnum(st,ef.ef_name,i)) t (pos e) in
						let pat = loop pctx e st in
						pat :: loop2 (i + 1) el tl
					| e :: _, [] ->
						error "Too many arguments" (pos e);
					| [],_ :: _ ->
						error "Not enough arguments" p;
					| [],[] ->
						[]
				in
				mk_con_pat (CEnum(en,ef)) (loop2 0 el tl) st.st_type p
			| _ -> perror p)
		| EConst(Ident "_") ->
			mk_any st.st_type p
		| EConst(Ident s) ->
			begin try
				let tc = monomorphs ctx.type_params (st.st_type) in
				let ec = match tc with
					| TEnum(en,pl) ->
						let ef = PMap.find s en.e_constrs in
						let et = mk (TTypeExpr (TEnumDecl en)) (TAnon { a_fields = PMap.empty; a_status = ref (EnumStatics en) }) p in
						mk (TField (et,FEnum (en,ef))) (apply_params en.e_types pl ef.ef_type) p
					| _ ->
						let old = ctx.untyped in
						ctx.untyped <- true;
						let e = try type_expr_with_type ctx e (Some tc) true with _ -> ctx.untyped <- old; raise Not_found in
						ctx.untyped <- old;
						(match tc with
							| TMono _ -> ()
							| _ -> try unify_raise ctx e.etype tc e.epos with Error (Unify _,_) -> raise Not_found);
						e
				in
				(match ec.eexpr with
					| TField (_,FEnum (en,ef)) ->
						unify_enum_field en (List.map (fun _ -> mk_mono()) en.e_types) ef tc;
						mk_con_pat (CEnum(en,ef)) [] st.st_type p
                    | TConst c ->
                        unify ctx ec.etype tc p;
                        mk_con_pat (CConst c) [] tc p
					| TTypeExpr mt ->
						let tcl = Typeload.load_instance ctx {tname="Class";tpackage=[];tsub=None;tparams=[]} p true in
						let t2 = match tcl with TAbstract(a,_) -> TAbstract(a,[mk_mono()]) | _ -> assert false in
						mk_con_pat (CType mt) [] t2 p
					| _ ->
						raise Not_found);
			with Not_found ->
				if not (is_lower_ident s) then error "Capture variables must be lower-case" p;
				let v = mk_var pctx s st.st_type p in
				mk_pat (PVar v) v.v_type p
			end
		| (EObjectDecl fl) ->
			begin match follow st.st_type with
			| TAnon {a_fields = fields}
			| TInst({cl_fields = fields},_) ->
				List.iter (fun (n,(_,p)) -> if not (PMap.mem n fields) then error (unify_error_msg (print_context()) (has_extra_field st.st_type n)) p) fl;
				let sl,pl,i = PMap.foldi (fun n cf (sl,pl,i) ->
					let st = mk_st (SField(st,n)) cf.cf_type (pos e) in
					let pat = try loop pctx (List.assoc n fl) st with Not_found -> (mk_any cf.cf_type p) in
					(n,cf) :: sl,pat :: pl,i + 1
				) fields ([],[],0) in
				mk_con_pat (CFields(i,sl)) pl st.st_type p
			| _ ->
				error ((s_type st.st_type) ^ " should be { }") p
			end
		| EArrayDecl [] ->
			mk_con_pat (CArray 0) [] st.st_type p
		| EArrayDecl el ->
			begin match follow st.st_type with
				| TInst({cl_path=[],"Array"},[t2]) ->
					let pl = ExtList.List.mapi (fun i e ->
						let st = mk_st (SArray(st,i)) t2 p in
						loop pctx e st
					) el in
					mk_con_pat (CArray (List.length el)) pl st.st_type p
				| _ ->
					error ((s_type st.st_type) ^ " should be Array") p
			end
		| EBinop(OpAssign,(EConst(Ident s),p2),e1) ->
			let v = mk_var pctx s st.st_type p in
			let pat1 = loop pctx e1 st in
			mk_pat (PBind(v,pat1)) st.st_type p2
		| EBinop(OpOr,(EBinop(OpOr,e1,e2),p2),e3) ->
			loop pctx (EBinop(OpOr,e1,(EBinop(OpOr,e2,e3),p2)),p) st
		| EBinop(OpOr,e1,e2) ->
			let old = pctx.pc_locals in
			let pat1 = loop pctx e1 st in
			begin match pat1.p_def with
				| PAny | PVar _ ->
					ctx.com.warning "This pattern is unused" (pos e2);
					pat1
				| _ ->
				let pctx2 = {
					pc_sub_vars = Some pctx.pc_locals;
					pc_locals = old;
				} in
				let pat2 = loop pctx2 e2 st in
				PMap.iter (fun s (_,p) -> if not (PMap.mem s pctx2.pc_locals) then verror s p) pctx.pc_locals;
				unify ctx pat1.p_type pat2.p_type pat1.p_pos;
				mk_pat (POr(pat1,pat2)) pat2.p_type (punion pat1.p_pos pat2.p_pos);
			end
		| _ ->
			error "Unrecognized pattern" p;
	in
	let pctx = {
		pc_locals = PMap.empty;
		pc_sub_vars = None;
	} in
	let e = loop pctx e st in
	PMap.iter (fun n (v,p) -> ctx.locals <- PMap.add n v ctx.locals) pctx.pc_locals;
	e

(* Match compilation *)

let unify_con con1 con2 = match con1.c_def,con2.c_def with
	| CExpr e1, CExpr e2 ->
		e1 == e2
	| CConst c1,CConst c2 ->
		c1 = c2
	| CEnum(e1,ef1),CEnum(e2,ef2) ->
		e1 == e2 && ef1.ef_name = ef2.ef_name
	| CFields (i1,fl1),CFields (i2,fl2) ->
		(try
			List.iter (fun (s,_) -> if not (List.mem_assoc s fl1) then raise Not_found) fl2;
			true
		with Not_found ->
			false)
	| CType mt1,CType mt2 ->
		t_path mt1 = t_path mt2
	| CArray a1, CArray a2 ->
		a1 == a2
	| _ ->
		false

let array_tl arr = Array.sub arr 1 (Array.length arr - 1)

let spec mctx con pmat =
	let a = arity con in
	let r = DynArray.create () in
	let add pv out =
		DynArray.add r (pv,out)
	in
	let rec loop2 pv out = match pv.(0).p_def with
		| PCon(c2,pl) when unify_con c2 con ->
			add (Array.append (Array.of_list pl) (array_tl pv)) out
		| PCon(c2,pl) ->
			()
		| PAny | PVar _->
			add (Array.append (Array.make a pv.(0)) (array_tl pv)) out
 		| POr(pat1,pat2) ->
			let tl = array_tl pv in
			let out2 = clone_out mctx out [pat2] pat2.p_pos in
			loop2 (Array.append [|pat1|] tl) out;
			loop2 (Array.append [|pat2|] tl) out2;
		| PBind(_,pat) ->
			loop2 (Array.append [|pat|] (array_tl pv)) out
	in
	let rec loop pmat = match pmat with
		| (pv,out) :: pl ->
			loop2 pv out;
			loop pl
		| [] ->
			()
	in
	loop pmat;
	DynArray.to_list r

let default mctx pmat =
	let r = DynArray.create () in
	let add pv out =
		DynArray.add r (pv,out)
	in
	let rec loop2 pv out = match pv.(0).p_def with
		| PCon _ ->
			()
		| PAny | PVar _->
			add (array_tl pv) out
 		| POr(pat1,pat2) ->
			let tl = array_tl pv in
			loop2 (Array.append [|pat1|] tl) out;
			loop2 (Array.append [|pat2|] tl) out;
		| PBind(_,pat) ->
			loop2 (Array.append [|pat|] (array_tl pv)) out
	in
 	let rec loop pmat = match pmat with
		| (pv,out) :: pl ->
			loop2 pv out;
			loop pl;
		| [] ->
			()
	in
	loop pmat;
	DynArray.to_list r

let pick_column pmat =
	let rec loop i pv = if Array.length pv = 0 then -1 else match pv.(0).p_def with
		| PVar _ | PAny ->
			loop (i + 1) (array_tl pv)
		| _ ->
			i
	in
	loop 0 (fst (List.hd pmat))

let swap_pmat_columns i pmat =
	List.iter (fun (pv,out) ->
		let tmp = pv.(i) in
		Array.set pv i pv.(0);
		Array.set pv 0 tmp;
	) pmat

let swap_columns i (row : 'a list) : 'a list =
	match row with
	| rh :: rt ->
		let hd = ref rh in
		let rec loop count acc col = match col with
			| [] -> acc
			| ch :: cl when i = count ->
				let acc = acc @ [!hd] @ cl in
				hd := ch;
				acc
			| ch :: cl ->
				loop (count + 1) (ch :: acc) cl
		in
		let tl = loop 1 [] rt in
		(!hd :: tl)
	| _ ->
		[]

let column_sigma mctx st pmat =
	let acc = ref [] in
	let unguarded = Hashtbl.create 0 in
	let add c g =
		if not (List.exists (fun c2 -> unify_con c2 c) !acc) then acc := c :: !acc;
		if not g then Hashtbl.replace unguarded c.c_def true;
	in
	let rec loop pmat = match pmat with
		| (pv,out) :: pr ->
			let rec loop2 = function
				| PCon (c,_) ->
					add c (out.o_guard <> None);
				| POr(pat1,pat2) ->
					loop2 pat1.p_def;
					loop2 pat2.p_def;
				| PVar v ->
					bind_st out st v;
				| PBind(v,pat) ->
					bind_st out st v;
					loop2 pat.p_def
				| PAny ->
					()
			in
			loop2 pv.(0).p_def;
			loop pr
		| [] ->
			()
	in
	loop pmat;
	List.rev_map (fun con -> con,not (Hashtbl.mem unguarded con.c_def)) !acc

let all_ctors mctx st =
	let h = ref PMap.empty in
	let inf = match follow st.st_type with
	| TAbstract({a_path = [],"Bool"},_) ->
		h := PMap.add (CConst(TBool true)) Ast.null_pos !h;
		h := PMap.add (CConst(TBool false)) Ast.null_pos !h;
		false
	| TInst({cl_path=[],"String"},_)
	| TInst({cl_path=[],"Array"},_)
	| TAbstract _ ->
		true
	| TEnum(en,pl) ->
		PMap.iter (fun _ ef ->
			let tc = monomorphs mctx.ctx.type_params st.st_type in
			try unify_enum_field en pl ef tc;
				h := PMap.add (CEnum(en,ef)) ef.ef_pos !h
			with Unify_error _ ->
				()
		) en.e_constrs;
		false
	| TInst ({cl_kind = KTypeParameter _},_) ->
		error "Unapplied type parameter" st.st_pos
	| TAnon a ->
		(match !(a.a_status) with
		| Statics c ->
			true
		| _ ->
			false)
	| TInst(_,_) ->
		false
	| _ ->
		true
	in
	h,inf

let rec collapse_pattern pl = match pl with
	| pat :: [] ->
		pat
	| pat :: pl ->
		let pat2 = collapse_pattern pl in
		{
			p_def = POr(pat,pat2);
			p_pos = punion pat.p_pos pat2.p_pos;
			p_type = pat.p_type
		}
	| [] ->
		assert false

let bind_remaining out pv stl =
	let rec loop stl pv =
		if Array.length pv = 0 then
			()
		else
			match stl,pv.(0).p_def with
			| st :: stl,PAny ->
				loop stl (array_tl pv)
			| st :: stl,PVar v ->
				bind_st out st v;
				loop stl (array_tl pv)
			| _ :: _,_->
				loop stl (array_tl pv)
			| [],_ ->
				()
	in
	loop stl pv

let rec compile mctx stl pmat = match pmat with
	| [] ->
		assert false
	| (pv,out) :: pl ->
		let i = pick_column pmat in
		if i = -1 then begin
			out.o_num_paths <- out.o_num_paths + 1;
			bind_remaining out pv stl;
			if out.o_guard = None || match pl with [] -> true | _ -> false then
				Bind(out,None)
			else
				Bind(out,Some (compile mctx stl pl))
		end else if i > 0 then begin
			swap_pmat_columns i pmat;
			let stls = swap_columns i stl in
			compile mctx stls pmat
		end else begin
			let st_head,st_tail = match stl with st :: stl -> st,stl | _ -> assert false in
			let sigma = column_sigma mctx st_head pmat in
			let all,inf = all_ctors mctx st_head in
			let cases = List.map (fun (c,g) ->
				if not g then all := PMap.remove c.c_def !all;
				let spec = spec mctx c pmat in
				let hsubs = (mk_subs st_head c) in
				let subs = hsubs @ st_tail in
				let dt = compile mctx subs spec in
				c,dt
			) sigma in
			let def = default mctx pmat in
			match def,cases with
			| _,[{c_def = CFields _},dt] ->
				dt
			| _ when not inf && PMap.is_empty !all ->
				Switch(st_head,cases)
			| [],_ when inf && not mctx.need_val ->
				Switch(st_head,cases)
			| [],_ when inf ->
				raise (Not_exhaustive(any,st_head))
			| [],_ ->
				let pl = PMap.foldi (fun cd p acc -> (mk_con_pat cd [] t_dynamic p) :: acc) !all [] in
				raise (Not_exhaustive(collapse_pattern pl,st_head))
			| def,[] ->
				compile mctx st_tail def
			| def,_ ->
				let cdef = mk_con (CConst TNull) t_dynamic st_head.st_pos in
				let cases = cases @ [cdef,compile mctx st_tail def] in
				Switch(st_head,cases)
		end

(* Conversion to typed AST *)

let mk_const ctx p = function
	| TString s -> mk (TConst (TString s)) ctx.com.basic.tstring p
	| TInt i -> mk (TConst (TInt i)) ctx.com.basic.tint p
	| TFloat f -> mk (TConst (TFloat f)) ctx.com.basic.tfloat p
	| TBool b -> mk (TConst (TBool b)) ctx.com.basic.tbool p
	| TNull -> mk (TConst TNull) (ctx.com.basic.tnull (mk_mono())) p
	| _ -> error "Unsupported constant" p

let rec st_to_unique_name ctx st = match st.st_def with
	| SField(st,f) -> st_to_unique_name ctx st ^ "_f" ^ f
	| SArray(st,i) -> st_to_unique_name ctx st ^ "_a" ^ (string_of_int i)
	| SEnum(st,n,i) -> st_to_unique_name ctx st ^ "_e" ^ n ^ "_" ^ (string_of_int i)
	| SVar v -> v.v_name
	| STuple (st,_,_) -> st_to_unique_name ctx st

let rec st_to_texpr mctx st = match st.st_def with
	| SVar v -> mk (TLocal v) v.v_type st.st_pos
	| SField (sts,f) -> mk (TField(st_to_texpr mctx sts,FDynamic f)) st.st_type st.st_pos
	| SArray (sts,i) -> mk (TArray(st_to_texpr mctx sts,mk_const mctx.ctx st.st_pos (TInt (Int32.of_int i)))) st.st_type st.st_pos
	| STuple (st,_,_) -> st_to_texpr mctx st
	| SEnum _ ->
		let n = st_to_unique_name mctx st in
		let v = try	Hashtbl.find mctx.v_lookup n with Not_found ->
			let v = alloc_var n st.st_type in
			Hashtbl.add mctx.v_lookup n v;
			v
		in
		mctx.ctx.locals <- PMap.add n v mctx.ctx.locals;
		mk (TLocal v) v.v_type st.st_pos

let replace_locals mctx out e =
	let all_subterms = Hashtbl.create 0 in
	let replace v =
		let st = List.assq v out.o_bindings in
		Hashtbl.remove all_subterms st;
		st
	in
	let rec loop e = match e.eexpr with
		| TLocal v ->
			(try
				let st = replace v in
				unify mctx.ctx e.etype st.st_type e.epos;
				st_to_texpr mctx st
			with Not_found ->
				e)
		| _ ->
			Type.map_expr loop e
	in
	let e = loop e in
	Hashtbl.iter (fun _ st -> mctx.ctx.com.warning "This variable is unused" (pos st)) all_subterms;
	e

let rec to_typed_ast mctx need_val dt =
	match dt with
	| Goto _ ->
		error "Not implemented yet" Ast.null_pos
	| Bind(out,dt) ->
		replace_locals mctx out begin match out.o_guard,dt with
			| Some eg,None ->
				mk (TIf(eg,out.o_expr,None)) t_dynamic out.o_expr.epos
			| Some eg,Some dt ->
				let eelse = to_typed_ast mctx need_val dt in
				mk (TIf(eg,out.o_expr,Some eelse)) eelse.etype (punion out.o_expr.epos eelse.epos)
			| _,None ->
				out.o_expr
			| _ -> assert false
		end
	| Switch(st,cases) ->
		match follow st.st_type with
		| TEnum(en,pl) -> to_enum_switch mctx need_val en pl st cases
		| TInst({cl_path = [],"Array"},[t]) -> to_array_switch mctx need_val t st cases
		| t -> to_value_switch mctx need_val t st cases

and to_enum_switch mctx need_val en pl st cases =
	let eval = st_to_texpr mctx st in
	let et = monomorphs mctx.ctx.type_params (TEnum(en,pl)) in
	let def = ref None in
	let el = ref [] in
	let rec loop acc cases = match cases with
		| [] ->
			el := acc;
			[]
		| (({c_def = CEnum(en,ef) }) as con,dt) :: cases ->
			let save = save_locals mctx.ctx in
			let etf = follow (monomorphs en.e_types (monomorphs ef.ef_params ef.ef_type)) in
			let vl = match etf with
				| TFun(args,r) ->
					unify mctx.ctx r et con.c_pos;
					let vl = ExtList.List.mapi (fun i (_,_,t) ->
						let st = mk_st (SEnum(st,ef.ef_name,i)) t st.st_pos in
						Some (match (st_to_texpr mctx st).eexpr with TLocal v -> v | _ -> assert false)
					) args in
					Some vl
				| _ -> None
			in
			let e = to_typed_ast mctx need_val dt in
			save();
			([ef.ef_index],vl,e) :: loop (e :: acc) cases
		| (({c_def = CConst TNull }),dt) :: cases ->
			let e = to_typed_ast mctx need_val dt in
			def := Some e;
			loop (e :: acc) cases
		| (con,_) :: _ ->
			error ("Unexpected") con.c_pos
	in
	let cases = loop [] cases in
	let t = if not need_val then (mk_mono()) else unify_min mctx.ctx !el in
	mk (TMatch(eval,(en,pl),cases,!def)) t eval.epos

and to_value_switch mctx need_val t st cases =
	let eval = st_to_texpr mctx st in
	let def = ref None in
	let el = ref [] in
	let rec loop acc cases = match cases with
		| [] ->
			el := acc;
			[]
		| ({c_def = CConst TNull},dt) :: cases ->
			let e = to_typed_ast mctx need_val dt in
			def := Some e;
			loop (e :: acc) cases
		| ({c_def = CConst c } as con,dt) :: cases ->
			let e = to_typed_ast mctx need_val dt in
			([mk_const mctx.ctx con.c_pos c],e) :: loop (e :: acc) cases
		| ({c_def = CType mt } as con,dt) :: cases ->
			let e = to_typed_ast mctx need_val dt in
			([Typer.type_module_type mctx.ctx mt None con.c_pos],e) :: loop (e :: acc) cases
		| ({c_def = CExpr e1},dt) :: cases ->
			let e = to_typed_ast mctx need_val dt in
			([e1],e) :: loop (e :: acc) cases
		| (con,_) :: _ ->
			error ("Unexpected "  ^ (s_con con)) con.c_pos
	in
	let cases = loop [] cases in
	let t = if not need_val then (mk_mono()) else unify_min mctx.ctx !el in
	mk (TSwitch(eval,cases,!def)) t eval.epos

and to_array_switch mctx need_val t st cases =
	let def = ref None in
	let el = ref [] in
	let rec loop acc cases = match cases with
		| [] ->
			el := acc;
			[]
		| ({c_def = CArray i} as con,dt) :: cases ->
			let e = to_typed_ast mctx need_val dt in
			([mk_const mctx.ctx con.c_pos (TInt (Int32.of_int i))],e) :: loop (e :: acc) cases
		| ({c_def = CConst TNull},dt) :: cases ->
			let e = to_typed_ast mctx need_val dt in
			def := Some e;
			loop (e :: acc) cases
		| (con,_) :: _ ->
			error ("Unexpected "  ^ (s_con con)) con.c_pos
	in
	let cases = loop [] cases in
	let eval = mk (TField(st_to_texpr mctx st,FDynamic "length")) mctx.ctx.com.basic.tint st.st_pos in
	let t = if not need_val then (mk_mono()) else unify_min mctx.ctx !el in
	mk (TSwitch(eval,cases,!def)) t eval.epos

(* Main *)

let rec collapse_case el = match el with
	| e :: [] ->
		e
	| e :: el ->
		let e2 = collapse_case el in
		EBinop(OpOr,e,e2),punion (pos e) (pos e2)
	| [] ->
		assert false

let match_expr ctx e cases def need_val with_type p =
	let cases = match cases,def with
		| [],None -> error "Empty switch" p
		| cases,Some def -> cases @ [[(EConst(Ident "_")),p],None,def]
		| _ -> cases
	in
	let evals = match fst e with
		| EArrayDecl el ->
			List.map (fun e -> type_expr ctx e true) el
		| _ ->
			let e = type_expr ctx e need_val in
			begin match e.etype with
			| TEnum(en,_) when PMap.is_empty en.e_constrs ->
				raise Exit
			| _ ->
				()
			end;
			[e]
	in
	let var_inits = ref [] in
	let a = List.length evals in
	let stl = ExtList.List.mapi (fun i e ->
		let rec loop e = match e.eexpr with
			| TField (ef,s) when (match s with FEnum _ -> false | _ -> true) ->
				mk_st (SField(loop ef,field_name s)) e.etype e.epos
			| TParenthesis e ->
				loop e
			| TLocal v ->
				mk_st (SVar v) e.etype e.epos
			| _ ->
				let v = gen_local ctx e.etype in
				var_inits := (v, Some e) :: !var_inits;
				mk_st (SVar v) e.etype e.epos
		in
		let st = loop e in
		if a = 1 then st else mk_st (STuple(st,i,a)) st.st_type st.st_pos
	) evals in
	let mctx = {
		ctx = ctx;
		stl = stl;
		need_val = need_val;
		v_lookup = Hashtbl.create 0;
		outcomes = PMap.empty;
		subtrees = Hashtbl.create 0;
		subtree_index = Hashtbl.create 0;
		num_subtrees = 0;
	} in
	let pl = List.map (fun (el,eg,e) ->
		let ep = collapse_case el in
		let save = save_locals ctx in
		let pl = match fst ep,stl with
			| EArrayDecl el,[st] when (match follow st.st_type with TInst({cl_path=[],"Array"},[_]) -> true | _ -> false) ->
				[to_pattern mctx ep st]
			| EArrayDecl el,stl ->
				begin try
					List.map2 (fun e st -> to_pattern mctx e st) el stl
				with Invalid_argument _ ->
					error ("Invalid number of arguments: expected " ^ (string_of_int (List.length stl)) ^ ", found " ^ (string_of_int (List.length el))) (pos ep)
				end
			| _,[st] ->
				[to_pattern mctx ep st]
			| EConst(Ident "_"),stl ->
				List.map (fun st -> mk_any st.st_type st.st_pos) stl
			| _,_ ->
				error "Unrecognized pattern" (pos ep);
		in
		let e = match e with
			| None -> mk (TBlock []) ctx.com.basic.tvoid (punion_el el)
			| Some e -> if need_val then type_expr_with_type ctx e with_type false else type_expr ctx e false
		in
		let eg = match eg with None -> None | Some e -> Some (type_expr ctx e true) in
		save();
		let out = mk_out mctx e eg pl (pos ep) in
		Array.of_list pl,out
	) cases in
	if Common.defined ctx.com Define.MatchDebug then print_endline (s_pat_matrix pl);
	begin try
		let dt = compile mctx stl pl in
		if Common.defined ctx.com Define.MatchDebug then print_endline (s_dt "" dt);
		PMap.iter (fun _ out -> if out.o_num_paths = 0 then display_error ctx "This pattern is unused" out.o_pos) mctx.outcomes;
		let e = to_typed_ast mctx need_val dt in
		let t = if not need_val then
			mk_mono()
		else
			try Typer.unify_min_raise ctx (List.rev_map (fun (_,out) -> out.o_expr) pl) with Error (Unify l,p) -> error (error_msg (Unify l)) p
		in
		if !var_inits = [] then
			e
		else begin
			mk (TBlock [
				mk (TVars !var_inits) t_dynamic e.epos;
				e;
			]) t e.epos
		end
	with Not_exhaustive(pat,st) ->
		let rec s_st_r nv v st = match st.st_def with
			| SVar v1 ->
				(if nv then v1.v_name else "") ^ v
			| STuple(st,i,a)->
				let r = a - i - 1 in
				"[" ^ (st_args i r (s_st_r nv v st)) ^ "]"
			| SArray (st,i) -> s_st_r true ("[" ^ (string_of_int i) ^ "] = " ^ v) st
			| SField (st,f) -> s_st_r true ("." ^ f ^ " = " ^ v) st
			| SEnum(sts,n,i) ->
				let ef = match follow sts.st_type with
					| TEnum(en,_) -> PMap.find n en.e_constrs
					| _ -> raise Not_found
				in
				let len = match follow ef.ef_type with TFun(args,_) -> List.length args | _ -> 0 in
				s_st_r false (ef.ef_name ^ "(" ^ (st_args i (len - 1 - i) v) ^ ")") sts
		in
		error ("Unmatched patterns: " ^ (s_st_r false (s_pat pat) st)) p
	end;
;;
match_expr_ref := match_expr