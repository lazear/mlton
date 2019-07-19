(* Copyright (C) 2019 Matthew Fluet.
 * Copyright (C) 2013-2014 Matthew Fluet, Brian Leibig.
 *
 * MLton is released under a HPND-style license.
 * See the file MLton-LICENSE for details.
 *)

functor LLVMCodegen(S: LLVM_CODEGEN_STRUCTS): LLVM_CODEGEN =
struct

open S

open Machine

structure ChunkLabel =
   struct
      open ChunkLabel
      fun toStringX cl = "X" ^ toString cl
      fun toString' cl =
         if !Control.llvmCC10
            then toStringX cl
            else toString cl
   end

local
    open Runtime
in
    structure GCField = GCField
end

datatype z = datatype RealSize.t
datatype z = datatype WordSize.prim

(* LLVM codegen context. Contains various values/functions that should
   be shared amongst all codegen functions. *)
datatype Context = Context of {
    amTimeProfiling: bool,
    program: Program.t,
    labelChunk: Label.t -> ChunkLabel.t,
    labelIndex: Label.t -> int,
    labelIndexAsString: Label.t -> string,
    nextChunks: Label.t vector
}

fun ctypes () =
    concat ["%uintptr_t = type i", Bits.toString (Control.Target.Size.cpointer ()), "\n"]

val mltypes =
"; ML types\n\
\%Int8 = type i8\n\
\%Int16 = type i16\n\
\%Int32 = type i32\n\
\%Int64 = type i64\n\
\%Real32 = type float\n\
\%Real64 = type double\n\
\%Word8 = type i8\n\
\%Word16 = type i16\n\
\%Word32 = type i32\n\
\%Word64 = type i64\n\
\%CPointer = type i8*\n\
\%Objptr = type i8*\n"

val chunkfntypes = "\
\%ChunkFn_t = type %uintptr_t(%CPointer,%CPointer,%CPointer,%uintptr_t)\n\
\%ChunkFnPtr_t = type %ChunkFn_t*\n\
\%ChunkFnPtrArr_t = type [0 x %ChunkFnPtr_t]\n"

val llvmIntrinsics =
"declare float @llvm.sqrt.f32(float %Val)\n\
\declare double @llvm.sqrt.f64(double %Val)\n\
\declare float @llvm.sin.f32(float %Val)\n\
\declare double @llvm.sin.f64(double %Val)\n\
\declare float @llvm.cos.f32(float %Val)\n\
\declare double @llvm.cos.f64(double %Val)\n\
\declare float @llvm.exp.f32(float %Val)\n\
\declare double @llvm.exp.f64(double %Val)\n\
\declare float @llvm.log.f32(float %Val)\n\
\declare double @llvm.log.f64(double %Val)\n\
\declare float @llvm.log10.f32(float %Val)\n\
\declare double @llvm.log10.f64(double %Val)\n\
\declare float @llvm.fma.f32(float %a, float %b, float %c)\n\
\declare double @llvm.fma.f64(double %a, double %b, double %c)\n\
\declare float @llvm.fabs.f32(float %Val) ; requires LLVM 3.2\n\
\declare double @llvm.fabs.f64(double %Val) ; requires LLVM 3.2\n\
\declare float @llvm.rint.f32(float %Val) ; requires LLVM 3.3\n\
\declare double @llvm.rint.f64(double %Val) ; requires LLVM 3.3\n\
\declare {i8, i1} @llvm.sadd.with.overflow.i8(i8 %a, i8 %b)\n\
\declare {i16, i1} @llvm.sadd.with.overflow.i16(i16 %a, i16 %b)\n\
\declare {i32, i1} @llvm.sadd.with.overflow.i32(i32 %a, i32 %b)\n\
\declare {i64, i1} @llvm.sadd.with.overflow.i64(i64 %a, i64 %b)\n\
\declare {i8, i1} @llvm.uadd.with.overflow.i8(i8 %a, i8 %b)\n\
\declare {i16, i1} @llvm.uadd.with.overflow.i16(i16 %a, i16 %b)\n\
\declare {i32, i1} @llvm.uadd.with.overflow.i32(i32 %a, i32 %b)\n\
\declare {i64, i1} @llvm.uadd.with.overflow.i64(i64 %a, i64 %b)\n\
\declare {i8, i1} @llvm.ssub.with.overflow.i8(i8 %a, i8 %b)\n\
\declare {i16, i1} @llvm.ssub.with.overflow.i16(i16 %a, i16 %b)\n\
\declare {i32, i1} @llvm.ssub.with.overflow.i32(i32 %a, i32 %b)\n\
\declare {i64, i1} @llvm.ssub.with.overflow.i64(i64 %a, i64 %b)\n\
\declare {i8, i1} @llvm.usub.with.overflow.i8(i8 %a, i8 %b)\n\
\declare {i16, i1} @llvm.usub.with.overflow.i16(i16 %a, i16 %b)\n\
\declare {i32, i1} @llvm.usub.with.overflow.i32(i32 %a, i32 %b)\n\
\declare {i64, i1} @llvm.usub.with.overflow.i64(i64 %a, i64 %b)\n\
\declare {i8, i1} @llvm.smul.with.overflow.i8(i8 %a, i8 %b)\n\
\declare {i16, i1} @llvm.smul.with.overflow.i16(i16 %a, i16 %b)\n\
\declare {i32, i1} @llvm.smul.with.overflow.i32(i32 %a, i32 %b)\n\
\declare {i64, i1} @llvm.smul.with.overflow.i64(i64 %a, i64 %b)\n\
\declare {i8, i1} @llvm.umul.with.overflow.i8(i8 %a, i8 %b)\n\
\declare {i16, i1} @llvm.umul.with.overflow.i16(i16 %a, i16 %b)\n\
\declare {i32, i1} @llvm.umul.with.overflow.i32(i32 %a, i32 %b)\n\
\declare {i64, i1} @llvm.umul.with.overflow.i64(i64 %a, i64 %b)\n"

fun implementsPrim (p: 'a Prim.t): bool =
   let
      datatype z = datatype Prim.Name.t
   in
      case Prim.name p of
         CPointer_add => true
       | CPointer_diff => true
       | CPointer_equal => true
       | CPointer_fromWord => true
       | CPointer_lt => true
       | CPointer_sub => true
       | CPointer_toWord => true
       | FFI_Symbol _ => true
       | Real_Math_acos _ => false
       | Real_Math_asin _ => false
       | Real_Math_atan _ => false
       | Real_Math_atan2 _ => false
       | Real_Math_cos _ => true
       | Real_Math_exp _ => true
       | Real_Math_ln _ => true
       | Real_Math_log10 _ => true
       | Real_Math_sin _ => true
       | Real_Math_sqrt _ => true
       | Real_Math_tan _ => false
       | Real_abs _ => true (* Requires LLVM 3.2 to use "llvm.fabs" intrinsic *)
       | Real_add _ => true
       | Real_castToWord _ => true
       | Real_div _ => true
       | Real_equal _ => true
       | Real_ldexp _ => false
       | Real_le _ => true
       | Real_lt _ => true
       | Real_mul _ => true
       | Real_muladd _ => true
       | Real_mulsub _ => true
       | Real_neg _ => true
       | Real_qequal _ => true
       | Real_rndToReal _ => true
       | Real_rndToWord _ => true
       | Real_round _ => true (* Requires LLVM 3.3 to use "llvm.rint" intrinsic *)
       | Real_sub _ => true
       | Thread_returnToC => false
       | Word_add _ => true
       | Word_addCheckP _ => true
       | Word_andb _ => true
       | Word_castToReal _ => true
       | Word_equal _ => true
       | Word_extdToWord _ => true
       | Word_lshift _ => true
       | Word_lt _ => true
       | Word_mul _ => true
       | Word_mulCheckP (ws, _) =>
            (case (!Control.Target.arch, ws) of
                (Control.Target.X86, ws) =>
                   (* @llvm.smul.with.overflow.i64 becomes a call to __mulodi4.
                    * @llvm.umul.with.overflow.i64 becomes a call to __udivdi3.
                    * These are provided by compiler-rt and not always by libgcc.
                    * In any case, do not depend on non-standard libraries.
                    *)
                   not (WordSize.equals (ws, WordSize.word64))
              | _ => true)
       | Word_neg _ => true
       | Word_negCheckP _ => true
       | Word_notb _ => true
       | Word_orb _ => true
       | Word_quot _ => true
       | Word_rem _ => true
       | Word_rndToReal _ => true
       | Word_rol _ => true
       | Word_ror _ => true
       | Word_rshift _ => true
       | Word_sub _ => true
       | Word_subCheckP _ => true
       | Word_xorb _ => true
       | _ => false
   end

(* WordX.toString converts to hexadecimal, this converts to base 10 *)
fun llwordx (w: WordX.t) =
    IntInf.format (WordX.toIntInf w, StringCvt.DEC)

fun llint (i: int) =
    if i >= 0
    then Int.toString i
    else "-" ^ Int.toString (~ i)

fun llbytes b = llint (Bytes.toInt b)

fun llws (ws: WordSize.t): string =
    case WordSize.prim ws of
        WordSize.W8 => "%Word8"
      | WordSize.W16 => "%Word16"
      | WordSize.W32 => "%Word32"
      | WordSize.W64 => "%Word64"

fun llwsInt (ws: WordSize.t): string =
    case WordSize.prim ws of
        WordSize.W8 => "i8"
      | WordSize.W16 => "i16"
      | WordSize.W32 => "i32"
      | WordSize.W64 => "i64"

fun llrs (rs: RealSize.t): string =
    case rs of
        RealSize.R32 => "%Real32"
      | RealSize.R64 => "%Real64"

(* Reuse CType for LLVM type *)
fun llty (ty: Type.t): string = "%" ^ CType.toString (Type.toCType ty)

fun typeOfGlobal global =
    let
        val t = Type.toCType (Global.ty global)
        val s = CType.toString t
        val number = llint (Global.numberOfType t)
        val array = concat ["[", number, " x %", s, "]"]
    in
        array
    end

fun getTypeFromPointer (typ: string):string =
    case typ of
        "%CPointer" => "i8"
      | "%Objptr" => "i8"
      | t =>
        let
            val str_list = String.explode t
            val len = List.length str_list
            val last_char = List.nth (str_list, len - 1)
        in
          if Char.equals (last_char, #"*")
          then String.implode (List.firstN (str_list, len - 1))
          else t
        end

(* Makes a two-operand instruction:
 * <lhs> = <opr> <ty> <a0>, <a1>
*)
fun mkinst (lhs, opr, ty, a0, a1) =
    concat ["\t", lhs, " = ", opr, " ", ty, " ", a0, ", ", a1, "\n"]

(* Makes a call to an LLVM math intrinsic function, given a RealSize as rs:
 * <lhs> = call type @llvm.<f>.fX(type <a0>)
*)
fun mkmath (lhs, f, rs, a0) =
    let
        val ty = llrs rs
        val fx = case rs of RealSize.R32 => "f32" | RealSize.R64 => "f64"
    in
        concat ["\t", lhs, " = call ", ty, " @llvm.", f, ".", fx, "(", ty, " ", a0, ")\n"]
    end

(* Makes a conversion instruction:
 * <lhs> = <opr> <fromty> <arg> to <toty>
*)
fun mkconv (lhs, opr, fromty, arg, toty) =
    concat ["\t", lhs, " = ", opr, " ", fromty, " ", arg, " to ", toty, "\n"]

(* Makes a getelementptr instruction:
 * <lhs> = getelementptr inbounds <ty>, <ty>* <arg>, [i32 <idx>]+
 * where <idcs> is a list of integer offsets
 * and ty must be a pointer type
 *)
fun mkgep (lhs, ty, arg, idcs) =
    let
        val indices = String.concatWith (List.map (idcs, fn (ity, i) => ity ^ " " ^ i), ", ")
    in
        concat ["\t", lhs, " = getelementptr inbounds ", getTypeFromPointer ty, ", ", ty, " ", arg, ", ", indices, "\n"]
    end



structure Metadata = struct
   datatype t =
      Unnamed of int
   fun str (Unnamed i) = "!" ^ (Int.toString i)

   val metaDataCounter = ref 0
   fun new () =
      let
         val i = !metaDataCounter
         val () = Int.inc metaDataCounter
      in
         Unnamed i
      end
   fun reset () =
      metaDataCounter := 0

   fun defineNode (t, ts) =
      concat
         [str t,
          " = !{",
          String.concatWith (ts, ", "),
          "}"]
end

structure SimpleOper = struct

   datatype t = Stack of int
              | Offset of int
              | SequenceOffset
              | Other
   val equals : t * t -> bool = op =
   val hash =
      fn Stack i => Hash.combine (0w0, Word.fromInt i)
       | Offset i => Hash.combine (0w1, Word.fromInt i)
       | SequenceOffset => Hash.permute 0w2
       | Other => Hash.permute 0w3
   val fromOper =
      fn Operand.StackOffset
         (StackOffset.T {offset, ...}) => Stack (Bytes.toInt offset)
       | Operand.Offset {offset, base, ...} =>
         if Type.isObjptr (Operand.ty base)
         then Offset (Bytes.toInt offset)
         else Other
       | Operand.SequenceOffset {base, ...} =>
         if Type.isObjptr (Operand.ty base)
         then SequenceOffset
         else Other
       | _ => Other
   val toString =
      fn Stack i => "Stack " ^ Int.toString i
       | Offset i => "Offset " ^ Int.toString i
       | SequenceOffset => "SequenceOffset"
       | Other => "Other"
end

val operScopes : (SimpleOper.t, Metadata.t) HashTable.t =
   HashTable.new
      {hash = SimpleOper.hash,
       equals = SimpleOper.equals}

fun scopeString scope =
   concat [", !tbaa ", Metadata.str scope]
(* Generates the string for alias.scope and noalias metadata *)
fun getOperScopes t =
   HashTable.lookupOrInsert
   (operScopes, SimpleOper.fromOper t,
    Metadata.new)

fun mkOperScope oper =
   case !Control.llvmAAMD of
      Control.LLVMAliasAnalysisMetaData.None => ""
    | Control.LLVMAliasAnalysisMetaData.TBAA =>
         scopeString (getOperScopes oper)

(* Makes a load instruction:
 * <lhs> = load <ty>, <ty>* <arg>
 * where ty must be a pointer type
 *)
fun mkload (lhs, ty, arg, scope) = concat ["\t", lhs, " = load ", getTypeFromPointer ty, ", ", ty, " ", arg, scope, "\n"]

(* Makes a store instruction:
 * store <ty> <arg>, <ty>* <loc>
 * where <ty> is the type of <arg>
 *)
fun mkstore (ty, arg, loc, scope) = concat ["\tstore ", ty, " ", arg, ", ", ty, "* ", loc, scope, "\n"]

val tempCounter = Counter.new 0

fun resetLLVMTemp () = Counter.reset (tempCounter, 0)
fun nextLLVMTemp () = concat ["%t", Int.toString (Counter.next tempCounter)]

fun temporaryName (ty: CType.t, index: int): string =
    concat ["%temp", CType.name ty, "_", Int.toString index]

val cFunctions : string list ref = ref []

fun addCFunction f = if not (List.contains (!cFunctions, f, String.equals))
                     then cFunctions := List.cons (f, !cFunctions)
                     else ()

val ffiSymbols : {name: string, cty: CType.t option, symbolScope: CFunction.SymbolScope.t} list ref = ref []

fun addFfiSymbol s = if not (List.contains (!ffiSymbols, s, fn ({name=n1, ...}, {name=n2, ...}) =>
                             String.equals (n1, n2)))
                     then ffiSymbols := List.cons (s, !ffiSymbols)
                     else ()

(* argv - vector of (pre, ty, addr) triples
   i - index of argv
   returns: (pre, type, temp)
 *)
fun getArg (argv, i) =
    if Vector.length argv > i
    then Vector.sub (argv, i)
    else ("", "", "")

(* Converts an operand into its LLVM representation. Returns a triple
 (pre, ty, temporary) where

 pre - A string containing preliminary statements that must be
 executed before the temporary can be referenced

 ty - A string containing the LLVM representation of the temporary's
 type when dereferenced (meaning temporary is really a pointer)

 temporary - The temporary containing a pointer to the value of the operand
 *)
fun getOperandAddr (cxt, operand) =
   let
      val scope = mkOperScope operand
   in
    case operand of
        Operand.Contents {oper, ty} =>
        let
            val (operPre, operTy, operTemp) = getOperandAddr (cxt, oper)
            val llvmTy = llty ty
            val loaded = nextLLVMTemp ()
            val load = mkload (loaded, operTy ^ "*", operTemp, scope)
            val temporary = nextLLVMTemp ()
            val cast = mkconv (temporary, "bitcast", operTy, loaded, llvmTy ^ "*")
        in
            (concat [operPre, load, cast], llvmTy, temporary)
        end
      | Operand.Frontier => ("", "%CPointer", "%frontier")
      | Operand.Global global =>
        let
            val globalType = Global.ty global
            val globalIndex = Global.index global
            val llvmTy = llty globalType
            val ty = typeOfGlobal global
            val globalID = "@global" ^ CType.toString (Type.toCType globalType)
            val ptr = nextLLVMTemp ()
            val gep = mkgep (ptr, ty ^ "*", globalID, [("i32", "0"), ("i32", llint globalIndex)])
        in
            (gep, llvmTy, ptr)
        end
      | Operand.Offset {base, offset, ty} =>
        let
            val (basePre, baseTy, baseTemp) = getOperandValue (cxt, base)
            val idx = llbytes offset
            val llvmTy = llty ty
            val ptr = nextLLVMTemp ()
            val gep = mkgep (ptr, baseTy, baseTemp, [("i32", idx)])
            val temporary = nextLLVMTemp ()
            val cast = mkconv (temporary, "bitcast", baseTy, ptr, llvmTy ^ "*")
        in
            (concat [basePre, gep, cast], llvmTy, temporary)
        end
      | Operand.SequenceOffset {base, index, offset, scale, ty} =>
        let
            (* arrayoffset = base + (index * scale) + offset *)
            val (basePre, baseTy, baseTemp) = getOperandValue (cxt, base)
            val (indexPre, indexTy, indexTemp) = getOperandValue (cxt, index)
            val scl = Scale.toString scale (* "1", "2", "4", or "8" *)
            val scaledIndex = nextLLVMTemp ()
            val scaleIndex = mkinst (scaledIndex, "mul nsw", indexTy, indexTemp, scl)
            val ofs = llbytes offset
            val offsettedIndex = nextLLVMTemp ()
            val offsetIndex = mkinst (offsettedIndex, "add nsw", indexTy, scaledIndex, ofs)
            val llvmTy = llty ty
            val ptr = nextLLVMTemp ()
            val gep = mkgep (ptr, baseTy, baseTemp, [(indexTy, offsettedIndex)])
            val castedPtr = nextLLVMTemp ()
            val cast = mkconv (castedPtr, "bitcast", baseTy, ptr, llvmTy ^ "*")
        in
            (concat [basePre, indexPre, scaleIndex, offsetIndex, gep, cast], llvmTy, castedPtr)
        end
      | Operand.StackOffset stackOffset =>
        let
            val StackOffset.T {offset, ty} = stackOffset
            val idx = llbytes offset
            val stackTop = nextLLVMTemp ()
            val load = mkload (stackTop, "%CPointer*", "%stackTop", scope)
            val gepTemp = nextLLVMTemp ()
            val gep = mkgep (gepTemp, "%CPointer", stackTop, [("i32", idx)])
            val llvmTy = llty ty
            val temp = nextLLVMTemp ()
            val cast = mkconv (temp, "bitcast", "%CPointer", gepTemp, llvmTy ^ "*")
        in
            (concat [load, gep, cast], llvmTy, temp)
        end
      | Operand.StackTop => ("", "%CPointer", "%stackTop")
      | Operand.Temporary temporary =>
        let
            val tempTy = Temporary.ty temporary
            val temp = temporaryName (Type.toCType tempTy, Temporary.index temporary)
            val ty = llty tempTy
        in
            ("", ty, temp)
        end
      | _ => Error.bug ("Cannot get address of " ^ Operand.toString operand)
   end

(* ty is the type of the value *)
and getOperandValue (cxt, operand) =
    let
        fun loadOperand () =
            let
                val (pre, ty, addr) = getOperandAddr (cxt, operand)
                val scope = mkOperScope operand
                val temp = nextLLVMTemp ()
                val load = mkload (temp, ty ^ "*", addr, scope)
            in
                (pre ^ load, ty, temp)
            end
        val Context { labelIndexAsString, ... } = cxt
    in
        case operand of
            Operand.Cast (oper, ty) =>
            let
                val (operPre, operTy, operTemp) =
                   getOperandValue (cxt, oper)
                val llvmTy = llty ty
                val temp = nextLLVMTemp ()
                fun isIntType cty = case cty of
                                            CType.Int8 => true
                                          | CType.Int16 => true
                                          | CType.Int32 => true
                                          | CType.Int64 => true
                                          | CType.Word8 => true
                                          | CType.Word16 => true
                                          | CType.Word32 => true
                                          | CType.Word64 => true
                                          | _ => false
                fun isPtrType cty = case cty of
                                            CType.CPointer => true
                                          | CType.Objptr => true
                                          | _ => false
                val operIsInt = (isIntType o Type.toCType o Operand.ty) oper
                val operIsPtr = (isPtrType o Type.toCType o Operand.ty) oper
                val tyIsInt = (isIntType o Type.toCType) ty
                val tyIsPtr = (isPtrType o Type.toCType) ty
                val operation = if operIsInt andalso tyIsPtr
                                then "inttoptr"
                                else if operIsPtr andalso tyIsInt
                                        then "ptrtoint"
                                        else "bitcast"
                val inst = mkconv (temp, operation, operTy, operTemp, llvmTy)
            in
                (concat [operPre, inst], llvmTy, temp)
            end
          | Operand.Contents _ => loadOperand ()
          | Operand.Frontier => loadOperand ()
          | Operand.GCState => ("", "%CPointer", "%gcState")
          | Operand.Global _ => loadOperand ()
          | Operand.Label label => ("", llws (WordSize.cpointer ()), labelIndexAsString label)
          | Operand.Null => ("", "i8*", "null")
          | Operand.Offset _ => loadOperand ()
          | Operand.Real real => ("", (llrs o RealX.size) real, RealX.toString (real, {suffix = false}))
          | Operand.SequenceOffset _ => loadOperand ()
          | Operand.StackOffset _ => loadOperand ()
          | Operand.StackTop => loadOperand()
          | Operand.Temporary  _ => loadOperand ()
          | Operand.Word word => ("", (llws o WordX.size) word, llwordx word)
    end

(* Returns (instruction, ty) pair for the given prim operation *)
fun outputPrim (prim, res, argty, arg0, arg1, arg2) =
    let
        datatype z = datatype Prim.Name.t

        fun mkoverflowp (ws, intrinsic) =
        let
          val tmp1 = nextLLVMTemp ()
          val tmp2 = nextLLVMTemp ()
          val ty = llws ws
          val oper = concat ["\t", tmp1, " = call {", ty, ", i1} @llvm.",
                             intrinsic, ".with.overflow.", llwsInt ws,
                             "(", ty, " ", arg0, ", ", ty, " ", arg1, ")\n"]
          val extr = concat ["\t", tmp2, " = extractvalue {", ty, ", i1} ", tmp1,
                             ", 1\n"]
          val ext = mkconv (res, "zext", "i1", tmp2, "%Word32")
        in
          (concat [oper, extr, ext], "%Word32")
        end
    in
        case Prim.name prim of
            CPointer_add =>
            let
                val tmp1 = nextLLVMTemp ()
                val inst1 = mkconv (tmp1, "ptrtoint", "%CPointer", arg0, "%uintptr_t")
                val tmp2 = nextLLVMTemp ()
                val inst2 = mkinst (tmp2, "add", "%uintptr_t", tmp1, arg1)
                val inst3 = mkconv (res, "inttoptr", "%uintptr_t", tmp2, "%CPointer")
            in
                (concat [inst1, inst2, inst3], "%CPointer")
            end
          | CPointer_diff =>
            let
                val tmp1 = nextLLVMTemp ()
                val inst1 = mkconv (tmp1, "ptrtoint", "%CPointer", arg0, "%uintptr_t")
                val tmp2 = nextLLVMTemp ()
                val inst2 = mkconv (tmp2, "ptrtoint", "%CPointer", arg1, "%uintptr_t")
                val inst3 = mkinst (res, "sub", "%uintptr_t", tmp1, tmp2)
            in
                (concat [inst1, inst2, inst3], "%uintptr_t")
            end
          | CPointer_equal =>
            let
                val temp = nextLLVMTemp ()
                val cmp = mkinst (temp, "icmp eq", "%CPointer", arg0, arg1)
                val ext = mkconv (res, "zext", "i1", temp, "%Word32")
            in
                (concat [cmp, ext], "%Word32")
            end
          | CPointer_fromWord =>
            (mkconv (res, "inttoptr", "%uintptr_t", arg0, "%CPointer"), "%CPointer")
          | CPointer_lt =>
            let
                val temp = nextLLVMTemp ()
                val cmp = mkinst (temp, "icmp ult", "%CPointer", arg0, arg1)
                val ext = mkconv (res, "zext", "i1", temp, "%Word32")
            in
                (concat [cmp, ext], "%Word32")
            end
          | CPointer_sub =>
            let
                val tmp1 = nextLLVMTemp ()
                val inst1 = mkconv (tmp1, "ptrtoint", "%CPointer", arg0, "%uintptr_t")
                val tmp2 = nextLLVMTemp ()
                val inst2 = mkinst (tmp2, "sub", "%uintptr_t", tmp1, arg1)
                val inst3 = mkconv (res, "inttoptr", "%uintptr_t", tmp2, "%CPointer")
            in
                (concat [inst1, inst2, inst3], "%CPointer")
            end
          | CPointer_toWord =>
            (mkconv (res, "ptrtoint", "%CPointer", arg0, "%uintptr_t"), "%CPointer")
          | FFI_Symbol (s as {name, cty, ...}) =>
            let
                val () = addFfiSymbol s
                val ty = case cty of
                             SOME t => "%" ^ CType.toString t
                           | NONE => "i8"
                val inst = mkconv (res, "bitcast", ty ^ "*", "@" ^ name, "%CPointer")
            in
                (inst, "%CPointer")
            end
          | Real_Math_cos rs => (mkmath (res, "cos", rs, arg0), llrs rs)
          | Real_Math_exp rs => (mkmath (res, "exp", rs, arg0), llrs rs)
          | Real_Math_ln rs => (mkmath (res, "log", rs, arg0), llrs rs)
          | Real_Math_log10 rs => (mkmath (res, "log10", rs, arg0), llrs rs)
          | Real_Math_sin rs => (mkmath (res, "sin", rs, arg0), llrs rs)
          | Real_Math_sqrt rs => (mkmath (res, "sqrt", rs, arg0), llrs rs)
          | Real_abs rs => (mkmath (res, "fabs", rs, arg0), llrs rs)
          | Real_add rs => (mkinst (res, "fadd", llrs rs, arg0, arg1), llrs rs)
          | Real_castToWord (rs, ws) =>
            (case rs of
                 R32 => if WordSize.equals (ws, WordSize.word32)
                        then (mkconv (res, "bitcast", "float", arg0, "i32"), "i32")
                        else Error.bug "LLVM codegen: Real_castToWord"
               | R64 => if WordSize.equals (ws, WordSize.word64)
                        then (mkconv (res, "bitcast", "double", arg0, "i64"), "i64")
                        else Error.bug "LLVM codegen: Real_castToWord")
          | Real_div rs => (mkinst (res, "fdiv", llrs rs, arg0, arg1), llrs rs)
          | Real_equal rs =>
            let
                val temp = nextLLVMTemp ()
                val cmp = mkinst (temp, "fcmp oeq", llrs rs, arg0, arg1)
                val ext = mkconv (res, "zext", "i1", temp, "%Word32")
            in
                (concat [cmp, ext], "%Word32")
            end
          | Real_le rs =>
            let
                val temp = nextLLVMTemp ()
                val cmp = mkinst (temp, "fcmp ole", llrs rs, arg0, arg1)
                val ext = mkconv (res, "zext", "i1", temp, "%Word32")
            in
                (concat [cmp, ext], "%Word32")
            end
          | Real_lt rs =>
            let
                val temp = nextLLVMTemp ()
                val cmp = mkinst (temp, "fcmp olt", llrs rs, arg0, arg1)
                val ext = mkconv (res, "zext", "i1", temp, "%Word32")
            in
                (concat [cmp, ext], "%Word32")
            end
          | Real_mul rs => (mkinst (res, "fmul", llrs rs, arg0, arg1), llrs rs)
          | Real_muladd rs =>
            let
                val size = case rs of
                               RealSize.R32 => "f32"
                             | RealSize.R64 => "f64"
                val llsize = llrs rs
                val inst = concat ["\t", res, " = call ", llsize, " @llvm.fma.", size, "(",
                                   llsize, " ", arg0, ", ", llsize, " ",
                                   arg1, ", ", llsize, " ", arg2, ")\n"]
            in
                (inst, llsize)
            end
          | Real_mulsub rs =>
            let
                val size = case rs of
                               RealSize.R32 => "f32"
                             | RealSize.R64 => "f64"
                val llsize = llrs rs
                val tmp1 = nextLLVMTemp ()
                val inst1 = mkinst (tmp1, "fsub", llsize, "-0.0", arg2)
                val inst2 = concat ["\t", res, " = call ", llsize, " @llvm.fma.", size, "(",
                                    llsize, " ", arg0, ", ", llsize, " ",
                                    arg1, ", ", llsize, " ", tmp1, ")\n"]
            in
                (concat [inst1, inst2], llsize)
            end
          | Real_neg rs => (mkinst (res, "fsub", llrs rs, "-0.0", arg0), llrs rs)
          | Real_qequal rs =>
            let
                val temp = nextLLVMTemp ()
                val cmp = mkinst (temp, "fcmp ueq", llrs rs, arg0, arg1)
                val ext = mkconv (res, "zext", "i1", temp, "%Word32")
            in
                (concat [cmp, ext], "%Word32")
            end
          | Real_rndToReal rs =>
            (case rs of
                 (RealSize.R64, RealSize.R32) =>
                 (mkconv (res, "fptrunc", "double", arg0, "float"), "float")
               | (RealSize.R32, RealSize.R64) =>
                 (mkconv (res, "fpext", "float", arg0, "double"), "double")
               | (RealSize.R32, RealSize.R32) => (* this is a no-op *)
                 (mkconv (res, "bitcast", "float", arg0, "float"), "float")
               | (RealSize.R64, RealSize.R64) => (* this is a no-op *)
                 (mkconv (res, "bitcast", "double", arg0, "double"), "double"))
          | Real_rndToWord (rs, ws, {signed}) =>
            let
                val opr = if signed then "fptosi" else "fptoui"
            in
                (mkconv (res, opr, llrs rs, arg0, llws ws), llws ws)
            end
          | Real_round rs => (mkmath (res, "rint", rs, arg0), llrs rs)
          | Real_sub rs => (mkinst (res, "fsub", llrs rs, arg0, arg1), llrs rs)
          | Word_add ws => (mkinst (res, "add", llws ws, arg0, arg1), llws ws)
          | Word_addCheckP (ws, {signed}) =>
              mkoverflowp (ws, if signed then "sadd" else "uadd")
          | Word_andb ws => (mkinst (res, "and", llws ws, arg0, arg1), llws ws)
          | Word_castToReal (ws, rs) =>
            (case rs of
                 R32 => if WordSize.equals (ws, WordSize.word32)
                        then (mkconv (res, "bitcast", "i32", arg0, "float"), "float")
                        else Error.bug "LLVM codegen: Word_castToReal"
               | R64 => if WordSize.equals (ws, WordSize.word64)
                        then (mkconv (res, "bitcast", "i64", arg0, "double"), "double")
                        else Error.bug "LLVM codegen: Word_castToReal")
          | Word_equal _ =>
            let
                val temp = nextLLVMTemp ()
                val cmp = mkinst (temp, "icmp eq", argty, arg0, arg1)
                val ext = mkconv (res, "zext", "i1", temp, "%Word32")
            in
                (concat [cmp, ext], "%Word32")
            end
          | Word_extdToWord (ws1, ws2, {signed}) =>
            let
                val opr = case WordSize.compare (ws1, ws2) of
                              LESS => if signed then "sext" else "zext"
                            | EQUAL => Error.bug "LLVM codegen: Word_extdToWord"
                            | GREATER => "trunc"
            in
                (mkconv (res, opr, llws ws1, arg0, llws ws2), llws ws2)
            end
          | Word_lshift ws => (mkinst (res, "shl", llws ws, arg0, arg1), llws ws)
          | Word_lt (ws, {signed}) =>
            let
                val temp = nextLLVMTemp ()
                val cmp = mkinst (temp, if signed then "icmp slt" else "icmp ult",
                                  llws ws, arg0, arg1)
                val ext = mkconv (res, "zext", "i1", temp, "%Word32")
            in
                (concat [cmp, ext], "%Word32")
            end
          | Word_mul (ws, _) => (mkinst (res, "mul", llws ws, arg0, arg1), llws ws)
          | Word_mulCheckP (ws, {signed}) =>
              mkoverflowp (ws, if signed then "smul" else "umul")
          | Word_neg ws => (mkinst (res, "sub", llws ws, "0", arg0), llws ws)
          | Word_negCheckP (ws, {signed}) =>
            let
              val ty = llws ws
              val tmp1 = nextLLVMTemp ()
              val tmp2 = nextLLVMTemp ()
              val intrinsic = if signed then "ssub" else "usub"
              val oper = concat ["\t", tmp1, " = call {", ty, ", i1} @llvm.",
                                 intrinsic, ".with.overflow.", llwsInt ws,
                                 "(", ty,  " 0, ", ty, " ", arg0, ")\n"]
              val extr = concat ["\t", tmp2 , " = extractvalue {", ty, ", i1}",
                                 tmp1, ", 1\n"]
              val ext = mkconv (res, "zext", "i1", tmp2, "%Word32")
            in
              (concat [oper, extr, ext], "%Word32")
            end
          | Word_notb ws => (mkinst (res, "xor", llws ws, arg0, "-1"), llws ws)
          | Word_orb ws => (mkinst (res, "or", llws ws, arg0, arg1), llws ws)
          | Word_quot (ws, {signed}) =>
            (mkinst (res, if signed then "sdiv" else "udiv", llws ws, arg0, arg1), llws ws)
          | Word_rem (ws, {signed}) =>
            (mkinst (res, if signed then "srem" else "urem", llws ws, arg0, arg1), llws ws)
          | Word_rndToReal (ws, rs, {signed}) =>
            let
                val opr = if signed then "sitofp" else "uitofp"
            in
                (mkconv (res, opr, llws ws, arg0, llrs rs), llrs rs)
            end
          | Word_rol ws =>
            let
                (* (arg0 >> (size - arg1)) | (arg0 << arg1) *)
                val ty = llws ws
                val tmp1 = nextLLVMTemp ()
                val inst1 = mkinst (tmp1, "sub", ty, WordSize.toString ws, arg1)
                val tmp2 = nextLLVMTemp ()
                val inst2 = mkinst (tmp2, "lshr", ty, arg0, tmp1)
                val tmp3 = nextLLVMTemp ()
                val inst3 = mkinst (tmp3, "shl", ty, arg0, arg1)
                val inst4 = mkinst (res, "or", ty, tmp2, tmp3)
            in
                (concat [inst1, inst2, inst3, inst4], llws ws)
            end
          | Word_ror ws =>
            let
                (* (arg0 >> arg1) | (arg0 << (size - arg1)) *)
                val ty = llws ws
                val tmp1 = nextLLVMTemp ()
                val inst1 = mkinst (tmp1, "lshr", ty, arg0, arg1)
                val tmp2 = nextLLVMTemp ()
                val inst2 = mkinst (tmp2, "sub", ty, WordSize.toString ws, arg1)
                val tmp3 = nextLLVMTemp ()
                val inst3 = mkinst (tmp3, "shl", ty, arg0, tmp2)
                val inst4 = mkinst (res, "or", ty, tmp1, tmp3)
            in
                (concat [inst1, inst2, inst3, inst4], llws ws)
            end
          | Word_rshift (ws, {signed}) =>
            let
                val opr = if signed then "ashr" else "lshr"
            in
                (mkinst (res, opr, llws ws, arg0, arg1), llws ws)
            end
          | Word_sub ws => (mkinst (res, "sub", llws ws, arg0, arg1), llws ws)
          | Word_subCheckP (ws, {signed}) =>
              mkoverflowp (ws, if signed then "ssub" else "usub")
          | Word_xorb ws => (mkinst (res, "xor", llws ws, arg0, arg1), llws ws)
          | _ => Error.bug "LLVM Codegen: Unsupported operation in outputPrim"
    end

fun outputPrimApp (cxt, p) =
    let
        datatype z = datatype Prim.Name.t
        val {args, dst, prim} = p
        fun typeOfArg0 () = (WordSize.fromBits o Type.width o Operand.ty o Vector.sub) (args, 0)
        val castArg1 = case Prim.name prim of
                           Word_rshift _ => SOME (typeOfArg0 ())
                         | Word_lshift _ => SOME (typeOfArg0 ())
                         | Word_rol _ => SOME (typeOfArg0 ())
                         | Word_ror _ => SOME (typeOfArg0 ())
                         | _ => NONE
        val operands = Vector.map (args, fn opr => getOperandValue (cxt, opr))
        val (arg0pre, arg0ty, arg0temp) = getArg (operands, 0)
        val (arg1pre, _, arg1) = getArg (operands, 1)
        val (cast, arg1temp) = case castArg1 of
                                   SOME ty =>
                                   let
                                       val temp = nextLLVMTemp ()
                                       val opr = case WordSize.prim ty of
                                                     WordSize.W8 => "trunc"
                                                   | WordSize.W16 => "trunc"
                                                   | WordSize.W32 => "bitcast"
                                                   | WordSize.W64 => "zext"
                                       val inst = mkconv (temp, opr, "%Word32", arg1, llws ty)
                                   in
                                       (inst, temp)
                                   end
                                 | NONE => ("", arg1)
        val (arg2pre, _, arg2temp) = getArg (operands, 2)
        val temp = nextLLVMTemp ()
        val (inst, _) = outputPrim (prim, temp, arg0ty, arg0temp, arg1temp, arg2temp)
        val storeDest =
            case dst of
                NONE => ""
              | SOME dest =>
                let
                    val (destPre, destTy, destTemp) = getOperandAddr (cxt, dest)
                    val scope = mkOperScope dest
                    val store = mkstore (destTy, temp, destTemp, scope)
                in
                    concat [destPre, store]
                end
    in
        concat [arg0pre, arg1pre, cast, arg2pre, inst, storeDest]
    end

fun outputStatement (cxt: Context, stmt: Statement.t): string =
    let
        val comment = concat ["\t; ", Layout.toString (Statement.layout stmt), "\n"]
        val stmtcode =
            case stmt of
                Statement.Move {dst, src} =>
                let
                    val (srcpre, _, srctemp) = getOperandValue (cxt, src)
                    val (dstpre, dstty, dsttemp) = getOperandAddr (cxt, dst)
                    val scope = mkOperScope dst
                    val store = mkstore (dstty, srctemp, dsttemp, scope)
                in
                    concat [srcpre, dstpre, store]
                end
              | Statement.Noop => "\t; Noop\n"
              | Statement.PrimApp p => outputPrimApp (cxt, p)
              | Statement.ProfileLabel _ => "\t; ProfileLabel\n"
    in
        concat [comment, stmtcode]
    end

local
   fun mk (dst, src) cxt =
      outputStatement (cxt, Statement.Move {dst = dst (), src = src ()})
   fun stackTop () = Operand.StackTop
   fun gcStateStackTop () = Operand.gcField GCField.StackTop
   fun frontier () = Operand.Frontier
   fun gcStateFrontier () = Operand.gcField GCField.Frontier
in
   val cacheStackTop = mk (stackTop, gcStateStackTop)
   val flushStackTop = mk (gcStateStackTop, stackTop)
   val cacheFrontier = mk (frontier, gcStateFrontier)
   val flushFrontier = mk (gcStateFrontier, frontier)
end

(* LeaveChunk(nextChunk, nextBlock)

   if (TailCall) {
     return nextChunk(gcState, stackTop, frontier, nextBlock);
   } else {
     FlushFrontier();
     FlushStackTop();
     return nextBlock;
   }
*)
fun leaveChunk (cxt, nextChunk, nextBlock) =
   if !Control.chunkTailCall
      then let
              val stackTopArg = nextLLVMTemp ()
              val frontierArg = nextLLVMTemp ()
              val res = nextLLVMTemp ()
           in
              concat
              [mkload (stackTopArg, "%CPointer*", "%stackTop", ""),
               mkload (frontierArg, "%CPointer*", "%frontier", ""),
               "\t", res, " = musttail call ",
               if !Control.llvmCC10
                  then "cc10 "
                  else "",
               "%uintptr_t ",
               nextChunk, "(",
               "%CPointer ", "%gcState", ", ",
               "%CPointer ", stackTopArg, ", ",
               "%CPointer ", frontierArg, ", ",
               "%uintptr_t ", nextBlock, ")\n",
               "\tret %uintptr_t ", res, "\n"]
           end
      else concat [flushFrontier cxt,
                   flushStackTop cxt,
                   "\tret %uintptr_t ", nextBlock, "\n"]

(* Return(mustReturnToSelf, mayReturnToSelf, mustReturnToOther)

   nextBlock = *(uintptr_t* )(StackTop - sizeof(uintptr_t));
   ChunkFnPtr_t nextChunk = nextChunks[nextBlock];
   if (mustReturnToSelf || (mayReturnToSelf && (nextChunk == selfChunk))) {
     goto doSwitchNextBlock;
   } else if (mustReturnToOther != NULL) {
     LeaveChunk( *mustReturnToOther, nextBlock);
   } else {
     LeaveChunk( *nextChunk, nextBlock);
   }
*)
fun callReturn (cxt, selfChunk, mustReturnToSelf, mayReturnToSelf, mustReturnToOther) =
   let
      val stackTop = nextLLVMTemp ()
      val loadStackTop = mkload (stackTop, "%CPointer*", "%stackTop", "")
      val nextBlock = nextLLVMTemp ()
      val loadNextBlockFromStackTop =
         let
            val tmp1 = nextLLVMTemp ()
            val tmp2 = nextLLVMTemp ()
         in
            concat
            [mkgep (tmp1, "%CPointer", stackTop, [("i32", "-" ^ (llbytes (Runtime.labelSize ())))]),
             mkconv (tmp2, "bitcast", "%CPointer", tmp1, "%uintptr_t*"),
             mkload (nextBlock, "%uintptr_t*", tmp2, "")]
         end
      val storeNextBlock = mkstore ("%uintptr_t", nextBlock, "%nextBlock", "")
      val nextChunk = nextLLVMTemp ()
      val loadNextChunk =
         let
            val tmp = nextLLVMTemp ()
         in
            concat
            [mkgep (tmp, "%ChunkFnPtrArr_t*",
                    if !Control.llvmCC10
                       then "@nextXChunks"
                       else "@nextChunks",
                    [("i32", "0"), ("%uintptr_t", nextBlock)]),
             mkload (nextChunk, "%ChunkFnPtr_t*", tmp, "")]
         end
      val returnToSelf = nextLLVMTemp ()
      val computeReturnToSelf =
         let
            val tmp1 = nextLLVMTemp ()
            val tmp2 = nextLLVMTemp ()
         in
            concat
            [mkinst (tmp1, "icmp eq", "%ChunkFnPtr_t", nextChunk, concat ["@", ChunkLabel.toString' selfChunk]),
             mkinst (tmp2, "and", "i1", if mayReturnToSelf then "1" else "0", tmp1),
             mkinst (returnToSelf, "or", "i1", if mustReturnToSelf then "1" else "0", tmp2)]
         end
      val returnToSelfLabel = Label.toString (Label.newNoname ())
      val leaveChunkLabel = Label.toString (Label.newNoname ())
   in
      concat
      [loadStackTop, loadNextBlockFromStackTop, storeNextBlock, loadNextChunk, computeReturnToSelf,
       "\tbr i1 ", returnToSelf, ", label %", returnToSelfLabel, ", label %", leaveChunkLabel, "\n",
       returnToSelfLabel, ":\n",
       "\tbr label %doSwitchNextBlock\n",
       leaveChunkLabel, ":\n",
       case mustReturnToOther of
          NONE => leaveChunk (cxt, nextChunk, nextBlock)
        | SOME dstChunk => leaveChunk (cxt, concat ["@", ChunkLabel.toString' dstChunk], nextBlock)]
   end

fun adjStackTop (cxt, size: Bytes.t) =
   concat
   [outputStatement (cxt,
                     Statement.PrimApp
                     {args = Vector.new2
                             (Operand.StackTop,
                              Operand.Word
                              (WordX.fromBytes
                               (size,
                                WordSize.cptrdiff ()))),
                      dst = SOME Operand.StackTop,
                      prim = Prim.cpointerAdd}),
    let
       val Context { amTimeProfiling, ... } = cxt
    in
       if amTimeProfiling
          then flushStackTop cxt
          else ""
    end]
fun pop (cxt, fi: FrameInfo.t) =
   adjStackTop (cxt, Bytes.~ (FrameInfo.size fi))
fun push (cxt, return: Label.t, size: Bytes.t) =
   concat
   [outputStatement (cxt,
                     Statement.Move
                     {dst = Operand.stackOffset
                            {offset = Bytes.- (size, Runtime.labelSize ()),
                             ty = Type.label return},
                      src = Operand.Label return}),
    adjStackTop (cxt, size)]

fun outputTransfer (cxt, chunkLabel, transfer) =
    let
        val comment = concat ["\t; ", Layout.toString (Transfer.layout transfer), "\n"]
        val Context { labelChunk, labelIndexAsString, ... } = cxt
        fun rtrans rsTo =
           let
              fun isSelf c = ChunkLabel.equals (chunkLabel, c)
              val rsTo =
                 List.fold
                 (rsTo, [], fn (l, cs) =>
                  let
                     val c = labelChunk l
                  in
                     if List.exists (cs, fn c' => ChunkLabel.equals (c, c'))
                        then cs
                        else c::cs
                  end)
              val mayRToSelf = List.exists (rsTo, isSelf)
              val (mustRToSelf, mustRToOther) =
                 case List.revKeepAll (rsTo, not o isSelf) of
                    [] => (true, NONE)
                  | c::rsTo =>
                       (false,
                        List.fold (rsTo, SOME c, fn (c', co) =>
                                   case co of
                                      NONE => NONE
                                    | SOME c => if ChunkLabel.equals (c, c')
                                                   then SOME c
                                                   else NONE))
           in
              callReturn (cxt, chunkLabel,
                          !Control.chunkMustRToSelfOpt andalso mustRToSelf,
                          !Control.chunkMayRToSelfOpt andalso mayRToSelf,
                          if (!Control.chunkMustRToOtherOpt andalso
                              (!Control.chunkMayRToSelfOpt orelse not mayRToSelf))
                             then mustRToOther
                             else NONE)
           end
    in
        case transfer of
            Transfer.CCall {func =
                            CFunction.T
                            {target = CFunction.Target.Direct "Thread_returnToC", ...},
                            return = SOME {return, size = SOME size}, ...} =>
            concat [comment,
                    push (cxt, return, size),
                    flushFrontier cxt,
                    flushStackTop cxt,
                    "\tret %uintptr_t -1\n"]
          | Transfer.CCall {args, func, return} =>
            let
               val CFunction.T {return = returnTy, target, ...} = func
               val (argsPre, args) =
                  let
                     val args = Vector.toListMap (args, fn opr => getOperandValue (cxt, opr))
                  in
                     (String.concat (List.map (args, #1)),
                      List.map (args, fn (_, ty, temp) => (ty, temp)))
                  end
               val push =
                  case return of
                     NONE => ""
                   | SOME {size = NONE, ...} => ""
                   | SOME {return, size = SOME size} => push (cxt, return, size)
               val flushFrontierCode = if CFunction.modifiesFrontier func then flushFrontier cxt else ""
               val flushStackTopCode = if CFunction.readsStackTop func then flushStackTop cxt else ""
               val (callLHS, callType, afterCall) =
                  if Type.isUnit returnTy
                     then ("\t", "void", "")
                     else let
                             val resTemp = nextLLVMTemp ()
                          in
                             (concat ["\t", resTemp, " = "],
                              llty returnTy,
                              mkstore (llty returnTy, resTemp,
                                       "%CReturn" ^ CType.name (Type.toCType returnTy), ""))
                          end
               val (fnptrPre, fnptrVal, args) =
                  case target of
                     CFunction.Target.Direct name =>
                        let
                           val name = "@" ^ name
                           val () =
                              addCFunction
                              (concat [callType, " ",
                                       name, " (",
                                       String.concatWith
                                       (List.map (args, #1),
                                        ", "), ")"])
                        in
                           ("", name, args)
                        end
                   | CFunction.Target.Indirect =>
                        let
                           val (fnptrArgTy, fnptrArgTemp, args) =
                              case args of
                                 (fnptrTy, fnptrTemp)::args => (fnptrTy, fnptrTemp, args)
                               | _ => Error.bug "LLVMCodegen.outputTransfer: CCall,Indirect"
                           val fnptrTy =
                              concat [callType, " (",
                                      String.concatWith
                                      (List.map (args, #1),
                                       ", "), ") *"]
                           val fnptrTemp = nextLLVMTemp ()
                           val cast = mkconv (fnptrTemp, "bitcast",
                                              fnptrArgTy, fnptrArgTemp,
                                              fnptrTy)
                        in
                           (cast,
                            fnptrTemp,
                            args)
                        end
               val call =
                  concat [callLHS,
                          "call ",
                          callType, " ",
                          fnptrVal, "(",
                          String.concatWith
                          (List.map
                           (args, fn (ty, temp) => ty ^ " " ^ temp),
                           ", "), ")"]
               val epilogue =
                  case return of
                     NONE => "\tret %uintptr_t -2\n"
                   | SOME {return, ...} =>
                        let
                           val cacheFrontierCode =
                              if CFunction.modifiesFrontier func then cacheFrontier cxt else ""
                           val cacheStackTopCode =
                              if CFunction.writesStackTop func then cacheStackTop cxt else ""
                           val br = if CFunction.maySwitchThreadsFrom func
                                       then callReturn (cxt, chunkLabel, false, true, NONE)
                                       else concat ["\tbr label %", Label.toString return, "\n"]
                        in
                           concat [cacheFrontierCode, cacheStackTopCode, br]
                        end
            in
               concat [comment,
                       "\t; GetOperands\n",
                       argsPre,
                       push,
                       flushFrontierCode,
                       flushStackTopCode,
                       "\t; Call\n",
                       fnptrPre,
                       call,
                       afterCall,
                       epilogue]
            end
          | Transfer.Call {label, return, ...} =>
            let
                val dstChunk = labelChunk label
                val push = case return of
                               NONE => ""
                             | SOME {return, size, ...} => push (cxt, return, size)
                val call = if ChunkLabel.equals (chunkLabel, dstChunk)
                           then concat ["\t; NearCall\n",
                                        "\tbr label %", Label.toString label, "\n"]
                           else concat ["\t; FarCall\n",
                                        leaveChunk (cxt,
                                                    concat ["@", ChunkLabel.toString' dstChunk],
                                                    labelIndexAsString label)]
            in
                concat [push, call]
            end
          | Transfer.Goto label =>
            let
                val goto = concat ["\tbr label %", Label.toString label, "\n"]
            in
                concat [comment, goto]
            end
          | Transfer.Raise {raisesTo} =>
            let
               (* StackTop = StackBottom + ExnStack *)
               val cutStack =
                  outputStatement (cxt,
                                   Statement.PrimApp
                                   {args = Vector.new2
                                           (Operand.gcField GCField.StackBottom,
                                            Operand.gcField GCField.ExnStack),
                                    dst = SOME Operand.StackTop,
                                    prim = Prim.cpointerAdd})
            in
               concat [comment, cutStack, rtrans raisesTo]
            end
          | Transfer.Return {returnsTo} =>
            concat [comment, rtrans returnsTo]
          | Transfer.Switch switch =>
            let
                val Switch.T {cases, default, test, ...} = switch
                val (testpre, testty, testtemp) = getOperandValue (cxt, test)
                val (default, extra) =
                   case default of
                      SOME d => (d, "")
                    | NONE => let
                                 val d = Label.newNoname ()
                              in
                                 (d,
                                  concat [Label.toString d, ":\n",
                                          "\tunreachable\n"])
                              end
            in
               concat [comment, testpre,
                       "\tswitch ", testty, " ", testtemp,
                       ", label %", Label.toString default, " [\n",
                       String.concatV
                       (Vector.map
                        (cases, fn (w, l) =>
                         concat ["\t\t", llws (WordX.size w), " ", llwordx w,
                                 ", label %", Label.toString l, "\n"])),
                       "\t]\n", extra]
            end
    end

fun outputBlock (cxt, chunkLabel, block) =
    let
        val Block.T {kind, label, statements, transfer, ...} = block
        val labelstr = Label.toString label
        val blockLabel = labelstr ^ ":\n"
        val dopop = case kind of
                        Kind.Cont {frameInfo, ...} => pop (cxt, frameInfo)
                      | Kind.CReturn {dst, frameInfo, ...} =>
                        let
                            val popfi = case frameInfo of
                                            NONE => ""
                                          | SOME fi => pop (cxt, fi)
                            val move = case dst of
                                           NONE => ""
                                         | SOME x =>
                                           let
                                               val xop = Live.toOperand x
                                               val ty = Operand.ty xop
                                               val llvmTy = llty ty
                                               val temp = nextLLVMTemp ()
                                               val scope = mkOperScope xop
                                               val load = mkload (temp, llvmTy ^ "*",
                                                                  "%CReturn" ^
                                                                  CType.name (Type.toCType ty),
                                                                  scope)
                                               val (dstpre, dstty, dsttemp) =
                                                   getOperandAddr (cxt, xop)
                                               val store = mkstore (dstty, temp, dsttemp, scope)
                                           in
                                               concat [dstpre, load, store]
                                           end
                        in
                            concat [popfi, move]
                        end
                      | Kind.Handler {frameInfo, ...} => pop (cxt, frameInfo)
                      | _ => ""
        val outputStatementWithCxt = fn s => outputStatement (cxt, s)
        val blockBody = String.concatV (Vector.map (statements, outputStatementWithCxt))
        val blockTransfer = outputTransfer (cxt, chunkLabel, transfer)
    in
        concat [blockLabel, dopop, blockBody, blockTransfer, "\n"]
    end

fun outputLLVMDeclarations print =
    let
        val globals = concat (List.map (CType.all, fn t =>
                          let
                              val s = CType.toString t
                              val n = Global.numberOfType t
                          in
                              if n > 0
                                 then concat ["@global", s, " = external hidden global [",
                                              llint n, " x %", s, "]\n"]
                                 else ""
                          end))
    in
        print (concat [llvmIntrinsics, "\n", mltypes, "\n", ctypes (),
                       "\n", chunkfntypes,
                       "\n", globals, "\n"])
    end

fun outputChunkFn (cxt, chunk, print) =
   let
        val () = resetLLVMTemp ()
        val Context { labelIndex, ... } = cxt
        val Chunk.T {blocks, chunkLabel, tempsMax} = chunk
        val entries =
           let
              val entries = ref []
              val () =
                 Vector.foreach
                 (blocks, fn Block.T {kind, label, ...} =>
                  if Kind.isEntry kind
                     then List.push (entries, (label, labelIndex label))
                     else ())
           in
              List.insertionSort (!entries, fn ((_, i1), (_, i2)) => i1 <= i2)
           end
        val numEntries = List.length entries
        val () = if !Control.chunkJumpTable
                    then let
                            val () = print (concat ["@", ChunkLabel.toString' chunkLabel, ".nextLabels ",
                                                    "= internal constant ",
                                                    "[", llint numEntries, " x i8*] ",
                                                    "[\n"])
                            val () = List.foreachi (entries, fn (i, (label, _)) =>
                                                    print (concat ["\t\ti8* blockaddress(",
                                                                   "@",
                                                                   ChunkLabel.toString' chunkLabel,
                                                                   ", ",
                                                                   "%", Label.toString label, ")",
                                                                   if i < numEntries - 1
                                                                      then ",\n"
                                                                      else " ]\n"]))
                         in
                            ()
                         end
                    else ()
        val () = print (concat ["define hidden %uintptr_t @",
                                ChunkLabel.toString chunkLabel,
                                "(%CPointer %gcState, %CPointer %stackTopArg, %CPointer %frontierArg, %uintptr_t %nextBlockArg) {\nentry:\n"])
        val () =
           if !Control.llvmCC10
              then (print (concat ["\t%res = call cc10 %uintptr_t @",
                                   ChunkLabel.toStringX chunkLabel,
                                   "(%CPointer %gcState, %CPointer %stackTopArg, %CPointer %frontierArg, %uintptr_t %nextBlockArg)\n",
                                   "\tret %uintptr_t %res\n}\n"])
                    ; print (concat ["define hidden cc10 %uintptr_t @",
                                     ChunkLabel.toStringX chunkLabel,
                                     "(%CPointer %gcState, %CPointer %stackTopArg, %CPointer %frontierArg, %uintptr_t %nextBlockArg) {\nentry:\n"]))
              else ()
        val () = print "\t%stackTop = alloca %CPointer\n"
        val () = print "\t%frontier = alloca %CPointer\n"
        val () = print "\t%nextBlock = alloca %uintptr_t\n"
        val () = List.foreach (CType.all,
                               fn t =>
                                  print (concat ["\t%CReturn", CType.name t,
                                                 " = alloca %", CType.toString t, "\n"]))
        val () = List.foreach (CType.all,
                               fn t =>
                                  let
                                      val pre = concat ["\t%temp", CType.name t, "_"]
                                      val post = concat [" = alloca %", CType.toString t, "\n"]
                                  in
                                      Int.for (0, 1 + tempsMax t,
                                               fn i => print (concat [pre, llint i, post]))
                                  end)
        val () = print (mkstore ("%CPointer", "%stackTopArg", "%stackTop", ""))
        val () = print (mkstore ("%CPointer", "%frontierArg", "%frontier", ""))
        val () = print (mkstore ("%uintptr_t", "%nextBlockArg", "%nextBlock", ""))
        val () = print "\tbr label %doSwitchNextBlock\n\n"
        val () = print "doSwitchNextBlock:\n"
        val () =
           if !Control.chunkJumpTable
              then let
                      val tmp1 = nextLLVMTemp ()
                      val tmp2 = nextLLVMTemp ()
                      val tmp3 = nextLLVMTemp ()
                      val tmp4 = nextLLVMTemp ()
                      val () = print (mkload (tmp1, "%uintptr_t*", "%nextBlock", ""))
                      val () = print (mkinst (tmp2, "sub", "i64", tmp1, llint (#2 (List.first entries))))
                      val () = print (mkgep (tmp3,
                                             concat ["[", llint numEntries, " x i8*]*"],
                                             concat ["@", ChunkLabel.toString' chunkLabel, ".nextLabels"],
                                             [("i64", "0"), ("%uintptr_t", tmp2)]))
                      val () = print (mkload (tmp4, "i8**", tmp3, ""))
                      val () = print (concat ["\tindirectbr i8* ", tmp4,
                                              ", [\n"])
                      val () = List.foreachi (entries, fn (i, (label, _)) =>
                                              print (concat ["\t\t label %",
                                                             Label.toString label,
                                                             if i < numEntries - 1
                                                                then ",\n"
                                                                else " ]\n"]))
                   in
                      ()
                   end
              else let
                      val tmp = nextLLVMTemp ()
                      val () = print (mkload (tmp, "%uintptr_t*", "%nextBlock", ""))
                      val () = print (concat ["\tswitch %uintptr_t ", tmp,
                                              ", label %switchNextBlockDefault [\n"])
                      val () = List.foreach (entries, fn (label, index) =>
                                             print (concat ["\t\t%uintptr_t ",
                                                            llint index,
                                                            ", label %",
                                                            Label.toString label,
                                                            "\n"]))
                      val () = print "\t]\n\n"
                      val () = print "switchNextBlockDefault:\n"
                      val () = print "\tunreachable\n"
                   in
                      ()
                   end
        val () = print "\n"
        val () = print (String.concatV (Vector.map (blocks, fn b => outputBlock (cxt, chunkLabel, b))))
        val () = print "}\n\n"
   in
      ()
   end

fun outputChunks (cxt, chunks,
                  outputLL: unit -> {file: File.t,
                                     print: string -> unit,
                                     done: unit -> unit}) =
   let
        val Context { program, ... } = cxt
        val () = cFunctions := []
        val () = ffiSymbols := []
        val () = HashTable.removeAll (operScopes, fn _ => true)
        val () = Metadata.reset ()
        val { done, print, file=_ } = outputLL ()
        val () = outputLLVMDeclarations print
        val () = print "\n"
        val () = let
                    fun declareChunk (Chunk.T {chunkLabel, ...}) =
                       if List.exists (chunks, fn chunk =>
                                       ChunkLabel.equals (chunkLabel, Chunk.chunkLabel chunk))
                          then ()
                          else print (concat ["declare hidden %uintptr_t @",
                                              ChunkLabel.toString' chunkLabel,
                                              "(%CPointer,%CPointer,%CPointer,%uintptr_t)\n"])
                    val Program.T {chunks, ...} = program
                 in
                    List.foreach (chunks, declareChunk)
                    ; print (if !Control.llvmCC10 then "@nextXChunks" else "@nextChunks")
                    ; print " = external hidden global %ChunkFnPtrArr_t\n"
                    ; print "\n\n"
                 end
        val () = List.foreach (chunks, fn chunk => outputChunkFn (cxt, chunk, print))
        val () =
           case !Control.llvmAAMD of
              Control.LLVMAliasAnalysisMetaData.None => ()
            | Control.LLVMAliasAnalysisMetaData.TBAA =>
                 let
                    val operDomain = Metadata.new ()
                    val () = print (concat
                                    [Metadata.defineNode (operDomain, ["!\"operRoot\""]),
                                     "\t; ", "Operator domain", "\n"])
                    val () =
                       List.foreach
                       (HashTable.toList operScopes, fn (oper, m) =>
                        let
                           val () = print (Metadata.defineNode
                                           (m,
                                            ["!\"" ^ SimpleOper.toString oper ^ "\"",
                                             Metadata.str operDomain,
                                             "i64 0"]))
                           val () = print "\n"
                        in
                           ()
                        end)
                    val () = print "\n"
                 in
                    ()
                 end
        val () = List.foreach (!cFunctions, fn f =>
                     print (concat ["declare ", f, "\n"]))
        val () = List.foreach (!ffiSymbols, fn {name, cty, symbolScope} =>
                    let
                        val ty = case cty of
                                        SOME t => "%" ^ CType.toString t
                                      | NONE => "i8"
                        val visibility = case symbolScope of
                                             CFunction.SymbolScope.External => "default"
                                           | CFunction.SymbolScope.Private => "hidden"
                                           | CFunction.SymbolScope.Public => "default"
                    in
                        print (concat ["@", name, " = external ", visibility, " global ", ty,
                                       "\n"])
                    end)

   in
      done ()
   end

fun makeContext program =
    let
        val Program.T { chunks, frameInfos, ...} = program
        val {get = labelInfo: Label.t -> {chunkLabel: ChunkLabel.t,
                                          index: int option},
             set = setLabelInfo, ...} =
           Property.getSetOnce
           (Label.plist, Property.initRaise ("LLVMCodeGen.labelInfo", Label.layout))
        val nextChunks = Array.new (Vector.length frameInfos, NONE)
        val _ =
           List.foreach
           (chunks, fn Chunk.T {blocks, chunkLabel, ...} =>
            Vector.foreach
            (blocks, fn Block.T {kind, label, ...} =>
             let
                val index =
                   case Kind.frameInfoOpt kind of
                      NONE => NONE
                    | SOME fi =>
                         let
                            val index = FrameInfo.index fi
                         in
                            if Kind.isEntry kind
                               then Array.update (nextChunks, index, SOME label)
                               else ()
                            ; SOME index
                         end
             in
                setLabelInfo (label, {chunkLabel = chunkLabel,
                                      index = index})
             end))
        val nextChunks = Vector.keepAllMap (Vector.fromArray nextChunks, fn lo => lo)
        val labelChunk = #chunkLabel o labelInfo
        val labelIndex = valOf o #index o labelInfo
        fun labelIndexAsString (l: Label.t): string = llint (labelIndex l)
        val amTimeProfiling =
           !Control.profile = Control.ProfileTimeField
           orelse !Control.profile = Control.ProfileTimeLabel
    in
        Context { amTimeProfiling = amTimeProfiling,
                  program = program,
                  labelIndex = labelIndex,
                  labelIndexAsString = labelIndexAsString,
                  labelChunk = labelChunk,
                  nextChunks = nextChunks
                }
    end

fun transLLVM (cxt, outputLL) =
    let
        val Context { program, ... } = cxt
        val Program.T { chunks, ...} = program
        val chunks =
           List.revMap
           (chunks, fn chunk as Chunk.T {blocks, ...} =>
            (chunk,
             Vector.fold
             (blocks, 0, fn (Block.T {statements, ...}, n) =>
              n + Vector.length statements + 1)))
        fun batch (chunks, acc, n) =
           case chunks of
              [] => outputChunks (cxt, acc, outputLL)
            | (chunk, s)::chunks' =>
                 let
                    val m = n + s
                 in
                    if List.isEmpty acc orelse m <= !Control.chunkBatch
                       then batch (chunks', chunk::acc, m)
                       else (outputChunks (cxt, acc, outputLL);
                             batch (chunks, [], 0))
                 end
    in
       batch (chunks, [], 0)
    end

structure C = CCodegen.C

fun transC (cxt, outputC) =
   let
      val Context { program, ... } = cxt
      val Program.T {main = main, chunks = chunks, ... } = program
      val Context { labelChunk, labelIndexAsString, nextChunks, ... } = cxt

      fun defineNextChunks (print, nextChunksName, chunkName) =
         (List.foreach
          (chunks, fn Chunk.T {chunkLabel, ...} =>
           (print "PRIVATE extern ChunkFn_t "
            ; print (chunkName chunkLabel)
            ; print ";\n"))
          ; print "PRIVATE ChunkFnPtr_t "
          ; print nextChunksName
          ; print "["
          ; print (C.int (Vector.length nextChunks))
          ; print "] = {\n"
          ; Vector.foreachi
            (nextChunks, fn (i, label) =>
             (print "\t"
              ; print "/* "
              ; print (C.int i)
              ; print ": */ "
              ; print "/* "
              ; print (Label.toString label)
              ; print " */ &("
              ; print (chunkName (labelChunk label))
              ; print "),\n"))
          ; print "};\n")
      val defineNextChunks = fn print =>
         (defineNextChunks (print, "nextChunks", ChunkLabel.toString)
          ; if !Control.llvmCC10
               then defineNextChunks (print, "nextXChunks", ChunkLabel.toStringX)
               else ())

      val {print, done, file = _} = outputC ()
      val _ =
         CCodegen.outputDeclarations
         {additionalMainArgs = [labelIndexAsString (#label main)],
          includes = ["c-main.h"],
          print = print,
          program = program,
          rest = fn () => defineNextChunks print}
      val _ = done ()
   in
      ()
   end

fun output {program, outputC, outputLL} =
    let
        val context = makeContext program
        val () = transLLVM (context, outputLL)
        val () = transC (context, outputC)
    in
        ()
    end

end
