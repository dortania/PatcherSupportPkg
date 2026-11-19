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
// Gradient samples of 3D textures and cubes in compute kernels (which broke the kernel) done at the level they pick.
// NVAIR_GRADIENT_FIX=0.
//
// Depth comparisons at a computed level or bias (which returned the depth) done at level 0 / the implicit level.
// NVAIR_COMPARE_LEVEL_FIX=0.
//
// Depth comparisons with gradients (no body: the pipeline failed) done at level 0. NVAIR_COMPARE_GRADIENT_FIX=0.
//
// clz and ctz asked for the defined result at 0 (the library's undefined one folds to garbage for a constant 0).
// NVAIR_COUNT_ZERO_FIX=0.
//
// Private arrays of bytes and halfwords done on 32-bit words (a stored word reached their loads unmasked).
// NVAIR_NARROW_PRIVATE_ARRAY_FIX=0.
//
// discard_fragment in fragment functions with derivatives made a demote to a helper lane (the lane ended there, and its
// quad's later derivatives were 0). NVAIR_DEMOTE_DISCARD=0.
//
// Device loads in fragment functions at a 32-bit index with its top bit set read element 0 (helper lanes' wrapped
// indexes faulted the driver, which failed a later command buffer: ANGLE's PBO uploads). NVAIR_FRAGMENT_LOAD_GUARD=0.
//
// 32-bit products of 16-bit factors, and products an or uses, hidden from the optimizer behind an opaque min (it took
// bits of products for clear). NVAIR_NARROW_MULTIPLY_FIX=0.
//
// Half vectors spelled as bitcasts of integers in constant initializers (a constant half2x2 array crashed the
// compiler) rewritten as plain half vectors. NVAIR_HALF_CONSTANT_FIX=0.
//
// Constant-length copies (llvm.memcpy) of 64 bytes or more made word loops (the back end's time was cubic in their size:
// a WebGPU CTS kernel kept the compiler busy for minutes). NVAIR_LARGE_COPY_LOOP=0.
//
// Depth and stencil textures sampled through texture2d in ANGLE's shaders made (x, 0, 0, 1) from a mask MetalOldCompat
// item 62 binds (the sampler gave (x, x, x, x)). NVAIR_DEPTH_CHANNELS=0.
//
// Texture atomics on read_write texture2d<uint/int> (no body in the plugin: the compiler crashed) made global atomics on
// the linear buffer MetalOldCompat item 58 gives such textures, bound at a hidden buffer index. NVAIR_TEXTURE_ATOMICS=0.
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
#include <cmath>
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

// ---- cube reads at a level -----------------------------------------------------------------------------------------------
// read() of a cube or cube array at a level above 0 gave level 0 on Kepler, in depth and color formats alike (GTX 770;
// reads of 2D and 2D-array textures at a level are right, and so is a cube sample with level(); s70's compute check of a
// Depth32Float cube array). The plugin's library reads a cube texel by a sample.tex.cube[.array].lod along the direction
// of its centre, with the level as the LOD, but works the direction out from level 0's size (txq ... lod(texture, 0)) and
// samples with a built-in sampler, 0x8000000000002049, whose LOD clamp is 0 and which has no mip filter. Each such body
// in the module gets the level's size and the same sampler with a nearest mip filter and the largest LOD clamp (bit 19 and
// 0x7bff, half 65504, in bits 48-63, as constexpr sampler(filter::nearest, mip_filter::nearest) is encoded). Level 0
// reads the same texel as before. A body that isn't exactly that (two size queries at 0, one sample with that sampler)
// is left alone; one given the level in an earlier run (the plugin runs its pass managers twice) is skipped.
// NVAIR_CUBE_READ_LEVEL=0 turns it off.
extern "C" {
LLVMValueRef LLVMConstIntToPtr(LLVMValueRef, LLVMTypeRef);
unsigned LLVMCountParams(LLVMValueRef);
LLVMValueRef LLVMGetCalledValue(LLVMValueRef);
}
enum { kOpIntToPtr = 40 };  // LLVM-C's LLVMIntToPtr
static bool startsWith(const char *s, const char *prefix);

static unsigned fixCubeReadLevels(LLVMModuleRef module, Gen &g) {
    static const struct { const char *prefix; unsigned level; } kForms[] = {  // the level's parameter
        {"air.read_texture_cube.", 3}, {"air.read_texture_cube_array.", 4}, {"air.read_depth_cube.", 4}, {"air.read_depth_cube_array.", 5},
    };
    const unsigned long long kPluginSampler = 0x8000000000002049ull, kLevelSampler = 0x807bff0000082049ull;
    unsigned fixed = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        int form = -1;
        for (unsigned i = 0; i < sizeof kForms / sizeof *kForms && form < 0; i++)
            if (!strncmp(name, kForms[i].prefix, strlen(kForms[i].prefix))) form = (int)i;
        if (form < 0 || LLVMIsDeclaration(f) || LLVMCountParams(f) <= kForms[form].level) continue;
        LLVMValueRef level = LLVMGetParam(f, kForms[form].level);
        if (!isInt(LLVMTypeOf(level), 32)) continue;
        std::vector<LLVMValueRef> sizes, samples;
        bool other = false, done = false;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (!LLVMIsACallInst(inst)) continue;
                LLVMValueRef callee = LLVMGetCalledValue(inst);
                const char *c = callee ? LLVMGetValueName(callee) : "";
                if (startsWith(c, "llvm.nvvm.txq.width.cube") || startsWith(c, "llvm.nvvm.txq.height.cube")) {
                    LLVMValueRef at = LLVMGetNumArgOperands(inst) == 2 ? LLVMGetOperand(inst, 1) : nullptr;
                    if (at == level) done = true;  // given the level in an earlier run
                    else if (at && LLVMIsAConstantInt(at) && !LLVMConstIntGetZExtValue(at)) sizes.push_back(inst);
                    else other = true;
                } else if (startsWith(c, "llvm.nvvm.sample.tex.cube") && strstr(c, ".lod.")) {
                    LLVMValueRef s = LLVMGetNumArgOperands(inst) >= 2 ? LLVMGetOperand(inst, 1) : nullptr;
                    bool plugin = s && LLVMIsAConstantExpr(s) && LLVMGetConstOpcode(s) == kOpIntToPtr &&
                                  LLVMIsAConstantInt(LLVMGetOperand(s, 0)) && LLVMConstIntGetZExtValue(LLVMGetOperand(s, 0)) == kPluginSampler;
                    if (plugin) samples.push_back(inst);
                    else if (!(s && LLVMIsAConstantExpr(s) && LLVMGetConstOpcode(s) == kOpIntToPtr && LLVMIsAConstantInt(LLVMGetOperand(s, 0)) &&
                               LLVMConstIntGetZExtValue(LLVMGetOperand(s, 0)) == kLevelSampler)) other = true;
                }
            }
        if (done) continue;
        if (other || sizes.size() != 2 || samples.size() != 1) {
            if (logging()) fprintf(stderr, "[nvair] %s: not the expected cube read, left alone\n", name);
            continue;
        }
        for (LLVMValueRef q : sizes) LLVMSetOperand(q, 1, level);
        LLVMValueRef old = LLVMGetOperand(samples[0], 1);
        LLVMSetOperand(samples[0], 1, LLVMConstIntToPtr(g.c64(kLevelSampler), LLVMTypeOf(old)));
        fixed++;
    }
    return fixed;
}

// ---- compare-exchange on threadgroup memory ----------------------------------------------------------------------------
// atomic_compare_exchange_weak_explicit on a threadgroup atomic that failed left the expected value as it was on Kepler
// instead of the value it found, so the old value came back as the comparand (GTX 770; WebGPU CTS atomicCompareExchangeWeak
// compare_exchange_weak_workgroup_basic: every exchange that fails; the device-memory form is right). The plugin's
// library body for air.atomic.local.cmpxchg.* lacks the store of the found value into *expected that its
// air.atomic.global.cmpxchg.* body makes where the exchange fails, and marks the pointer readonly. Each such body gets the
// store, at the start of its failure block, and loses readonly. NVAIR_LOCAL_CMPXCHG=0 turns it off.
extern "C" {
LLVMValueRef LLVMIsAICmpInst(LLVMValueRef);
}
enum { kOpBr = 2, kOpStore = 28 };  // LLVM-C's LLVMBr, LLVMStore

static unsigned fixLocalCompareExchange(LLVMModuleRef module, Gen &g) {
    static const unsigned readOnly = LLVMGetEnumAttributeKindForName("readonly", 8);
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (!startsWith(LLVMGetValueName(f), "air.atomic.local.cmpxchg.") || LLVMIsDeclaration(f) || LLVMCountParams(f) < 3) continue;
        LLVMValueRef expected = LLVMGetParam(f, 1);
        LLVMValueRef cas = nullptr, loaded = nullptr;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb && !cas; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst && !cas; inst = LLVMGetNextInstruction(inst)) {
                if (!LLVMIsACallInst(inst)) continue;
                LLVMValueRef callee = LLVMGetCalledValue(inst);
                if (!callee || !startsWith(LLVMGetValueName(callee), "llvm.nvvm.atomic.cas.") || LLVMGetNumArgOperands(inst) < 3) continue;
                LLVMValueRef cmp = LLVMGetOperand(inst, 1);
                if (LLVMIsALoadInst(cmp) && LLVMGetOperand(cmp, 0) == expected) cas = inst, loaded = cmp;
            }
        if (!cas) continue;
        // the conditional branch on (cas == loaded); its false successor is where the exchange failed
        LLVMBasicBlockRef failure = nullptr;
        for (LLVMUseRef u = LLVMGetFirstUse(cas); u && !failure; u = LLVMGetNextUse(u)) {
            LLVMValueRef icmp = LLVMIsAICmpInst(LLVMGetUser(u));
            if (!icmp || (LLVMGetOperand(icmp, 0) != loaded && LLVMGetOperand(icmp, 1) != loaded)) continue;
            for (LLVMUseRef v = LLVMGetFirstUse(icmp); v && !failure; v = LLVMGetNextUse(v)) {
                LLVMValueRef br = LLVMGetUser(v);
                if (LLVMGetInstructionOpcode(br) == kOpBr && LLVMGetNumOperands(br) == 3) failure = LLVMGetSuccessor(br, 1);
            }
        }
        if (!failure) continue;
        LLVMValueRef first = LLVMGetFirstInstruction(failure);
        if (first && LLVMGetInstructionOpcode(first) == kOpStore && LLVMGetOperand(first, 0) == cas && LLVMGetOperand(first, 1) == expected)
            continue;  // given the store in an earlier run
        if (!b) b = LLVMCreateBuilderInContext(g.context);
        LLVMPositionBuilderBefore(b, first);
        LLVMBuildStore(b, cas, expected);
        LLVMRemoveEnumAttributeAtIndex(f, 2, readOnly);  // parameter 1
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- signed integers to bool ------------------------------------------------------------------------------------------
// bool2(int2) and the other vectors of signed integers gave false for INT_MIN on Kepler (GTX 770; WebGPU CTS unary
// bool_conversion:i32, vec2-vec4; scalars and unsigned vectors are right). The plugin's library body for
// air.convert.u.v<n>i1.s.v<n>i<w> tests each lane as (x & (2^(w-1) - 1)) != 0, which is how a float lane is tested (so that
// -0.0 is false), not an integer one. Each such and in those bodies is replaced by the value it masks: x != 0.
// NVAIR_SIGNED_BOOL_FIX=0 turns it off.
static unsigned fixSignedBoolConversions(LLVMModuleRef module, Gen &g) {
    (void)g;
    unsigned fixed = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (!startsWith(name, "air.convert.u.") || !strstr(name, "i1.s.") || LLVMIsDeclaration(f)) continue;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (LLVMGetInstructionOpcode(inst) != 23 /* LLVMAnd */ || !LLVMGetFirstUse(inst)) continue;
                LLVMValueRef x = LLVMGetOperand(inst, 0), mask = LLVMGetOperand(inst, 1);
                LLVMTypeRef t = LLVMTypeOf(inst);
                if (LLVMGetTypeKind(t) != LLVMIntegerTypeKind || !LLVMIsAConstantInt(mask)) continue;
                unsigned width = LLVMGetIntTypeWidth(t);
                if (width < 2 || width > 64 || LLVMConstIntGetZExtValue(mask) != (width == 64 ? 0x7fffffffffffffffull : (1ull << (width - 1)) - 1)) continue;
                LLVMReplaceAllUsesWith(inst, x);
                fixed++;
            }
    }
    return fixed;
}

// ---- gradient samples of 3D textures and cubes --------------------------------------------------------------------------
// A sample of a 3D texture, cube or cube array with explicit gradients (gradient3d, gradientcube) in a compute kernel
// broke the kernel on Kepler: its stores after the sample never happened (GTX 770; 2D and 2D-array gradients are right,
// and so are all of them in fragment functions; a09's gradient read, i08's 3D integer one). The plugin lowers them to
// llvm.nvvm.sample.tex.{3d,3d.offset,cube,cube.array}.grad; each becomes the .lod form with the level the texture
// unit would pick (Vulkan's and OpenGL's formula, without anisotropy): 3D, lod = log2 of the longer of the two gradients
// scaled by the size of level 0; cubes, the same on the derivatives of the face coordinates of the major axis,
// (db * ma - b * dma) / (2 * ma^2) for the other two axes b, scaled by the face size. Sizes from llvm.nvvm.txq.*.
// Compute modules only (!air.kernel): fragment functions keep the hardware's own level, with anisotropy.
// NVAIR_GRADIENT_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMBuildFMul(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildFAdd(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildFSub(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildFDiv(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildFNeg(LLVMBuilderRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildFCmp(LLVMBuilderRef, int, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildPointerCast(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMConstReal(LLVMTypeRef, double);
LLVMTypeRef LLVMFloatTypeInContext(LLVMContextRef);
}
enum { LLVMRealOGE = 3, LLVMRealOLT = 4 };

struct FloatGen {
    Gen &g;
    LLVMBuilderRef b;
    LLVMTypeRef f32;
    LLVMValueRef c(double v) { return LLVMConstReal(f32, v); }
    LLVMValueRef call1(const char *name, LLVMValueRef x) {
        LLVMTypeRef p[1] = {f32};
        LLVMValueRef args[1] = {x};
        return LLVMBuildCall(b, g.intrinsic(name, f32, p, 1), args, 1, "");
    }
    LLVMValueRef max(LLVMValueRef x, LLVMValueRef y) {
        LLVMTypeRef p[2] = {f32, f32};
        LLVMValueRef args[2] = {x, y};
        return LLVMBuildCall(b, g.intrinsic("llvm.nvvm.fmax.f", f32, p, 2), args, 2, "");
    }
    LLVMValueRef abs(LLVMValueRef x) { return call1("llvm.nvvm.fabs.f", x); }
    LLVMValueRef mul(LLVMValueRef x, LLVMValueRef y) { return LLVMBuildFMul(b, x, y, ""); }
    LLVMValueRef add(LLVMValueRef x, LLVMValueRef y) { return LLVMBuildFAdd(b, x, y, ""); }
    LLVMValueRef sub(LLVMValueRef x, LLVMValueRef y) { return LLVMBuildFSub(b, x, y, ""); }
    LLVMValueRef sq(LLVMValueRef x) { return mul(x, x); }
    LLVMValueRef lane(LLVMValueRef v, unsigned i) { return LLVMBuildExtractElement(b, v, g.c32(i), ""); }
    LLVMValueRef sel(LLVMValueRef c, LLVMValueRef x, LLVMValueRef y) { return LLVMBuildSelect(b, c, x, y, ""); }
    // log2 of the length whose square is m (m kept above 0, so zero gradients give a very negative level: level 0)
    LLVMValueRef lodOfSquare(LLVMValueRef m) { return mul(c(0.5), call1("llvm.nvvm.lg2.approx.f32", max(m, c(1e-30)))); }
};

// llvm.nvvm.txq.width/height/depth.<kind>.lod.p1i8(texture, 0) as a float
static LLVMValueRef textureSize(FloatGen &fg, const char *what, const char *kind, LLVMValueRef texture) {
    char name[96];
    snprintf(name, sizeof name, "llvm.nvvm.txq.%s.%s.lod.p1i8", what, kind);
    LLVMValueRef f = LLVMGetNamedFunction(fg.g.module, name);
    if (!f) {
        LLVMTypeRef p[2] = {LLVMTypeOf(texture), fg.g.i32};
        f = LLVMAddFunction(fg.g.module, name, LLVMFunctionType(fg.g.i32, p, 2, 0));
    }
    LLVMTypeRef params[2];
    LLVMGetParamTypes(LLVMGetElementType(LLVMTypeOf(f)), params);
    LLVMValueRef args[2] = {LLVMBuildPointerCast(fg.b, texture, params[0], ""), fg.g.c32(0)};
    LLVMValueRef size = LLVMBuildCall(fg.b, f, args, 2, "");
    LLVMTypeRef p1[1] = {fg.g.i32};
    LLVMValueRef cvtArgs[1] = {size};
    return LLVMBuildCall(fg.b, fg.g.intrinsic("llvm.nvvm.cvt.f.f32.u.i32.rte", fg.f32, p1, 1), cvtArgs, 1, "");
}

// The level for gradients dx, dy at coordinate p of a cube face size w: on the major axis' face coordinates.
static LLVMValueRef cubeLod(FloatGen &fg, LLVMValueRef p, LLVMValueRef dx, LLVMValueRef dy, LLVMValueRef w) {
    LLVMValueRef x = fg.lane(p, 0), y = fg.lane(p, 1), z = fg.lane(p, 2);
    LLVMValueRef ax = fg.abs(x), ay = fg.abs(y), az = fg.abs(z);
    LLVMBuilderRef b = fg.b;
    LLVMValueRef isX = LLVMBuildAnd(b, LLVMBuildFCmp(b, LLVMRealOGE, ax, ay, ""), LLVMBuildFCmp(b, LLVMRealOGE, ax, az, ""), "");
    LLVMValueRef isY = LLVMBuildAnd(b, LLVMBuildNot(b, isX, ""), LLVMBuildFCmp(b, LLVMRealOGE, ay, az, ""), "");
    // major axis a, others u and v: X -> (y, z), Y -> (x, z), Z -> (x, y)
    auto pick = [&](LLVMValueRef vx, LLVMValueRef vy, LLVMValueRef vz) { return fg.sel(isX, vx, fg.sel(isY, vy, vz)); };
    LLVMValueRef pa = pick(x, y, z), pu = pick(y, x, x), pv = pick(z, z, y), ma = fg.abs(pa);
    LLVMValueRef negative = LLVMBuildFCmp(b, LLVMRealOLT, pa, fg.c(0), "");
    auto spread = [&](LLVMValueRef d) {  // (du * ma - u * dma)^2 + (dv * ma - v * dma)^2
        LLVMValueRef dx_ = fg.lane(d, 0), dy_ = fg.lane(d, 1), dz_ = fg.lane(d, 2);
        LLVMValueRef da = pick(dx_, dy_, dz_), du = pick(dy_, dx_, dx_), dv = pick(dz_, dz_, dy_);
        LLVMValueRef dma = fg.sel(negative, LLVMBuildFNeg(b, da, ""), da);
        return fg.add(fg.sq(fg.sub(fg.mul(du, ma), fg.mul(pu, dma))), fg.sq(fg.sub(fg.mul(dv, ma), fg.mul(pv, dma))));
    };
    LLVMValueRef ma2 = fg.sq(ma), scale = fg.mul(fg.c(0.25), fg.sq(w));
    LLVMValueRef m = LLVMBuildFDiv(b, fg.mul(scale, fg.max(spread(dx), spread(dy))), fg.max(fg.sq(ma2), fg.c(1e-30)), "");
    return fg.lodOfSquare(m);
}

static unsigned fixGradientSamples(LLVMModuleRef module, Gen &g) {
    static const struct { const char *kind; const char *size; bool cube; } kKinds[] = {
        {"3d.grad.", "3d", false}, {"3d.offset.grad.", "3d", false}, {"cube.grad.", "cube", true}, {"cube.array.grad.", "cube.array", true},
    };
    static const char kPrefix[] = "llvm.nvvm.sample.tex.";
    if (!LLVMGetNamedMetadataNumOperands(module, "air.kernel")) return 0;  // fragment and vertex functions are right
    std::vector<LLVMValueRef> functions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        if (!strncmp(LLVMGetValueName(f), kPrefix, sizeof kPrefix - 1) && strstr(LLVMGetValueName(f), ".grad.") && LLVMGetFirstUse(f))
            functions.push_back(f);
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (LLVMValueRef f : functions) {
        const char *rest = LLVMGetValueName(f) + sizeof kPrefix - 1;
        int k = -1;
        for (unsigned i = 0; i < sizeof kKinds / sizeof *kKinds && k < 0; i++)
            if (!strncmp(rest, kKinds[i].kind, strlen(kKinds[i].kind))) k = (int)i;
        if (k < 0) continue;
        // the .lod form: the same parameters with the two gradients replaced by one float level
        std::string name = LLVMGetValueName(f);
        name.replace(name.find(".grad."), 6, ".lod.");
        LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(f));
        unsigned count = LLVMCountParamTypes(type);
        if (count < 5 || count > 8) continue;
        LLVMTypeRef params[8];
        LLVMGetParamTypes(type, params);
        LLVMTypeRef f32 = LLVMFloatTypeInContext(g.context);
        auto floatVector = [&](LLVMTypeRef t) {  // the coordinate and the gradients: float vectors of 3 or more lanes
            return LLVMGetTypeKind(t) == LLVMVectorTypeKind && LLVMGetElementType(t) == f32 && LLVMGetVectorSize(t) >= 3;
        };
        if (!floatVector(params[2]) || !floatVector(params[count - 2]) || !floatVector(params[count - 1])) continue;
        params[count - 2] = f32;
        LLVMValueRef lodForm = LLVMGetNamedFunction(module, name.c_str());
        LLVMTypeRef lodType = LLVMFunctionType(LLVMGetReturnType(type), params, count - 1, 0);
        if (!lodForm) lodForm = LLVMAddFunction(module, name.c_str(), lodType);
        else if (LLVMGetElementType(LLVMTypeOf(lodForm)) != lodType) continue;
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u))
            if (LLVMValueRef call = LLVMIsACallInst(LLVMGetUser(u)))
                if (LLVMGetNumOperands(call) == (int)count + 1 && LLVMGetOperand(call, count) == f) calls.push_back(call);
        if (!b) b = LLVMCreateBuilderInContext(g.context);
        for (LLVMValueRef call : calls) {
            LLVMPositionBuilderBefore(b, call);
            FloatGen fg{g, b, f32};
            LLVMValueRef texture = LLVMGetOperand(call, 0), p = LLVMGetOperand(call, 2);
            LLVMValueRef dx = LLVMGetOperand(call, count - 2), dy = LLVMGetOperand(call, count - 1), lod;
            LLVMValueRef w = textureSize(fg, "width", kKinds[k].size, texture);
            if (kKinds[k].cube) {
                lod = cubeLod(fg, p, dx, dy, w);
            } else {
                LLVMValueRef h = textureSize(fg, "height", "3d", texture), d = textureSize(fg, "depth", "3d", texture);
                auto spread = [&](LLVMValueRef v) {
                    return fg.add(fg.add(fg.sq(fg.mul(fg.lane(v, 0), w)), fg.sq(fg.mul(fg.lane(v, 1), h))), fg.sq(fg.mul(fg.lane(v, 2), d)));
                };
                lod = fg.lodOfSquare(fg.max(spread(dx), spread(dy)));
            }
            LLVMValueRef args[8];
            for (unsigned i = 0; i < count - 2; i++) args[i] = LLVMGetOperand(call, i);
            args[count - 2] = lod;
            LLVMValueRef sample = LLVMBuildCall(b, lodForm, args, count - 1, "");
            LLVMReplaceAllUsesWith(call, sample);
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- depth comparisons at a level other than a constant 0 -----------------------------------------------------------------
// On Kepler a depth comparison (sample_compare) with an explicit level or a bias that isn't a constant 0 returns the
// texel's depth instead of the comparison: level(1.0), level(0.4), level(-1.0) and bias(5.0) all did, on a one-level
// texture too, while the implicit level, level(0.0) and bias(0.0) compare (GTX 770, fragment function; i03, ANGLE's
// texture(sampler2DShadow, coord, bias)). Gradient comparisons have no body at all. There is no form that compares at a
// level above 0, so: a .lod comparison is done at level 0 (exact for shadow maps with one level, which every level
// clamps to; a mipmapped one compares at level 0), and in fragment functions a .bias one at the implicit level, as
// IntelAdapter does for Intel's compiler. NVAIR_COMPARE_LEVEL_FIX=0 turns it off.
static unsigned fixDepthCompareLevels(LLVMModuleRef module, Gen &g) {
    static const char kPrefix[] = "llvm.nvvm.sample.compare.tex.";
    bool compute = LLVMGetNamedMetadataNumOperands(module, "air.kernel") != 0;
    std::vector<LLVMValueRef> functions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (!strncmp(name, kPrefix, sizeof kPrefix - 1) && (strstr(name, ".lod.") || (!compute && strstr(name, ".bias."))) && LLVMGetFirstUse(f))
            functions.push_back(f);
    }
    LLVMTypeRef f32 = LLVMFloatTypeInContext(g.context);
    LLVMValueRef zero = LLVMConstReal(f32, 0.0);
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (LLVMValueRef f : functions) {
        LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(f));
        unsigned count = LLVMCountParamTypes(type);
        if (count < 5 || count > 8) continue;
        LLVMTypeRef params[8];
        LLVMGetParamTypes(type, params);
        if (params[count - 1] != f32) continue;
        bool bias = strstr(LLVMGetValueName(f), ".bias.") != nullptr;
        LLVMValueRef implicit = nullptr;
        if (bias) {  // the same name without .bias, and without its last parameter
            std::string name = LLVMGetValueName(f);
            name.replace(name.find(".bias."), 6, ".");
            LLVMTypeRef implicitType = LLVMFunctionType(LLVMGetReturnType(type), params, count - 1, 0);
            implicit = LLVMGetNamedFunction(module, name.c_str());
            if (!implicit) implicit = LLVMAddFunction(module, name.c_str(), implicitType);
            else if (LLVMGetElementType(LLVMTypeOf(implicit)) != implicitType) continue;
        }
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u))
            if (LLVMValueRef call = LLVMIsACallInst(LLVMGetUser(u)))
                if (LLVMGetNumOperands(call) == (int)count + 1 && LLVMGetOperand(call, count) == f) calls.push_back(call);
        for (LLVMValueRef call : calls) {
            LLVMValueRef level = LLVMGetOperand(call, count - 1);
            if (level == zero) continue;  // compares already
            if (!bias) {
                LLVMSetOperand(call, count - 1, zero);
            } else {
                if (!b) b = LLVMCreateBuilderInContext(g.context);
                LLVMPositionBuilderBefore(b, call);
                LLVMValueRef args[8];
                for (unsigned i = 0; i < count - 1; i++) args[i] = LLVMGetOperand(call, i);
                LLVMValueRef sample = LLVMBuildCall(b, implicit, args, count - 1, "");
                LLVMReplaceAllUsesWith(call, sample);
                LLVMInstructionEraseFromParent(call);
            }
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- depth comparisons with gradients (no body in the plugin) ---------------------------------------------------------
// The plugin's library has sample_compare on 2D, 2D-array, cube and cube-array depth textures at a level or with a bias,
// and no gradient form: a comparison with gradient2d(...) or gradientcube(...) stayed a bare declaration, which
// instruction selection fails on ("Unhandled constant"). Kepler compares only at level 0 anyway (see the next fix), so
// such a comparison is made at level 0 through the intrinsic the library's own level form calls
// (llvm.nvvm.sample.compare.tex.<shape>[.offset].lod): exact for shadow maps of one level, level 0 of a mipmapped one.
// A 2D comparison with a texel offset keeps it when the offset is a constant (the hardware takes it as an immediate);
// one with a computed offset is left as it is. The newer front ends' { float, i8 } result gets the comparison in the
// float. NVAIR_COMPARE_GRADIENT_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMBuildInsertValue(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, unsigned, const char *);
LLVMTypeRef LLVMVectorType(LLVMTypeRef, unsigned);
LLVMTypeRef LLVMPointerType(LLVMTypeRef, unsigned);
LLVMValueRef LLVMGetCalledValue(LLVMValueRef);
LLVMValueRef LLVMBuildBitCast(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMConstNull(LLVMTypeRef);
LLVMTypeRef LLVMStructGetTypeAtIndex(LLVMTypeRef, unsigned);
unsigned LLVMCountStructElementTypes(LLVMTypeRef);
LLVMValueRef LLVMIsAConstantAggregateZero(LLVMValueRef);
LLVMValueRef LLVMIsAConstantDataVector(LLVMValueRef);
LLVMValueRef LLVMIsAConstantVector(LLVMValueRef);
}
static unsigned fixGradientCompares(LLVMModuleRef module, Gen &g) {
    enum { kStructKind = 10, kPointerKind = 12 };
    LLVMTypeRef f32 = LLVMFloatTypeInContext(g.context), v2 = LLVMVectorType(f32, 2), v3 = LLVMVectorType(f32, 3), v4 = LLVMVectorType(f32, 4);
    LLVMTypeRef v2i = LLVMVectorType(g.i32, 2), i8 = LLVMInt8TypeInContext(g.context);
    // (texture, sampler, i32, coord, [i32 layer,] float reference, dPdx, dPdy, [float min LOD clamp,] [i1 offset?, int2 offset,] i32):
    // the 3802 runtime compiler's forms have no clamp, the newer front ends' have
    static const struct { const char *air, *shape; bool cube, array; } kForms[] = {
        {"air.sample_compare_depth_2d_grad.f32", "2d", false, false},
        {"air.sample_compare_depth_2d_array_grad.f32", "2d.array", false, true},
        {"air.sample_compare_depth_cube_grad.f32", "cube", true, false},
        {"air.sample_compare_depth_cube_array_grad.f32", "cube.array", true, true},
    };
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (const auto &form : kForms) {
        LLVMValueRef f = LLVMGetNamedFunction(module, form.air);
        if (!f || !LLVMIsDeclaration(f) || !LLVMGetFirstUse(f)) continue;
        LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(f));
        unsigned count = LLVMCountParamTypes(type), c = 3, r = form.array ? 5 : 4, dx = r + 1, after = r + 3;
        LLVMTypeRef params[12];
        if (count > 12 || count < after + 1) continue;
        LLVMGetParamTypes(type, params);
        LLVMTypeRef coordType = form.cube ? v3 : v2;
        if (LLVMGetTypeKind(params[0]) != kPointerKind || LLVMGetTypeKind(params[1]) != kPointerKind || params[c] != coordType ||
            params[r] != f32 || params[dx] != coordType || params[dx + 1] != coordType || (form.array && !isInt(params[4], 32)))
            continue;
        unsigned next = after + (params[after] == f32 ? 1 : 0);  // past the clamp, if any
        int hasOffset = -1;
        if (!form.cube) {  // i1 has-offset, int2 offset, i32
            if (count != next + 3 || !isInt(params[next], 1) || params[next + 1] != v2i || !isInt(params[next + 2], 32)) continue;
            hasOffset = (int)next;
        } else if (count != next + 1 || !isInt(params[next], 32)) {
            continue;
        }
        LLVMTypeRef result = LLVMGetReturnType(type);
        bool pair = LLVMGetTypeKind(result) == kStructKind;
        if (!pair && result != f32) continue;
        if (pair && (LLVMCountStructElementTypes(result) < 1 || LLVMStructGetTypeAtIndex(result, 0) != f32)) continue;
        unsigned samplerSpace = LLVMGetPointerAddressSpace(params[1]);
        LLVMTypeRef texturePointer = LLVMPointerType(i8, 1), samplerPointer = LLVMPointerType(i8, samplerSpace);
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u))
            if (LLVMValueRef call = LLVMIsACallInst(LLVMGetUser(u)))
                if (LLVMGetCalledValue(call) == f) calls.push_back(call);
        for (LLVMValueRef call : calls) {
            bool offset = false;
            if (hasOffset >= 0) {
                LLVMValueRef flag = LLVMGetOperand(call, hasOffset), value = LLVMGetOperand(call, hasOffset + 1);
                if (!LLVMIsAConstantInt(flag)) continue;  // computed: left as it is
                offset = LLVMConstIntGetZExtValue(flag) && !LLVMIsAConstantAggregateZero(value);
                if (offset && !LLVMIsAConstantDataVector(value) && !LLVMIsAConstantVector(value)) continue;
            }
            char name[112];
            snprintf(name, sizeof name, "llvm.nvvm.sample.compare.tex.%s%s.lod.v4f32.p1i8.p%ui8", form.shape, offset ? ".offset" : "", samplerSpace);
            LLVMTypeRef lodParams[7];
            unsigned n = 0;
            lodParams[n++] = texturePointer, lodParams[n++] = samplerPointer, lodParams[n++] = form.cube ? v4 : v2;
            if (form.array) lodParams[n++] = g.i32;
            lodParams[n++] = f32;
            if (offset) lodParams[n++] = v2i;
            lodParams[n++] = f32;
            LLVMValueRef lod = g.intrinsic(name, v4, lodParams, n);
            if (!b) b = LLVMCreateBuilderInContext(g.context);
            LLVMPositionBuilderBefore(b, call);
            LLVMValueRef coord = LLVMGetOperand(call, c);
            if (form.cube) {
                LLVMValueRef packed = LLVMConstNull(v4);
                for (unsigned k = 0; k < 3; k++)
                    packed = LLVMBuildInsertElement(b, packed, LLVMBuildExtractElement(b, coord, g.c32(k), ""), g.c32(k), "");
                coord = packed;
            }
            LLVMValueRef args[7];
            unsigned a = 0;
            args[a++] = LLVMBuildBitCast(b, LLVMGetOperand(call, 0), texturePointer, "");
            args[a++] = LLVMBuildBitCast(b, LLVMGetOperand(call, 1), samplerPointer, "");
            args[a++] = coord;
            if (form.array) args[a++] = LLVMGetOperand(call, 4);
            args[a++] = LLVMGetOperand(call, r);
            if (offset) args[a++] = LLVMGetOperand(call, hasOffset + 1);
            args[a++] = LLVMConstReal(f32, 0.0);
            LLVMValueRef value = LLVMBuildExtractElement(b, LLVMBuildCall(b, lod, args, a, ""), g.c32(0), "");
            if (pair) {
                LLVMValueRef whole = LLVMBuildInsertValue(b, LLVMGetUndef(result), value, 0, "");
                if (LLVMCountStructElementTypes(result) > 1 && isInt(LLVMStructGetTypeAtIndex(result, 1), 8))
                    whole = LLVMBuildInsertValue(b, whole, LLVMConstInt(LLVMStructGetTypeAtIndex(result, 1), 1, 0), 1, "");  // resident
                value = whole;
            }
            LLVMReplaceAllUsesWith(call, value);
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- clz and ctz of a constant 0 ----------------------------------------------------------------------------------------
// The plugin's built-in library writes air.clz.i32 as llvm.ctlz.i32(x, true): "the result for 0 is undefined". At run
// time the GPU gives 32 for 0 anyway, but where the optimizer sees a constant 0 it folds the count to undef, and Metal's
// clz(0) is the width: madhi(v, clz(0u), 0) came out as garbage on Kepler (fuzz seed 758, plain kernels). Every
// llvm.ctlz / llvm.cttz call asks for the defined result instead (false), which the hardware gives at no cost.
// NVAIR_COUNT_ZERO_FIX=0 turns it off.
static unsigned defineCountOfZero(LLVMModuleRef module, Gen &g) {
    unsigned fixed = 0;
    LLVMValueRef yes = LLVMConstInt(g.i1, 1, 0), no = LLVMConstInt(g.i1, 0, 0);
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (strncmp(name, "llvm.ctlz.", 10) && strncmp(name, "llvm.cttz.", 10)) continue;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) {
            LLVMValueRef call = LLVMIsACallInst(LLVMGetUser(u));
            if (!call || LLVMGetNumOperands(call) != 3 || LLVMGetOperand(call, 2) != f || LLVMGetOperand(call, 1) != yes) continue;
            LLVMSetOperand(call, 1, no);
            fixed++;
        }
    }
    return fixed;
}

// ---- private arrays of bytes and halfwords done on 32-bit words (IntelAdapter's widenNarrowPrivateArrays) ---------------
// A private uchar / ushort array (uchar pc[8]) is stored with truncating stores and read with extending loads, and Kepler's
// back end forwarded a stored 32-bit value to such a load without masking it: pc[i] kept the bits above its byte where a
// 64-bit product and compare used it (mslfuzz2 LONG=1 seeds 575 and 770, reduced: with a uint array, or the byte from a
// register, right). The same bug as Intel's i47. An array of 8- or 16-bit integers that only GEPs into its elements reach,
// with only loads and stores of the element type behind them, becomes an array of i32: stores zero-extend, loads
// truncate. NVAIR_NARROW_PRIVATE_ARRAY_FIX=0 turns it off.
// Known limit: with the word array, a store and a later load at a variable index inside a loop, with enough other code
// around them, can give the load the slot's old value (mslfuzz2 VEC=1 seeds 1413 and 1523; right with the byte array or
// with a statement or two less). Not fixable from here, as far as tried: reaching every element at a constant index
// (selects or masks) lets the array become registers, where LLVM narrows it to bytes again and the stale upper bits
// come back (seed 126, and 575's kind); volatile word accesses don't help either. The widening alone has fewer wrong
// kernels (VEC 1-2000: these two) than any of those.
extern "C" {
LLVMValueRef LLVMIsAAllocaInst(LLVMValueRef);
LLVMTypeRef LLVMGetAllocatedType(LLVMValueRef);
LLVMValueRef LLVMIsAGetElementPtrInst(LLVMValueRef);
LLVMValueRef LLVMBuildAlloca(LLVMBuilderRef, LLVMTypeRef, const char *);
LLVMTypeRef LLVMArrayType(LLVMTypeRef, unsigned);
LLVMValueRef LLVMBuildGEP(LLVMBuilderRef, LLVMValueRef, LLVMValueRef *, unsigned, const char *);
}

static unsigned widenNarrowPrivateArrays(LLVMModuleRef module, Gen &g) {
    enum { kArrayKind = 11 };
    std::vector<LLVMValueRef> allocas;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMIsAAllocaInst(inst)) allocas.push_back(inst);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef alloca : allocas) {
        LLVMTypeRef array = LLVMGetAllocatedType(alloca);
        if (LLVMGetTypeKind(array) != kArrayKind) continue;
        LLVMTypeRef element = LLVMGetElementType(array);
        if (LLVMGetTypeKind(element) != LLVMIntegerTypeKind) continue;
        unsigned width = LLVMGetIntTypeWidth(element), length = LLVMGetArrayLength(array);
        if ((width != 8 && width != 16) || length < 1 || length > 64) continue;
        // every use: GEP alloca, 0, i (two indices, the first 0) whose users are loads / stores of the element type
        std::vector<LLVMValueRef> geps;
        bool plain = true;
        for (LLVMUseRef u = LLVMGetFirstUse(alloca); u && plain; u = LLVMGetNextUse(u)) {
            LLVMValueRef gep = LLVMGetUser(u);
            if (!LLVMIsAGetElementPtrInst(gep) || LLVMGetOperand(gep, 0) != alloca || LLVMGetNumOperands(gep) != 3 ||
                !LLVMIsAConstantInt(LLVMGetOperand(gep, 1)) || LLVMConstIntGetZExtValue(LLVMGetOperand(gep, 1)) != 0) { plain = false; break; }
            for (LLVMUseRef v = LLVMGetFirstUse(gep); v && plain; v = LLVMGetNextUse(v)) {
                LLVMValueRef user = LLVMGetUser(v);
                if (LLVMIsALoadInst(user)) plain = LLVMTypeOf(user) == element;
                else if (LLVMIsAStoreInst(user)) plain = LLVMGetOperand(user, 1) == gep && LLVMTypeOf(LLVMGetOperand(user, 0)) == element;
                else plain = false;
            }
            geps.push_back(gep);
        }
        if (!plain || geps.empty()) continue;
        if (!b) b = LLVMCreateBuilderInContext(g.context);
        LLVMPositionBuilderBefore(b, alloca);
        LLVMValueRef wide = LLVMBuildAlloca(b, LLVMArrayType(g.i32, length), "");
        LLVMSetAlignment(wide, 4);
        for (LLVMValueRef gep : geps) {
            LLVMPositionBuilderBefore(b, gep);
            LLVMValueRef indices[2] = {LLVMGetOperand(gep, 1), LLVMGetOperand(gep, 2)};
            LLVMValueRef slot = LLVMBuildGEP(b, wide, indices, 2, "");
            std::vector<LLVMValueRef> users;
            for (LLVMUseRef v = LLVMGetFirstUse(gep); v; v = LLVMGetNextUse(v)) users.push_back(LLVMGetUser(v));
            for (LLVMValueRef user : users) {
                LLVMPositionBuilderBefore(b, user);
                if (LLVMIsALoadInst(user)) {
                    LLVMValueRef word = LLVMBuildLoad(b, slot, "");
                    LLVMReplaceAllUsesWith(user, LLVMBuildTrunc(b, word, element, ""));
                } else {
                    LLVMBuildStore(b, LLVMBuildZExt(b, LLVMGetOperand(user, 0), g.i32, ""), slot);
                }
                LLVMInstructionEraseFromParent(user);
            }
            LLVMInstructionEraseFromParent(gep);
        }
        LLVMInstructionEraseFromParent(alloca);
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- device loads in fragment functions at a negative 32-bit index ------------------------------------------------------
// Kepler's driver faults on a load outside every buffer, and reports it on a later command buffer as
// kIOAccelCommandBufferCallbackErrorInvalidResource (the app sees that command buffer fail; ANGLE loses the context).
// Fragment functions run helper lanes for the pixels of a 2x2 quad outside the primitive or the scissor rectangle, and
// their loads count: ANGLE's buffer-to-texture shaders (readFromBuffer*TextureFS, how WebGL uploads from a pixel unpack
// buffer that needs converting) compute uint2(position) - textureOffset, which wraps for those lanes, and read
// ~4 GB past the buffer: Chrome's WebGL lost its context in texSubImage2D from a PBO of RGBA4, RGB565, RGB5_A1 and RGB
// data, and after two GPU process crashes turned WebGL off (Khronos WebGL 2.0.1, deqp texsubimage2d_pbo). On a 2 GB
// card no buffer reaches 2^31 bytes, so a 32-bit index with its top bit set can only be outside: in fragment modules,
// such an index (the i32 a device load's GEP widens) reads element 0 instead, as x & ~(x >> 31) (no predicate).
// NVAIR_FRAGMENT_LOAD_GUARD=0 turns it off.
enum { kGuardAnd = 23, kGuardXor = 25, kPointerKind = 12 };  // LLVM-C's LLVMAnd, LLVMXor, LLVMPointerTypeKind
static bool guardedIndex(LLVMValueRef x) {  // x & ~(x >> 31), as this pass writes it
    if (!LLVMIsAInstruction(x) || LLVMGetInstructionOpcode(x) != kGuardAnd) return false;
    LLVMValueRef m = LLVMGetOperand(x, 1);
    return LLVMIsAInstruction(m) && LLVMGetInstructionOpcode(m) == kGuardXor;
}
static unsigned guardFragmentLoads(LLVMModuleRef module, Gen &g) {
    if (!LLVMGetNamedMetadataNumOperands(module, "air.fragment")) return 0;
    std::vector<LLVMValueRef> loads;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMIsALoadInst(inst)) loads.push_back(inst);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef load : loads) {
        LLVMValueRef gep = LLVMGetOperand(load, 0);
        if (!LLVMIsAGetElementPtrInst(gep)) continue;
        LLVMTypeRef pt = LLVMTypeOf(gep);
        if (LLVMGetTypeKind(pt) != kPointerKind || LLVMGetPointerAddressSpace(pt) != 1) continue;  // device memory
        unsigned n = LLVMGetNumOperands(gep);
        LLVMValueRef index = LLVMGetOperand(gep, n - 1);
        if (!LLVMIsAInstruction(index)) continue;
        unsigned op = LLVMGetInstructionOpcode(index);
        if (op != LLVMZExt && op != LLVMSExt) continue;
        LLVMValueRef x = LLVMGetOperand(index, 0);
        if (!isInt(LLVMTypeOf(x), 32) || LLVMIsAConstantInt(x) || guardedIndex(x)) continue;
        if (!b) b = LLVMCreateBuilderInContext(g.context);
        LLVMPositionBuilderBefore(b, index);
        LLVMValueRef keep = LLVMBuildXor(b, LLVMBuildAShr(b, x, g.c32(31), ""), g.c32(~0u), "");
        LLVMSetOperand(index, 0, LLVMBuildAnd(b, x, keep, ""));
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- discard_fragment as demote-to-helper ---------------------------------------------------------------------------
// The plugin's library defines air.discard_fragment as llvm.nvvm.discard_fragment + llvm.nvvm.exit: the lane ends there,
// and every derivative its 2x2 quad takes after that is 0, on all of the quad's lanes (dfdx of a value computed before
// the discard too; before the discard they're right). Metal 2.3 and WGSL make a discarded fragment a helper that runs on
// for its quad's derivatives, and front ends rely on it (Tint emits discard_fragment() and takes dpdx after it): the WebGPU
// CTS statement,discard:derivatives read 0 where it wants +/-3, and an implicit-LOD sample after an alpha-test discard
// picks level 0 in the quads at the cut-out's edge. In a fragment function that calls air.discard_fragment itself, where
// a derivative, texture sample or quad / SIMD operation can run after a discard, each call sets a private flag, the lane
// runs on, and it is discarded where the function returns; its device stores, atomics and texture writes after the
// flag is set are skipped (each through an always-inline nvair.guard: the inliner splits the blocks). A function that only
// reaches discard_fragment through a call keeps it as it was. NVAIR_DEMOTE_DISCARD=0 turns it off.
static bool startsWith(const char *s, const char *prefix) { return !strncmp(s, prefix, strlen(prefix)); }
static LLVMValueRef calledFunction(LLVMValueRef call) {
    LLVMValueRef callee = LLVMGetCalledValue(call);
    return callee && LLVMIsAConstant(callee) && LLVMGetValueName(callee) ? callee : nullptr;
}
static bool needsHelpers(const char *name) {
    return startsWith(name, "air.dfdx") || startsWith(name, "air.dfdy") || startsWith(name, "air.fwidth") ||
           startsWith(name, "air.sample_texture") || startsWith(name, "air.quad_") || startsWith(name, "air.simd_");
}
static bool sideEffect(LLVMValueRef inst) {
    if (LLVMIsAStoreInst(inst)) {
        LLVMTypeRef pt = LLVMTypeOf(LLVMGetOperand(inst, 1));
        return LLVMGetTypeKind(pt) == kPointerKind && LLVMGetPointerAddressSpace(pt) == 1 && !LLVMGetVolatile(inst);
    }
    if (!LLVMIsACallInst(inst)) return false;
    LLVMValueRef f = calledFunction(inst);
    const char *name = f ? LLVMGetValueName(f) : "";
    return (startsWith(name, "air.atomic.") && !strstr(name, "fence")) || startsWith(name, "air.write_texture");
}
// Whether code that needs the quad's other lanes (helpersNeeded) can run after this discard: the rest of its block and every
// block reachable from there.
static bool helpersAfter(LLVMValueRef discardCall) {
    auto needs = [](LLVMValueRef inst) {
        if (!LLVMIsACallInst(inst)) return false;
        LLVMValueRef callee = calledFunction(inst);
        return callee && needsHelpers(LLVMGetValueName(callee));
    };
    for (LLVMValueRef inst = LLVMGetNextInstruction(discardCall); inst; inst = LLVMGetNextInstruction(inst))
        if (needs(inst)) return true;
    std::vector<LLVMBasicBlockRef> work, seen;
    auto push = [&](LLVMBasicBlockRef bb) {
        if (LLVMValueRef term = LLVMGetBasicBlockTerminator(bb))
            for (unsigned i = 0, n = LLVMGetNumSuccessors(term); i < n; i++) {
                LLVMBasicBlockRef next = LLVMGetSuccessor(term, i);
                if (std::find(seen.begin(), seen.end(), next) == seen.end()) seen.push_back(next), work.push_back(next);
            }
    };
    push(LLVMGetInstructionParent(discardCall));
    while (!work.empty()) {
        LLVMBasicBlockRef bb = work.back();
        work.pop_back();
        for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
            if (needs(inst)) return true;
        push(bb);
    }
    return false;
}
// nvair.guard(i1 demoted, operands...): the store or call when demoted is false (undef / nothing otherwise)
static void guardInstruction(Gen &g, LLVMBuilderRef b, LLVMValueRef inst, LLVMValueRef flag) {
    bool store = LLVMIsAStoreInst(inst);
    unsigned n = store ? 2 : LLVMGetNumArgOperands(inst);
    std::vector<LLVMTypeRef> types(1, g.i1);
    std::vector<LLVMValueRef> args;
    LLVMPositionBuilderBefore(b, inst);
    args.push_back(LLVMBuildLoad(b, flag, ""));
    for (unsigned i = 0; i < n; i++) types.push_back(LLVMTypeOf(LLVMGetOperand(inst, i))), args.push_back(LLVMGetOperand(inst, i));
    LLVMTypeRef ret = store ? LLVMVoidTypeInContext(g.context) : LLVMTypeOf(inst);
    LLVMValueRef f = LLVMAddFunction(g.module, "nvair.guard", LLVMFunctionType(ret, types.data(), (unsigned)types.size(), 0));
    markInline(g.context, f);
    LLVMBuilderRef fb = LLVMCreateBuilderInContext(g.context);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(g.context, f, ""), run = LLVMAppendBasicBlockInContext(g.context, f, ""),
                      skip = LLVMAppendBasicBlockInContext(g.context, f, "");
    LLVMPositionBuilderAtEnd(fb, entry);
    LLVMBuildCondBr(fb, LLVMGetParam(f, 0), skip, run);
    LLVMPositionBuilderAtEnd(fb, run);
    bool isVoid = LLVMGetTypeKind(ret) == 0;  // LLVMVoidTypeKind
    if (store) {
        LLVMValueRef st = LLVMBuildStore(fb, LLVMGetParam(f, 1), LLVMGetParam(f, 2));
        if (unsigned align = LLVMGetAlignment(inst)) LLVMSetAlignment(st, align);
        LLVMBuildRetVoid(fb);
    } else {
        std::vector<LLVMValueRef> params;
        for (unsigned i = 0; i < n; i++) params.push_back(LLVMGetParam(f, i + 1));
        LLVMValueRef r = LLVMBuildCall(fb, LLVMGetCalledValue(inst), params.data(), n, "");
        if (isVoid) LLVMBuildRetVoid(fb); else LLVMBuildRet(fb, r);
    }
    LLVMPositionBuilderAtEnd(fb, skip);
    if (isVoid) LLVMBuildRetVoid(fb); else LLVMBuildRet(fb, LLVMGetUndef(ret));
    LLVMDisposeBuilder(fb);
    LLVMValueRef call = LLVMBuildCall(b, f, args.data(), (unsigned)args.size(), "");
    if (!isVoid) LLVMReplaceAllUsesWith(inst, call);
    LLVMInstructionEraseFromParent(inst);
}
static unsigned demoteDiscards(LLVMModuleRef module, Gen &g) {
    LLVMValueRef discard = LLVMGetNamedFunction(module, "air.discard_fragment");
    if (!discard || !LLVMGetNamedMetadataNumOperands(module, "air.fragment")) return 0;
    unsigned demoted = 0;
    LLVMValueRef exitHelper = nullptr;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *fname = LLVMGetValueName(f);
        if (LLVMIsDeclaration(f) || startsWith(fname, "air.") || startsWith(fname, "nvair.")) continue;
        std::vector<LLVMValueRef> discards, effects, returns;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (LLVMIsAReturnInst(inst)) returns.push_back(inst);
                else if (sideEffect(inst)) effects.push_back(inst);
                else if (LLVMIsACallInst(inst)) {
                    LLVMValueRef callee = calledFunction(inst);
                    if (callee == discard) discards.push_back(inst);
                }
            }
        if (discards.empty() || returns.empty()) continue;
        bool helpers = false, killing = false;  // killing: a front end that ends the lane itself (unreachable after the call)
        for (LLVMValueRef d : discards) {
            LLVMValueRef next = LLVMGetNextInstruction(d);
            killing |= next && LLVMIsAUnreachableInst(next);
            helpers = helpers || helpersAfter(d);
        }
        if (!helpers || killing) continue;
        if (!exitHelper) {  // nvair.demote_exit(i1 demoted): discard_fragment (the lane ends) when demoted
            LLVMTypeRef params[1] = {g.i1};
            exitHelper = LLVMAddFunction(module, "nvair.demote_exit", LLVMFunctionType(LLVMVoidTypeInContext(g.context), params, 1, 0));
            markInline(g.context, exitHelper);
            LLVMBuilderRef fb = LLVMCreateBuilderInContext(g.context);
            LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(g.context, exitHelper, ""),
                              kill = LLVMAppendBasicBlockInContext(g.context, exitHelper, ""),
                              done = LLVMAppendBasicBlockInContext(g.context, exitHelper, "");
            LLVMPositionBuilderAtEnd(fb, entry);
            LLVMBuildCondBr(fb, LLVMGetParam(exitHelper, 0), kill, done);
            LLVMPositionBuilderAtEnd(fb, kill);
            LLVMBuildCall(fb, discard, nullptr, 0, "");
            LLVMBuildUnreachable(fb);
            LLVMPositionBuilderAtEnd(fb, done);
            LLVMBuildRetVoid(fb);
            LLVMDisposeBuilder(fb);
        }
        LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
        LLVMPositionBuilderBefore(b, LLVMGetFirstInstruction(LLVMGetEntryBasicBlock(f)));
        LLVMValueRef flag = LLVMBuildAlloca(b, g.i1, "nvair.demoted");
        LLVMBuildStore(b, LLVMConstInt(g.i1, 0, 0), flag);
        for (LLVMValueRef d : discards) {
            LLVMPositionBuilderBefore(b, d);
            LLVMBuildStore(b, LLVMConstInt(g.i1, 1, 0), flag);
            LLVMInstructionEraseFromParent(d);
        }
        for (LLVMValueRef e : effects) guardInstruction(g, b, e, flag);
        for (LLVMValueRef r : returns) {
            LLVMPositionBuilderBefore(b, r);
            LLVMValueRef args[1] = {LLVMBuildLoad(b, flag, "")};
            LLVMBuildCall(b, exitHelper, args, 1, "");
        }
        LLVMDisposeBuilder(b);
        demoted += (unsigned)discards.size();
        if (logging()) fprintf(stderr, "[nvair] %s: %zu discard(s) demoted to helpers, %zu side effect(s) guarded\n", fname, discards.size(), effects.size());
    }
    return demoted;
}

// ---- 32-bit products of 16-bit factors -----------------------------------------------------------------------------------
// When both factors of a 32-bit multiply are known to fit in 16 bits (zero-extended bytes / halfwords, masked with
// 0xffff or less, or such values or'ed together), Kepler's compiler took the product's top bit for clear, though 0xffff * 0xffff = 0xfffe0001: with it,
// -(int)(~(ushort(a) * ushort(b)) & 0x7fffffff), which is (product | 0x80000000) + 1, came out as product + 0x80000001,
// wrong by 2^31 for about half of all inputs (mslfuzz2 FRAG=1 seed 111, reduced; in kernels too; a full 32-bit product
// is right). One factor goes through llvm.nvvm.min.u.i32(x, ~0u), the value unchanged but its range hidden from the
// optimizer. The same wrong knowledge of a product made x % (((b | 1) * c) | 1) off by one in 17% of cases (the or taken
// for an add: mslfuzz GEN=mslfuzz.py seed 645, reduced; a divisor that isn't a product is right): an or that uses a
// 32-bit product gets it through the same opaque min. NVAIR_NARROW_MULTIPLY_FIX=0 turns both off.
enum { LLVMMul = 12, LLVMAnd = 23, LLVMOr = 24, LLVMXor = 25, LLVMSelect = 46 };
// Known to fit in 16 bits: a constant up to 0xffff, a zero-extended byte or halfword, an and with such a value, an or / xor
// / select of two such values, a shift right by 16 or more (what LLVM leaves of ushort casts, masks and | 0x8000).
static bool narrowFactor(LLVMValueRef v, int depth = 0) {
    if (LLVMIsAConstantInt(v)) return LLVMConstIntGetZExtValue(v) <= 0xffffu;
    if (depth > 4 || !LLVMIsAInstruction(v)) return false;
    switch (LLVMGetInstructionOpcode(v)) {
        case LLVMZExt: {
            LLVMTypeRef from = LLVMTypeOf(LLVMGetOperand(v, 0));
            return LLVMGetTypeKind(from) == LLVMIntegerTypeKind && LLVMGetIntTypeWidth(from) <= 16;
        }
        case LLVMAnd: return narrowFactor(LLVMGetOperand(v, 0), depth + 1) || narrowFactor(LLVMGetOperand(v, 1), depth + 1);
        case LLVMOr: case LLVMXor: return narrowFactor(LLVMGetOperand(v, 0), depth + 1) && narrowFactor(LLVMGetOperand(v, 1), depth + 1);
        case LLVMSelect: return narrowFactor(LLVMGetOperand(v, 1), depth + 1) && narrowFactor(LLVMGetOperand(v, 2), depth + 1);
        case LLVMLShr: {
            LLVMValueRef amount = LLVMGetOperand(v, 1);
            return isInt(LLVMTypeOf(v), 32) && LLVMIsAConstantInt(amount) && LLVMConstIntGetZExtValue(amount) >= 16;
        }
        default: return false;
    }
}
static unsigned hideNarrowProducts(LLVMModuleRef module, Gen &g) {
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    LLVMTypeRef params[2] = {g.i32, g.i32};
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (LLVMIsDeclaration(f) || !strncmp(LLVMGetValueName(f), "nvair.", 6)) continue;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (LLVMGetInstructionOpcode(inst) != LLVMMul || !isInt(LLVMTypeOf(inst), 32)) continue;
                // a product an or uses: the or gets it through the opaque min (its bits can't be taken for disjoint)
                std::vector<LLVMValueRef> ors;
                for (LLVMUseRef u = LLVMGetFirstUse(inst); u; u = LLVMGetNextUse(u)) {
                    LLVMValueRef user = LLVMGetUser(u);
                    if (LLVMIsAInstruction(user) && LLVMGetInstructionOpcode(user) == LLVMOr) ors.push_back(user);
                }
                if (!ors.empty()) {
                    if (!b) b = LLVMCreateBuilderInContext(g.context);
                    LLVMValueRef next = LLVMGetNextInstruction(inst);
                    if (next) LLVMPositionBuilderBefore(b, next);
                    LLVMValueRef args[2] = {inst, g.c32(~0u)};
                    LLVMValueRef hidden = LLVMBuildCall(b, g.intrinsic("llvm.nvvm.min.u.i32", g.i32, params, 2), args, 2, "");
                    for (LLVMValueRef user : ors)
                        for (unsigned i = 0; i < 2; i++)
                            if (LLVMGetOperand(user, i) == inst) LLVMSetOperand(user, i, hidden);
                    fixed++;
                    inst = hidden;  // continue after it
                    continue;
                }
                LLVMValueRef x = LLVMGetOperand(inst, 0), y = LLVMGetOperand(inst, 1);
                if (!narrowFactor(x) || !narrowFactor(y) || LLVMIsAConstantInt(x)) continue;
                if (!b) b = LLVMCreateBuilderInContext(g.context);
                LLVMPositionBuilderBefore(b, inst);
                LLVMValueRef args[2] = {x, g.c32(~0u)};
                LLVMValueRef hidden = LLVMBuildCall(b, g.intrinsic("llvm.nvvm.min.u.i32", g.i32, params, 2), args, 2, "");
                LLVMSetOperand(inst, 0, hidden);
                fixed++;
            }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- texture atomics on linear 2D textures (MetalOldCompat item 58) --------------------------------------------------
// Kepler's back end has no texture (surface) atomics the plugin can emit, and its library has no body for MSL 3.1's
// texture atomics (atomic_fetch_add etc. on a read_write texture2d<uint> or texture2d<int>): the compile crashed the
// compiler service (a01). MetalOldCompat item 58 makes each R32Uint / R32Sint 2D texture created with
// MTLTextureUsageShaderAtomic a linear texture in a buffer of its own, the texels after a 256-byte header {magic, row
// pitch in words, width, height}, and binds that buffer (or a dummy without the magic, for any other texture) at a hidden
// buffer index before each draw or dispatch. Here each texture atomic becomes the plugin's own global atomic on that
// buffer at word 64 + y * pitch + x, or on scratch word 8 of the header when the coordinate is outside the texture or the
// buffer has no header (relaxed order, the only one MSL allows on textures). The hidden indices: each read_write
// texture2d<uint> / texture2d<int> argument (not arrays), in order of [[texture(n)]], gets one, counted down from 30 over
// the buffer indices the function doesn't use (vertex functions keep 0-16 for vertex buffers); item 58 works the same out
// from the pipeline's reflection, which can't see what the plugin adds. The function is rebuilt with a parameter per
// texture its atomics use (__nvta_<n>); the old one stays, empty and renamed. Other texture types (1D, 2D arrays, 3D,
// texture buffers) have no linear form on Kepler and are left as they are. NVAIR_TEXTURE_ATOMICS=0 turns it off.
extern "C" {
LLVMValueRef LLVMBuildBitCast(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMTypeRef LLVMPointerType(LLVMTypeRef, unsigned);
LLVMTypeRef LLVMVectorType(LLVMTypeRef, unsigned);
LLVMValueRef LLVMConstNull(LLVMTypeRef);
LLVMValueRef LLVMMDStringInContext(LLVMContextRef, const char *, unsigned);
LLVMValueRef LLVMMDNodeInContext(LLVMContextRef, LLVMValueRef *, unsigned);
unsigned LLVMCountParams(LLVMValueRef);
void LLVMRemoveBasicBlockFromParent(LLVMBasicBlockRef);
int LLVMIsFunctionVarArg(LLVMTypeRef);
LLVMValueRef LLVMGetCalledValue(LLVMValueRef);
LLVMBasicBlockRef LLVMGetInstructionParent(LLVMValueRef);
LLVMValueRef LLVMGetBasicBlockParent(LLVMBasicBlockRef);
}
extern "C" void functionCopyAttributesFrom(void *function, const void *source) asm("__ZN4llvm8Function18copyAttributesFromEPKNS_11GlobalValueE");
extern "C" void basicBlockInsertInto(void *block, void *function, void *before) asm("__ZN4llvm10BasicBlock10insertIntoEPNS_8FunctionEPS0_");

static const unsigned kTexAtomicMagic = 0x4154564E;  // "NVTA"
enum { kTexAtomicHeaderWords = 64, kTexAtomicScratchWord = 8 };
enum { kTAFetch, kTALoad, kTAStore, kTACompareExchange };
static const struct { const char *air, *u, *s; int kind; } kTexAtomicOps[] = {  // the plugin's llvm.nvvm.atomic.<op>.i32.p1i32
    {"fetch_add", "add.u", "add.s", kTAFetch}, {"fetch_sub", "sub.u", "sub.u", kTAFetch},
    {"fetch_min", "min.u", "min.s", kTAFetch}, {"fetch_max", "max.u", "max.s", kTAFetch},
    {"fetch_and", "and.u", "and.u", kTAFetch}, {"fetch_or", "or.u", "or.u", kTAFetch},
    {"fetch_xor", "xor.u", "xor.u", kTAFetch}, {"exchange", "exch", "exch", kTAFetch},
    {"load", "or.u", "or.u", kTALoad},  // or 0: read at L2, where the other atomics are
    {"store", "exch", "exch", kTAStore}, {"compare_exchange_weak", "cas", "cas", kTACompareExchange},
};
static long metadataFieldAfter(const std::vector<LLVMValueRef> &f, const char *key, unsigned skip = 1) {
    for (size_t k = 0; k + skip < f.size(); k++)
        if (isString(f[k], key) && LLVMIsAConstantInt(f[k + skip])) return (long)LLVMConstIntGetZExtValue(f[k + skip]);
    return -1;
}
static bool atomicTextureArgument(const std::vector<LLVMValueRef> &f) {  // read_write texture2d<uint> / <int>, not an array
    if (f.size() < 5 || !isString(f[1], "air.texture") || metadataFieldAfter(f, "air.location_index", 2) != 1) return false;
    bool readWrite = false, type = false;
    for (size_t k = 0; k < f.size(); k++) {
        readWrite |= isString(f[k], "air.read_write");
        if (k + 1 < f.size() && isString(f[k], "air.arg_type_name")) {
            unsigned length = 0;
            const char *t = LLVMIsAMDString(f[k + 1]) ? LLVMGetMDString(f[k + 1], &length) : nullptr;
            std::string name = t ? std::string(t, length) : std::string();
            type = !name.compare(0, 15, "texture2d<uint,") || !name.compare(0, 14, "texture2d<int,");
        }
    }
    return readWrite && type;
}

struct TexAtomicCall { LLVMValueRef call; int op; bool isSigned; };
static unsigned lowerTextureAtomics(LLVMModuleRef module, Gen &g) {
    std::vector<TexAtomicCall> calls;
    for (int op = 0; op < (int)(sizeof kTexAtomicOps / sizeof *kTexAtomicOps); op++)
        for (int s = 0; s < 4; s++) {  // s & 1: signed; s & 2: ushort coordinates
            char name[128];
            snprintf(name, sizeof name, "air.atomic_%s_explicit_texture_2d%s.%c.v4i32", kTexAtomicOps[op].air, s & 2 ? ".i16" : "",
                     s & 1 ? 's' : 'u');
            LLVMValueRef f = LLVMGetNamedFunction(module, name);
            if (!f) continue;
            for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) {
                LLVMValueRef c = LLVMGetUser(u);
                if (LLVMIsACallInst(c) && LLVMGetCalledValue(c) == f) calls.push_back({c, op, (s & 1) != 0});
            }
        }
    if (calls.empty()) return 0;
    LLVMTypeRef global = LLVMPointerType(g.i32, 1), v4 = LLVMVectorType(g.i32, 4);
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    unsigned lowered = 0;
    for (const char *list : {"air.kernel", "air.fragment", "air.vertex"}) {
        std::vector<LLVMValueRef> entries(LLVMGetNamedMetadataNumOperands(module, list));
        if (entries.empty()) continue;
        LLVMGetNamedMetadataOperands(module, list, entries.data());
        for (LLVMValueRef entry : entries) {
            std::vector<LLVMValueRef> parts = metadataOperands(entry);
            void *node = metadataOf(entry);
            if (parts.size() < 3 || !parts[0] || !node || LLVMIsDeclaration(parts[0])) continue;
            LLVMValueRef function = parts[0];
            std::vector<TexAtomicCall *> mine;
            for (TexAtomicCall &c : calls)
                if (LLVMGetBasicBlockParent(LLVMGetInstructionParent(c.call)) == function) mine.push_back(&c);
            if (mine.empty()) continue;
            // the hidden indices, as item 58 works them out
            std::vector<LLVMValueRef> args = metadataOperands(parts[2]);
            bool used[31] = {false};
            std::vector<std::pair<long, long>> textures;  // (binding, parameter)
            for (LLVMValueRef arg : args) {
                std::vector<LLVMValueRef> f = metadataOperands(arg);
                if (f.size() < 2 || !LLVMIsAConstantInt(f[0])) continue;
                if (isString(f[1], "air.buffer") || isString(f[1], "air.indirect_buffer")) {
                    long index = metadataFieldAfter(f, "air.location_index"), count = metadataFieldAfter(f, "air.location_index", 2);
                    for (long k = 0; index >= 0 && k < (count > 0 ? count : 1); k++)
                        if (index + k < 31) used[index + k] = true;
                } else if (atomicTextureArgument(f)) {
                    textures.push_back({metadataFieldAfter(f, "air.location_index"), (long)LLVMConstIntGetZExtValue(f[0])});
                }
            }
            std::sort(textures.begin(), textures.end());
            std::vector<int> hidden(textures.size(), -1);
            int next = 30, lowest = !strcmp(list, "air.vertex") ? 17 : 0;
            bool room = true;
            for (size_t t = 0; t < textures.size(); t++) {
                while (next >= lowest && used[next]) next--;
                if (next < lowest) { room = false; break; }
                hidden[t] = next--;
            }
            if (!room) {
                if (logging()) fprintf(stderr, "[nvair] %s: texture atomics, but no free buffer indices for them\n", LLVMGetValueName(function));
                continue;
            }
            // the textures this function's atomics use, in texture order
            std::vector<int> callTexture(mine.size(), -1);
            std::vector<size_t> needed;
            for (size_t i = 0; i < mine.size(); i++) {
                LLVMValueRef texture = LLVMGetOperand(mine[i]->call, 0);
                for (size_t t = 0; t < textures.size(); t++)
                    if (texture == LLVMGetParam(function, (unsigned)textures[t].second)) callTexture[i] = (int)t;
                if (callTexture[i] < 0) {
                    if (logging()) fprintf(stderr, "[nvair] %s: a texture atomic not on a texture2d argument, left as is\n", LLVMGetValueName(function));
                    continue;
                }
                if (std::find(needed.begin(), needed.end(), (size_t)callTexture[i]) == needed.end()) needed.push_back(callTexture[i]);
            }
            if (needed.empty()) continue;
            std::sort(needed.begin(), needed.end());
            // the new function: the old parameters, then one buffer per texture in `needed`; the body moves over
            LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(function));
            unsigned params = LLVMCountParams(function);
            std::vector<LLVMTypeRef> types(LLVMCountParamTypes(type));
            LLVMGetParamTypes(type, types.data());
            for (size_t k = 0; k < needed.size(); k++) types.push_back(global);
            std::string name = LLVMGetValueName(function);
            LLVMSetValueName(function, (name + ".nvta").c_str());
            LLVMValueRef rebuilt = LLVMAddFunction(module, name.c_str(),
                LLVMFunctionType(LLVMGetReturnType(type), types.data(), (unsigned)types.size(), LLVMIsFunctionVarArg(type)));
            LLVMSetLinkage(rebuilt, LLVMGetLinkage(function));
            functionCopyAttributesFrom(rebuilt, function);
            for (unsigned p = 0; p < params; p++) {
                LLVMSetValueName(LLVMGetParam(rebuilt, p), LLVMGetValueName(LLVMGetParam(function, p)));
                LLVMReplaceAllUsesWith(LLVMGetParam(function, p), LLVMGetParam(rebuilt, p));
            }
            while (LLVMBasicBlockRef block = LLVMGetFirstBasicBlock(function)) {
                LLVMRemoveBasicBlockFromParent(block);
                basicBlockInsertInto(block, rebuilt, nullptr);
            }
            std::vector<LLVMValueRef> newArgs = args;
            for (size_t k = 0; k < needed.size(); k++) {
                char argName[32];
                snprintf(argName, sizeof argName, "__nvta_%ld", textures[needed[k]].first);
                LLVMSetValueName(LLVMGetParam(rebuilt, params + (unsigned)k), argName);
                auto str = [&](const char *t) { return LLVMMDStringInContext(g.context, t, (unsigned)strlen(t)); };
                LLVMValueRef f[] = {g.c32(params + k), str("air.buffer"), str("air.location_index"), g.c32(hidden[needed[k]]), g.c32(1),
                                    str("air.read_write"), str("air.arg_type_size"), g.c32(4), str("air.arg_type_align_size"), g.c32(4),
                                    str("air.arg_type_name"), str("uint"), str("air.arg_name"), str(argName)};
                newArgs.push_back(LLVMMDNodeInContext(g.context, f, sizeof f / sizeof *f));
            }
            void *argList = metadataOf(LLVMMDNodeInContext(g.context, newArgs.data(), (unsigned)newArgs.size()));
            if (!argList) continue;  // (can't happen for a fresh node)
            mdNodeReplaceOperand(node, 0, valueAsMetadata(rebuilt));
            mdNodeReplaceOperand(node, 2, argList);
            // the atomics
            for (size_t i = 0; i < mine.size(); i++) {
                if (callTexture[i] < 0) continue;
                LLVMValueRef call = mine[i]->call;
                const auto &op = kTexAtomicOps[mine[i]->op];
                size_t position = std::find(needed.begin(), needed.end(), (size_t)callTexture[i]) - needed.begin();
                LLVMValueRef base = LLVMGetParam(rebuilt, params + (unsigned)position);
                LLVMPositionBuilderBefore(b, call);
                LLVMValueRef coord = LLVMGetOperand(call, op.kind == kTAStore ? 2 : 1);
                LLVMValueRef x = LLVMBuildExtractElement(b, coord, g.c32(0), ""), y = LLVMBuildExtractElement(b, coord, g.c32(1), "");
                if (LLVMTypeOf(x) != g.i32) { x = LLVMBuildZExt(b, x, g.i32, ""); y = LLVMBuildZExt(b, y, g.i32, ""); }
                auto word = [&](unsigned k) { LLVMValueRef index = g.c32(k); return LLVMBuildLoad(b, LLVMBuildGEP(b, base, &index, 1, ""), ""); };
                LLVMValueRef ok = LLVMBuildICmp(b, LLVMIntEQ, word(0), g.c32(kTexAtomicMagic), "");
                ok = LLVMBuildAnd(b, ok, LLVMBuildICmp(b, LLVMIntULT, x, word(2), ""), "");
                ok = LLVMBuildAnd(b, ok, LLVMBuildICmp(b, LLVMIntULT, y, word(3), ""), "");
                LLVMValueRef index = LLVMBuildAdd(b, LLVMBuildAdd(b, LLVMBuildMul(b, y, word(1), ""), x, ""), g.c32(kTexAtomicHeaderWords), "");
                index = LLVMBuildSelect(b, ok, index, g.c32(kTexAtomicScratchWord), "");
                LLVMValueRef pointer = LLVMBuildGEP(b, base, &index, 1, "");
                char nvvm[64];
                const char *which = mine[i]->isSigned ? op.s : op.u;
                LLVMTypeRef two[2] = {global, g.i32}, three[3] = {global, g.i32, g.i32};
                if (op.kind == kTACompareExchange) {
                    LLVMValueRef cas = g.intrinsic("llvm.nvvm.atomic.cas.i32.p1i32.p0i8", g.i32, three, 3);
                    LLVMValueRef expectedPointer = LLVMBuildBitCast(b, LLVMGetOperand(call, 2), LLVMPointerType(g.i32, 0), "");
                    LLVMValueRef expected = LLVMBuildLoad(b, expectedPointer, "");
                    LLVMValueRef a[3] = {pointer, expected, LLVMBuildExtractElement(b, LLVMGetOperand(call, 3), g.c32(0), "")};
                    LLVMValueRef old = LLVMBuildCall(b, cas, a, 3, "");
                    LLVMBuildStore(b, old, expectedPointer);
                    LLVMValueRef same = LLVMBuildICmp(b, LLVMIntEQ, old, expected, "");
                    LLVMTypeRef result = LLVMTypeOf(call);
                    LLVMReplaceAllUsesWith(call, result == g.i1 ? same : LLVMBuildZExt(b, same, result, ""));
                } else {
                    snprintf(nvvm, sizeof nvvm, "llvm.nvvm.atomic.%s.i32.p1i32", which);
                    LLVMValueRef value = op.kind == kTALoad ? g.c32(0)
                                       : LLVMBuildExtractElement(b, LLVMGetOperand(call, op.kind == kTAStore ? 1 : 2), g.c32(0), "");
                    LLVMValueRef a[2] = {pointer, value};
                    LLVMValueRef old = LLVMBuildCall(b, g.intrinsic(nvvm, g.i32, two, 2), a, 2, "");
                    if (op.kind != kTAStore) LLVMReplaceAllUsesWith(call, LLVMBuildInsertElement(b, LLVMConstNull(v4), old, g.c32(0), ""));
                }
                LLVMInstructionEraseFromParent(call);
                lowered++;
            }
            if (logging()) {
                fprintf(stderr, "[nvair] %s: %zu texture atomic(s) on linear texture buffers", name.c_str(), mine.size());
                for (size_t k = 0; k < needed.size(); k++) fprintf(stderr, " texture(%ld)->buffer(%d)", textures[needed[k]].first, hidden[needed[k]]);
                fprintf(stderr, "\n");
            }
        }
    }
    LLVMDisposeBuilder(b);
    return lowered;
}

// ---- depth / stencil textures' channels in ANGLE's shaders (MetalOldCompat item 62) ------------------------------------
// Kepler's sampler returns a depth texture's depth in all four channels, (d, d, d, d), and a stencil view's value as
// (s, s, s, s), through texture2d<float> / <uint>; OpenGL ES wants (d, 0, 0, 1) and (s, 0, 0, 1), and ANGLE gets that from
// swizzled views this driver doesn't make. In an ANGLE vertex or fragment function (an ANGLE_angleUniforms argument) with a
// texture argument that isn't a depth texture, each sample or read of a texture argument comes out (x, 0, 0, 1) when bit
// n (its [[texture(n)]]) of a mask is set: a constant uint array at a hidden buffer index (__nvds), the next free one
// counted down from 30 after the texture atomics' (vertex functions keep 0-16), which item 62 works out the same way from
// the pipeline's reflection and fills before each draw from the textures bound. NVAIR_DEPTH_CHANNELS=0 turns it off.
static bool depthTextureArgument(const std::vector<LLVMValueRef> &f) {
    for (size_t k = 0; k + 1 < f.size(); k++)
        if (isString(f[k], "air.arg_type_name")) {
            unsigned length = 0;
            const char *t = LLVMIsAMDString(f[k + 1]) ? LLVMGetMDString(f[k + 1], &length) : nullptr;
            return t && length >= 5 && !strncmp(t, "depth", 5);
        }
    return false;
}
static bool argumentNamed(const std::vector<LLVMValueRef> &f, const char *name) {
    for (size_t k = 0; k + 1 < f.size(); k++)
        if (isString(f[k], "air.arg_name") && isString(f[k + 1], name)) return true;
    return false;
}
static unsigned fixDepthChannels(LLVMModuleRef module, Gen &g) {
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (const char *list : {"air.fragment", "air.vertex"}) {
        std::vector<LLVMValueRef> entries(LLVMGetNamedMetadataNumOperands(module, list));
        if (entries.empty()) continue;
        LLVMGetNamedMetadataOperands(module, list, entries.data());
        for (LLVMValueRef entry : entries) {
            std::vector<LLVMValueRef> parts = metadataOperands(entry);
            void *node = metadataOf(entry);
            if (parts.size() < 3 || !parts[0] || !node || LLVMIsDeclaration(parts[0])) continue;
            LLVMValueRef function = parts[0];
            std::vector<LLVMValueRef> args = metadataOperands(parts[2]);
            bool used[31] = {false}, angle = false;
            std::vector<std::pair<long, long>> textures;  // (binding, parameter)
            for (LLVMValueRef arg : args) {
                std::vector<LLVMValueRef> f = metadataOperands(arg);
                if (f.size() < 2 || !LLVMIsAConstantInt(f[0])) continue;
                if (isString(f[1], "air.buffer") || isString(f[1], "air.indirect_buffer")) {
                    long index = metadataFieldAfter(f, "air.location_index"), count = metadataFieldAfter(f, "air.location_index", 2);
                    for (long k = 0; index >= 0 && k < (count > 0 ? count : 1); k++)
                        if (index + k < 31) used[index + k] = true;
                    angle |= argumentNamed(f, "ANGLE_angleUniforms");
                } else if (isString(f[1], "air.texture") && !depthTextureArgument(f)) {
                    textures.push_back({metadataFieldAfter(f, "air.location_index"), (long)LLVMConstIntGetZExtValue(f[0])});
                }
            }
            if (!angle || textures.empty()) continue;
            int hidden = 30, lowest = !strcmp(list, "air.vertex") ? 17 : 0;
            while (hidden >= lowest && used[hidden]) hidden--;
            if (hidden < lowest) continue;
            // the samples and reads of a texture argument, with its binding
            std::vector<std::pair<LLVMValueRef, long>> calls;
            for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(function); bb; bb = LLVMGetNextBasicBlock(bb))
                for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                    if (!LLVMIsACallInst(inst)) continue;
                    LLVMValueRef callee = calledFunction(inst);
                    const char *name = callee ? LLVMGetValueName(callee) : "";
                    if (!startsWith(name, "air.sample_texture_") && !startsWith(name, "air.read_texture_")) continue;
                    LLVMTypeRef rt = LLVMTypeOf(inst);
                    if (LLVMGetTypeKind(rt) != LLVMVectorTypeKind || LLVMGetVectorSize(rt) != 4) continue;
                    LLVMValueRef texture = LLVMGetOperand(inst, 0);
                    for (auto &t : textures)
                        if (t.first >= 0 && t.first < 128 && texture == LLVMGetParam(function, (unsigned)t.second)) calls.push_back({inst, t.first});
                }
            if (calls.empty()) continue;
            // the function again, with the mask parameter last; the body moves over
            LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(function)), mask = LLVMPointerType(g.i32, 2);
            unsigned params = LLVMCountParams(function);
            std::vector<LLVMTypeRef> types(LLVMCountParamTypes(type));
            LLVMGetParamTypes(type, types.data());
            types.push_back(mask);
            std::string name = LLVMGetValueName(function);
            LLVMSetValueName(function, (name + ".nvds").c_str());
            LLVMValueRef rebuilt = LLVMAddFunction(module, name.c_str(),
                LLVMFunctionType(LLVMGetReturnType(type), types.data(), (unsigned)types.size(), LLVMIsFunctionVarArg(type)));
            LLVMSetLinkage(rebuilt, LLVMGetLinkage(function));
            functionCopyAttributesFrom(rebuilt, function);
            for (unsigned p = 0; p < params; p++) {
                LLVMSetValueName(LLVMGetParam(rebuilt, p), LLVMGetValueName(LLVMGetParam(function, p)));
                LLVMReplaceAllUsesWith(LLVMGetParam(function, p), LLVMGetParam(rebuilt, p));
            }
            while (LLVMBasicBlockRef block = LLVMGetFirstBasicBlock(function)) {
                LLVMRemoveBasicBlockFromParent(block);
                basicBlockInsertInto(block, rebuilt, nullptr);
            }
            LLVMValueRef base = LLVMGetParam(rebuilt, params);
            LLVMSetValueName(base, "__nvds");
            auto str = [&](const char *t) { return LLVMMDStringInContext(g.context, t, (unsigned)strlen(t)); };
            LLVMValueRef f[] = {g.c32(params), str("air.buffer"), str("air.location_index"), g.c32(hidden), g.c32(1), str("air.read"),
                                str("air.arg_type_size"), g.c32(4), str("air.arg_type_align_size"), g.c32(4),
                                str("air.arg_type_name"), str("uint"), str("air.arg_name"), str("__nvds")};
            std::vector<LLVMValueRef> newArgs = args;
            newArgs.push_back(LLVMMDNodeInContext(g.context, f, sizeof f / sizeof *f));
            void *argList = metadataOf(LLVMMDNodeInContext(g.context, newArgs.data(), (unsigned)newArgs.size()));
            if (!argList) continue;
            mdNodeReplaceOperand(node, 0, valueAsMetadata(rebuilt));
            mdNodeReplaceOperand(node, 2, argList);
            if (!b) b = LLVMCreateBuilderInContext(g.context);
            for (auto &c : calls) {
                LLVMValueRef call = c.first;
                LLVMPositionBuilderBefore(b, LLVMGetNextInstruction(call));
                LLVMValueRef index = g.c32((unsigned)(c.second / 32));
                LLVMValueRef word = LLVMBuildLoad(b, LLVMBuildGEP(b, base, &index, 1, ""), "");
                LLVMValueRef bit = LLVMBuildAnd(b, LLVMBuildLShr(b, word, g.c32((unsigned)(c.second % 32)), ""), g.c32(1), "");
                LLVMValueRef isDepth = LLVMBuildICmp(b, LLVMIntNE, bit, g.c32(0), "");
                LLVMTypeRef element = LLVMGetElementType(LLVMTypeOf(call));
                bool integer = LLVMGetTypeKind(element) == LLVMIntegerTypeKind;
                LLVMValueRef zero = LLVMConstNull(element), one = integer ? LLVMConstInt(element, 1, 0) : LLVMConstReal(element, 1.0);
                LLVMValueRef v1 = LLVMBuildInsertElement(b, call, zero, g.c32(1), "");
                LLVMValueRef v2 = LLVMBuildInsertElement(b, v1, zero, g.c32(2), "");
                LLVMValueRef v3 = LLVMBuildInsertElement(b, v2, one, g.c32(3), "");
                LLVMValueRef result = LLVMBuildSelect(b, isDepth, v3, call, "");
                LLVMReplaceAllUsesWith(call, result);
                LLVMSetOperand(v1, 0, call);
                LLVMSetOperand(result, 2, call);
                fixed++;
            }
            if (logging())
                fprintf(stderr, "[nvair] %s: %zu texture sample(s) / read(s) given depth channels, mask at buffer %d\n", name.c_str(), calls.size(), hidden);
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- large copies as loops ---------------------------------------------------------------------------------------------
// The plugin's back end takes time about cubic in the size of a constant-length llvm.memcpy (it lowers each to one load
// and store a word): a pipeline copying a 168-byte struct between device buffers took 14 s to build, 232 bytes 37 s, and
// a WebGPU CTS kernel copying a few such structs (shader,execution,expression,call,user,ptr_aliasing) kept the compiler
// service busy for over 13 minutes (the page never got its pipeline). A memcpy of 64 bytes or more, word-aligned and a
// whole number of words, becomes a loop of word loads and stores (nvair.copy.<dst>.<src>, always-inline), its trip count
// behind the plugin's opaque llvm.nvvm.min.u.i32 so the optimizer can't unroll it back. NVAIR_LARGE_COPY_LOOP=0.
static LLVMValueRef copyHelper(Gen &g, unsigned dstSpace, unsigned srcSpace) {
    char name[64];
    snprintf(name, sizeof name, "nvair.copy.%u.%u", dstSpace, srcSpace);
    if (LLVMValueRef f = LLVMGetNamedFunction(g.module, name)) return f;
    LLVMTypeRef i8 = LLVMInt8TypeInContext(g.context);
    LLVMTypeRef params[3] = {LLVMPointerType(i8, dstSpace), LLVMPointerType(i8, srcSpace), g.i32};
    LLVMValueRef f = LLVMAddFunction(g.module, name, LLVMFunctionType(LLVMVoidTypeInContext(g.context), params, 3, 0));
    markInline(g.context, f);
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(g.context, f, ""), loop = LLVMAppendBasicBlockInContext(g.context, f, ""),
                      done = LLVMAppendBasicBlockInContext(g.context, f, "");
    LLVMPositionBuilderAtEnd(b, entry);
    LLVMValueRef dst = LLVMBuildBitCast(b, LLVMGetParam(f, 0), LLVMPointerType(g.i32, dstSpace), "");
    LLVMValueRef src = LLVMBuildBitCast(b, LLVMGetParam(f, 1), LLVMPointerType(g.i32, srcSpace), "");
    LLVMTypeRef two[2] = {g.i32, g.i32};
    LLVMValueRef minArgs[2] = {LLVMGetParam(f, 2), g.c32(~0u)};
    LLVMValueRef count = LLVMBuildCall(b, g.intrinsic("llvm.nvvm.min.u.i32", g.i32, two, 2), minArgs, 2, "");
    LLVMBuildBr(b, loop);
    LLVMPositionBuilderAtEnd(b, loop);
    LLVMValueRef i = LLVMBuildPhi(b, g.i32, "");
    LLVMValueRef from = LLVMBuildGEP(b, src, &i, 1, ""), to = LLVMBuildGEP(b, dst, &i, 1, "");
    LLVMValueRef word = LLVMBuildLoad(b, from, "");
    LLVMSetAlignment(word, 4);
    LLVMSetAlignment(LLVMBuildStore(b, word, to), 4);
    LLVMValueRef next = LLVMBuildAdd(b, i, g.c32(1), "");
    LLVMValueRef zero = g.c32(0);
    LLVMBasicBlockRef from0 = entry, fromLoop = loop;
    LLVMAddIncoming(i, &zero, &from0, 1);
    LLVMAddIncoming(i, &next, &fromLoop, 1);
    LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntULT, next, count, ""), loop, done);
    LLVMPositionBuilderAtEnd(b, done);
    LLVMBuildRetVoid(b);
    LLVMDisposeBuilder(b);
    return f;
}
static unsigned loopLargeCopies(LLVMModuleRef module, Gen &g) {
    std::vector<LLVMValueRef> copies;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *fname = LLVMGetValueName(f);
        if (LLVMIsDeclaration(f) || startsWith(fname, "nvair.")) continue;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (!LLVMIsACallInst(inst)) continue;
                LLVMValueRef callee = calledFunction(inst);
                if (!callee || !startsWith(LLVMGetValueName(callee), "llvm.memcpy.") || LLVMGetNumArgOperands(inst) != 5) continue;
                LLVMValueRef length = LLVMGetOperand(inst, 2), align = LLVMGetOperand(inst, 3), isVolatile = LLVMGetOperand(inst, 4);
                if (!LLVMIsAConstantInt(length) || !LLVMIsAConstantInt(align) || !LLVMIsAConstantInt(isVolatile)) continue;
                unsigned long long bytes = LLVMConstIntGetZExtValue(length);
                if (bytes < 64 || bytes % 4 || bytes / 4 > 0x7fffffffull || LLVMConstIntGetZExtValue(align) < 4 || LLVMConstIntGetZExtValue(isVolatile))
                    continue;
                copies.push_back(inst);
            }
    }
    if (copies.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (LLVMValueRef copy : copies) {
        LLVMValueRef dst = LLVMGetOperand(copy, 0), src = LLVMGetOperand(copy, 1);
        LLVMTypeRef dt = LLVMTypeOf(dst), st = LLVMTypeOf(src);
        LLVMValueRef helper = copyHelper(g, LLVMGetPointerAddressSpace(dt), LLVMGetPointerAddressSpace(st));
        LLVMPositionBuilderBefore(b, copy);
        LLVMValueRef args[3] = {dst, src, g.c32((unsigned)(LLVMConstIntGetZExtValue(LLVMGetOperand(copy, 2)) / 4))};
        LLVMBuildCall(b, helper, args, 3, "");
        LLVMInstructionEraseFromParent(copy);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)copies.size();
}

// ---- half vectors spelled as bitcasts in constants --------------------------------------------------------------------
// A constant array of half2x2 (WGSL `const` matrices of f16: WebGPU CTS shader,execution,expression,constructor) reaches
// the plugin with each half2 column spelled as a constant expression, bitcast (<1 x i32> <i32 bits> to <2 x half>), and
// its constant lowering crashes on that (a null dereference in a recursive walk: the compiler service died on every try,
// and the app's next compile waited on it forever). half2 alone, half4, half3x3 and float2x2 constants are spelled
// plainly and compile. In global initializers, each such bitcast becomes the plain half vector it stands for.
// NVAIR_HALF_CONSTANT_FIX=0 turns it off.
enum { kOpBitCast = 41 };  // LLVM-C's LLVMBitCast
static double halfBitsToDouble(unsigned h) {
    int sign = (h >> 15) & 1, exponent = (h >> 10) & 31;
    unsigned mantissa = h & 1023;
    double v;
    if (exponent == 0) v = std::ldexp((double)mantissa, -24);
    else if (exponent == 31) v = mantissa ? NAN : INFINITY;
    else v = std::ldexp((double)(mantissa | 1024), exponent - 25);
    return sign ? -v : v;
}
// The bits of a constant integer or vector of integers, low element first; false if it isn't one.
static bool constantBits(LLVMValueRef c, std::vector<uint8_t> &bytes) {
    LLVMTypeRef t = LLVMTypeOf(c);
    auto addInt = [&](LLVMValueRef v) {
        if (!LLVMIsAConstantInt(v)) return false;
        unsigned width = LLVMGetIntTypeWidth(LLVMTypeOf(v));
        if (width % 8 || width > 64) return false;
        unsigned long long x = LLVMConstIntGetZExtValue(v);
        for (unsigned k = 0; k < width / 8; k++) bytes.push_back((uint8_t)(x >> (8 * k)));
        return true;
    };
    if (LLVMGetTypeKind(t) == LLVMIntegerTypeKind) return addInt(c);
    if (LLVMGetTypeKind(t) != LLVMVectorTypeKind) return false;
    unsigned n = LLVMGetVectorSize(t);
    for (unsigned i = 0; i < n; i++) {
        LLVMValueRef e = LLVMIsAConstantDataVector(c) ? LLVMGetElementAsConstant(c, i) : LLVMIsAConstantVector(c) ? LLVMGetOperand(c, i) : nullptr;
        if (!e || !addInt(e)) return false;
    }
    return true;
}
static LLVMValueRef foldHalfBitcasts(Gen &g, LLVMValueRef c, bool &changed, int depth = 0) {
    if (!c || depth > 16) return c;
    LLVMTypeRef t = LLVMTypeOf(c);
    if (LLVMIsAConstantExpr(c) && LLVMGetConstOpcode(c) == kOpBitCast && LLVMGetTypeKind(t) == LLVMVectorTypeKind &&
        LLVMGetElementType(t) == LLVMHalfTypeInContext(g.context)) {
        std::vector<uint8_t> bytes;
        unsigned n = LLVMGetVectorSize(t);
        if (!constantBits(LLVMGetOperand(c, 0), bytes) || bytes.size() != 2 * n) return c;
        std::vector<LLVMValueRef> halves;
        for (unsigned i = 0; i < n; i++)
            halves.push_back(LLVMConstReal(LLVMHalfTypeInContext(g.context), halfBitsToDouble(bytes[2 * i] | bytes[2 * i + 1] << 8)));
        changed = true;
        return LLVMConstVector(halves.data(), n);
    }
    bool isStruct = LLVMIsAConstantStruct(c), isArray = LLVMIsAConstantArray(c), isVector = LLVMIsAConstantVector(c);
    if (!isStruct && !isArray && !isVector) return c;
    unsigned n = (unsigned)LLVMGetNumOperands(c);
    std::vector<LLVMValueRef> elements(n);
    bool inner = false;
    for (unsigned i = 0; i < n; i++) elements[i] = foldHalfBitcasts(g, LLVMGetOperand(c, i), inner, depth + 1);
    if (!inner) return c;
    changed = true;
    if (isArray) return LLVMConstArray(LLVMGetElementType(t), elements.data(), n);
    if (isVector) return LLVMConstVector(elements.data(), n);
    return LLVMGetStructName(t) ? LLVMConstNamedStruct(t, elements.data(), n)
                                : LLVMConstStructInContext(g.context, elements.data(), n, LLVMIsPackedStruct(t));
}
static unsigned foldHalfVectorBitcasts(LLVMModuleRef module, Gen &g) {
    unsigned fixed = 0;
    for (LLVMValueRef v = LLVMGetFirstGlobal(module); v; v = LLVMGetNextGlobal(v)) {
        LLVMValueRef init = LLVMIsDeclaration(v) ? nullptr : LLVMGetInitializer(v);
        if (!init) continue;
        bool changed = false;
        LLVMValueRef folded = foldHalfBitcasts(g, init, changed);
        if (changed) LLVMSetInitializer(v, folded), fixed++;
    }
    return fixed;
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
        unsigned atomics = disabled("NVAIR_TEXTURE_ATOMICS") ? 0 : lowerTextureAtomics(module, g);
        if (atomics && logging()) fprintf(stderr, "[nvair] %u texture atomic(s) made global atomics on linear texture buffers\n", atomics);
        unsigned depthChannels = disabled("NVAIR_DEPTH_CHANNELS") ? 0 : fixDepthChannels(module, g);
        (void)depthChannels;
        unsigned cubeReads = disabled("NVAIR_CUBE_READ_LEVEL") ? 0 : fixCubeReadLevels(module, g);
        unsigned exchanges = disabled("NVAIR_LOCAL_CMPXCHG") ? 0 : fixLocalCompareExchange(module, g);
        unsigned signedBools = disabled("NVAIR_SIGNED_BOOL_FIX") ? 0 : fixSignedBoolConversions(module, g);
        if (signedBools && logging()) fprintf(stderr, "[nvair] %u sign mask(s) taken out of signed-to-bool conversions\n", signedBools);
        if (exchanges && logging()) fprintf(stderr, "[nvair] %u threadgroup compare-exchange body(ies) given the store of the value found\n", exchanges);
        if (cubeReads && logging()) fprintf(stderr, "[nvair] %u cube read body(ies) given the level's size and a mip-filtered sampler\n", cubeReads);
        unsigned defined = disabled("NVAIR_INTRINSICS") ? 0 : defineMissingIntrinsics(g);
        unsigned fixed = disabled("NVAIR_I64_FIX") ? 0 : fixWideInstructions(module, g);
        unsigned samplers = disabled("NVAIR_SAMPLER_STATE_FIX") ? 0 : fixSamplerStateWords(module, g);
        unsigned bools = disabled("NVAIR_THREADGROUP_BOOL_FIX") ? 0 : widenThreadgroupBools(module, g);
        if (bools && logging()) fprintf(stderr, "[nvair] %u threadgroup bool(s) widened to i8\n", bools);
        unsigned cubes = disabled("NVAIR_CUBE_ARRAY_FIX") ? 0 : clampCubeArrayIndices(module, g);
        if (cubes && logging()) fprintf(stderr, "[nvair] %u cube array index(es) raised to 0\n", cubes);
        unsigned gradients = disabled("NVAIR_GRADIENT_FIX") ? 0 : fixGradientSamples(module, g);
        if (gradients && logging()) fprintf(stderr, "[nvair] %u 3D / cube gradient sample(s) done at their level\n", gradients);
        unsigned products = disabled("NVAIR_NARROW_MULTIPLY_FIX") ? 0 : hideNarrowProducts(module, g);
        if (products && logging()) fprintf(stderr, "[nvair] %u product(s) of 16-bit factors given an opaque factor\n", products);
        unsigned guarded = disabled("NVAIR_FRAGMENT_LOAD_GUARD") ? 0 : guardFragmentLoads(module, g);
        if (guarded && logging()) fprintf(stderr, "[nvair] %u fragment device load(s) kept from a negative index\n", guarded);
        unsigned demoted = disabled("NVAIR_DEMOTE_DISCARD") ? 0 : demoteDiscards(module, g);
        unsigned halves = disabled("NVAIR_HALF_CONSTANT_FIX") ? 0 : foldHalfVectorBitcasts(module, g);
        if (halves && logging()) fprintf(stderr, "[nvair] %u constant(s) with half vectors spelled as bitcasts rewritten\n", halves);
        unsigned copies = disabled("NVAIR_LARGE_COPY_LOOP") ? 0 : loopLargeCopies(module, g);
        if (copies && logging()) fprintf(stderr, "[nvair] %u large copy(ies) made word loops\n", copies);
        unsigned narrow = disabled("NVAIR_NARROW_PRIVATE_ARRAY_FIX") ? 0 : widenNarrowPrivateArrays(module, g);
        if (narrow && logging()) fprintf(stderr, "[nvair] %u private byte / halfword array(s) done on 32-bit words\n", narrow);
        unsigned counts = disabled("NVAIR_COUNT_ZERO_FIX") ? 0 : defineCountOfZero(module, g);
        if (counts && logging()) fprintf(stderr, "[nvair] %u clz/ctz call(s) made defined for 0\n", counts);
        unsigned gradients2 = disabled("NVAIR_COMPARE_GRADIENT_FIX") ? 0 : fixGradientCompares(module, g);
        if (gradients2 && logging()) fprintf(stderr, "[nvair] %u gradient comparison(s) made at level 0\n", gradients2);
        unsigned compares = disabled("NVAIR_COMPARE_LEVEL_FIX") ? 0 : fixDepthCompareLevels(module, g);
        if (compares && logging()) fprintf(stderr, "[nvair] %u depth comparison(s) moved to a level that compares\n", compares);
        if (samplers && logging()) fprintf(stderr, "[nvair] %u constexpr sampler(s) in the [2 x i64] form rewritten as i64\n", samplers);
        if (defined || fixed || demoted || copies) inlineBodies(module);
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
