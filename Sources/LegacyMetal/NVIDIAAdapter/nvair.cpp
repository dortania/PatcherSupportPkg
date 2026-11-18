// GeForceAIRCompat.dylib: AIR compatibility for OCLP's Kepler Metal compiler (GeForceAIRPlugin, GTX 600/700 GPUs on
// macOS 14+), which runs on the shared 3802 libLLVM like Intel's plugin (IntelAdapter/intelatomics.cpp, same hook).
//
// The plugin links its built-in library into each module before its first llvm::legacy::PassManager::run: the AIR
// intrinsics it knows get bodies there (air.popcount.i32 -> llvm.ctpop.i32, air.min.u.i32 -> llvm.nvvm.min.u.i32), and
// its instruction selection matches a few more by name (air.simd_ shuffle, broadcast, shuffle_up, shuffle_down,
// shuffle_xor). Every other AIR intrinsic stays a bare declaration, which selection takes for a call to an external
// function and fails on ("Unhandled constant") when the pipeline is made; a few under air.simd_ trap the compiler
// instead ("Compiler encountered an internal error"). Front ends newer than the plugin (2020) emit more of them, among
// them every 64-bit min, max, mulhi and madhi: Blender's and the fuzzer's 64-bit integer code, i49 and four tests whose
// subject is another GPU's bug (a21, a22, a34, i27) couldn't make a pipeline on Kepler.
//
// Before each PassManager::run, each bare declaration of an intrinsic below gets a body made of IR the plugin compiles,
// becomes internal and always_inline, and is inlined (LLVM's always-inliner), so selection never sees it:
//   air.{min,max}.{u,s}.i64, air.clamp.{u,s}.i64   compare and select
//   air.popcount.i64, air.clz.i64, air.ctz.i64     on the two 32-bit halves (llvm.ctpop/ctlz/cttz.i32)
//   air.reverse_bits.i64                           the halves reversed (llvm.nvvm.reverse_bits) and swapped
//   air.abs.s.i64                                  compare and select
//   air.mul_hi.{u,s}.i64, air.mad_hi.{u,s}.i64     from four 32 x 32 -> 64 bit products (signed: corrected after)
//   air.quad_shuffle_xor.<type>                    air.simd_shuffle_xor.<type> with the mask's low 2 bits (a quad is
//                                                   4 aligned lanes of the 32-wide SIMD group, so lane ^ (mask & 3)
//                                                   is the same lane either way)
// These are exact. Reductions over a SIMD group or quad (simd_sum, quad_sum, ...), simd_ballot, simd_all/any and the
// active-thread mask are not provided: the plugin has no vote instruction or lane mask to build them from, and a
// butterfly of shuffles is only right when all 32 lanes are active. Any AIR intrinsic still bare after this is logged
// (NVAIR_LOG), and the compile fails as before.
//
// Two 64-bit instructions the plugin compiles but gets wrong (a 64-bit value is a pair of 32-bit registers, and both
// lowerings leave the high one unset or wrong), measured on a GTX 770 against the CPU over 4096 random pairs each:
//   zext / sext i1 -> i64   (o = a < b ? 1 : 0 for ulongs: all 4096 had garbage high words) -> 0 or 1 through
//                           llvm.nvvm.min.u.i32 and a zext from 32 bits (a select of 1 and 0, the obvious form, is
//                           folded back into the zext by the plugin's optimizer), negated for sext
//   udiv, urem, sdiv, srem i64 (94% of quotients wrong; with a constant divisor too, which becomes a 64-bit
//                           multiply-high that is also wrong) -> nvair.udiv64 / nvair.urem64: 64 unrolled steps of
//                           shift, compare, select and subtract (straight-line: a branch and loop there let the
//                           plugin misorder private-array accesses), signed through the magnitudes. Division by 0
//                           gives all ones (Metal leaves it undefined).
//   shl, lshr, ashr i64 by a variable amount: from 32-bit shifts of the halves. In a fragment function next to straight-
//                           line division code, a signed one came out unsigned (i67: long >> s, 102 of 256 pixels).
// Vectors of them (ulong2 / ulong2) one lane at a time. NVAIR_I64_FIX=0 turns these off, NVAIR_SHIFT_FIX=0 the shifts only.
//
// Constexpr samplers from newer front ends: a library built with Xcode 16.3+ (AIR 2.7, iMovie 10.4.4's viewer shader)
// stores each as a [2 x i64] constant where the plugin reads the one i64 the 3802 runtime compiler writes (the same
// word, bit 63 set; the macOS 14 form). On the array the plugin traps ("Compiler encountered an internal error").
// Rewritten to the one-word form, as IntelAdapter does for Intel's back end. NVAIR_SAMPLER_STATE_FIX=0 turns it off.
//
// Threadgroup bools (i1 globals in threadgroup memory) widened to i8, as IntelAdapter does. NVAIR_THREADGROUP_BOOL_FIX=0.
//
// Cube array indices below 0 raised to 0, as AMDAdapter does. NVAIR_CUBE_ARRAY_FIX=0.
//
// Installed (planned): GeForceAIRPlugin.bundle/Contents/MacOS/GeForceAIRCompat.dylib, a weak dependency of
// GeForceAIRPlugin. Test use: DYLD_INSERT_LIBRARIES=Tests/tools/localcc.dylib:build/GeForceAIRCompat-test.dylib
//   NVAIR_LOG=1             log what is rewritten (NVAIR_LOG=/path: append to that file)
//   NVAIR_DUMP_INPUT=<dir>  write every module as it reaches the pass manager
//   NVAIR_INTRINSICS=0      rewrite nothing
#include <dlfcn.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <algorithm>
#include <string>
#include <vector>

extern "C" {
typedef struct LLVMOpaqueModule *LLVMModuleRef;
typedef struct LLVMOpaqueContext *LLVMContextRef;
typedef struct LLVMOpaqueType *LLVMTypeRef;
typedef struct LLVMOpaqueValue *LLVMValueRef;
typedef struct LLVMOpaqueBasicBlock *LLVMBasicBlockRef;
typedef struct LLVMOpaqueBuilder *LLVMBuilderRef;
typedef struct LLVMOpaqueUse *LLVMUseRef;
typedef struct LLVMOpaquePassManager *LLVMPassManagerRef;
typedef struct LLVMOpaqueAttributeRef *LLVMAttributeRef;
enum { LLVMIntEQ = 32, LLVMIntNE, LLVMIntUGT, LLVMIntUGE, LLVMIntULT, LLVMIntULE, LLVMIntSGT, LLVMIntSGE, LLVMIntSLT, LLVMIntSLE };
enum { LLVMInternalLinkage = 8 };
enum { LLVMIntegerTypeKind = 8 };
static const unsigned LLVMAttributeFunctionIndex = ~0u;
char *LLVMPrintModuleToString(LLVMModuleRef);
void LLVMDisposeMessage(char *);
LLVMContextRef LLVMGetModuleContext(LLVMModuleRef);
LLVMValueRef LLVMGetFirstFunction(LLVMModuleRef);
LLVMValueRef LLVMGetNextFunction(LLVMValueRef);
LLVMValueRef LLVMGetNamedFunction(LLVMModuleRef, const char *);
LLVMTypeRef LLVMVoidTypeInContext(LLVMContextRef);
LLVMValueRef LLVMIsAConstantExpr(LLVMValueRef);
unsigned LLVMGetConstOpcode(LLVMValueRef);
LLVMValueRef LLVMConstVector(LLVMValueRef *, unsigned);
LLVMValueRef LLVMConstArray(LLVMTypeRef, LLVMValueRef *, unsigned);
LLVMValueRef LLVMConstNamedStruct(LLVMTypeRef, LLVMValueRef *, unsigned);
LLVMValueRef LLVMConstStructInContext(LLVMContextRef, LLVMValueRef *, unsigned, int);
LLVMTypeRef LLVMHalfTypeInContext(LLVMContextRef);
const char *LLVMGetStructName(LLVMTypeRef);
int LLVMIsPackedStruct(LLVMTypeRef);
LLVMValueRef LLVMIsAConstantStruct(LLVMValueRef);
LLVMValueRef LLVMIsAConstantArray(LLVMValueRef);
LLVMValueRef LLVMGetBasicBlockTerminator(LLVMBasicBlockRef);
LLVMBasicBlockRef LLVMGetInstructionParent(LLVMValueRef);
unsigned LLVMGetNumSuccessors(LLVMValueRef);
LLVMBasicBlockRef LLVMGetSuccessor(LLVMValueRef, unsigned);
LLVMValueRef LLVMIsAUnreachableInst(LLVMValueRef);
LLVMValueRef LLVMBuildRetVoid(LLVMBuilderRef);
LLVMValueRef LLVMBuildUnreachable(LLVMBuilderRef);
LLVMValueRef LLVMIsAReturnInst(LLVMValueRef);
LLVMBasicBlockRef LLVMGetEntryBasicBlock(LLVMValueRef);
unsigned LLVMGetAlignment(LLVMValueRef);
int LLVMGetVolatile(LLVMValueRef);
unsigned LLVMGetNumArgOperands(LLVMValueRef);
LLVMValueRef LLVMAddFunction(LLVMModuleRef, const char *, LLVMTypeRef);
const char *LLVMGetValueName(LLVMValueRef);
int LLVMIsDeclaration(LLVMValueRef);
LLVMUseRef LLVMGetFirstUse(LLVMValueRef);
void LLVMSetLinkage(LLVMValueRef, int);
LLVMTypeRef LLVMTypeOf(LLVMValueRef);
LLVMTypeRef LLVMGetElementType(LLVMTypeRef);
LLVMTypeRef LLVMGetReturnType(LLVMTypeRef);
unsigned LLVMCountParamTypes(LLVMTypeRef);
void LLVMGetParamTypes(LLVMTypeRef, LLVMTypeRef *);
int LLVMGetTypeKind(LLVMTypeRef);
unsigned LLVMGetIntTypeWidth(LLVMTypeRef);
LLVMTypeRef LLVMInt1TypeInContext(LLVMContextRef);
LLVMTypeRef LLVMInt16TypeInContext(LLVMContextRef);
LLVMTypeRef LLVMInt32TypeInContext(LLVMContextRef);
LLVMTypeRef LLVMInt64TypeInContext(LLVMContextRef);
LLVMTypeRef LLVMFunctionType(LLVMTypeRef, LLVMTypeRef *, unsigned, int);
LLVMValueRef LLVMConstInt(LLVMTypeRef, unsigned long long, int);
LLVMValueRef LLVMGetParam(LLVMValueRef, unsigned);
LLVMBasicBlockRef LLVMAppendBasicBlockInContext(LLVMContextRef, LLVMValueRef, const char *);
LLVMBuilderRef LLVMCreateBuilderInContext(LLVMContextRef);
void LLVMPositionBuilderAtEnd(LLVMBuilderRef, LLVMBasicBlockRef);
void LLVMDisposeBuilder(LLVMBuilderRef);
LLVMValueRef LLVMBuildRet(LLVMBuilderRef, LLVMValueRef);
LLVMValueRef LLVMBuildICmp(LLVMBuilderRef, int, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildSelect(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildAdd(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildSub(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildMul(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildAnd(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildLShr(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildZExt(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMBuildTrunc(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMBuildCall(LLVMBuilderRef, LLVMValueRef, LLVMValueRef *, unsigned, const char *);
unsigned LLVMGetEnumAttributeKindForName(const char *, size_t);
LLVMAttributeRef LLVMCreateEnumAttribute(LLVMContextRef, unsigned, unsigned long long);
void LLVMAddAttributeAtIndex(LLVMValueRef, unsigned, LLVMAttributeRef);
void LLVMRemoveEnumAttributeAtIndex(LLVMValueRef, unsigned, unsigned);
enum { LLVMUDiv = 14, LLVMSDiv = 15, LLVMURem = 17, LLVMSRem = 18, LLVMShl = 20, LLVMLShr = 21, LLVMAShr = 22, LLVMTrunc = 30, LLVMZExt = 31, LLVMSExt = 32 };
int LLVMGetInstructionOpcode(LLVMValueRef);
LLVMBasicBlockRef LLVMGetFirstBasicBlock(LLVMValueRef);
LLVMBasicBlockRef LLVMGetNextBasicBlock(LLVMBasicBlockRef);
LLVMValueRef LLVMGetFirstInstruction(LLVMBasicBlockRef);
LLVMValueRef LLVMGetNextInstruction(LLVMValueRef);
LLVMValueRef LLVMGetOperand(LLVMValueRef, unsigned);
LLVMValueRef LLVMIsAConstantInt(LLVMValueRef);
LLVMValueRef LLVMIsAInstruction(LLVMValueRef);
LLVMValueRef LLVMIsAConstant(LLVMValueRef);
void LLVMReplaceAllUsesWith(LLVMValueRef, LLVMValueRef);
void LLVMInstructionEraseFromParent(LLVMValueRef);
void LLVMPositionBuilderBefore(LLVMBuilderRef, LLVMValueRef);
LLVMValueRef LLVMBuildCondBr(LLVMBuilderRef, LLVMValueRef, LLVMBasicBlockRef, LLVMBasicBlockRef);
LLVMValueRef LLVMBuildBr(LLVMBuilderRef, LLVMBasicBlockRef);
LLVMValueRef LLVMBuildPhi(LLVMBuilderRef, LLVMTypeRef, const char *);
void LLVMAddIncoming(LLVMValueRef, LLVMValueRef *, LLVMBasicBlockRef *, unsigned);
LLVMValueRef LLVMBuildOr(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildShl(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildAShr(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildUDiv(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildURem(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildNeg(LLVMBuilderRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildNot(LLVMBuilderRef, LLVMValueRef, const char *);
LLVMTypeRef LLVMStructTypeInContext(LLVMContextRef, LLVMTypeRef *, unsigned, int);
enum { LLVMVectorTypeKind = 13 };
unsigned LLVMGetVectorSize(LLVMTypeRef);
LLVMValueRef LLVMGetUndef(LLVMTypeRef);
LLVMValueRef LLVMBuildExtractElement(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildInsertElement(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMPassManagerRef LLVMCreatePassManager(void);
void LLVMAddAlwaysInlinerPass(LLVMPassManagerRef);
int LLVMRunPassManager(LLVMPassManagerRef, LLVMModuleRef);
void LLVMDisposePassManager(LLVMPassManagerRef);
}
extern "C" int passManagerRun(void *self, LLVMModuleRef module) asm("__ZN4llvm6legacy11PassManager3runERNS_6ModuleE");

static const char *const kPluginSuffix = "/GeForceAIRPlugin";
static bool logging() { return getenv("NVAIR_LOG") != nullptr; }
static bool disabled(const char *name) { const char *v = getenv(name); return v && !strcmp(v, "0"); }

// ---- bodies for AIR intrinsics the plugin lacks ----------------------------------------------------------------------
struct Gen {
    LLVMModuleRef module;
    LLVMContextRef context;
    LLVMBuilderRef b;
    LLVMTypeRef i1, i16, i32, i64;
    LLVMValueRef c32(unsigned long long v) { return LLVMConstInt(i32, v, 0); }
    LLVMValueRef c64(unsigned long long v) { return LLVMConstInt(i64, v, 0); }
    LLVMValueRef intrinsic(const char *name, LLVMTypeRef ret, LLVMTypeRef *params, unsigned count) {
        LLVMValueRef f = LLVMGetNamedFunction(module, name);
        return f ? f : LLVMAddFunction(module, name, LLVMFunctionType(ret, params, count, 0));
    }
    LLVMValueRef call(LLVMValueRef f, LLVMValueRef *args, unsigned count) { return LLVMBuildCall(b, f, args, count, ""); }
    LLVMValueRef lo(LLVMValueRef v) { return LLVMBuildTrunc(b, v, i32, ""); }
    LLVMValueRef hi(LLVMValueRef v) { return LLVMBuildTrunc(b, LLVMBuildLShr(b, v, c64(32), ""), i32, ""); }
    LLVMValueRef wide(LLVMValueRef v) { return LLVMBuildZExt(b, v, i64, ""); }
    // c (i1) as 0 or 1 in 64 bits, through llvm.nvvm.min.u.i32 (the plugin's own min, opaque to InstCombine): select c,
    // 1, 0 and zext (zext c) are folded back into zext i1 -> i64 by the plugin's optimizer, and that is what it gets wrong
    LLVMValueRef bool64(LLVMBuilderRef at, LLVMValueRef c) {
        LLVMTypeRef params[2] = {i32, i32};
        LLVMValueRef args[2] = {LLVMBuildZExt(at, c, i32, ""), LLVMConstInt(i32, 1, 0)};
        LLVMValueRef min = LLVMGetNamedFunction(module, "llvm.nvvm.min.u.i32");
        if (!min) min = LLVMAddFunction(module, "llvm.nvvm.min.u.i32", LLVMFunctionType(i32, params, 2, 0));
        return LLVMBuildZExt(at, LLVMBuildCall(at, min, args, 2, ""), i64, "");
    }
    // llvm.ctpop/ctlz/cttz.i32; the count intrinsics are asked for with zero defined (32)
    LLVMValueRef count32(const char *op, LLVMValueRef v) {
        char name[32];
        snprintf(name, sizeof name, "llvm.%s.i32", op);
        bool flag = strcmp(op, "ctpop");
        LLVMTypeRef params[2] = {i32, i1};
        LLVMValueRef args[2] = {v, LLVMConstInt(i1, 0, 0)};
        return call(intrinsic(name, i32, params, flag ? 2 : 1), args, flag ? 2 : 1);
    }
    // high 64 bits of the 128-bit product of a and b, unsigned
    LLVMValueRef mulHiU(LLVMValueRef a, LLVMValueRef b64) {
        LLVMValueRef mask = c64(0xffffffffull), k32 = c64(32);
        LLVMValueRef aL = LLVMBuildAnd(b, a, mask, ""), aH = LLVMBuildLShr(b, a, k32, "");
        LLVMValueRef bL = LLVMBuildAnd(b, b64, mask, ""), bH = LLVMBuildLShr(b, b64, k32, "");
        LLVMValueRef p0 = LLVMBuildMul(b, aL, bL, ""), p1 = LLVMBuildMul(b, aL, bH, "");
        LLVMValueRef p2 = LLVMBuildMul(b, aH, bL, ""), p3 = LLVMBuildMul(b, aH, bH, "");
        LLVMValueRef mid = LLVMBuildAdd(b, LLVMBuildAdd(b, LLVMBuildLShr(b, p0, k32, ""), LLVMBuildAnd(b, p1, mask, ""), ""),
                                        LLVMBuildAnd(b, p2, mask, ""), "");
        LLVMValueRef h = LLVMBuildAdd(b, p3, LLVMBuildLShr(b, p1, k32, ""), "");
        h = LLVMBuildAdd(b, h, LLVMBuildLShr(b, p2, k32, ""), "");
        return LLVMBuildAdd(b, h, LLVMBuildLShr(b, mid, k32, ""), "");
    }
    // signed: hi(a * b) = hiU(a, b) - (a < 0 ? b : 0) - (b < 0 ? a : 0)  (mod 2^64)
    LLVMValueRef mulHi(LLVMValueRef a, LLVMValueRef b64, bool isSigned) {
        LLVMValueRef h = mulHiU(a, b64);
        if (!isSigned) return h;
        LLVMValueRef zero = c64(0);
        h = LLVMBuildSub(b, h, LLVMBuildSelect(b, LLVMBuildICmp(b, LLVMIntSLT, a, zero, ""), b64, zero, ""), "");
        return LLVMBuildSub(b, h, LLVMBuildSelect(b, LLVMBuildICmp(b, LLVMIntSLT, b64, zero, ""), a, zero, ""), "");
    }
};

static bool isInt(LLVMTypeRef t, unsigned width) { return LLVMGetTypeKind(t) == LLVMIntegerTypeKind && LLVMGetIntTypeWidth(t) == width; }

// Checks the declaration's type: returns int width `ret`, `count` parameters of the widths given (0: any type).
static bool shape(LLVMValueRef f, unsigned ret, unsigned count, const unsigned *widths) {
    LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(f));
    if ((ret && !isInt(LLVMGetReturnType(type), ret)) || LLVMCountParamTypes(type) != count || count > 4) return false;
    LLVMTypeRef params[4];
    LLVMGetParamTypes(type, params);
    for (unsigned i = 0; i < count; i++)
        if (widths[i] && !isInt(params[i], widths[i])) return false;
    return true;
}

// Builds a body for the bare declaration f if its name and type are one this file provides; true if it did.
static bool define(Gen &g, LLVMValueRef f, const char *name) {
    static const unsigned k64[3] = {64, 64, 64}, kClz[2] = {64, 1};
    const char *rest;
    bool isSigned = false;
    enum { None, Min, Max, Clamp, Popcount, Clz, Ctz, MulHi, MadHi, QuadXor, Reverse, Abs } kind = None;
    if ((rest = !strncmp(name, "air.min.", 8) ? name + 8 : nullptr)) kind = Min;
    else if ((rest = !strncmp(name, "air.max.", 8) ? name + 8 : nullptr)) kind = Max;
    else if ((rest = !strncmp(name, "air.clamp.", 10) ? name + 10 : nullptr)) kind = Clamp;
    else if ((rest = !strncmp(name, "air.mul_hi.", 11) ? name + 11 : nullptr)) kind = MulHi;
    else if ((rest = !strncmp(name, "air.mad_hi.", 11) ? name + 11 : nullptr)) kind = MadHi;
    else if (!strcmp(name, "air.popcount.i64")) kind = Popcount;
    else if (!strcmp(name, "air.clz.i64")) kind = Clz;
    else if (!strcmp(name, "air.ctz.i64")) kind = Ctz;
    else if (!strcmp(name, "air.reverse_bits.i64")) kind = Reverse;
    else if (!strcmp(name, "air.abs.s.i64")) kind = Abs;
    else if (!strncmp(name, "air.quad_shuffle_xor.", 21)) kind = QuadXor;
    if (rest) {  // <u|s>.i64
        if (strcmp(rest, "u.i64") && strcmp(rest, "s.i64")) return false;
        isSigned = rest[0] == 's';
    }
    unsigned arity = kind == Clamp || kind == MadHi ? 3 : kind == Popcount || kind == Reverse || kind == Abs ? 1 : 2;
    switch (kind) {
        case None: return false;
        case Clz: case Ctz: if (!shape(f, 64, 2, kClz)) return false; break;
        case QuadXor: {
            static const unsigned kXor[2] = {0, 16};
            LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(f));
            if (!shape(f, 0, 2, kXor)) return false;
            LLVMTypeRef params[2];
            LLVMGetParamTypes(type, params);
            if (LLVMGetReturnType(type) != params[0]) return false;
            break;
        }
        default: if (!shape(f, 64, arity, k64)) return false;
    }

    // The body goes into a function of this file's own, and the calls are pointed at it: the plugin keeps its AIR
    // declaration (it deletes the declarations it collected once the run is over), and LLVM's always-inliner deletes
    // the helper once every call is inlined (a dead internal always_inline function), which the plugin never sees.
    LLVMValueRef declaration = f;
    char helper[160];
    snprintf(helper, sizeof helper, "nvair.impl.%s", name);
    f = LLVMAddFunction(g.module, helper, LLVMGetElementType(LLVMTypeOf(declaration)));
    LLVMPositionBuilderAtEnd(g.b, LLVMAppendBasicBlockInContext(g.context, f, "entry"));
    LLVMValueRef p0 = LLVMGetParam(f, 0), p1 = arity > 1 || kind == Clz || kind == Ctz || kind == QuadXor ? LLVMGetParam(f, 1) : nullptr;
    LLVMValueRef result = nullptr;
    LLVMBuilderRef b = g.b;
    switch (kind) {
        case Min: case Max: {
            int pred = kind == Min ? (isSigned ? LLVMIntSLT : LLVMIntULT) : (isSigned ? LLVMIntSGT : LLVMIntUGT);
            result = LLVMBuildSelect(b, LLVMBuildICmp(b, pred, p0, p1, ""), p0, p1, "");
            break;
        }
        case Clamp: {  // clamp(x, lo, hi) = min(max(x, lo), hi)
            LLVMValueRef p2 = LLVMGetParam(f, 2);
            LLVMValueRef m = LLVMBuildSelect(b, LLVMBuildICmp(b, isSigned ? LLVMIntSGT : LLVMIntUGT, p0, p1, ""), p0, p1, "");
            result = LLVMBuildSelect(b, LLVMBuildICmp(b, isSigned ? LLVMIntSLT : LLVMIntULT, m, p2, ""), m, p2, "");
            break;
        }
        case Popcount:
            result = g.wide(LLVMBuildAdd(b, g.count32("ctpop", g.lo(p0)), g.count32("ctpop", g.hi(p0)), ""));
            break;
        case Reverse: {  // each half reversed by the plugin's own llvm.nvvm.reverse_bits, and the halves swapped
            LLVMTypeRef params[1] = {g.i32};
            LLVMValueRef reverse = g.intrinsic("llvm.nvvm.reverse_bits", g.i32, params, 1), lo[1] = {g.lo(p0)}, hi[1] = {g.hi(p0)};
            LLVMValueRef top = LLVMBuildShl(b, g.wide(g.call(reverse, lo, 1)), g.c64(32), "");
            result = LLVMBuildOr(b, top, g.wide(g.call(reverse, hi, 1)), "");
            break;
        }
        case Abs:
            result = LLVMBuildSelect(b, LLVMBuildICmp(b, LLVMIntSLT, p0, g.c64(0), ""), LLVMBuildSub(b, g.c64(0), p0, ""), p0, "");
            break;
        case Clz: {  // the high half's count, or 32 + the low half's when the high half is 0
            LLVMValueRef h = g.hi(p0), isZero = LLVMBuildICmp(b, LLVMIntEQ, h, g.c32(0), "");
            LLVMValueRef low = LLVMBuildAdd(b, g.count32("ctlz", g.lo(p0)), g.c32(32), "");
            result = g.wide(LLVMBuildSelect(b, isZero, low, g.count32("ctlz", h), ""));
            break;
        }
        case Ctz: {  // the low half's count, or 32 + the high half's when the low half is 0
            LLVMValueRef l = g.lo(p0), isZero = LLVMBuildICmp(b, LLVMIntEQ, l, g.c32(0), "");
            LLVMValueRef high = LLVMBuildAdd(b, g.count32("cttz", g.hi(p0)), g.c32(32), "");
            result = g.wide(LLVMBuildSelect(b, isZero, high, g.count32("cttz", l), ""));
            break;
        }
        case MulHi: result = g.mulHi(p0, p1, isSigned); break;
        case MadHi: result = LLVMBuildAdd(b, g.mulHi(p0, p1, isSigned), LLVMGetParam(f, 2), ""); break;
        case QuadXor: {
            char simd[128];
            snprintf(simd, sizeof simd, "air.simd_shuffle_xor.%s", name + 21);
            LLVMValueRef shuffle = LLVMGetNamedFunction(g.module, simd);
            if (!shuffle) shuffle = LLVMAddFunction(g.module, simd, LLVMGetElementType(LLVMTypeOf(f)));
            LLVMValueRef args[2] = {p0, LLVMBuildAnd(b, p1, LLVMConstInt(g.i16, 3, 0), "")};
            result = g.call(shuffle, args, 2);
            break;
        }
        case None: break;
    }
    LLVMBuildRet(b, result);
    LLVMSetLinkage(f, LLVMInternalLinkage);
    static const unsigned alwaysInline = LLVMGetEnumAttributeKindForName("alwaysinline", 12),
                          noInline = LLVMGetEnumAttributeKindForName("noinline", 8);
    LLVMRemoveEnumAttributeAtIndex(f, LLVMAttributeFunctionIndex, noInline);
    LLVMAddAttributeAtIndex(f, LLVMAttributeFunctionIndex, LLVMCreateEnumAttribute(g.context, alwaysInline, 0));
    LLVMReplaceAllUsesWith(declaration, f);  // the declaration stays, unused
    return true;
}

static Gen makeGen(LLVMModuleRef module) {
    Gen g;
    g.module = module;
    g.context = LLVMGetModuleContext(module);
    g.i1 = LLVMInt1TypeInContext(g.context), g.i16 = LLVMInt16TypeInContext(g.context);
    g.i32 = LLVMInt32TypeInContext(g.context), g.i64 = LLVMInt64TypeInContext(g.context);
    g.b = nullptr;
    return g;
}

static unsigned defineMissingIntrinsics(Gen &g) {
    unsigned defined = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(g.module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (strncmp(name, "air.", 4) || !LLVMIsDeclaration(f) || !LLVMGetFirstUse(f)) continue;
        if (!g.b) g.b = LLVMCreateBuilderInContext(g.context);
        if (define(g, f, name)) {
            defined++;
            if (logging()) fprintf(stderr, "[nvair] defined %s\n", name);
        }
    }
    if (g.b) LLVMDisposeBuilder(g.b), g.b = nullptr;
    return defined;
}

// Inlines the always_inline helpers made here (nvair.*), which the inliner then deletes. Nothing the plugin made is
// deleted: it collected its AIR declarations before this run and deletes them after it (LLVMDeleteFunction), so
// deleting one here left it a dangling pointer (a crash in the compiler service); the declarations stay, unused.
static void inlineBodies(LLVMModuleRef module) {
    LLVMPassManagerRef pm = LLVMCreatePassManager();
    LLVMAddAlwaysInlinerPass(pm);
    LLVMRunPassManager(pm, module);
    LLVMDisposePassManager(pm);
}

// ---- 64-bit instructions the plugin gets wrong -----------------------------------------------------------------------
static void markInline(LLVMContextRef context, LLVMValueRef f) {
    static const unsigned alwaysInline = LLVMGetEnumAttributeKindForName("alwaysinline", 12);
    LLVMSetLinkage(f, LLVMInternalLinkage);
    LLVMAddAttributeAtIndex(f, LLVMAttributeFunctionIndex, LLVMCreateEnumAttribute(context, alwaysInline, 0));
}

// nvair.udiv64 / nvair.urem64 (i64 a, i64 b): restoring division, one quotient bit per step from the top, unrolled into
// straight-line code (64 steps of shift, compare, select and subtract). The first version took a 32-bit division when
// both operands fit and looped otherwise; with its branch and loop inlined, Kepler's compiler got a private-array load
// and store around two such divisions in the wrong order (pc[a / b] = (uchar)(c / (d | pc[i])) read the stored byte:
// mslfuzz2 LONG=1 seed 770, reduced), and the straight-line form compiles right. The quotient's bits are collected in two
// 32-bit halves: widening a bool to 64 bits is what the plugin gets wrong. Division by 0 gives all ones (remainder: a).
static LLVMValueRef divisionHelper(Gen &g, bool remainder) {
    const char *name = remainder ? "nvair.urem64" : "nvair.udiv64";
    if (LLVMValueRef f = LLVMGetNamedFunction(g.module, name)) return f;
    LLVMTypeRef params[2] = {g.i64, g.i64};
    LLVMValueRef f = LLVMAddFunction(g.module, name, LLVMFunctionType(g.i64, params, 2, 0));
    LLVMValueRef a = LLVMGetParam(f, 0), d = LLVMGetParam(f, 1);
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    LLVMPositionBuilderAtEnd(b, LLVMAppendBasicBlockInContext(g.context, f, "entry"));
    LLVMValueRef r = g.c64(0), halves[2] = {g.c32(0), g.c32(0)};  // the quotient's high and low 32 bits
    for (int i = 63; i >= 0; i--) {
        LLVMValueRef bit = i ? LLVMBuildAnd(b, LLVMBuildLShr(b, a, g.c64((unsigned)i), ""), g.c64(1), "") : LLVMBuildAnd(b, a, g.c64(1), "");
        LLVMValueRef r1 = LLVMBuildOr(b, LLVMBuildShl(b, r, g.c64(1), ""), bit, "");
        LLVMValueRef ge = LLVMBuildICmp(b, LLVMIntUGE, r1, d, "");
        r = LLVMBuildSelect(b, ge, LLVMBuildSub(b, r1, d, ""), r1, "");
        LLVMValueRef &half = halves[i >= 32 ? 0 : 1];
        half = LLVMBuildOr(b, LLVMBuildShl(b, half, g.c32(1), ""), LLVMBuildZExt(b, ge, g.i32, ""), "");
    }
    LLVMValueRef q = LLVMBuildOr(b, LLVMBuildShl(b, LLVMBuildZExt(b, halves[0], g.i64, ""), g.c64(32), ""), LLVMBuildZExt(b, halves[1], g.i64, ""), "");
    LLVMBuildRet(b, remainder ? r : q);
    LLVMDisposeBuilder(b);
    markInline(g.context, f);
    return f;
}

// Lanes of an integer type (1 for a scalar) if its elements are `width` bits, else 0.
static unsigned intLanes(LLVMTypeRef t, unsigned width) {
    if (LLVMGetTypeKind(t) == LLVMVectorTypeKind) return isInt(LLVMGetElementType(t), width) ? LLVMGetVectorSize(t) : 0;
    return isInt(t, width) ? 1 : 0;
}

// One lane of an i64 division or remainder (x, y: i64), through nvair.udiv64 / nvair.urem64.
static LLVMValueRef divideLane(Gen &g, LLVMBuilderRef b, int op, LLVMValueRef x, LLVMValueRef y) {
    bool isSigned = op == LLVMSDiv || op == LLVMSRem, remainder = op == LLVMURem || op == LLVMSRem;
    LLVMValueRef zero = g.c64(0), xNeg = nullptr, yNeg = nullptr;
    if (isSigned) {  // on the magnitudes; the quotient is negative if the signs differ, the remainder if x is
        xNeg = LLVMBuildICmp(b, LLVMIntSLT, x, zero, ""), yNeg = LLVMBuildICmp(b, LLVMIntSLT, y, zero, "");
        x = LLVMBuildSelect(b, xNeg, LLVMBuildNeg(b, x, ""), x, "");
        y = LLVMBuildSelect(b, yNeg, LLVMBuildNeg(b, y, ""), y, "");
    }
    LLVMValueRef args[2] = {x, y};
    LLVMValueRef result = LLVMBuildCall(b, divisionHelper(g, remainder), args, 2, "");
    if (isSigned) {
        LLVMValueRef negate = remainder ? xNeg : LLVMBuildICmp(b, LLVMIntNE, xNeg, yNeg, "");
        result = LLVMBuildSelect(b, negate, LLVMBuildNeg(b, result, ""), result, "");
    }
    return result;
}

// One lane of an i64 shift by a variable amount, from 32-bit shifts of the halves, without selects: the < 32 and >= 32
// results are combined through a mask (all ones below 32), the bits that cross over come from a double shift that is 0
// for an amount of 0, and the amount goes through llvm.nvvm.min.u.i32 so the optimizer can't bound it. A first version
// chose with selects; where the optimizer could tell the amount was 0 or 1 it turned them into predicates and a widened
// i1, which Kepler's code generation got wrong next to a threadgroup load after a barrier (the shift's result came out
// 0: LONG fuzz seeds 1295 and 1853, reduced), though the IR was right. Every 32-bit shift amount is masked into 0-31, so
// nothing is poison.
extern "C" LLVMValueRef LLVMBuildXor(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
static LLVMValueRef shiftLane(Gen &g, LLVMBuilderRef b, int op, LLVMValueRef x, LLVMValueRef amount) {
    LLVMTypeRef params[2] = {g.i32, g.i32};
    LLVMValueRef minArgs[2] = {LLVMBuildAnd(b, LLVMBuildTrunc(b, amount, g.i32, ""), g.c32(63), ""), g.c32(63)};
    LLVMValueRef s = LLVMBuildCall(b, g.intrinsic("llvm.nvvm.min.u.i32", g.i32, params, 2), minArgs, 2, "");
    LLVMValueRef s5 = LLVMBuildAnd(b, s, g.c32(31), ""), rest = LLVMBuildSub(b, g.c32(31), s5, "");
    LLVMValueRef m = LLVMBuildSub(b, g.c32(0), LLVMBuildXor(b, LLVMBuildLShr(b, s, g.c32(5), ""), g.c32(1), ""), ""), nm = LLVMBuildNot(b, m, "");
    LLVMValueRef lo = LLVMBuildTrunc(b, x, g.i32, ""), hi = LLVMBuildTrunc(b, LLVMBuildLShr(b, x, g.c64(32), ""), g.i32, ""), newLo, newHi;
    if (op == LLVMShl) {
        LLVMValueRef carry = LLVMBuildLShr(b, LLVMBuildLShr(b, lo, g.c32(1), ""), rest, "");  // lo >> (32 - s); 0 for s = 0
        LLVMValueRef loShifted = LLVMBuildShl(b, lo, s5, "");
        newLo = LLVMBuildAnd(b, loShifted, m, "");
        newHi = LLVMBuildOr(b, LLVMBuildAnd(b, LLVMBuildOr(b, LLVMBuildShl(b, hi, s5, ""), carry, ""), m, ""), LLVMBuildAnd(b, loShifted, nm, ""), "");
    } else {
        bool arithmetic = op == LLVMAShr;
        LLVMValueRef carry = LLVMBuildShl(b, LLVMBuildShl(b, hi, g.c32(1), ""), rest, "");  // hi << (32 - s); 0 for s = 0
        LLVMValueRef hiShifted = arithmetic ? LLVMBuildAShr(b, hi, s5, "") : LLVMBuildLShr(b, hi, s5, "");
        LLVMValueRef fill = arithmetic ? LLVMBuildAShr(b, hi, g.c32(31), "") : g.c32(0);
        newLo = LLVMBuildOr(b, LLVMBuildAnd(b, LLVMBuildOr(b, LLVMBuildLShr(b, lo, s5, ""), carry, ""), m, ""), LLVMBuildAnd(b, hiShifted, nm, ""), "");
        newHi = LLVMBuildOr(b, LLVMBuildAnd(b, hiShifted, m, ""), LLVMBuildAnd(b, fill, nm, ""), "");
    }
    return LLVMBuildOr(b, LLVMBuildShl(b, LLVMBuildZExt(b, newHi, g.i64, ""), g.c64(32), ""), LLVMBuildZExt(b, newLo, g.i64, ""), "");
}

static unsigned fixWideInstructions(LLVMModuleRef module, Gen &g) {
    unsigned fixed = 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (LLVMIsDeclaration(f) || !strncmp(LLVMGetValueName(f), "nvair.", 6)) continue;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb)) {
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb), next; inst; inst = next) {
                next = LLVMGetNextInstruction(inst);
                int op = LLVMGetInstructionOpcode(inst);
                LLVMTypeRef type = LLVMTypeOf(inst);
                unsigned lanes = intLanes(type, 64);
                bool widen = (op == LLVMZExt || op == LLVMSExt) && lanes && intLanes(LLVMTypeOf(LLVMGetOperand(inst, 0)), 1) == lanes;
                bool divide = (op == LLVMUDiv || op == LLVMURem || op == LLVMSDiv || op == LLVMSRem) && lanes;
                static const bool shiftFix = !disabled("NVAIR_SHIFT_FIX");
                bool shift = shiftFix && (op == LLVMShl || op == LLVMLShr || op == LLVMAShr) && lanes && !LLVMIsAConstantInt(LLVMGetOperand(inst, 1)) &&
                             !(LLVMGetTypeKind(type) == LLVMVectorTypeKind && LLVMIsAConstant(LLVMGetOperand(inst, 1)));
                if (!widen && !divide && !shift) continue;
                LLVMPositionBuilderBefore(b, inst);
                bool vector = LLVMGetTypeKind(type) == LLVMVectorTypeKind;
                LLVMValueRef replacement = vector ? LLVMGetUndef(type) : nullptr;
                for (unsigned lane = 0; lane < lanes; lane++) {  // vectors one lane at a time
                    LLVMValueRef index = g.c32(lane);
                    auto operand = [&](unsigned i) {
                        LLVMValueRef v = LLVMGetOperand(inst, i);
                        return vector ? LLVMBuildExtractElement(b, v, index, "") : v;
                    };
                    LLVMValueRef value;
                    if (widen) {
                        value = g.bool64(b, operand(0));
                        if (op == LLVMSExt) value = LLVMBuildSub(b, g.c64(0), value, "");
                    } else if (shift) {
                        value = shiftLane(g, b, op, operand(0), operand(1));
                    } else {
                        value = divideLane(g, b, op, operand(0), operand(1));
                    }
                    replacement = vector ? LLVMBuildInsertElement(b, replacement, value, index, "") : value;
                }
                LLVMReplaceAllUsesWith(inst, replacement);
                LLVMInstructionEraseFromParent(inst);
                fixed++;
            }
        }
    }
    LLVMDisposeBuilder(b);
    return fixed;
}

// ---- constexpr samplers from newer front ends ([2 x i64] -> i64 with bit 63 set; IntelAdapter's fixSamplerStateWords) ----
extern "C" {
unsigned LLVMGetNamedMetadataNumOperands(LLVMModuleRef, const char *);
void LLVMGetNamedMetadataOperands(LLVMModuleRef, const char *, LLVMValueRef *);
LLVMValueRef LLVMIsAMDNode(LLVMValueRef);
LLVMValueRef LLVMIsAMDString(LLVMValueRef);
unsigned LLVMGetMDNodeNumOperands(LLVMValueRef);
void LLVMGetMDNodeOperands(LLVMValueRef, LLVMValueRef *);
const char *LLVMGetMDString(LLVMValueRef, unsigned *);
LLVMValueRef LLVMIsAGlobalVariable(LLVMValueRef);
LLVMValueRef LLVMGetInitializer(LLVMValueRef);
void LLVMSetInitializer(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMIsAConstantDataArray(LLVMValueRef);
LLVMValueRef LLVMIsAConstantAggregateZero(LLVMValueRef);
LLVMValueRef LLVMGetElementAsConstant(LLVMValueRef, unsigned);
unsigned long long LLVMConstIntGetZExtValue(LLVMValueRef);
unsigned LLVMGetArrayLength(LLVMTypeRef);
LLVMValueRef LLVMAddGlobalInAddressSpace(LLVMModuleRef, LLVMTypeRef, const char *, unsigned);
void LLVMSetGlobalConstant(LLVMValueRef, int);
int LLVMGetLinkage(LLVMValueRef);
void LLVMSetAlignment(LLVMValueRef, unsigned);
unsigned LLVMGetPointerAddressSpace(LLVMTypeRef);
LLVMValueRef LLVMConstBitCast(LLVMValueRef, LLVMTypeRef);
void LLVMSetValueName(LLVMValueRef, const char *);
}
extern "C" void mdNodeReplaceOperand(void *node, unsigned index, void *replacement) asm("__ZN4llvm6MDNode18replaceOperandWithEjPNS_8MetadataE");
extern "C" void *valueAsMetadata(LLVMValueRef value) asm("__ZN4llvm15ValueAsMetadata3getEPNS_5ValueE");

static std::vector<LLVMValueRef> metadataOperands(LLVMValueRef node) {
    std::vector<LLVMValueRef> out(node && LLVMIsAMDNode(node) ? LLVMGetMDNodeNumOperands(node) : 0);
    if (!out.empty()) LLVMGetMDNodeOperands(node, out.data());
    return out;
}
static void *metadataOf(LLVMValueRef value) {  // MetadataAsValue::MD: +0x20 in this LLVM, as LLVMGetMDNodeNumOperands reads it
    if (!value || !LLVMIsAMDNode(value)) return nullptr;
    void *md = *(void **)((char *)value + 0x20);
    return md && *(unsigned *)((char *)md + 8) == LLVMGetMDNodeNumOperands(value) ? md : nullptr;
}
static bool isString(LLVMValueRef value, const char *text) {
    unsigned length = 0;
    const char *s = value && LLVMIsAMDString(value) ? LLVMGetMDString(value, &length) : nullptr;
    return s && length == strlen(text) && !memcmp(s, text, length);
}

static unsigned fixSamplerStateWords(LLVMModuleRef module, Gen &g) {
    enum { kArrayKind = 11 };  // LLVMTypeKind
    std::vector<LLVMValueRef> states(LLVMGetNamedMetadataNumOperands(module, "air.sampler_states"));
    if (states.empty()) return 0;
    LLVMGetNamedMetadataOperands(module, "air.sampler_states", states.data());
    unsigned fixed = 0;
    for (LLVMValueRef state : states) {  // !{!"air.sampler_state", [2 x i64] addrspace(2)* @__air_sampler_state}
        std::vector<LLVMValueRef> parts = metadataOperands(state);
        void *node = metadataOf(state);
        if (parts.size() != 2 || !isString(parts[0], "air.sampler_state") || !node) continue;
        LLVMValueRef global = parts[1] ? LLVMIsAGlobalVariable(parts[1]) : nullptr;
        LLVMValueRef words = global ? LLVMGetInitializer(global) : nullptr;
        LLVMTypeRef type = words ? LLVMTypeOf(words) : nullptr;
        bool zero = words && LLVMIsAConstantAggregateZero(words);  // a state with every field 0 is a zeroinitializer
        if (!type || LLVMGetTypeKind(type) != kArrayKind || LLVMGetArrayLength(type) != 2 || LLVMGetElementType(type) != g.i64 ||
            !(zero || LLVMIsAConstantDataArray(words)))
            continue;
        unsigned long long first = zero ? 0 : LLVMConstIntGetZExtValue(LLVMGetElementAsConstant(words, 0));
        unsigned long long second = zero ? 0 : LLVMConstIntGetZExtValue(LLVMGetElementAsConstant(words, 1));
        if (second && logging()) fprintf(stderr, "[nvair] sampler state: second word 0x%llx not representable, dropped\n", second);
        std::string name = LLVMGetValueName(global);
        LLVMValueRef word = LLVMAddGlobalInAddressSpace(module, g.i64, (name + ".word").c_str(), LLVMGetPointerAddressSpace(LLVMTypeOf(global)));
        LLVMSetInitializer(word, LLVMConstInt(g.i64, first | 1ull << 63, 0));
        LLVMSetGlobalConstant(word, 1);
        LLVMSetLinkage(word, LLVMGetLinkage(global));
        LLVMSetAlignment(word, 8);
        mdNodeReplaceOperand(node, 1, valueAsMetadata(word));
        LLVMReplaceAllUsesWith(global, LLVMConstBitCast(word, LLVMTypeOf(global)));
        LLVMSetValueName(global, "nvair.unused_sampler_state");  // kept, unused, as everything the plugin made
        LLVMSetValueName(word, name.c_str());
        fixed++;
    }
    return fixed;
}

// ---- threadgroup bools (IntelAdapter's widenThreadgroupBools) ---------------------------------------------------------
// LLVM shrinks a threadgroup bool to an i1 global; on Kepler a value stored to it and read back never arrived (a10:
// the output keeps its fill, WebKit's WebGPU workgroupUniformLoad on bool). Such globals become i8: loads compare with
// 0 (a truncation is turned back into an i1 load), stores zero-extend, both volatile so the optimizer doesn't shrink
// the global again. The i1 global stays, unused and renamed (the plugin keeps pointers to the module's objects across
// the run, as with its declarations). NVAIR_THREADGROUP_BOOL_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMGetFirstGlobal(LLVMModuleRef);
LLVMValueRef LLVMGetNextGlobal(LLVMValueRef);
LLVMValueRef LLVMIsALoadInst(LLVMValueRef);
LLVMValueRef LLVMIsAStoreInst(LLVMValueRef);
LLVMTypeRef LLVMInt8TypeInContext(LLVMContextRef);
void LLVMSetVolatile(LLVMValueRef, int);
LLVMUseRef LLVMGetNextUse(LLVMUseRef);
LLVMValueRef LLVMGetUser(LLVMUseRef);
LLVMValueRef LLVMBuildLoad(LLVMBuilderRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildStore(LLVMBuilderRef, LLVMValueRef, LLVMValueRef);
}

static unsigned widenThreadgroupBools(LLVMModuleRef module, Gen &g) {
    LLVMTypeRef i8 = LLVMInt8TypeInContext(g.context);
    std::vector<LLVMValueRef> globals;
    for (LLVMValueRef v = LLVMGetFirstGlobal(module); v; v = LLVMGetNextGlobal(v))
        if (LLVMGetPointerAddressSpace(LLVMTypeOf(v)) == 3 && LLVMGetElementType(LLVMTypeOf(v)) == g.i1 && LLVMGetFirstUse(v)) globals.push_back(v);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef v : globals) {
        std::vector<LLVMValueRef> users;
        bool plain = true;  // only loads from it and stores to it
        for (LLVMUseRef u = LLVMGetFirstUse(v); u; u = LLVMGetNextUse(u)) {
            LLVMValueRef user = LLVMGetUser(u);
            if (LLVMIsALoadInst(user) || (LLVMIsAStoreInst(user) && LLVMGetOperand(user, 1) == v && LLVMGetOperand(user, 0) != v)) users.push_back(user);
            else plain = false;
        }
        if (!plain) continue;
        std::string name = LLVMGetValueName(v);
        LLVMValueRef wide = LLVMAddGlobalInAddressSpace(module, i8, (name + ".i8").c_str(), 3);
        LLVMValueRef init = LLVMGetInitializer(v);
        LLVMSetInitializer(wide, init && LLVMIsAConstantInt(init) ? LLVMConstInt(i8, LLVMConstIntGetZExtValue(init), 0) : LLVMGetUndef(i8));
        LLVMSetLinkage(wide, LLVMGetLinkage(v));
        LLVMSetAlignment(wide, 1);
        if (!b) b = LLVMCreateBuilderInContext(g.context);
        for (LLVMValueRef user : users) {
            LLVMPositionBuilderBefore(b, user);
            if (LLVMIsALoadInst(user)) {
                LLVMValueRef load = LLVMBuildLoad(b, wide, "");
                LLVMSetVolatile(load, 1);
                LLVMReplaceAllUsesWith(user, LLVMBuildICmp(b, LLVMIntNE, load, LLVMConstInt(i8, 0, 0), ""));
            } else {
                LLVMSetVolatile(LLVMBuildStore(b, LLVMBuildZExt(b, LLVMGetOperand(user, 0), i8, ""), wide), 1);
            }
            LLVMInstructionEraseFromParent(user);
        }
        LLVMSetValueName(v, (name + ".unused").c_str());
        LLVMSetValueName(wide, name.c_str());
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- cube array indices below 0 (AMDAdapter's clampCubeArrayIndices) -----------------------------------------------------
// A cube array sample, gather or compare with an index below 0 read another cube than the first (a09, WebGPU CTS cube
// array cases with negative indices, which ask for the nearest layer): the index is raised to 0 first, with a compare
// and select (a new air.max declaration would be one the plugin has no body for). NVAIR_CUBE_ARRAY_FIX=0 turns it off.
extern "C" {
void LLVMSetOperand(LLVMValueRef, unsigned, LLVMValueRef);
LLVMValueRef LLVMIsACallInst(LLVMValueRef);
LLVMValueRef LLVMIsASelectInst(LLVMValueRef);
int LLVMGetNumOperands(LLVMValueRef);
}

static unsigned clampCubeArrayIndices(LLVMModuleRef module, Gen &g) {
    static const struct { const char *prefix; unsigned index; } kForms[] = {
        {"air.sample_texture_cube_array.", 3}, {"air.sample_texture_cube_array_grad.", 3}, {"air.gather_texture_cube_array.", 3},
        {"air.sample_depth_cube_array.", 4}, {"air.sample_compare_depth_cube_array.", 4}, {"air.gather_depth_cube_array.", 4},
        {"air.gather_compare_depth_cube_array.", 4},
    };
    unsigned clamped = 0;
    LLVMBuilderRef b = nullptr;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        int form = -1;
        for (unsigned i = 0; i < sizeof kForms / sizeof *kForms && form < 0; i++)
            if (!strncmp(name, kForms[i].prefix, strlen(kForms[i].prefix))) form = (int)i;
        if (form < 0) continue;
        unsigned index = kForms[form].index;
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) {
            LLVMValueRef call = LLVMIsACallInst(LLVMGetUser(u));
            if (call && LLVMGetNumOperands(call) > (int)index + 1 && LLVMGetOperand(call, LLVMGetNumOperands(call) - 1) == f &&
                isInt(LLVMTypeOf(LLVMGetOperand(call, index)), 32))
                calls.push_back(call);
        }
        for (LLVMValueRef call : calls) {
            LLVMValueRef value = LLVMGetOperand(call, index);
            if (LLVMIsAConstantInt(value) && (long long)LLVMConstIntGetZExtValue(value) >= 0 && LLVMConstIntGetZExtValue(value) < 0x80000000ull) continue;
            if (LLVMIsASelectInst(value) && LLVMGetOperand(value, 1) == g.c32(0)) continue;  // clamped in an earlier run
            if (!b) b = LLVMCreateBuilderInContext(g.context);
            LLVMPositionBuilderBefore(b, call);
            LLVMValueRef zero = g.c32(0);
            LLVMSetOperand(call, index, LLVMBuildSelect(b, LLVMBuildICmp(b, LLVMIntSLT, value, zero, ""), zero, value, ""));
            clamped++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return clamped;
}

static void logBareIntrinsics(LLVMModuleRef module) {
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (strncmp(name, "air.", 4) || !LLVMIsDeclaration(f) || !LLVMGetFirstUse(f)) continue;
        if (!strncmp(name, "air.simd_shuffle", 16) || !strncmp(name, "air.simd_broadcast", 18)) continue;  // selected by name
        fprintf(stderr, "[nvair] no body for %s\n", name);
    }
}

static int hookedRun(void *self, LLVMModuleRef module) {
#ifdef NVAIR_INTERPOSE  // the test build catches every PassManager::run in the process: act for the GeForce plugin's only
    {
        Dl_info caller;
        size_t suffix = strlen(kPluginSuffix), length;
        if (!dladdr(__builtin_return_address(0), &caller) || !caller.dli_fname || (length = strlen(caller.dli_fname)) < suffix ||
            strcmp(caller.dli_fname + length - suffix, kPluginSuffix))
            return passManagerRun(self, module);
    }
#endif
    if (const char *dir = getenv("NVAIR_DUMP_INPUT"); dir && module) {
        static int serial;
        char path[1024];
        snprintf(path, sizeof path, "%s/input-%d-%d.ll", dir, (int)getpid(), serial++);
        if (FILE *f = fopen(path, "w")) { char *text = LLVMPrintModuleToString(module); fputs(text, f); LLVMDisposeMessage(text); fclose(f); }
    }
    if (module) {
        Gen g = makeGen(module);
        unsigned defined = disabled("NVAIR_INTRINSICS") ? 0 : defineMissingIntrinsics(g);
        unsigned fixed = disabled("NVAIR_I64_FIX") ? 0 : fixWideInstructions(module, g);
        unsigned samplers = disabled("NVAIR_SAMPLER_STATE_FIX") ? 0 : fixSamplerStateWords(module, g);
        unsigned bools = disabled("NVAIR_THREADGROUP_BOOL_FIX") ? 0 : widenThreadgroupBools(module, g);
        if (bools && logging()) fprintf(stderr, "[nvair] %u threadgroup bool(s) widened to i8\n", bools);
        unsigned cubes = disabled("NVAIR_CUBE_ARRAY_FIX") ? 0 : clampCubeArrayIndices(module, g);
        if (cubes && logging()) fprintf(stderr, "[nvair] %u cube array index(es) raised to 0\n", cubes);
        if (samplers && logging()) fprintf(stderr, "[nvair] %u constexpr sampler(s) in the [2 x i64] form rewritten as i64\n", samplers);
        if (defined || fixed) inlineBodies(module);
        if (logging() && (defined || fixed)) fprintf(stderr, "[nvair] %u intrinsic(s) given bodies, %u 64-bit instruction(s) rewritten\n", defined, fixed);
        if (logging()) logBareIntrinsics(module);
    }
    return passManagerRun(self, module);
}

// Redirect the plugin's imported pointer to PassManager::run (found by value in its data segments).
static unsigned redirectPassManager(const mach_header_64 *header, intptr_t slide) {
    unsigned patched = 0;
    const char *p = (const char *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, p += ((const load_command *)p)->cmdsize) {
        const segment_command_64 *seg = (const segment_command_64 *)p;
        if (seg->cmd != LC_SEGMENT_64 || strncmp(seg->segname, "__DATA", 6)) continue;
        void **start = (void **)(seg->vmaddr + slide), **end = (void **)(seg->vmaddr + slide + seg->vmsize);
        for (void **slot = start; slot < end; slot++) {
            if (*slot != (void *)passManagerRun) continue;
            vm_protect(mach_task_self(), (vm_address_t)slot & ~(vm_address_t)(vm_page_size - 1), vm_page_size, false,
                       VM_PROT_READ | VM_PROT_WRITE);
            *slot = (void *)hookedRun;
            patched++;
        }
    }
    return patched;
}

static void installIntoPlugin() {
    static bool done;
    if (done) return;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0, suffix = strlen(kPluginSuffix);
        if (len < suffix || strcmp(name + len - suffix, kPluginSuffix)) continue;
        done = true;
        unsigned n = redirectPassManager((const mach_header_64 *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
        if (logging()) fprintf(stderr, "[nvair] %s: %u import(s) redirected\n", name, n);
    }
}

__attribute__((constructor)) static void installFromConstructor() {
    if (const char *log = getenv("NVAIR_LOG"); log && log[0] == '/') freopen(log, "a", stderr);
    installIntoPlugin();
}

#ifdef NVAIR_INTERPOSE  // test build for DYLD_INSERT_LIBRARIES
__attribute__((used, section("__DATA,__interpose"))) static struct { void *replacement, *original; } interposers[] = {
    {(void *)hookedRun, (void *)passManagerRun},
};
#endif
