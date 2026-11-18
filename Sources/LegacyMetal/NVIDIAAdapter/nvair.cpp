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
        if (defined) inlineBodies(module);
        if (logging() && defined) fprintf(stderr, "[nvair] %u intrinsic(s) given bodies\n", defined);
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
