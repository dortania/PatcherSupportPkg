// GeForceAIRCompat.dylib: AIR compatibility for OCLP's Kepler Metal compiler (GeForceAIRPlugin, GTX 600/700 on macOS
// 14+). It redirects the plugin's import of llvm::legacy::PassManager::run, so that before each run the module, already
// linked with the plugin's built-in library, goes through kModuleFixes: bodies for AIR intrinsics the plugin lacks and
// rewrites of IR its back end compiles wrong. Each fix has an NVAIR_* switch (=0: off), which the tests' "without the
// fix" column uses; FIXES.md lists them.
// Installed next to GeForceAIRPlugin as its weak dependency GeForceAIRCompat.dylib; in tests:
// DYLD_INSERT_LIBRARIES=Tests/tools/localcc.dylib:build/GeForceAIRCompat-test.dylib.
//   NVAIR_LOG=1             log what is rewritten (NVAIR_LOG=/path: append to that file)
//   NVAIR_DUMP_INPUT=<dir>  write every module as it reaches the pass manager
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

#include "LLVMC.h"
#include "LLVM38.h"

enum { LLVMIntEQ = 32, LLVMIntNE, LLVMIntUGT, LLVMIntUGE, LLVMIntULT, LLVMIntULE, LLVMIntSGT, LLVMIntSGE, LLVMIntSLT, LLVMIntSLE };
enum { LLVMInternalLinkage = 8 };
enum { LLVMIntegerTypeKind = 8 };
static const unsigned LLVMAttributeFunctionIndex = ~0u;
enum { LLVMUDiv = 14, LLVMSDiv = 15, LLVMURem = 17, LLVMSRem = 18, LLVMShl = 20, LLVMLShr = 21, LLVMAShr = 22, LLVMTrunc = 30, LLVMZExt = 31, LLVMSExt = 32 };
enum { LLVMArrayTypeKind = 11, LLVMVectorTypeKind = 13 };
extern "C" int passManagerRun(void *self, LLVMModuleRef module) asm("__ZN4llvm6legacy11PassManager3runERNS_6ModuleE");

static const char *const kPluginSuffix = "/GeForceAIRPlugin";
static bool logging() { return getenv("NVAIR_LOG") != nullptr; }
static bool disabled(const char *name) { const char *v = getenv(name); return v && !strcmp(v, "0"); }
static bool startsWith(const char *s, const char *prefix) { return !strncmp(s, prefix, strlen(prefix)); }
// The calls whose callee is f (with exactly argCount arguments, unless -1), in use-list order.
static std::vector<LLVMValueRef> callsTo(LLVMValueRef f, int argCount = -1) {
    std::vector<LLVMValueRef> calls;
    for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u))
        if (LLVMValueRef call = LLVMIsACallInst(LLVMGetUser(u)))
            if (LLVMGetCalledValue(call) == f && (argCount < 0 || LLVMGetNumOperands(call) == argCount + 1)) calls.push_back(call);
    return calls;
}

// ---- bodies for AIR intrinsics the plugin lacks ---------------------------------------------------------------------
// AIR intrinsics newer than the plugin stay bare declarations that instruction selection rejects ("Unhandled
// constant"): the 64-bit integer ones and quad_shuffle_xor get exact bodies, inlined afterwards; SIMD reductions and
// ballot can't be built without a vote instruction. NVAIR_INTRINSICS. (a21, a22, a34, i27, i49)
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
    // llvm.nvvm.min.u.i32(v, bound), the plugin's own min, which neither optimizer sees through: with bound ~0 the value
    // is unchanged but its range and origin are hidden, so a rewrite can't be folded back
    LLVMValueRef opaqueMin(LLVMBuilderRef at, LLVMValueRef v, LLVMValueRef bound) {
        LLVMTypeRef params[2] = {i32, i32};
        LLVMValueRef args[2] = {v, bound};
        return LLVMBuildCall(at, intrinsic("llvm.nvvm.min.u.i32", i32, params, 2), args, 2, "");
    }
    LLVMValueRef lo(LLVMValueRef v) { return LLVMBuildTrunc(b, v, i32, ""); }
    LLVMValueRef hi(LLVMValueRef v) { return LLVMBuildTrunc(b, LLVMBuildLShr(b, v, c64(32), ""), i32, ""); }
    LLVMValueRef wide(LLVMValueRef v) { return LLVMBuildZExt(b, v, i64, ""); }
    // c (i1) as 0 or 1 in 64 bits, through llvm.nvvm.min.u.i32 (the plugin's own min, opaque to InstCombine): select c,
    // 1, 0 and zext (zext c) are folded back into zext i1 -> i64 by the plugin's optimizer, and that is what it gets wrong
    LLVMValueRef bool64(LLVMBuilderRef at, LLVMValueRef c) {
        return LLVMBuildZExt(at, opaqueMin(at, LLVMBuildZExt(at, c, i32, ""), c32(1)), i64, "");
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

enum IntrinsicKind { kMin, kMax, kClamp, kPopcount, kClz, kCtz, kMulHi, kMadHi, kQuadXor, kReverse, kAbs };
enum NameMatch { kExactName, kNamePrefix, kSignedI64Prefix };  // kSignedI64Prefix: the prefix, then u.i64 or s.i64
static const struct { const char *name; NameMatch match; IntrinsicKind kind; unsigned arity; } kMissingIntrinsics[] = {
    {"air.min.", kSignedI64Prefix, kMin, 2}, {"air.max.", kSignedI64Prefix, kMax, 2}, {"air.clamp.", kSignedI64Prefix, kClamp, 3},
    {"air.mul_hi.", kSignedI64Prefix, kMulHi, 2}, {"air.mad_hi.", kSignedI64Prefix, kMadHi, 3},
    {"air.popcount.i64", kExactName, kPopcount, 1}, {"air.clz.i64", kExactName, kClz, 2}, {"air.ctz.i64", kExactName, kCtz, 2},
    {"air.reverse_bits.i64", kExactName, kReverse, 1}, {"air.abs.s.i64", kExactName, kAbs, 1},
    {"air.quad_shuffle_xor.", kNamePrefix, kQuadXor, 2},
};

// The entry of kMissingIntrinsics a declaration's name and type match, or -1.
static int missingIntrinsic(LLVMValueRef f, const char *name, bool &isSigned) {
    static const unsigned kWide[3] = {64, 64, 64}, kCountWidths[2] = {64, 1}, kShuffleWidths[2] = {0, 16};
    int entry = -1;
    for (int i = 0; i < (int)(sizeof kMissingIntrinsics / sizeof *kMissingIntrinsics) && entry < 0; i++) {
        const auto &m = kMissingIntrinsics[i];
        if (m.match == kExactName ? !strcmp(name, m.name) : startsWith(name, m.name)) entry = i;
    }
    if (entry < 0) return -1;
    const auto &m = kMissingIntrinsics[entry];
    if (m.match == kSignedI64Prefix) {
        const char *rest = name + strlen(m.name);
        if (strcmp(rest, "u.i64") && strcmp(rest, "s.i64")) return -1;
        isSigned = rest[0] == 's';
    }
    switch (m.kind) {
        case kClz: case kCtz: return shape(f, 64, 2, kCountWidths) ? entry : -1;
        case kQuadXor: {  // (T value, i16 lane mask) -> T
            LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(f)), params[2];
            if (!shape(f, 0, 2, kShuffleWidths)) return -1;
            LLVMGetParamTypes(type, params);
            return LLVMGetReturnType(type) == params[0] ? entry : -1;
        }
        default: return shape(f, 64, m.arity, kWide) ? entry : -1;
    }
}

// The body of the intrinsic `kind` in helper f, whose entry block the builder is at; returns the result.
static LLVMValueRef buildIntrinsicBody(Gen &g, IntrinsicKind kind, bool isSigned, unsigned arity, LLVMValueRef f, const char *name) {
    LLVMBuilderRef b = g.b;
    LLVMValueRef p0 = LLVMGetParam(f, 0), p1 = arity > 1 ? LLVMGetParam(f, 1) : nullptr;
    switch (kind) {
        case kMin: case kMax: {
            int pred = kind == kMin ? (isSigned ? LLVMIntSLT : LLVMIntULT) : (isSigned ? LLVMIntSGT : LLVMIntUGT);
            return LLVMBuildSelect(b, LLVMBuildICmp(b, pred, p0, p1, ""), p0, p1, "");
        }
        case kClamp: {  // clamp(x, lo, hi) = min(max(x, lo), hi)
            LLVMValueRef p2 = LLVMGetParam(f, 2);
            LLVMValueRef m = LLVMBuildSelect(b, LLVMBuildICmp(b, isSigned ? LLVMIntSGT : LLVMIntUGT, p0, p1, ""), p0, p1, "");
            return LLVMBuildSelect(b, LLVMBuildICmp(b, isSigned ? LLVMIntSLT : LLVMIntULT, m, p2, ""), m, p2, "");
        }
        case kPopcount:
            return g.wide(LLVMBuildAdd(b, g.count32("ctpop", g.lo(p0)), g.count32("ctpop", g.hi(p0)), ""));
        case kReverse: {  // each half reversed by the plugin's own llvm.nvvm.reverse_bits, and the halves swapped
            LLVMTypeRef params[1] = {g.i32};
            LLVMValueRef reverse = g.intrinsic("llvm.nvvm.reverse_bits", g.i32, params, 1), lo[1] = {g.lo(p0)}, hi[1] = {g.hi(p0)};
            LLVMValueRef top = LLVMBuildShl(b, g.wide(g.call(reverse, lo, 1)), g.c64(32), "");
            return LLVMBuildOr(b, top, g.wide(g.call(reverse, hi, 1)), "");
        }
        case kAbs:
            return LLVMBuildSelect(b, LLVMBuildICmp(b, LLVMIntSLT, p0, g.c64(0), ""), LLVMBuildSub(b, g.c64(0), p0, ""), p0, "");
        case kClz: {  // the high half's count, or 32 + the low half's when the high half is 0
            LLVMValueRef h = g.hi(p0), isZero = LLVMBuildICmp(b, LLVMIntEQ, h, g.c32(0), "");
            LLVMValueRef low = LLVMBuildAdd(b, g.count32("ctlz", g.lo(p0)), g.c32(32), "");
            return g.wide(LLVMBuildSelect(b, isZero, low, g.count32("ctlz", h), ""));
        }
        case kCtz: {  // the low half's count, or 32 + the high half's when the low half is 0
            LLVMValueRef l = g.lo(p0), isZero = LLVMBuildICmp(b, LLVMIntEQ, l, g.c32(0), "");
            LLVMValueRef high = LLVMBuildAdd(b, g.count32("cttz", g.hi(p0)), g.c32(32), "");
            return g.wide(LLVMBuildSelect(b, isZero, high, g.count32("cttz", l), ""));
        }
        case kMulHi: return g.mulHi(p0, p1, isSigned);
        case kMadHi: return LLVMBuildAdd(b, g.mulHi(p0, p1, isSigned), LLVMGetParam(f, 2), "");
        case kQuadXor: {  // the SIMD-group shuffle within the quad: lane mask & 3
            char simd[128];
            snprintf(simd, sizeof simd, "air.simd_shuffle_xor.%s", name + strlen("air.quad_shuffle_xor."));
            LLVMValueRef shuffle = LLVMGetNamedFunction(g.module, simd);
            if (!shuffle) shuffle = LLVMAddFunction(g.module, simd, LLVMGetElementType(LLVMTypeOf(f)));
            LLVMValueRef args[2] = {p0, LLVMBuildAnd(b, p1, LLVMConstInt(g.i16, 3, 0), "")};
            return g.call(shuffle, args, 2);
        }
    }
    return nullptr;
}

// Builds a body for the bare declaration f if its name and type are one this file provides; true if it did. The body
// goes into an internal always-inline helper (nvair.impl.<name>) and the calls are pointed at it: the plugin keeps its
// declaration (it deletes the declarations it collected after the run), and the always-inliner deletes the helper.
static bool define(Gen &g, LLVMValueRef f, const char *name) {
    bool isSigned = false;
    int entry = missingIntrinsic(f, name, isSigned);
    if (entry < 0) return false;
    char helperName[160];
    snprintf(helperName, sizeof helperName, "nvair.impl.%s", name);
    LLVMValueRef helper = LLVMAddFunction(g.module, helperName, LLVMGetElementType(LLVMTypeOf(f)));
    LLVMPositionBuilderAtEnd(g.b, LLVMAppendBasicBlockInContext(g.context, helper, "entry"));
    const auto &m = kMissingIntrinsics[entry];
    LLVMBuildRet(g.b, buildIntrinsicBody(g, m.kind, isSigned, m.arity, helper, name));
    LLVMSetLinkage(helper, LLVMInternalLinkage);
    static const unsigned alwaysInline = LLVMGetEnumAttributeKindForName("alwaysinline", 12),
                          noInline = LLVMGetEnumAttributeKindForName("noinline", 8);
    LLVMRemoveEnumAttributeAtIndex(helper, LLVMAttributeFunctionIndex, noInline);
    LLVMAddAttributeAtIndex(helper, LLVMAttributeFunctionIndex, LLVMCreateEnumAttribute(g.context, alwaysInline, 0));
    LLVMReplaceAllUsesWith(f, helper);  // the declaration stays, unused
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

// ---- 64-bit instructions the plugin gets wrong ----------------------------------------------------------------------
// A 64-bit value is a register pair, and the plugin's zext/sext from i1, 64-bit division and remainder, and variable
// 64-bit shifts left the high half wrong: rebuilt from 32-bit operations (division as 64 straight-line steps; the 1-bit
// extensions through the opaque min, as a select folds back). NVAIR_I64_FIX, NVAIR_SHIFT_FIX (shifts). (i67, n06)
static void markInline(LLVMContextRef context, LLVMValueRef f) {
    static const unsigned alwaysInline = LLVMGetEnumAttributeKindForName("alwaysinline", 12);
    LLVMSetLinkage(f, LLVMInternalLinkage);
    LLVMAddAttributeAtIndex(f, LLVMAttributeFunctionIndex, LLVMCreateEnumAttribute(context, alwaysInline, 0));
}

// nvair.udiv64 / nvair.urem64: restoring division unrolled into 64 straight-line steps, the quotient collected in two
// 32-bit halves. A looped form miscompiled private-array accesses around it and the plugin widens bools to 64 bits
// wrong (n06). Division by 0 gives all ones (remainder: a).
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

// One lane of an i64 shift by a variable amount from 32-bit shifts of the halves, combined through masks, not selects
// (the optimizer turns selects into a widened i1, which Kepler gets wrong), the amount behind the opaque min. Every
// 32-bit amount is masked into 0-31, so nothing is poison. (n06)
static LLVMValueRef shiftLane(Gen &g, LLVMBuilderRef b, int op, LLVMValueRef x, LLVMValueRef amount) {
    LLVMValueRef s = g.opaqueMin(b, LLVMBuildAnd(b, LLVMBuildTrunc(b, amount, g.i32, ""), g.c32(63), ""), g.c32(63));
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

// ---- constexpr samplers from newer front ends (IntelAdapter's fixSamplerStateWords) ---------------------------------
// Xcode 16.3+ libraries (AIR 2.7) store a constexpr sampler as [2 x i64] where the plugin reads one i64 and traps:
// rewritten to the one-word form (bit 63 set), as the Intel adapter does. NVAIR_SAMPLER_STATE_FIX. (i05)
extern "C" void mdNodeReplaceOperand(void *node, unsigned index, void *replacement) asm("__ZN4llvm6MDNode18replaceOperandWithEjPNS_8MetadataE");
extern "C" void *valueAsMetadata(LLVMValueRef value) asm("__ZN4llvm15ValueAsMetadata3getEPNS_5ValueE");


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

// ---- threadgroup bools (IntelAdapter's widenThreadgroupBools) -------------------------------------------------------
// A value stored to an i1 threadgroup global and read back never arrived on Kepler: such globals become volatile i8
// (the i1 one stays, unused and renamed: the plugin keeps pointers into the module). NVAIR_THREADGROUP_BOOL_FIX. (a10)
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

// ---- texture-array layers below 0 -----------------------------------------------------------------------------------
// Kepler takes an array sample's or gather's i32 layer as unsigned, so a negative layer read the last layer or cube,
// where WebGPU clamps to 0 (Safari passes WGSL's layer unclamped): the layer argument of
// llvm.nvvm.{sample,gather}*.array* becomes select(layer < 0, 0, layer). NVAIR_ARRAY_LAYER_CLAMP. (n52, a09)
static unsigned clampArrayLayers(LLVMModuleRef module, Gen &g) {
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (!(startsWith(name, "llvm.nvvm.sample.") || startsWith(name, "llvm.nvvm.gather.")) || !strstr(name, ".array")) continue;
        for (LLVMValueRef call : callsTo(f)) {
            if (LLVMGetNumArgOperands(call) <= 3) continue;
            LLVMValueRef layer = LLVMGetOperand(call, 3);
            if (!isInt(LLVMTypeOf(layer), 32)) continue;
            if (LLVMIsAConstantInt(layer)) {
                if ((int)LLVMConstIntGetZExtValue(layer) < 0) { LLVMSetOperand(call, 3, g.c32(0)); fixed++; }
                continue;
            }
            if (LLVMIsAInstruction(layer) && startsWith(LLVMGetValueName(layer), "nvair.layer")) continue;  // an earlier run's
            if (!b) b = LLVMCreateBuilderInContext(g.context);
            LLVMPositionBuilderBefore(b, call);
            LLVMValueRef negative = LLVMBuildICmp(b, LLVMIntSLT, layer, g.c32(0), "");
            LLVMSetOperand(call, 3, LLVMBuildSelect(b, negative, g.c32(0), layer, "nvair.layer"));
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- cube reads at a level ------------------------------------------------------------------------------------------
// read() of a cube (array) at a level above 0 read level 0: the plugin's body samples along the texel's direction from
// level 0's size with a built-in sampler without mip filter and with LOD clamp 0. Each such body gets the level's size
// and a nearest-mip sampler with the largest LOD clamp (bodies fixed in an earlier run are skipped).
// NVAIR_CUBE_READ_LEVEL. (n14)
enum { kOpIntToPtr = 40 };  // LLVM-C's LLVMIntToPtr
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

// ---- compare-exchange on threadgroup memory -------------------------------------------------------------------------
// A failed threadgroup compare-exchange left *expected unchanged: the plugin's local cmpxchg body lacks the store of
// the found value that its global one makes (and marks the pointer readonly). The store is added. NVAIR_LOCAL_CMPXCHG.
// (n18)
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

// ---- atomics whose operand comes out of a divergent branch ----------------------------------------------------------
// The back end merges an atomic whose operand it takes for warp-uniform into one atomic for the warp, and takes a phi
// of uniform values for uniform even at the join of a per-lane branch: such operands go through a volatile private
// slot. NVAIR_ATOMIC_JOIN_FIX. (n25)
static bool reachesPhi(LLVMValueRef v, int depth) {
    if (!v || !LLVMIsAInstruction(v)) return false;
    if (LLVMIsAPHINode(v)) return true;
    if (depth == 0 || !(LLVMIsABinaryOperator(v) || LLVMIsACastInst(v) || LLVMIsASelectInst(v))) return false;
    for (unsigned i = 0, n = (unsigned)LLVMGetNumOperands(v); i < n; i++)
        if (reachesPhi(LLVMGetOperand(v, i), depth - 1)) return true;
    return false;
}
static unsigned fixAtomicJoinOperands(LLVMModuleRef module, Gen &g) {
    static const char *const kOps[] = {"add.", "sub.", "min.", "max.", "and.", "or.", "xor.", "xchg."};
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (LLVMIsDeclaration(f) || startsWith(LLVMGetValueName(f), "air.")) continue;  // call sites, not the library's bodies
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (!LLVMIsACallInst(inst) || LLVMGetNumArgOperands(inst) < 2) continue;
                LLVMValueRef callee = LLVMGetCalledValue(inst);
                const char *name = callee ? LLVMGetValueName(callee) : "";
                const char *op = startsWith(name, "air.atomic.local.") ? name + 17 : startsWith(name, "air.atomic.global.") ? name + 18 : nullptr;
                bool rmw = false;
                for (const char *k : kOps) rmw |= op && startsWith(op, k);
                if (!rmw) continue;
                LLVMValueRef v = LLVMGetOperand(inst, 1);
                if ((LLVMIsALoadInst(v) && LLVMGetVolatile(v)) || !reachesPhi(v, 6)) continue;  // already through a slot, or no join
                if (!b) b = LLVMCreateBuilderInContext(g.context);
                LLVMPositionBuilderBefore(b, LLVMGetFirstInstruction(LLVMGetEntryBasicBlock(f)));
                LLVMValueRef slot = LLVMBuildAlloca(b, LLVMTypeOf(v), "nvair.atomic.operand");
                LLVMPositionBuilderBefore(b, inst);
                LLVMSetVolatile(LLVMBuildStore(b, v, slot), 1);
                LLVMValueRef reloaded = LLVMBuildLoad(b, slot, "");
                LLVMSetVolatile(reloaded, 1);
                LLVMSetOperand(inst, 1, reloaded);
                fixed++;
            }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- signed integers to bool ----------------------------------------------------------------------------------------
// The plugin's body for bool vectors of signed integers tests (x & INT_MAX) != 0, the float test, so INT_MIN gave
// false: the mask is dropped (x != 0). NVAIR_SIGNED_BOOL_FIX. (n19)
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

// ---- gradient samples of 3D textures and cubes ----------------------------------------------------------------------
// Gradient samples of 3D textures and cubes broke compute kernels, cube gradients along the major axis got the wrong
// level elsewhere, and so did 3D ones in ANGLE's vertex shaders: each is done at the level Vulkan's formula picks (no
// anisotropy). NVAIR_GRADIENT_FIX (compute), NVAIR_CUBE_GRADIENT_FIX, NVAIR_VERTEX_3D_GRADIENT_FIX. (a09, i08, n27)
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
    bool compute = LLVMGetNamedMetadataNumOperands(module, "air.kernel") != 0;
    bool vertex3d = !compute && LLVMGetNamedMetadataNumOperands(module, "air.vertex") && !disabled("NVAIR_VERTEX_3D_GRADIENT_FIX");
    if (compute ? disabled("NVAIR_GRADIENT_FIX") : disabled("NVAIR_CUBE_GRADIENT_FIX") && !vertex3d) return 0;
    bool cubes = compute || !disabled("NVAIR_CUBE_GRADIENT_FIX");
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
        if (k < 0 || (kKinds[k].cube ? !cubes : !compute && !vertex3d)) continue;  // fragment functions: cubes only
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
        std::vector<LLVMValueRef> calls = callsTo(f, (int)count);
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

// ---- depth comparisons at a level other than a constant 0 -----------------------------------------------------------
// A depth comparison at a level or bias other than a constant 0 returned the depth: a .lod one is done at level 0
// (exact for one-level shadow maps), a .bias one in fragment functions at the implicit level. NVAIR_COMPARE_LEVEL_FIX.
// (i03)
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
        std::vector<LLVMValueRef> calls = callsTo(f, (int)count);
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

// ---- depth comparisons with gradients (no body in the plugin) -------------------------------------------------------
// Depth comparisons with gradients have no body in the plugin (instruction selection fails): done at level 0 through
// the library's own level intrinsic, keeping a constant texel offset. NVAIR_COMPARE_GRADIENT_FIX. (i78, n05)
// Parameters: (texture, sampler, i32, coord, [i32 layer,] float reference, dPdx, dPdy, [float min LOD clamp,]
// [i1 offset?, int2 offset,] i32); the 3802 runtime compiler's forms have no clamp, the newer front ends' have.
struct GradientCompareForm { const char *air, *shape; bool cube, array; };
static const GradientCompareForm kGradientCompareForms[] = {
    {"air.sample_compare_depth_2d_grad.f32", "2d", false, false},
    {"air.sample_compare_depth_2d_array_grad.f32", "2d.array", false, true},
    {"air.sample_compare_depth_cube_grad.f32", "cube", true, false},
    {"air.sample_compare_depth_cube_array_grad.f32", "cube.array", true, true},
};
struct GradientCompareLayout {
    unsigned reference;  // the parameter index of the depth reference
    int offsetFlag;      // of the i1 has-offset parameter, -1 for cubes
    bool pair;           // the newer front ends' { float, i8 } result
    LLVMTypeRef result;
    unsigned samplerSpace;
};
enum { kCompareCoordParam = 3, kCompareLayerParam = 4 };
// Whether the declaration's type is one of the forms above, and where its parameters are.
static bool gradientCompareLayout(Gen &g, LLVMTypeRef type, const GradientCompareForm &form, GradientCompareLayout &out) {
    enum { kStructKind = 10, kPointerKind = 12 };
    LLVMTypeRef f32 = LLVMFloatTypeInContext(g.context), v2i = LLVMVectorType(g.i32, 2);
    LLVMTypeRef coordType = LLVMVectorType(f32, form.cube ? 3 : 2);
    unsigned count = LLVMCountParamTypes(type), r = form.array ? 5 : 4, dx = r + 1, after = r + 3;
    LLVMTypeRef params[12];
    if (count > 12 || count < after + 1) return false;
    LLVMGetParamTypes(type, params);
    if (LLVMGetTypeKind(params[0]) != kPointerKind || LLVMGetTypeKind(params[1]) != kPointerKind ||
        params[kCompareCoordParam] != coordType || params[r] != f32 || params[dx] != coordType || params[dx + 1] != coordType ||
        (form.array && !isInt(params[kCompareLayerParam], 32)))
        return false;
    unsigned next = after + (params[after] == f32 ? 1 : 0);  // past the clamp, if any
    out.offsetFlag = -1;
    if (!form.cube) {  // i1 has-offset, int2 offset, i32
        if (count != next + 3 || !isInt(params[next], 1) || params[next + 1] != v2i || !isInt(params[next + 2], 32)) return false;
        out.offsetFlag = (int)next;
    } else if (count != next + 1 || !isInt(params[next], 32)) {
        return false;
    }
    out.result = LLVMGetReturnType(type);
    out.pair = LLVMGetTypeKind(out.result) == kStructKind;
    if (!out.pair && out.result != f32) return false;
    if (out.pair && (LLVMCountStructElementTypes(out.result) < 1 || LLVMStructGetTypeAtIndex(out.result, 0) != f32)) return false;
    out.reference = r;
    out.samplerSpace = LLVMGetPointerAddressSpace(params[1]);
    return true;
}
// Whether the call has a constant texel offset (in *offset); false for a computed one, which is left as it is.
static bool constantTexelOffset(LLVMValueRef call, int offsetFlag, bool *offset) {
    *offset = false;
    if (offsetFlag < 0) return true;
    LLVMValueRef flag = LLVMGetOperand(call, offsetFlag), value = LLVMGetOperand(call, offsetFlag + 1);
    if (!LLVMIsAConstantInt(flag)) return false;
    *offset = LLVMConstIntGetZExtValue(flag) && !LLVMIsAConstantAggregateZero(value);
    return !*offset || LLVMIsAConstantDataVector(value) || LLVMIsAConstantVector(value);
}
// The call as the library's level form at level 0 (llvm.nvvm.sample.compare.tex.<shape>[.offset].lod), its result in
// the call's type.
static LLVMValueRef levelZeroCompare(Gen &g, LLVMBuilderRef b, LLVMValueRef call, const GradientCompareForm &form,
                                     const GradientCompareLayout &layout, bool offset) {
    LLVMTypeRef f32 = LLVMFloatTypeInContext(g.context), v4 = LLVMVectorType(f32, 4), v2i = LLVMVectorType(g.i32, 2);
    LLVMTypeRef texturePointer = LLVMPointerType(LLVMInt8TypeInContext(g.context), 1);
    LLVMTypeRef samplerPointer = LLVMPointerType(LLVMInt8TypeInContext(g.context), layout.samplerSpace);
    char name[112];
    snprintf(name, sizeof name, "llvm.nvvm.sample.compare.tex.%s%s.lod.v4f32.p1i8.p%ui8", form.shape, offset ? ".offset" : "",
             layout.samplerSpace);
    LLVMTypeRef lodParams[7];
    unsigned n = 0;
    lodParams[n++] = texturePointer, lodParams[n++] = samplerPointer, lodParams[n++] = form.cube ? v4 : LLVMVectorType(f32, 2);
    if (form.array) lodParams[n++] = g.i32;
    lodParams[n++] = f32;
    if (offset) lodParams[n++] = v2i;
    lodParams[n++] = f32;
    LLVMValueRef lod = g.intrinsic(name, v4, lodParams, n);
    LLVMPositionBuilderBefore(b, call);
    LLVMValueRef coord = LLVMGetOperand(call, kCompareCoordParam);
    if (form.cube) {  // float3 -> float4
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
    if (form.array) args[a++] = LLVMGetOperand(call, kCompareLayerParam);
    args[a++] = LLVMGetOperand(call, layout.reference);
    if (offset) args[a++] = LLVMGetOperand(call, layout.offsetFlag + 1);
    args[a++] = LLVMConstReal(f32, 0.0);
    LLVMValueRef value = LLVMBuildExtractElement(b, LLVMBuildCall(b, lod, args, a, ""), g.c32(0), "");
    if (!layout.pair) return value;
    LLVMValueRef whole = LLVMBuildInsertValue(b, LLVMGetUndef(layout.result), value, 0, "");
    if (LLVMCountStructElementTypes(layout.result) > 1 && isInt(LLVMStructGetTypeAtIndex(layout.result, 1), 8))
        whole = LLVMBuildInsertValue(b, whole, LLVMConstInt(LLVMStructGetTypeAtIndex(layout.result, 1), 1, 0), 1, "");  // resident
    return whole;
}
static unsigned fixGradientCompares(LLVMModuleRef module, Gen &g) {
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (const auto &form : kGradientCompareForms) {
        LLVMValueRef f = LLVMGetNamedFunction(module, form.air);
        if (!f || !LLVMIsDeclaration(f) || !LLVMGetFirstUse(f)) continue;
        GradientCompareLayout layout;
        if (!gradientCompareLayout(g, LLVMGetElementType(LLVMTypeOf(f)), form, layout)) continue;
        for (LLVMValueRef call : callsTo(f)) {
            bool offset;
            if (!constantTexelOffset(call, layout.offsetFlag, &offset)) continue;
            if (!b) b = LLVMCreateBuilderInContext(g.context);
            LLVMValueRef value = levelZeroCompare(g, b, call, form, layout, offset);
            LLVMReplaceAllUsesWith(call, value);
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- clz and ctz of a constant 0 ------------------------------------------------------------------------------------
// The library's clz/ctz are undefined at 0, which the optimizer folds to garbage for a constant 0 (Metal's is the
// width): every llvm.ctlz/cttz asks for the defined result, which the hardware gives anyway. NVAIR_COUNT_ZERO_FIX.
// (n01)
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

// ---- private arrays of bytes and halfwords done on 32-bit words (IntelAdapter's widenNarrowPrivateArrays) -----------
// The back end forwarded a stored word to a narrow load from a private uchar/ushort array without masking it: each such
// load's value is masked to its width through the opaque min. NVAIR_NARROW_PRIVATE_ARRAY_FIX (i47, n02);
// NVAIR_PRIVATE_ARRAY_WORDS=1 brings back the older i32-array form, which was layout-sensitive.
// ANGLE writes GLSL arrays as metal::array, a struct around the array that the private-array fixes don't match: such an
// alloca becomes the array itself, before them. NVAIR_ARRAY_STRUCT_FIX. (n44, n45, n46)
static unsigned unwrapArrayStructs(LLVMModuleRef module, Gen &g) {
    enum { kStructKind = 10, kArrayKind = 11 };
    std::vector<LLVMValueRef> allocas;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMIsAAllocaInst(inst)) allocas.push_back(inst);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef alloca : allocas) {
        LLVMTypeRef wrapper = LLVMGetAllocatedType(alloca);
        if (LLVMGetTypeKind(wrapper) != kStructKind || LLVMCountStructElementTypes(wrapper) != 1) continue;
        LLVMTypeRef array;
        LLVMGetStructElementTypes(wrapper, &array);
        if (LLVMGetTypeKind(array) != kArrayKind) continue;
        // the GEPs that step into the array: (s, 0, 0, ...) with constant zeros
        std::vector<LLVMValueRef> geps;
        for (LLVMUseRef u = LLVMGetFirstUse(alloca); u; u = LLVMGetNextUse(u)) {
            LLVMValueRef gep = LLVMGetUser(u);
            if (LLVMIsAGetElementPtrInst(gep) && LLVMGetOperand(gep, 0) == alloca && LLVMGetNumOperands(gep) >= 3 &&
                LLVMIsAConstantInt(LLVMGetOperand(gep, 1)) && !LLVMConstIntGetZExtValue(LLVMGetOperand(gep, 1)) &&
                LLVMIsAConstantInt(LLVMGetOperand(gep, 2)) && !LLVMConstIntGetZExtValue(LLVMGetOperand(gep, 2)))
                geps.push_back(gep);
        }
        if (geps.empty()) continue;
        if (!b) b = LLVMCreateBuilderInContext(g.context);
        LLVMPositionBuilderBefore(b, alloca);
        LLVMValueRef plain = LLVMBuildAlloca(b, array, "");
        LLVMSetAlignment(plain, LLVMGetAlignment(alloca));
        for (LLVMValueRef gep : geps) {
            unsigned n = LLVMGetNumOperands(gep);
            LLVMValueRef replacement = plain;  // (s, 0, 0): the array
            if (n > 3) {
                std::vector<LLVMValueRef> indices;
                indices.push_back(LLVMGetOperand(gep, 1));
                for (unsigned i = 3; i < n; i++) indices.push_back(LLVMGetOperand(gep, i));
                LLVMPositionBuilderBefore(b, gep);
                replacement = LLVMBuildGEP(b, plain, indices.data(), (unsigned)indices.size(), "");
            }
            LLVMReplaceAllUsesWith(gep, replacement);
            LLVMInstructionEraseFromParent(gep);
        }
        if (LLVMGetFirstUse(alloca)) {  // the rest see the same memory through the struct's pointer type
            LLVMPositionBuilderBefore(b, alloca);
            LLVMReplaceAllUsesWith(alloca, LLVMBuildBitCast(b, plain, LLVMTypeOf(alloca), ""));
        }
        LLVMInstructionEraseFromParent(alloca);
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
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
        if (!getenv("NVAIR_PRIVATE_ARRAY_WORDS")) {  // keep the byte array, each load's value masked (see above)
            if (!b) b = LLVMCreateBuilderInContext(g.context);
            for (LLVMValueRef gep : geps) {
                std::vector<LLVMValueRef> loads;
                for (LLVMUseRef v = LLVMGetFirstUse(gep); v; v = LLVMGetNextUse(v))
                    if (LLVMIsALoadInst(LLVMGetUser(v))) loads.push_back(LLVMGetUser(v));
                for (LLVMValueRef load : loads) {
                    LLVMUseRef first = LLVMGetFirstUse(load);  // already masked by an earlier run: zext feeding the min
                    LLVMValueRef u0 = first ? LLVMGetUser(first) : nullptr;
                    if (u0 && LLVMIsAInstruction(u0) && LLVMGetInstructionOpcode(u0) == LLVMZExt && LLVMGetFirstUse(u0) &&
                        LLVMIsACallInst(LLVMGetUser(LLVMGetFirstUse(u0))))
                        continue;
                    LLVMValueRef next = LLVMGetNextInstruction(load);
                    if (!next) continue;
                    LLVMPositionBuilderBefore(b, next);
                    LLVMValueRef z = LLVMBuildZExt(b, load, g.i32, "");
                    LLVMValueRef m = g.opaqueMin(b, z, g.c32(~0u));
                    LLVMValueRef t = LLVMBuildTrunc(b, LLVMBuildAnd(b, m, g.c32(width == 8 ? 0xffu : 0xffffu), ""), element, "");
                    LLVMReplaceAllUsesWith(load, t);
                    LLVMSetOperand(z, 0, load);
                }
            }
            fixed++;
            continue;
        }
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

// ---- device loads in fragment functions at a negative 32-bit index --------------------------------------------------
// Kepler faults on a load outside every buffer (a later command buffer fails), and helper lanes of ANGLE's PBO-upload
// shaders compute wrapped indices: in fragment modules a 32-bit index with its top bit set, beyond any buffer on a 2 GB
// card, reads element 0 instead. NVAIR_FRAGMENT_LOAD_GUARD. (n07)
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
// The plugin ends a discarded lane, so its quad's later derivatives are 0, where Metal 2.3 and WGSL keep it as a
// helper: a discard sets a flag, the lane runs on with its stores skipped, and is discarded on return.
// NVAIR_DEMOTE_DISCARD. (n10)
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
// Whether code that needs the quad's other lanes (helpersNeeded) can run after this discard: the rest of its block and
// every block reachable from there.
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

// ---- 32-bit products of 16-bit factors ------------------------------------------------------------------------------
// With both factors known to fit in 16 bits the back end took the product's top bit for clear (and an or with a product
// for an add): one factor, and a product an or uses, go through the opaque min. NVAIR_NARROW_MULTIPLY_FIX (n03);
// products of a narrow value and a wide constant reach their users the same way, NVAIR_WIDE_CONSTANT_PRODUCT_FIX (n42).
enum { LLVMMul = 12, LLVMAnd = 23, LLVMOr = 24, LLVMXor = 25, LLVMSelect = 46 };
// Known to fit in 16 bits: a constant up to 0xffff, a zero-extended byte or halfword, an and with such a value, an or /
// xor / select of two such values, a shift right by 16 or more (what LLVM leaves of ushort casts, masks and | 0x8000).
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
    bool wideConstants = !disabled("NVAIR_WIDE_CONSTANT_PRODUCT_FIX");
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
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
                    LLVMValueRef hidden = g.opaqueMin(b, inst, g.c32(~0u));
                    for (LLVMValueRef user : ors)
                        for (unsigned i = 0; i < 2; i++)
                            if (LLVMGetOperand(user, i) == inst) LLVMSetOperand(user, i, hidden);
                    fixed++;
                    inst = hidden;  // continue after it
                    continue;
                }
                LLVMValueRef x = LLVMGetOperand(inst, 0), y = LLVMGetOperand(inst, 1);
                // a narrow factor times a constant wider than 16 bits: the product reaches its users through the opaque min
                if (wideConstants && LLVMIsAConstantInt(y) && LLVMConstIntGetZExtValue(y) > 0xffffu && !LLVMIsAConstantInt(x) &&
                    narrowFactor(x)) {
                    LLVMValueRef next = LLVMGetNextInstruction(inst);
                    if (!next) continue;
                    if (!b) b = LLVMCreateBuilderInContext(g.context);
                    LLVMPositionBuilderBefore(b, next);
                    LLVMValueRef hidden = g.opaqueMin(b, inst, g.c32(~0u));
                    LLVMReplaceAllUsesWith(inst, hidden);
                    LLVMSetOperand(hidden, 0, inst);
                    fixed++;
                    inst = hidden;  // continue after it
                    continue;
                }
                if (!narrowFactor(x) || !narrowFactor(y) || LLVMIsAConstantInt(x)) continue;
                if (!b) b = LLVMCreateBuilderInContext(g.context);
                LLVMPositionBuilderBefore(b, inst);
                LLVMValueRef hidden = g.opaqueMin(b, x, g.c32(~0u));
                LLVMSetOperand(inst, 0, hidden);
                fixed++;
            }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- entry points and hidden buffer arguments (texture atomics, depth channels) -------------------------------------
extern "C" void functionCopyAttributesFrom(void *function, const void *source) asm("__ZN4llvm8Function18copyAttributesFromEPKNS_11GlobalValueE");
extern "C" void basicBlockInsertInto(void *block, void *function, void *before) asm("__ZN4llvm10BasicBlock10insertIntoEPNS_8FunctionEPS0_");

// Hidden buffer indices are taken from 30 down over the indices an entry point leaves free; vertex functions keep 0-16
// for vertex buffers. MetalOldCompat items 58 and 62 count them the same way from the pipeline's reflection.
enum { kBufferIndexCount = 31, kHighestHiddenBuffer = 30, kLowestVertexHiddenBuffer = 17 };
static int lowestHiddenBuffer(const char *list) { return !strcmp(list, "air.vertex") ? kLowestVertexHiddenBuffer : 0; }

struct EntryPoint { LLVMValueRef function; void *node; std::vector<LLVMValueRef> args; };
// The defined functions an entry-point list (air.kernel, air.fragment, air.vertex) names, with their argument metadata.
static std::vector<EntryPoint> entryPoints(LLVMModuleRef module, const char *list) {
    std::vector<EntryPoint> out;
    std::vector<LLVMValueRef> entries(LLVMGetNamedMetadataNumOperands(module, list));
    if (entries.empty()) return out;
    LLVMGetNamedMetadataOperands(module, list, entries.data());
    for (LLVMValueRef entry : entries) {
        std::vector<LLVMValueRef> parts = metadataOperands(entry);
        void *node = metadataOf(entry);
        if (parts.size() < 3 || !parts[0] || !node || LLVMIsDeclaration(parts[0])) continue;
        out.push_back({parts[0], node, metadataOperands(parts[2])});
    }
    return out;
}

static long metadataFieldAfter(const std::vector<LLVMValueRef> &f, const char *key, unsigned skip = 1) {
    for (size_t k = 0; k + skip < f.size(); k++)
        if (isString(f[k], key) && LLVMIsAConstantInt(f[k + skip])) return (long)LLVMConstIntGetZExtValue(f[k + skip]);
    return -1;
}
static bool isBufferArgument(const std::vector<LLVMValueRef> &f) {
    return isString(f[1], "air.buffer") || isString(f[1], "air.indirect_buffer");
}
static void markBufferIndices(const std::vector<LLVMValueRef> &f, bool used[kBufferIndexCount]) {
    long index = metadataFieldAfter(f, "air.location_index"), count = metadataFieldAfter(f, "air.location_index", 2);
    for (long k = 0; index >= 0 && k < (count > 0 ? count : 1); k++)
        if (index + k < kBufferIndexCount) used[index + k] = true;
}
// The highest free buffer index at or below `start`, or -1 if there is none down to `lowest`.
static int freeBufferIndex(const bool used[kBufferIndexCount], int start, int lowest) {
    while (start >= lowest && used[start]) start--;
    return start >= lowest ? start : -1;
}

// The entry point again with `extraCount` parameters of type `extra` after its own; the body and the uses of its
// parameters move over. The old function stays, empty, renamed with `suffix`: the plugin keeps pointers to it.
static LLVMValueRef rebuildWithParameters(LLVMModuleRef module, LLVMValueRef function, LLVMTypeRef extra, size_t extraCount,
                                          const char *suffix) {
    LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(function));
    unsigned params = LLVMCountParams(function);
    std::vector<LLVMTypeRef> types(LLVMCountParamTypes(type));
    LLVMGetParamTypes(type, types.data());
    types.insert(types.end(), extraCount, extra);
    std::string name = LLVMGetValueName(function);
    LLVMSetValueName(function, (name + suffix).c_str());
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
    return rebuilt;
}
// The argument metadata of a hidden uint buffer parameter; access is "air.read" or "air.read_write".
static LLVMValueRef hiddenBufferArgument(Gen &g, unsigned param, int bufferIndex, const char *access, const char *argName) {
    auto str = [&](const char *t) { return LLVMMDStringInContext(g.context, t, (unsigned)strlen(t)); };
    LLVMValueRef f[] = {g.c32(param), str("air.buffer"), str("air.location_index"), g.c32(bufferIndex), g.c32(1), str(access),
                        str("air.arg_type_size"), g.c32(4), str("air.arg_type_align_size"), g.c32(4),
                        str("air.arg_type_name"), str("uint"), str("air.arg_name"), str(argName)};
    return LLVMMDNodeInContext(g.context, f, sizeof f / sizeof *f);
}
// Points the entry point's metadata at `rebuilt` and the argument list `args`; false if the list can't be made.
static bool updateEntryPoint(Gen &g, void *node, LLVMValueRef rebuilt, std::vector<LLVMValueRef> &args) {
    void *argList = metadataOf(LLVMMDNodeInContext(g.context, args.data(), (unsigned)args.size()));
    if (!argList) return false;
    mdNodeReplaceOperand(node, 0, valueAsMetadata(rebuilt));
    mdNodeReplaceOperand(node, 2, argList);
    return true;
}

// ---- texture atomics on linear 2D textures (MetalOldCompat item 58) -------------------------------------------------
// The plugin can't compile texture atomics (the compiler crashed). Item 58 puts such textures in a buffer after a
// 256-byte header {magic, row pitch in words, width, height}; each atomic becomes a global one at word 64 + y * pitch +
// x (scratch word 8 when outside or headerless), the buffer at a hidden index per read_write texture2d<uint/int>
// argument. NVAIR_TEXTURE_ATOMICS. (a01, n04)
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
static std::vector<TexAtomicCall> textureAtomicCalls(LLVMModuleRef module) {
    std::vector<TexAtomicCall> calls;
    for (int op = 0; op < (int)(sizeof kTexAtomicOps / sizeof *kTexAtomicOps); op++)
        for (int s = 0; s < 4; s++) {  // s & 1: signed; s & 2: ushort coordinates
            char name[128];
            snprintf(name, sizeof name, "air.atomic_%s_explicit_texture_2d%s.%c.v4i32", kTexAtomicOps[op].air, s & 2 ? ".i16" : "",
                     s & 1 ? 's' : 'u');
            LLVMValueRef f = LLVMGetNamedFunction(module, name);
            if (!f) continue;
            for (LLVMValueRef c : callsTo(f)) calls.push_back({c, op, (s & 1) != 0});
        }
    return calls;
}
// The entry point's atomic textures as (binding, parameter) in binding order, each with its hidden buffer index;
// false if the free indices run out.
static bool atomicTextureBuffers(const std::vector<LLVMValueRef> &args, int lowest, std::vector<std::pair<long, long>> &textures,
                                 std::vector<int> &hidden) {
    bool used[kBufferIndexCount] = {false};
    for (LLVMValueRef arg : args) {
        std::vector<LLVMValueRef> f = metadataOperands(arg);
        if (f.size() < 2 || !LLVMIsAConstantInt(f[0])) continue;
        if (isBufferArgument(f)) markBufferIndices(f, used);
        else if (atomicTextureArgument(f)) textures.push_back({metadataFieldAfter(f, "air.location_index"), (long)LLVMConstIntGetZExtValue(f[0])});
    }
    std::sort(textures.begin(), textures.end());
    hidden.assign(textures.size(), -1);
    int next = kHighestHiddenBuffer;
    for (size_t t = 0; t < textures.size(); t++) {
        int index = freeBufferIndex(used, next, lowest);
        if (index < 0) return false;
        hidden[t] = index;
        next = index - 1;
    }
    return true;
}
// For each atomic, the position of its texture in `textures` (-1: not a texture argument, left as is), and the
// positions used, sorted.
static std::vector<size_t> texturesUsed(LLVMValueRef function, const std::vector<TexAtomicCall *> &atomics,
                                        const std::vector<std::pair<long, long>> &textures, std::vector<int> &callTexture) {
    std::vector<size_t> needed;
    callTexture.assign(atomics.size(), -1);
    for (size_t i = 0; i < atomics.size(); i++) {
        LLVMValueRef texture = LLVMGetOperand(atomics[i]->call, 0);
        for (size_t t = 0; t < textures.size(); t++)
            if (texture == LLVMGetParam(function, (unsigned)textures[t].second)) callTexture[i] = (int)t;
        if (callTexture[i] < 0) {
            if (logging()) fprintf(stderr, "[nvair] %s: a texture atomic not on a texture2d argument, left as is\n", LLVMGetValueName(function));
            continue;
        }
        if (std::find(needed.begin(), needed.end(), (size_t)callTexture[i]) == needed.end()) needed.push_back(callTexture[i]);
    }
    std::sort(needed.begin(), needed.end());
    return needed;
}
// One texture atomic as the plugin's global atomic on its texel in the linear buffer at `base`, or on the scratch word
// when the texel is outside the texture or the buffer has no header.
static void lowerTextureAtomic(Gen &g, LLVMBuilderRef b, const TexAtomicCall &atomic, LLVMValueRef base) {
    LLVMValueRef call = atomic.call;
    const auto &op = kTexAtomicOps[atomic.op];
    LLVMTypeRef global = LLVMPointerType(g.i32, 1);
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
    if (op.kind == kTACompareExchange) {
        LLVMTypeRef three[3] = {global, g.i32, g.i32};
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
        char nvvm[64];
        snprintf(nvvm, sizeof nvvm, "llvm.nvvm.atomic.%s.i32.p1i32", atomic.isSigned ? op.s : op.u);
        LLVMTypeRef two[2] = {global, g.i32};
        LLVMValueRef value = op.kind == kTALoad ? g.c32(0)
                           : LLVMBuildExtractElement(b, LLVMGetOperand(call, op.kind == kTAStore ? 1 : 2), g.c32(0), "");
        LLVMValueRef a[2] = {pointer, value};
        LLVMValueRef old = LLVMBuildCall(b, g.intrinsic(nvvm, g.i32, two, 2), a, 2, "");
        if (op.kind != kTAStore) LLVMReplaceAllUsesWith(call, LLVMBuildInsertElement(b, LLVMConstNull(LLVMVectorType(g.i32, 4)), old, g.c32(0), ""));
    }
    LLVMInstructionEraseFromParent(call);
}
static unsigned lowerTextureAtomics(LLVMModuleRef module, Gen &g) {
    std::vector<TexAtomicCall> calls = textureAtomicCalls(module);
    if (calls.empty()) return 0;
    LLVMTypeRef global = LLVMPointerType(g.i32, 1);
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    unsigned lowered = 0;
    for (const char *list : {"air.kernel", "air.fragment", "air.vertex"})
        for (EntryPoint &entry : entryPoints(module, list)) {
            LLVMValueRef function = entry.function;
            std::vector<TexAtomicCall *> atomics;
            for (TexAtomicCall &c : calls)
                if (LLVMGetBasicBlockParent(LLVMGetInstructionParent(c.call)) == function) atomics.push_back(&c);
            if (atomics.empty()) continue;
            std::vector<std::pair<long, long>> textures;  // (binding, parameter)
            std::vector<int> hidden;
            if (!atomicTextureBuffers(entry.args, lowestHiddenBuffer(list), textures, hidden)) {
                if (logging()) fprintf(stderr, "[nvair] %s: texture atomics, but no free buffer indices for them\n", LLVMGetValueName(function));
                continue;
            }
            std::vector<int> callTexture;
            std::vector<size_t> needed = texturesUsed(function, atomics, textures, callTexture);
            if (needed.empty()) continue;
            unsigned params = LLVMCountParams(function);
            LLVMValueRef rebuilt = rebuildWithParameters(module, function, global, needed.size(), ".nvta");
            std::vector<LLVMValueRef> args = entry.args;
            for (size_t k = 0; k < needed.size(); k++) {
                char argName[32];
                snprintf(argName, sizeof argName, "__nvta_%ld", textures[needed[k]].first);
                LLVMSetValueName(LLVMGetParam(rebuilt, params + (unsigned)k), argName);
                args.push_back(hiddenBufferArgument(g, params + (unsigned)k, hidden[needed[k]], "air.read_write", argName));
            }
            if (!updateEntryPoint(g, entry.node, rebuilt, args)) continue;  // (can't happen for a fresh node)
            for (size_t i = 0; i < atomics.size(); i++) {
                if (callTexture[i] < 0) continue;
                size_t position = std::find(needed.begin(), needed.end(), (size_t)callTexture[i]) - needed.begin();
                lowerTextureAtomic(g, b, *atomics[i], LLVMGetParam(rebuilt, params + (unsigned)position));
                lowered++;
            }
            if (logging()) {
                fprintf(stderr, "[nvair] %s: %zu texture atomic(s) on linear texture buffers", LLVMGetValueName(rebuilt), atomics.size());
                for (size_t k = 0; k < needed.size(); k++) fprintf(stderr, " texture(%ld)->buffer(%d)", textures[needed[k]].first, hidden[needed[k]]);
                fprintf(stderr, "\n");
            }
        }
    LLVMDisposeBuilder(b);
    return lowered;
}

// ---- depth / stencil textures' channels in ANGLE's shaders (MetalOldCompat item 62) ---------------------------------
// Kepler's sampler returns (d, d, d, d) for depth and (s, s, s, s) for stencil where OpenGL ES wants (x, 0, 0, 1): in
// ANGLE's shaders a sample or read of texture argument n gives (x, 0, 0, 1) when bit n of a mask is set, at the next
// hidden index after item 58's (item 62 fills it per draw). NVAIR_DEPTH_CHANNELS. (n11)
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
// The 4-channel samples and reads of the given texture arguments (binding, parameter), each with its binding.
static std::vector<std::pair<LLVMValueRef, long>> textureSamplesAndReads(LLVMValueRef function, const std::vector<std::pair<long, long>> &textures) {
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
    return calls;
}
// The call's (x, y, z, w) becomes (x, 0, 0, 1) where bit `binding` of the mask is set.
static void applyDepthChannelMask(Gen &g, LLVMBuilderRef b, LLVMValueRef call, LLVMValueRef mask, long binding) {
    LLVMPositionBuilderBefore(b, LLVMGetNextInstruction(call));
    LLVMValueRef index = g.c32((unsigned)(binding / 32));
    LLVMValueRef word = LLVMBuildLoad(b, LLVMBuildGEP(b, mask, &index, 1, ""), "");
    LLVMValueRef bit = LLVMBuildAnd(b, LLVMBuildLShr(b, word, g.c32((unsigned)(binding % 32)), ""), g.c32(1), "");
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
}
static unsigned fixDepthChannels(LLVMModuleRef module, Gen &g) {
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (const char *list : {"air.fragment", "air.vertex"})
        for (EntryPoint &entry : entryPoints(module, list)) {
            bool used[kBufferIndexCount] = {false}, angle = false;
            std::vector<std::pair<long, long>> textures;  // (binding, parameter)
            for (LLVMValueRef arg : entry.args) {
                std::vector<LLVMValueRef> f = metadataOperands(arg);
                if (f.size() < 2 || !LLVMIsAConstantInt(f[0])) continue;
                if (isBufferArgument(f)) {
                    markBufferIndices(f, used);
                    angle |= argumentNamed(f, "ANGLE_angleUniforms");
                } else if (isString(f[1], "air.texture") && !depthTextureArgument(f)) {
                    textures.push_back({metadataFieldAfter(f, "air.location_index"), (long)LLVMConstIntGetZExtValue(f[0])});
                }
            }
            if (!angle || textures.empty()) continue;
            int hidden = freeBufferIndex(used, kHighestHiddenBuffer, lowestHiddenBuffer(list));
            if (hidden < 0) continue;
            std::vector<std::pair<LLVMValueRef, long>> calls = textureSamplesAndReads(entry.function, textures);
            if (calls.empty()) continue;
            unsigned params = LLVMCountParams(entry.function);
            LLVMValueRef rebuilt = rebuildWithParameters(module, entry.function, LLVMPointerType(g.i32, 2), 1, ".nvds");
            LLVMValueRef mask = LLVMGetParam(rebuilt, params);
            LLVMSetValueName(mask, "__nvds");
            std::vector<LLVMValueRef> args = entry.args;
            args.push_back(hiddenBufferArgument(g, params, hidden, "air.read", "__nvds"));
            if (!updateEntryPoint(g, entry.node, rebuilt, args)) continue;
            if (!b) b = LLVMCreateBuilderInContext(g.context);
            for (auto &c : calls) {
                applyDepthChannelMask(g, b, c.first, mask, c.second);
                fixed++;
            }
            if (logging())
                fprintf(stderr, "[nvair] %s: %zu texture sample(s) / read(s) given depth channels, mask at buffer %d\n", LLVMGetValueName(rebuilt), calls.size(), hidden);
        }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- large copies as loops ------------------------------------------------------------------------------------------
// The back end's time is about cubic in a constant-length memcpy's size (a WebGPU CTS kernel took 13 minutes): copies
// of 64 bytes or more, whole words, become word loops with the trip count behind the opaque min. NVAIR_LARGE_COPY_LOOP.
// (n12)
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
    LLVMValueRef count = g.opaqueMin(b, LLVMGetParam(f, 2), g.c32(~0u));
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

// ---- half vectors spelled as bitcasts in constants ------------------------------------------------------------------
// A constant half2x2 array arrives with each column as a bitcast constant expression, which crashes the plugin's
// constant lowering: such bitcasts in global initializers become plain half vectors. NVAIR_HALF_CONSTANT_FIX. (n13)
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

// ---- private arrays: loads at a constant index ----------------------------------------------------------------------
// The back end took two loads of one private-array element at a constant index for one value across a store at a
// variable index: such loads get an always-zero index from the thread position, a different one each.
// NVAIR_PRIVATE_CONSTANT_LOAD_FIX (n26), NVAIR_PRIVATE_CONSTANT_GRAPHICS_FIX (n31); loads after the last store stay,
// NVAIR_PRIVATE_FINAL_LOADS_FIX=0 too (n40).
static bool loadAfterLastStore(LLVMValueRef load, LLVMValueRef array) {
    LLVMValueRef term = LLVMGetBasicBlockTerminator(LLVMGetInstructionParent(load));
    if (!term || LLVMGetInstructionOpcode(term) != 1) return false;  // ret
    for (LLVMValueRef i = LLVMGetNextInstruction(load); i; i = LLVMGetNextInstruction(i)) {
        if (!LLVMIsAStoreInst(i)) continue;
        LLVMValueRef ptr = LLVMGetOperand(i, 1);
        if (ptr == array || (LLVMIsAGetElementPtrInst(ptr) && LLVMGetOperand(ptr, 0) == array)) return false;
    }
    return true;
}
static unsigned fixPrivateConstantLoads(LLVMModuleRef module, Gen &g) {
    bool graphics = !disabled("NVAIR_PRIVATE_CONSTANT_GRAPHICS_FIX"), finalLoads = !disabled("NVAIR_PRIVATE_FINAL_LOADS_FIX");
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (const char *list : {"air.kernel", "air.fragment", "air.vertex"}) {
    bool kernel = !strcmp(list, "air.kernel");
    if (!kernel && !graphics) continue;
    std::vector<LLVMValueRef> entries(LLVMGetNamedMetadataNumOperands(module, list));
    if (entries.empty()) continue;
    LLVMGetNamedMetadataOperands(module, list, entries.data());
    for (LLVMValueRef entry : entries) {
        std::vector<LLVMValueRef> parts = metadataOperands(entry);
        LLVMValueRef f = parts.empty() ? nullptr : parts[0];
        if (!f || LLVMIsDeclaration(f) || !LLVMGetFirstBasicBlock(f)) continue;
        // the value to make the opaque 0 from, (x + k) >> 31 being 0 for any k the pass uses: a kernel's thread position
        // in the threadgroup (below 1024) if it has it, else in the grid; a fragment function's position (x, a float of
        // at least 0, whose bits are below 2^31); a vertex function's vertex_id. None: left alone
        LLVMValueRef position = nullptr;
        bool inGroup = false;
        for (LLVMValueRef arg : parts.size() > 2 ? metadataOperands(parts[2]) : std::vector<LLVMValueRef>()) {
            std::vector<LLVMValueRef> fields = metadataOperands(arg);
            if (fields.size() < 2 || !LLVMIsAConstantInt(fields[0]) || LLVMConstIntGetZExtValue(fields[0]) >= LLVMCountParams(f)) continue;
            LLVMValueRef param = LLVMGetParam(f, (unsigned)LLVMConstIntGetZExtValue(fields[0]));
            if (kernel) {
                bool group = isString(fields[1], "air.thread_position_in_threadgroup") || isString(fields[1], "air.thread_index_in_threadgroup");
                if ((group && !inGroup) || (!position && isString(fields[1], "air.thread_position_in_grid"))) position = param, inGroup = group;
            } else if (!position && (isString(fields[1], "air.position") || isString(fields[1], "air.vertex_id"))) {
                position = param;
            }
        }
        if (!position) continue;
        LLVMBasicBlockRef first = LLVMGetEntryBasicBlock(f);
        LLVMValueRef zero = nullptr;  // position.x as i32, read at the first array that needs it
        for (LLVMValueRef a = LLVMGetFirstInstruction(first); a; a = LLVMGetNextInstruction(a)) {
            if (!LLVMIsAAllocaInst(a) || LLVMGetTypeKind(LLVMGetElementType(LLVMTypeOf(a))) != LLVMArrayTypeKind) continue;
            // the array's element GEPs [0, i]: one with a variable i makes the constant ones candidates
            std::vector<LLVMValueRef> constant;
            bool variable = false;
            for (LLVMUseRef u = LLVMGetFirstUse(a); u; u = LLVMGetNextUse(u)) {
                LLVMValueRef gep = LLVMIsAGetElementPtrInst(LLVMGetUser(u));
                if (!gep || LLVMGetNumOperands(gep) != 3 || LLVMGetOperand(gep, 0) != a) continue;
                LLVMValueRef i0 = LLVMGetOperand(gep, 1), i1 = LLVMGetOperand(gep, 2);
                if (!LLVMIsAConstantInt(i0) || LLVMConstIntGetZExtValue(i0) != 0) continue;
                if (LLVMIsAConstantInt(i1)) constant.push_back(gep);
                else variable = true;
            }
            if (!variable || constant.empty()) continue;
            for (LLVMValueRef gep : constant) {
                std::vector<LLVMValueRef> loads;
                for (LLVMUseRef u = LLVMGetFirstUse(gep); u; u = LLVMGetNextUse(u)) {
                    LLVMValueRef load = LLVMIsALoadInst(LLVMGetUser(u));
                    if (load && LLVMGetOperand(load, 0) == gep) loads.push_back(load);
                }
                for (LLVMValueRef load : loads) {
                    if (finalLoads && loadAfterLastStore(load, a)) continue;
                    if (!b) b = LLVMCreateBuilderInContext(g.context);
                    if (!zero) {  // position.x, once
                        LLVMValueRef at = LLVMGetFirstInstruction(first);
                        while (at && LLVMIsAAllocaInst(at)) at = LLVMGetNextInstruction(at);
                        LLVMPositionBuilderBefore(b, at);
                        LLVMValueRef x = position;
                        if (LLVMGetTypeKind(LLVMTypeOf(x)) == LLVMVectorTypeKind) x = LLVMBuildExtractElement(b, x, LLVMConstInt(g.i32, 0, 0), "");
                        if (LLVMTypeOf(x) == LLVMFloatTypeInContext(g.context)) x = LLVMBuildBitCast(b, x, g.i32, "");  // position.x
                        if (!isInt(LLVMTypeOf(x), 32)) break;
                        zero = x;
                    }
                    // each load its own 0, (position.x + k) >> 31: one shared 0 would leave the addresses equal to the back end
                    LLVMValueRef k = LLVMGetOperand(gep, 2);  // the index, in its own type (i64 from Metal's front end)
                    LLVMTypeRef kt = LLVMTypeOf(k);
                    if (LLVMGetTypeKind(kt) != LLVMIntegerTypeKind || LLVMGetIntTypeWidth(kt) < 32) continue;
                    LLVMPositionBuilderBefore(b, load);
                    LLVMValueRef own = LLVMBuildLShr(b, LLVMBuildAdd(b, zero, LLVMConstInt(g.i32, (fixed & 0xffff) + 1, 0), ""), LLVMConstInt(g.i32, 31, 0), "");
                    if (LLVMGetIntTypeWidth(kt) > 32) own = LLVMBuildZExt(b, own, kt, "");
                    LLVMValueRef index[2] = {LLVMGetOperand(gep, 1), LLVMBuildAdd(b, k, own, "")};
                    LLVMSetOperand(load, 0, LLVMBuildGEP(b, a, index, 2, ""));
                    fixed++;
                }
            }
        }
    }
    }  // the entry lists
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- overflow intrinsics --------------------------------------------------------------------------------------------
// The back end can't select LLVM's *.with.overflow intrinsics, which the front end and the plugin's optimizer make of
// overflow checks: each becomes plain arithmetic plus a compare or the product's high half. NVAIR_OVERFLOW_FIX. (n28)
static unsigned fixOverflowIntrinsics(LLVMModuleRef module, Gen &g) {
    std::vector<LLVMValueRef> functions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *n = LLVMGetValueName(f);
        if (!strncmp(n, "llvm.", 5) && strstr(n, ".with.overflow.i") && LLVMGetFirstUse(f)) functions.push_back(f);
    }
    unsigned fixed = 0;
    if (functions.empty()) return 0;
    // a builder of its own (makeGen leaves g.b null), lent to g for mulHi
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context), saved = g.b;
    g.b = b;
    for (LLVMValueRef f : functions) {
        const char *n = LLVMGetValueName(f) + 5;  // {u,s}{add,sub,mul}.with.overflow.i<w>
        bool isSigned = n[0] == 's';
        int op = !strncmp(n + 1, "add.", 4) ? 0 : !strncmp(n + 1, "sub.", 4) ? 1 : !strncmp(n + 1, "mul.", 4) ? 2 : -1;
        unsigned w = (unsigned)atoi(strstr(n, ".with.overflow.i") + 16);
        if ((n[0] != 'u' && n[0] != 's') || op < 0 || (w != 8 && w != 16 && w != 32 && w != 64)) continue;
        std::vector<LLVMValueRef> calls = callsTo(f, 2);
        for (LLVMValueRef call : calls) {
            LLVMValueRef x = LLVMGetOperand(call, 0), y = LLVMGetOperand(call, 1), r, ov;
            LLVMTypeRef t = LLVMTypeOf(x);
            if (!isInt(t, w)) continue;
            LLVMPositionBuilderBefore(b, call);
            LLVMValueRef zero = LLVMConstInt(t, 0, 0);
            // the overflow bits compare against values the optimizer can't see through, behind the plugin's own
            // llvm.nvvm.min.u.i32: against constants, InstCombine folds them straight back into the intrinsics (the plugin
            // optimizes between the runs of this pass)
            LLVMTypeRef i32 = g.i32, i64 = LLVMInt64TypeInContext(g.context);
            auto minU = [&](LLVMValueRef v, unsigned long long k) { return g.opaqueMin(b, v, g.c32(k)); };
            auto to32 = [&](LLVMValueRef v) { return w == 32 ? v : LLVMBuildZExt(b, v, i32, ""); };
            if (op == 0) {  // signed: x and y of one sign, the sum of the other; unsigned: the sum below x
                r = LLVMBuildAdd(b, x, y, "");
                if (isSigned)
                    ov = LLVMBuildICmp(b, LLVMIntSLT, LLVMBuildAnd(b, LLVMBuildXor(b, x, r, ""), LLVMBuildXor(b, y, r, ""), ""), zero, "");
                else
                    ov = w == 64 ? LLVMBuildICmp(b, LLVMIntULT, r, x, "") : LLVMBuildICmp(b, LLVMIntULT, to32(r), minU(to32(x), 0xffffffff), "");
            } else if (op == 1) {  // signed: x and y of different signs, the difference of y's; unsigned: x below y
                r = LLVMBuildSub(b, x, y, "");
                ov = isSigned ? LLVMBuildICmp(b, LLVMIntSLT, LLVMBuildAnd(b, LLVMBuildXor(b, x, y, ""), LLVMBuildXor(b, x, r, ""), ""), zero, "")
                              : LLVMBuildICmp(b, LLVMIntULT, x, y, "");
            } else if (w == 64) {
                r = LLVMBuildMul(b, x, y, "");
                LLVMValueRef hi = g.mulHi(x, y, isSigned);
                ov = LLVMBuildICmp(b, LLVMIntNE, hi, isSigned ? LLVMBuildAShr(b, r, LLVMConstInt(t, 63, 0), "") : zero, "");
            } else {  // the exact product in i64 (sign extension as a shift left and an arithmetic shift right)
                LLVMValueRef s = LLVMConstInt(i64, 64 - w, 0), k = LLVMConstInt(i64, w, 0);
                auto wide = [&](LLVMValueRef v) {
                    LLVMValueRef z = LLVMBuildZExt(b, v, i64, "");
                    return isSigned ? LLVMBuildAShr(b, LLVMBuildShl(b, z, s, ""), s, "") : z;
                };
                LLVMValueRef product = LLVMBuildMul(b, wide(x), wide(y), "");
                r = LLVMBuildTrunc(b, product, t, "");
                // d: the high half (unsigned), or the high half xor the sign of the low half (signed); 0 unless it overflowed
                LLVMValueRef d;
                if (!isSigned) {
                    d = LLVMBuildTrunc(b, LLVMBuildLShr(b, product, k, ""), i32, "");
                } else {
                    LLVMValueRef sign = LLVMBuildAShr(b, LLVMBuildShl(b, product, s, ""), LLVMConstInt(i64, 63, 0), "");
                    d = LLVMBuildTrunc(b, LLVMBuildXor(b, LLVMBuildAShr(b, product, k, ""), sign, ""), i32, "");
                }
                ov = LLVMBuildICmp(b, LLVMIntNE, d, minU(d, 0), "");
            }
            LLVMValueRef v = LLVMBuildInsertValue(b, LLVMBuildInsertValue(b, LLVMGetUndef(LLVMTypeOf(call)), r, 0, ""), ov, 1, "");
            LLVMReplaceAllUsesWith(call, v);
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    g.b = saved;
    LLVMDisposeBuilder(b);
    return fixed;
}

// ---- saturating multiply-add ----------------------------------------------------------------------------------------
// madsat came out saturated for a zero product in a big kernel (a carry into the 64-bit high word): each call gets the
// adapter's body, with the carry from a compare instead of a 64-bit add. NVAIR_MAD_SAT_FIX. (n30)
static unsigned lowerMadSat(LLVMModuleRef module, Gen &g) {
    std::vector<LLVMValueRef> functions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        if (!strncmp(LLVMGetValueName(f), "air.mad_sat.", 12) && LLVMGetFirstUse(f)) functions.push_back(f);
    if (functions.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    LLVMTypeRef i32 = g.i32, i64 = LLVMInt64TypeInContext(g.context);
    auto c32 = [&](unsigned long long v) { return LLVMConstInt(i32, v, 0); };
    auto minU = [&](LLVMValueRef v, unsigned long long k) { return g.opaqueMin(b, v, g.c32(k)); };
    auto nonzero = [&](LLVMValueRef v) { return LLVMBuildICmp(b, LLVMIntNE, v, minU(v, 0), ""); };  // v != 0, opaquely
    unsigned fixed = 0;
    for (LLVMValueRef f : functions) {
        const char *n = LLVMGetValueName(f) + 12;  // u.i32, s.i16, ...
        bool isSigned = n[0] == 's';
        if ((n[0] != 'u' && n[0] != 's') || strncmp(n + 1, ".i", 2)) continue;  // scalar forms
        unsigned w = (unsigned)atoi(n + 3);
        if (w != 8 && w != 16 && w != 32) continue;
        std::vector<LLVMValueRef> calls = callsTo(f, 3);
        for (LLVMValueRef call : calls) {
            LLVMValueRef x = LLVMGetOperand(call, 0), y = LLVMGetOperand(call, 1), z = LLVMGetOperand(call, 2);
            LLVMTypeRef t = LLVMTypeOf(x);
            if (!isInt(t, w) || LLVMTypeOf(call) != t) continue;
            LLVMPositionBuilderBefore(b, call);
            LLVMValueRef maxT = LLVMConstInt(t, isSigned ? (1ull << (w - 1)) - 1 : (w == 32 ? 0xffffffffull : (1ull << w) - 1), 0);
            LLVMValueRef minT = LLVMConstInt(t, isSigned ? 1ull << (w - 1) : 0, 0);
            LLVMValueRef r;
            if (w < 32) {  // exact in 32 bits
                LLVMValueRef s = c32(32 - w);
                auto wide = [&](LLVMValueRef v) {
                    LLVMValueRef zx = LLVMBuildZExt(b, v, i32, "");
                    return isSigned ? LLVMBuildAShr(b, LLVMBuildShl(b, zx, s, ""), s, "") : zx;
                };
                LLVMValueRef p = LLVMBuildAdd(b, LLVMBuildMul(b, wide(x), wide(y), ""), wide(z), "");
                LLVMValueRef lo = LLVMBuildTrunc(b, p, t, "");
                if (!isSigned) {
                    r = LLVMBuildSelect(b, nonzero(LLVMBuildLShr(b, p, c32(w), "")), maxT, lo, "");
                } else {  // in range when p >> (w - 1) is 0 or -1, that is when (it + 1) >> 1 (unsigned) is 0
                    LLVMValueRef e = LLVMBuildLShr(b, LLVMBuildAdd(b, LLVMBuildAShr(b, p, c32(w - 1), ""), c32(1), ""), c32(1), "");
                    LLVMValueRef limit = LLVMBuildSelect(b, LLVMBuildICmp(b, LLVMIntSLT, p, c32(0), ""), minT, maxT, "");
                    r = LLVMBuildSelect(b, nonzero(e), limit, lo, "");
                }
            } else {  // the 64-bit product's two words, plus c with the carry from a compare
                LLVMValueRef s = LLVMConstInt(i64, 32, 0);
                auto wide = [&](LLVMValueRef v) {
                    LLVMValueRef zx = LLVMBuildZExt(b, v, i64, "");
                    return isSigned ? LLVMBuildAShr(b, LLVMBuildShl(b, zx, s, ""), s, "") : zx;
                };
                LLVMValueRef prod = LLVMBuildMul(b, wide(x), wide(y), "");
                LLVMValueRef plo = LLVMBuildTrunc(b, prod, i32, ""), phi = LLVMBuildTrunc(b, LLVMBuildLShr(b, prod, s, ""), i32, "");
                LLVMValueRef sum = LLVMBuildAdd(b, plo, z, "");
                LLVMValueRef carry = LLVMBuildZExt(b, LLVMBuildICmp(b, LLVMIntULT, sum, minU(plo, 0xffffffff), ""), i32, "");
                if (!isSigned) {
                    r = LLVMBuildSelect(b, nonzero(LLVMBuildAdd(b, phi, carry, "")), maxT, sum, "");
                } else {  // high word: phi + (c's sign word) + carry; in range when it is the sign word of the low word
                    LLVMValueRef shi = LLVMBuildAdd(b, LLVMBuildAdd(b, phi, LLVMBuildAShr(b, z, c32(31), ""), ""), carry, "");
                    LLVMValueRef d = LLVMBuildXor(b, shi, LLVMBuildAShr(b, sum, c32(31), ""), "");
                    LLVMValueRef limit = LLVMBuildSelect(b, LLVMBuildICmp(b, LLVMIntSLT, shi, c32(0), ""), minT, maxT, "");
                    r = LLVMBuildSelect(b, nonzero(d), limit, sum, "");
                }
            }
            LLVMReplaceAllUsesWith(call, r);
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    LLVMDisposeBuilder(b);
    return fixed;
}

// ---- remainder by a divisor that turns out to be 1 ------------------------------------------------------------------
// A 32-bit remainder by a variable divisor of 1 went wrong in some register contexts (the division's final correction
// always runs for 1): x % b becomes select(b == 1, 0, x % b), the arm through the opaque min. NVAIR_DIVISOR_ONE_FIX.
// (n32)
static unsigned guardDivisorOne(LLVMModuleRef module, Gen &g) {
    std::vector<LLVMValueRef> divs;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int op = LLVMGetInstructionOpcode(inst);
                if ((op != LLVMURem && op != LLVMSRem) || !isInt(LLVMTypeOf(inst), 32)) continue;  // remainders only (below)
                if (LLVMIsAConstant(LLVMGetOperand(inst, 1))) continue;  // a constant divisor isn't 1 (or is folded)
                // guarded on an earlier run: its only use is our select
                LLVMUseRef u = LLVMGetFirstUse(inst);
                if (u && !LLVMGetNextUse(u)) {
                    LLVMValueRef user = LLVMGetUser(u);
                    if (LLVMIsASelectInst(user) && LLVMGetOperand(user, 2) == inst) {
                        LLVMValueRef c = LLVMGetOperand(user, 0);
                        if (LLVMIsAICmpInst(c) && LLVMGetOperand(c, 0) == LLVMGetOperand(inst, 1) && LLVMIsAConstantInt(LLVMGetOperand(c, 1)) &&
                            LLVMConstIntGetZExtValue(LLVMGetOperand(c, 1)) == 1)
                            continue;
                    }
                }
                divs.push_back(inst);
            }
    if (divs.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    unsigned n = 0;
    for (LLVMValueRef inst : divs) {
        LLVMValueRef next = LLVMGetNextInstruction(inst);
        if (!next) continue;
        LLVMValueRef d = LLVMGetOperand(inst, 1);
        LLVMPositionBuilderBefore(b, next);
        LLVMValueRef special = g.opaqueMin(b, LLVMBuildAnd(b, d, g.c32(0), ""), g.c32(0xffffffff));  // 0
        LLVMValueRef r = LLVMBuildSelect(b, LLVMBuildICmp(b, LLVMIntEQ, d, g.c32(1), ""), special, inst, "");
        LLVMReplaceAllUsesWith(inst, r);
        LLVMSetOperand(r, 2, inst);
        n++;
    }
    LLVMDisposeBuilder(b);
    return n;
}

// ---- a 2- or 4-lane vector of 8- or 16-bit integers masked or shifted with a constant -------------------------------
// An and with a constant, or shifts by per-lane constant amounts, of a 2- or 4-lane 8/16-bit vector lost bits: done
// lane by lane (Kepler takes such vectors apart anyway). NVAIR_VECTOR_CONSTANT_FIX. (n35)
static bool perLaneAmounts(LLVMValueRef c) {  // a constant vector whose lanes aren't all the same constant
    if (!LLVMIsAConstant(c)) return false;
    bool dv = LLVMIsAConstantDataVector(c), cv = LLVMIsAConstantVector(c);
    if (!dv && !cv) return false;  // zeroinitializer and the like
    unsigned long long first = 0;
    for (unsigned i = 0, n = LLVMGetVectorSize(LLVMTypeOf(c)); i < n; i++) {
        LLVMValueRef e = dv ? LLVMGetElementAsConstant(c, i) : LLVMGetOperand(c, i);
        if (!e || !LLVMIsAConstantInt(e)) continue;  // an undef lane: any amount
        unsigned long long v = LLVMConstIntGetZExtValue(e);
        if (i && v != first) return true;
        first = v;
    }
    return false;
}
static unsigned scalarizeConstantLaneOps(LLVMModuleRef module, Gen &g) {
    enum { kShl = 20, kLShr = 21, kAShr = 22, kAnd = 23 };
    std::vector<LLVMValueRef> ops;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int op = LLVMGetInstructionOpcode(inst);
                if (op != kAnd && op != kShl && op != kLShr && op != kAShr) continue;
                LLVMTypeRef t = LLVMTypeOf(inst);
                if (LLVMGetTypeKind(t) != LLVMVectorTypeKind || (LLVMGetVectorSize(t) != 2 && LLVMGetVectorSize(t) != 4)) continue;
                LLVMTypeRef e = LLVMGetElementType(t);
                if (LLVMGetTypeKind(e) != LLVMIntegerTypeKind || LLVMGetIntTypeWidth(e) > 16) continue;
                if (op == kAnd ? !LLVMIsAConstant(LLVMGetOperand(inst, 0)) && !LLVMIsAConstant(LLVMGetOperand(inst, 1))
                               : !perLaneAmounts(LLVMGetOperand(inst, 1)))
                    continue;
                ops.push_back(inst);
            }
    if (ops.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (LLVMValueRef inst : ops) {
        int op = LLVMGetInstructionOpcode(inst);
        LLVMPositionBuilderBefore(b, inst);
        LLVMValueRef x = LLVMGetOperand(inst, 0), y = LLVMGetOperand(inst, 1), r = LLVMGetUndef(LLVMTypeOf(inst));
        for (unsigned i = 0, n = LLVMGetVectorSize(LLVMTypeOf(inst)); i < n; i++) {
            LLVMValueRef xi = LLVMBuildExtractElement(b, x, g.c32(i), ""), yi = LLVMBuildExtractElement(b, y, g.c32(i), "");
            LLVMValueRef v = op == kAnd ? LLVMBuildAnd(b, xi, yi, "") : op == kShl ? LLVMBuildShl(b, xi, yi, "")
                           : op == kLShr ? LLVMBuildLShr(b, xi, yi, "") : LLVMBuildAShr(b, xi, yi, "");
            r = LLVMBuildInsertElement(b, r, v, g.c32(i), "");
        }
        LLVMReplaceAllUsesWith(inst, r);
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)ops.size();
}

// ---- divisions and remainders of 8- and 16-bit values ---------------------------------------------------------------
// Divisions and remainders of i8/i16 scalars came out wrong: done in 32 bits on the extended operands, through the
// opaque min so the optimizer can't narrow them back. NVAIR_NARROW_DIVISION_FIX. (n34, n43)
static unsigned widenNarrowDivisions(LLVMModuleRef module, Gen &g) {
    std::vector<LLVMValueRef> ops;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int op = LLVMGetInstructionOpcode(inst);
                if (op != LLVMUDiv && op != LLVMSDiv && op != LLVMURem && op != LLVMSRem) continue;
                LLVMTypeRef t = LLVMTypeOf(inst);
                if (LLVMGetTypeKind(t) == LLVMIntegerTypeKind && (LLVMGetIntTypeWidth(t) == 8 || LLVMGetIntTypeWidth(t) == 16))
                    ops.push_back(inst);
            }
    if (ops.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (LLVMValueRef inst : ops) {
        int op = LLVMGetInstructionOpcode(inst);
        bool sgn = op == LLVMSDiv || op == LLVMSRem;
        unsigned w = LLVMGetIntTypeWidth(LLVMTypeOf(inst));
        LLVMPositionBuilderBefore(b, inst);
        LLVMValueRef v[2];
        for (int i = 0; i < 2; i++) {
            LLVMValueRef x = LLVMGetOperand(inst, i);
            if (LLVMIsAConstantInt(x)) {
                unsigned long long c = LLVMConstIntGetZExtValue(x);
                if (sgn && (c >> (w - 1)) & 1) c |= ~((1ull << w) - 1);
                v[i] = g.c32((unsigned)c);
                continue;
            }
            v[i] = g.opaqueMin(b, sgn ? LLVMBuildSExt(b, x, g.i32, "") : LLVMBuildZExt(b, x, g.i32, ""), g.c32(~0u));
        }
        LLVMValueRef r = op == LLVMUDiv ? LLVMBuildUDiv(b, v[0], v[1], "") : op == LLVMSDiv ? LLVMBuildSDiv(b, v[0], v[1], "")
                       : op == LLVMURem ? LLVMBuildURem(b, v[0], v[1], "") : LLVMBuildSRem(b, v[0], v[1], "");
        LLVMReplaceAllUsesWith(inst, LLVMBuildTrunc(b, r, LLVMTypeOf(inst), ""));
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)ops.size();
}

// ---- right shifts of 8- and 16-bit values ---------------------------------------------------------------------------
// For an i8/i16 right shift by a masked amount the back end dropped the mask and shifted by the whole register: done in
// 32 bits, the amount (and a variable value) through the opaque min. NVAIR_NARROW_SHIFT_FIX. (n47)
static unsigned widenNarrowShifts(LLVMModuleRef module, Gen &g) {
    std::vector<LLVMValueRef> ops;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int op = LLVMGetInstructionOpcode(inst);
                if (op != LLVMLShr && op != LLVMAShr) continue;
                LLVMTypeRef t = LLVMTypeOf(inst);
                if (LLVMGetTypeKind(t) == LLVMIntegerTypeKind && (LLVMGetIntTypeWidth(t) == 8 || LLVMGetIntTypeWidth(t) == 16))
                    ops.push_back(inst);
            }
    if (ops.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (LLVMValueRef inst : ops) {
        bool sgn = LLVMGetInstructionOpcode(inst) == LLVMAShr;
        unsigned w = LLVMGetIntTypeWidth(LLVMTypeOf(inst));
        LLVMPositionBuilderBefore(b, inst);
        LLVMValueRef v[2];
        for (int i = 0; i < 2; i++) {  // the value sign- (ashr) or zero-extended (lshr), the amount zero-extended
            LLVMValueRef x = LLVMGetOperand(inst, i);
            bool extendSign = sgn && i == 0;
            if (LLVMIsAConstantInt(x)) {
                unsigned long long c = LLVMConstIntGetZExtValue(x);
                if (extendSign && (c >> (w - 1)) & 1) c |= ~((1ull << w) - 1);
                v[i] = g.c32((unsigned)c);
                continue;
            }
            v[i] = g.opaqueMin(b, extendSign ? LLVMBuildSExt(b, x, g.i32, "") : LLVMBuildZExt(b, x, g.i32, ""), g.c32(~0u));
        }
        if (LLVMIsAConstantInt(LLVMGetOperand(inst, 1))) {  // a constant amount: through the opaque min too, so the optimizer can't narrow it back
            v[1] = g.opaqueMin(b, v[1], g.c32(~0u));
        }
        LLVMValueRef r = sgn ? LLVMBuildAShr(b, v[0], v[1], "") : LLVMBuildLShr(b, v[0], v[1], "");
        LLVMReplaceAllUsesWith(inst, LLVMBuildTrunc(b, r, LLVMTypeOf(inst), ""));
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)ops.size();
}

// ---- compares of 8- and 16-bit values -------------------------------------------------------------------------------
// Equality and unsigned compares of i8/i16 scalars came out wrong: done on operands zero-extended to 32 bits through
// the opaque min (signed ones stay: widening them broke other kernels). NVAIR_NARROW_COMPARE_FIX. (n39, n41)
static unsigned widenNarrowCompares(LLVMModuleRef module, Gen &g) {
    std::vector<LLVMValueRef> cmps;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (LLVMGetInstructionOpcode(inst) != 42 || LLVMGetICmpPredicate(inst) >= LLVMIntSGT) continue;  // icmp eq/ne/u*
                LLVMTypeRef t = LLVMTypeOf(LLVMGetOperand(inst, 0));
                if (LLVMGetTypeKind(t) == LLVMIntegerTypeKind && (LLVMGetIntTypeWidth(t) == 8 || LLVMGetIntTypeWidth(t) == 16))
                    cmps.push_back(inst);
            }
    if (cmps.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (LLVMValueRef c : cmps) {
        LLVMPositionBuilderBefore(b, c);
        LLVMValueRef ops[2];
        for (int i = 0; i < 2; i++) {
            LLVMValueRef x = LLVMGetOperand(c, i);
            if (LLVMIsAConstantInt(x)) { ops[i] = g.c32((unsigned)LLVMConstIntGetZExtValue(x)); continue; }
            ops[i] = g.opaqueMin(b, LLVMBuildZExt(b, x, g.i32, ""), g.c32(~0u));
        }
        LLVMReplaceAllUsesWith(c, LLVMBuildICmp(b, LLVMGetICmpPredicate(c), ops[0], ops[1], ""));
        LLVMInstructionEraseFromParent(c);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)cmps.size();
}

// ---- operations on 2- to 4-lane vectors of 8- or 16-bit integers ----------------------------------------------------
// The back end's packed handling of 2- to 4-lane 8/16-bit vectors went wrong in loops: integer arithmetic, logic,
// shifts, compares, their extensions and selects on such vectors are done lane by lane. NVAIR_NARROW_VECTOR_FIX. (n37,
// n39)
static bool narrowVectorType(LLVMTypeRef t) {
    if (LLVMGetTypeKind(t) != LLVMVectorTypeKind || LLVMGetVectorSize(t) < 2 || LLVMGetVectorSize(t) > 4) return false;
    LLVMTypeRef e = LLVMGetElementType(t);
    return LLVMGetTypeKind(e) == LLVMIntegerTypeKind && LLVMGetIntTypeWidth(e) <= 16;
}
static unsigned scalarizeNarrowVectors(LLVMModuleRef module, Gen &g) {
    enum { kAdd = 8, kSub = 10, kMul = 12, kShl = 20, kLShr = 21, kAShr = 22, kAnd = 23, kOr = 24, kXor = 25, kICmp = 42, kSelect = 46 };
    bool oddOff = disabled("NVAIR_ODD_VECTOR_FIX"), constOff = disabled("NVAIR_VECTOR_CONSTANT_FIX");
    std::vector<LLVMValueRef> ops;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int op = LLVMGetInstructionOpcode(inst);
                bool bin = op == kAdd || op == kSub || op == kMul || op == LLVMUDiv || op == LLVMSDiv || op == LLVMURem || op == LLVMSRem ||
                           op == kShl || op == kLShr || op == kAShr || op == kAnd || op == kOr || op == kXor;
                if (bin) {
                    LLVMTypeRef t = LLVMTypeOf(inst);
                    if (!narrowVectorType(t)) continue;
                    if (oddOff && LLVMGetVectorSize(t) == 3) continue;  // the 3-lane arithmetic's switch
                    if (constOff && LLVMGetVectorSize(t) != 3 &&        // the constant masks and shifts' switch
                        (op == kAnd ? LLVMIsAConstant(LLVMGetOperand(inst, 0)) || LLVMIsAConstant(LLVMGetOperand(inst, 1))
                                    : (op == kShl || op == kLShr || op == kAShr) && perLaneAmounts(LLVMGetOperand(inst, 1))))
                        continue;
                    ops.push_back(inst);
                } else if (op == kSelect) {
                    if (narrowVectorType(LLVMTypeOf(inst))) ops.push_back(inst);
                } else if (op == kICmp) {
                    if (narrowVectorType(LLVMTypeOf(LLVMGetOperand(inst, 0)))) ops.push_back(inst);
                } else if (op == LLVMZExt || op == LLVMSExt) {
                    LLVMTypeRef from = LLVMTypeOf(LLVMGetOperand(inst, 0));
                    if (narrowVectorType(LLVMTypeOf(inst)) && LLVMGetTypeKind(from) == LLVMVectorTypeKind && LLVMGetIntTypeWidth(LLVMGetElementType(from)) == 1)
                        ops.push_back(inst);
                }
            }
    if (ops.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (LLVMValueRef inst : ops) {
        int op = LLVMGetInstructionOpcode(inst);
        LLVMPositionBuilderBefore(b, inst);
        LLVMValueRef x = LLVMGetOperand(inst, 0), r = LLVMGetUndef(LLVMTypeOf(inst));
        bool scalarCond = op == kSelect && LLVMGetTypeKind(LLVMTypeOf(x)) != LLVMVectorTypeKind;  // a select's condition may be one i1
        unsigned n = LLVMGetVectorSize(LLVMTypeOf(op == kSelect ? inst : x));
        for (unsigned i = 0; i < n; i++) {
            LLVMValueRef xi = scalarCond ? x : LLVMBuildExtractElement(b, x, g.c32(i), ""), v;
            if (op == kSelect) {
                v = LLVMBuildSelect(b, xi, LLVMBuildExtractElement(b, LLVMGetOperand(inst, 1), g.c32(i), ""),
                                    LLVMBuildExtractElement(b, LLVMGetOperand(inst, 2), g.c32(i), ""), "");
            } else if (op == LLVMZExt || op == LLVMSExt) {
                LLVMTypeRef et = LLVMGetElementType(LLVMTypeOf(inst));
                v = op == LLVMZExt ? LLVMBuildZExt(b, xi, et, "") : LLVMBuildSExt(b, xi, et, "");
            } else {
                LLVMValueRef yi = LLVMBuildExtractElement(b, LLVMGetOperand(inst, 1), g.c32(i), "");
                switch (op) {
                case kICmp: v = LLVMBuildICmp(b, LLVMGetICmpPredicate(inst), xi, yi, ""); break;
                case kAdd: v = LLVMBuildAdd(b, xi, yi, ""); break;
                case kSub: v = LLVMBuildSub(b, xi, yi, ""); break;
                case kMul: v = LLVMBuildMul(b, xi, yi, ""); break;
                case LLVMUDiv: v = LLVMBuildUDiv(b, xi, yi, ""); break;
                case LLVMSDiv: v = LLVMBuildSDiv(b, xi, yi, ""); break;
                case LLVMURem: v = LLVMBuildURem(b, xi, yi, ""); break;
                case LLVMSRem: v = LLVMBuildSRem(b, xi, yi, ""); break;
                case kShl: v = LLVMBuildShl(b, xi, yi, ""); break;
                case kLShr: v = LLVMBuildLShr(b, xi, yi, ""); break;
                case kAShr: v = LLVMBuildAShr(b, xi, yi, ""); break;
                case kAnd: v = LLVMBuildAnd(b, xi, yi, ""); break;
                case kOr: v = LLVMBuildOr(b, xi, yi, ""); break;
                default: v = LLVMBuildXor(b, xi, yi, ""); break;
                }
            }
            r = LLVMBuildInsertElement(b, r, v, g.c32(i), "");
        }
        LLVMReplaceAllUsesWith(inst, r);
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)ops.size();
}

// ---- a saturating add or subtract of a product ----------------------------------------------------------------------
// The back end folds a multiply into a following saturating add or subtract and gets the saturation wrong: the product
// goes through the opaque min. NVAIR_SATURATED_PRODUCT_FIX. (n36)
static unsigned hideSaturatedProducts(LLVMModuleRef module, Gen &g) {
    static const char *const names[] = {"air.add_sat.s.i32", "air.add_sat.u.i32", "air.sub_sat.s.i32", "air.sub_sat.u.i32",
                                        "llvm.nvvm.add.sat.s.i32", "llvm.nvvm.add.sat.u.i32", "llvm.nvvm.sub.sat.s.i32", "llvm.nvvm.sub.sat.u.i32"};
    std::vector<std::pair<LLVMValueRef, unsigned>> todo;
    for (const char *name : names) {
        LLVMValueRef f = LLVMGetNamedFunction(module, name);
        if (!f) continue;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) {
            LLVMValueRef call = LLVMGetUser(u);
            if (!LLVMIsACallInst(call) || LLVMGetNumOperands(call) != 3 || LLVMGetOperand(call, 2) != f) continue;
            for (unsigned k = 0; k < 2; k++) {
                LLVMValueRef x = LLVMGetOperand(call, k);
                if (LLVMIsAInstruction(x) && LLVMGetInstructionOpcode(x) == 12 /* mul */) todo.push_back({call, k});
            }
        }
    }
    if (todo.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (auto &[call, k] : todo) {
        LLVMPositionBuilderBefore(b, call);
        LLVMSetOperand(call, k, g.opaqueMin(b, LLVMGetOperand(call, k), g.c32(~0u)));
    }
    LLVMDisposeBuilder(b);
    return (unsigned)todo.size();
}

// ---- a subtraction of a bitwise not ---------------------------------------------------------------------------------
// The back end folded x - ~y into x + y - 1 (it is x + y + 1): written as x + (y + 1). NVAIR_SUB_NOT_FIX. (n38)
static unsigned rewriteSubtractedNots(LLVMModuleRef module, Gen &g) {
    enum { kSub = 10, kXor = 25 };
    auto allOnes = [](LLVMValueRef c) { return LLVMIsAConstantInt(c) && LLVMConstIntGetZExtValue(c) == 0xffffffffull; };
    std::vector<LLVMValueRef> subs;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (LLVMGetInstructionOpcode(inst) != kSub || !isInt(LLVMTypeOf(inst), 32)) continue;
                LLVMValueRef y = LLVMGetOperand(inst, 1);
                if (!LLVMIsAInstruction(y) || LLVMGetInstructionOpcode(y) != kXor) continue;
                if (allOnes(LLVMGetOperand(y, 0)) || allOnes(LLVMGetOperand(y, 1))) subs.push_back(inst);
            }
    if (subs.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (LLVMValueRef inst : subs) {
        LLVMValueRef y = LLVMGetOperand(inst, 1);
        LLVMValueRef v = allOnes(LLVMGetOperand(y, 1)) ? LLVMGetOperand(y, 0) : LLVMGetOperand(y, 1);
        LLVMPositionBuilderBefore(b, inst);
        LLVMValueRef r = LLVMBuildAdd(b, LLVMGetOperand(inst, 0), LLVMBuildAdd(b, v, g.c32(1), ""), "");
        LLVMReplaceAllUsesWith(inst, r);
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)subs.size();
}

// ---- an unsigned division of a sign-extended 8- or 16-bit value -----------------------------------------------------
// The back end divides an unsigned division of a sign-extended i8/i16 in floating point as if it had 16 significant
// bits, wrong for negative values: the dividend goes through the opaque min, hiding the sext. NVAIR_SEXT_DIVIDEND_FIX.
// (n34)
static unsigned hideSignExtendedDividends(LLVMModuleRef module, Gen &g) {
    std::vector<LLVMValueRef> divs;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (LLVMIsDeclaration(f) || !strncmp(LLVMGetValueName(f), "nvair.", 6)) continue;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int op = LLVMGetInstructionOpcode(inst);
                if ((op != LLVMUDiv && op != LLVMURem) || !isInt(LLVMTypeOf(inst), 32)) continue;
                LLVMValueRef x = LLVMGetOperand(inst, 0);
                if (LLVMIsAInstruction(x) && LLVMGetInstructionOpcode(x) == LLVMSExt) divs.push_back(inst);
            }
    }
    if (divs.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (LLVMValueRef inst : divs) {
        LLVMPositionBuilderBefore(b, inst);
        LLVMSetOperand(inst, 0, g.opaqueMin(b, LLVMGetOperand(inst, 0), g.c32(~0u)));
    }
    LLVMDisposeBuilder(b);
    return (unsigned)divs.size();
}

// ---- arithmetic on 3-lane vectors of 8- and 16-bit integers ---------------------------------------------------------
// Lane z of a 3-lane 8/16-bit vector, beside the back end's undefined padding lane, came out wrong: integer arithmetic
// on such vectors is done lane by lane. NVAIR_ODD_VECTOR_FIX. (n33)
static unsigned scalarizeOddVectors(LLVMModuleRef module, Gen &g) {
    enum { kAdd = 8, kSub = 10, kMul = 12, kShl = 20, kLShr = 21, kAShr = 22, kAnd = 23, kOr = 24, kXor = 25 };
    std::vector<LLVMValueRef> ops;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int op = LLVMGetInstructionOpcode(inst);
                if (op != kAdd && op != kSub && op != kMul && op != kShl && op != kLShr && op != kAShr && op != kAnd && op != kOr && op != kXor &&
                    op != LLVMUDiv && op != LLVMSDiv && op != LLVMURem && op != LLVMSRem)
                    continue;
                LLVMTypeRef t = LLVMTypeOf(inst);
                if (LLVMGetTypeKind(t) != LLVMVectorTypeKind || LLVMGetVectorSize(t) != 3) continue;
                LLVMTypeRef e = LLVMGetElementType(t);
                if (LLVMGetTypeKind(e) != LLVMIntegerTypeKind || LLVMGetIntTypeWidth(e) > 16) continue;
                ops.push_back(inst);
            }
    if (ops.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(g.context);
    for (LLVMValueRef inst : ops) {
        int op = LLVMGetInstructionOpcode(inst);
        LLVMPositionBuilderBefore(b, inst);
        LLVMValueRef x = LLVMGetOperand(inst, 0), y = LLVMGetOperand(inst, 1), r = LLVMGetUndef(LLVMTypeOf(inst));
        for (unsigned i = 0; i < 3; i++) {
            LLVMValueRef xi = LLVMBuildExtractElement(b, x, g.c32(i), ""), yi = LLVMBuildExtractElement(b, y, g.c32(i), ""), v;
            switch (op) {
            case kAdd: v = LLVMBuildAdd(b, xi, yi, ""); break;
            case kSub: v = LLVMBuildSub(b, xi, yi, ""); break;
            case kMul: v = LLVMBuildMul(b, xi, yi, ""); break;
            case kShl: v = LLVMBuildShl(b, xi, yi, ""); break;
            case kLShr: v = LLVMBuildLShr(b, xi, yi, ""); break;
            case kAShr: v = LLVMBuildAShr(b, xi, yi, ""); break;
            case kAnd: v = LLVMBuildAnd(b, xi, yi, ""); break;
            case kOr: v = LLVMBuildOr(b, xi, yi, ""); break;
            case kXor: v = LLVMBuildXor(b, xi, yi, ""); break;
            case LLVMUDiv: v = LLVMBuildUDiv(b, xi, yi, ""); break;
            case LLVMSDiv: v = LLVMBuildSDiv(b, xi, yi, ""); break;
            case LLVMURem: v = LLVMBuildURem(b, xi, yi, ""); break;
            default: v = LLVMBuildSRem(b, xi, yi, ""); break;
            }
            r = LLVMBuildInsertElement(b, r, v, g.c32(i), "");
        }
        LLVMReplaceAllUsesWith(inst, r);
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)ops.size();
}

// The module fixes, in the order they run (each counts what it rewrote; 0 = nothing to do). A null switch name: the
// fix reads its own switches. needsInlining: the fix calls bodies made internal and always_inline, inlined afterwards.
struct ModuleFix {
    const char *switchName;
    unsigned (*apply)(LLVMModuleRef, Gen &);
    const char *logFormat;
    bool needsInlining;
};
static const ModuleFix kModuleFixes[] = {
    {"NVAIR_INLINE_ASM_FIX", [](LLVMModuleRef m, Gen &) { return dropUnusedInlineAsmCalls(m); }, "[nvair] %u inline asm call(s) dropped\n", false},
    {"NVAIR_ARRAY_STRUCT_FIX", unwrapArrayStructs, "[nvair] %u private array(s) in a struct (metal::array) made plain arrays\n", false},  // before the private-array fixes
    {"NVAIR_TEXTURE_ATOMICS", lowerTextureAtomics, "[nvair] %u texture atomic(s) made global atomics on linear texture buffers\n", false},
    {"NVAIR_DEPTH_CHANNELS", fixDepthChannels, nullptr, false},
    {"NVAIR_CUBE_READ_LEVEL", fixCubeReadLevels, "[nvair] %u cube read body(ies) given the level's size and a mip-filtered sampler\n", false},
    {"NVAIR_ARRAY_LAYER_CLAMP", clampArrayLayers, "[nvair] %u texture-array layer(s) clamped at 0\n", false},
    {"NVAIR_LOCAL_CMPXCHG", fixLocalCompareExchange, "[nvair] %u threadgroup compare-exchange body(ies) given the store of the value found\n", false},
    {"NVAIR_SIGNED_BOOL_FIX", fixSignedBoolConversions, "[nvair] %u sign mask(s) taken out of signed-to-bool conversions\n", false},
    {"NVAIR_ATOMIC_JOIN_FIX", fixAtomicJoinOperands, "[nvair] %u atomic operand(s) from a branch join put through a private slot\n", false},
    {"NVAIR_PRIVATE_CONSTANT_LOAD_FIX", fixPrivateConstantLoads, "[nvair] %u constant-index private load(s) given an opaque index\n", false},
    {"NVAIR_ODD_VECTOR_FIX", scalarizeOddVectors, "[nvair] %u operation(s) on 3-lane 8/16-bit vectors done lane by lane\n", false},
    {"NVAIR_VECTOR_CONSTANT_FIX", scalarizeConstantLaneOps, "[nvair] %u and(s)/shift(s) of a 2/4-lane 8/16-bit vector by a constant done lane by lane\n", false},
    {"NVAIR_DIVISOR_ONE_FIX", guardDivisorOne, "[nvair] %u remainder(s) guarded for a divisor of 1\n", false},
    {"NVAIR_SEXT_DIVIDEND_FIX", hideSignExtendedDividends, "[nvair] %u unsigned division(s) of a sign-extended value given an opaque dividend\n", false},
    {"NVAIR_SUB_NOT_FIX", rewriteSubtractedNots, "[nvair] %u subtraction(s) of a bitwise not made x + (y + 1)\n", false},
    {"NVAIR_SATURATED_PRODUCT_FIX", hideSaturatedProducts, "[nvair] %u product(s) given to a saturating add/subtract through an opaque value\n", false},
    {"NVAIR_NARROW_VECTOR_FIX", scalarizeNarrowVectors, "[nvair] %u operation(s) on 2-4 lane 8/16-bit vectors done lane by lane\n", false},
    {"NVAIR_NARROW_DIVISION_FIX", widenNarrowDivisions, "[nvair] %u division(s)/remainder(s) of 8/16-bit values made 32-bit\n", false},
    {"NVAIR_NARROW_SHIFT_FIX", widenNarrowShifts, "[nvair] %u right shift(s) of 8/16-bit values made 32-bit\n", false},
    {"NVAIR_NARROW_COMPARE_FIX", widenNarrowCompares, "[nvair] %u compare(s) of 8/16-bit values made 32-bit\n", false},
    {"NVAIR_MAD_SAT_FIX", lowerMadSat, "[nvair] %u madsat call(s) given the adapter's own body\n", false},
    {"NVAIR_OVERFLOW_FIX", fixOverflowIntrinsics, "[nvair] %u overflow intrinsic(s) made plain arithmetic\n", false},
    {"NVAIR_INTRINSICS", [](LLVMModuleRef, Gen &g) { return defineMissingIntrinsics(g); }, "[nvair] %u intrinsic(s) given bodies\n", true},
    {"NVAIR_I64_FIX", fixWideInstructions, "[nvair] %u 64-bit instruction(s) rewritten\n", true},
    {"NVAIR_SAMPLER_STATE_FIX", fixSamplerStateWords, "[nvair] %u constexpr sampler(s) in the [2 x i64] form rewritten as i64\n", false},
    {"NVAIR_THREADGROUP_BOOL_FIX", widenThreadgroupBools, "[nvair] %u threadgroup bool(s) widened to i8\n", false},
    {nullptr, fixGradientSamples, "[nvair] %u 3D / cube gradient sample(s) done at their level\n", false},  // NVAIR_GRADIENT_FIX, NVAIR_CUBE_GRADIENT_FIX
    {"NVAIR_NARROW_MULTIPLY_FIX", hideNarrowProducts, "[nvair] %u product(s) of 16-bit factors given an opaque factor\n", false},
    {"NVAIR_FRAGMENT_LOAD_GUARD", guardFragmentLoads, "[nvair] %u fragment device load(s) kept from a negative index\n", false},
    {"NVAIR_DEMOTE_DISCARD", demoteDiscards, nullptr, true},
    {"NVAIR_HALF_CONSTANT_FIX", foldHalfVectorBitcasts, "[nvair] %u constant(s) with half vectors spelled as bitcasts rewritten\n", false},
    {"NVAIR_LARGE_COPY_LOOP", loopLargeCopies, "[nvair] %u large copy(ies) made word loops\n", true},
    {"NVAIR_NARROW_PRIVATE_ARRAY_FIX", widenNarrowPrivateArrays, "[nvair] %u private byte / halfword array(s) with masked loads (or on 32-bit words)\n", false},
    {"NVAIR_COUNT_ZERO_FIX", defineCountOfZero, "[nvair] %u clz/ctz call(s) made defined for 0\n", false},
    {"NVAIR_COMPARE_GRADIENT_FIX", fixGradientCompares, "[nvair] %u gradient comparison(s) made at level 0\n", false},
    {"NVAIR_COMPARE_LEVEL_FIX", fixDepthCompareLevels, "[nvair] %u depth comparison(s) moved to a level that compares\n", false},
};

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
        bool inliningNeeded = false;
        for (const ModuleFix &fix : kModuleFixes) {
            if (fix.switchName && disabled(fix.switchName)) continue;
            unsigned count = fix.apply(module, g);
            if (!count) continue;
            inliningNeeded |= fix.needsInlining;
            if (fix.logFormat && logging()) fprintf(stderr, fix.logFormat, count);
        }
        if (inliningNeeded) inlineBodies(module);
        if (logging()) logBareIntrinsics(module);
    }
    return passManagerRun(self, module);
}

// Redirect the plugin's imported pointer to PassManager::run (found by value in its data segments).

static void installIntoPlugin() {
    static bool done;
    if (done) return;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0, suffix = strlen(kPluginSuffix);
        if (len < suffix || strcmp(name + len - suffix, kPluginSuffix)) continue;
        done = true;
        unsigned n = redirectImportedPointer((const mach_header_64 *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i),
                                             (void *)passManagerRun, (void *)hookedRun);
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
