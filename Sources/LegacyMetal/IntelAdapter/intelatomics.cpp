// IntelTextureAtomics.dylib: MSL texture atomics (Metal 3.1) for OCLP's 3802 Intel Metal compiler
// (libMTLIntelCompilerPlugin + libIGIL-Metal, Haswell / Ivy Bridge GPUs on macOS 14+).
//
// The plugin's built-in function library (runtime.igil64.bc) has no air.atomic_*_explicit_texture_* functions, so
// such shaders fail to compile, but the IGIL back end has image atomics (llvm.igil.atom.<op>i32.image) and USC
// compiles them. The back end's own handling of them only works for a texture used in the entry block of a compute
// function and names the wrong UAV, so three steps:
//   1. Before each llvm::legacy::PassManager::run on a module (imported from the 3802 libLLVM; LLVM-C API used for
//      the rewrite): air.atomic_<op>_explicit_texture_<dim>(texture, coords, [layer,] value, order, scope) ->
//      llvm.igil.atom.<op>i32.image(ptrtoint texture, tag, value, <coords, tag>, 0), tag = the texture's binding.
//   2. IGILTargetLowering::LowerImageAtomic (inline hook): image operand = the tag, value back in its place.
//   3. Before each MTLIntelCompiler::compile*FunctionIGILtoBinary: IMM_ATOMIC_* image operand -> the u<N> declared
//      for the binding found through coords.w, which is cleared.
// Installed: AppleIntelHD5000GraphicsMTLDriver.bundle/Contents/MacOS/IntelTextureAtomics.dylib (Haswell, 12.5 payload) and
// AppleIntelHD4000GraphicsMTLDriver.bundle/Contents/MacOS/IntelTextureAtomics.dylib (Ivy Bridge, 11.7.10 payloads), a weak
// dependency of each bundle's libMTLIntelCompilerPlugin.dylib. On Ivy Bridge the IGIL entry hooks (texture atomics) don't
// match its plugin and stay off, and the Haswell sampler workaround is skipped; the IR fixes for compiler crashes apply. Test use: DYLD_INSERT_LIBRARIES=Tests/tools/localcc.dylib:build/intelatomics-test.dylib
//   INTELTEX_LOG=1        log what is rewritten (INTELTEX_LOG=/path: append the log to that file, e.g. from
//                         MTLCompilerService through __XPC_INTELTEX_LOG)
//   INTELTEX_DUMP=<dir>   write each lowered module and the IGIL text before the fix
//   INTELTEX_DUMP_INPUT=<dir>  write every module as it reaches the pass manager
// Also (compiler compatibility, not texture atomics): air.max_work_group_size dropped (the back end aborts on it),
// air.struct_type_info dropped from array-of-struct buffer arguments (the argument-buffer emulation asserts on them),
// signed i8/i16 conversions in vertex functions done with shifts of the 32-bit word (the back end can read the top lane
// from the wrong word), the LOD bias dropped from depth comparisons (the back end can't compile them), texel offsets
// of integer texture samples moved into the coordinates (the back end ignores them), constexpr samplers from newer
// front ends ([2 x i64]) rewritten in the i64 form the back end reads (it crashes on the array), and explicit levels in
// compute kernels remapped so the sampler's narrow mip blend there comes out linear, threadgroup bools widened to i8
// (the back end can't select i1 loads and stores there), aligned subword accesses to private memory done on their word,
// float3 vertex inputs read through fmax (a bare copy to an output reads an unset register), and variable-index accesses to
// small private arrays done at constant indices (the back end addresses such arrays two incompatible ways), and loads
// and stores through a select of private pointers split per pointer (the back end forwards stale loads of such arrays).
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/mman.h>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <set>
#include <map>
#include <functional>
#include <algorithm>
#include <atomic>
#include "gen7eu.h"

extern "C" {
typedef struct LLVMOpaqueModule *LLVMModuleRef;
typedef struct LLVMOpaqueValue *LLVMValueRef;
typedef struct LLVMOpaqueType *LLVMTypeRef;
typedef struct LLVMOpaqueBuilder *LLVMBuilderRef;
typedef struct LLVMOpaqueContext *LLVMContextRef;
typedef struct LLVMOpaqueUse *LLVMUseRef;
LLVMValueRef LLVMGetNamedFunction(LLVMModuleRef, const char *);
LLVMContextRef LLVMGetModuleContext(LLVMModuleRef);
LLVMBuilderRef LLVMCreateBuilderInContext(LLVMContextRef);
void LLVMPositionBuilderBefore(LLVMBuilderRef, LLVMValueRef);
void LLVMDisposeBuilder(LLVMBuilderRef);
LLVMTypeRef LLVMInt32TypeInContext(LLVMContextRef);
LLVMTypeRef LLVMVectorType(LLVMTypeRef, unsigned);
LLVMTypeRef LLVMTypeOf(LLVMValueRef);
int LLVMGetTypeKind(LLVMTypeRef);
unsigned LLVMGetVectorSize(LLVMTypeRef);
LLVMValueRef LLVMConstInt(LLVMTypeRef, unsigned long long, int);
LLVMValueRef LLVMConstNull(LLVMTypeRef);
LLVMValueRef LLVMGetUndef(LLVMTypeRef);
LLVMValueRef LLVMBuildInsertElement(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildExtractElement(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildNeg(LLVMBuilderRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildPtrToInt(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMBuildCall(LLVMBuilderRef, LLVMValueRef, LLVMValueRef *, unsigned, const char *);
LLVMValueRef LLVMBuildLoad(LLVMBuilderRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildStore(LLVMBuilderRef, LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMBuildICmp(LLVMBuilderRef, int, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildZExt(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
void LLVMReplaceAllUsesWith(LLVMValueRef, LLVMValueRef);
void LLVMInstructionEraseFromParent(LLVMValueRef);
LLVMUseRef LLVMGetFirstUse(LLVMValueRef);
LLVMUseRef LLVMGetNextUse(LLVMUseRef);
LLVMValueRef LLVMGetUser(LLVMUseRef);
int LLVMGetNumOperands(LLVMValueRef);
LLVMValueRef LLVMGetOperand(LLVMValueRef, unsigned);
LLVMValueRef LLVMIsAArgument(LLVMValueRef);
LLVMValueRef LLVMGetParamParent(LLVMValueRef);
unsigned LLVMCountParams(LLVMValueRef);
LLVMValueRef LLVMGetParam(LLVMValueRef, unsigned);
LLVMTypeRef LLVMTypeOf(LLVMValueRef);
LLVMTypeRef LLVMGetElementType(LLVMTypeRef);
int LLVMGetTypeKind(LLVMTypeRef);
unsigned LLVMGetNamedMetadataNumOperands(LLVMModuleRef, const char *);
void LLVMGetNamedMetadataOperands(LLVMModuleRef, const char *, LLVMValueRef *);
unsigned LLVMGetMDNodeNumOperands(LLVMValueRef);
void LLVMGetMDNodeOperands(LLVMValueRef, LLVMValueRef *);
const char *LLVMGetMDString(LLVMValueRef, unsigned *);
LLVMValueRef LLVMIsAMDNode(LLVMValueRef);
LLVMValueRef LLVMIsAMDString(LLVMValueRef);
LLVMValueRef LLVMIsAConstantInt(LLVMValueRef);
LLVMValueRef LLVMMDNodeInContext(LLVMContextRef, LLVMValueRef *, unsigned);
unsigned long long LLVMConstIntGetZExtValue(LLVMValueRef);
char *LLVMPrintModuleToString(LLVMModuleRef);
LLVMValueRef LLVMGetFirstFunction(LLVMModuleRef);
LLVMValueRef LLVMGetNextFunction(LLVMValueRef);
const char *LLVMGetValueName(LLVMValueRef);
char *LLVMPrintTypeToString(LLVMTypeRef);
void LLVMDisposeMessage(char *);
// Texture/sampler loads through escaped pointers (fixEscapedHandleLoads)
typedef struct LLVMOpaqueBasicBlock *LLVMBasicBlockRef;
LLVMBasicBlockRef LLVMGetFirstBasicBlock(LLVMValueRef);
LLVMBasicBlockRef LLVMGetNextBasicBlock(LLVMBasicBlockRef);
LLVMValueRef LLVMGetFirstInstruction(LLVMBasicBlockRef);
LLVMValueRef LLVMGetNextInstruction(LLVMValueRef);
LLVMValueRef LLVMIsALoadInst(LLVMValueRef);
LLVMValueRef LLVMIsAAllocaInst(LLVMValueRef);
LLVMValueRef LLVMBuildAlloca(LLVMBuilderRef, LLVMTypeRef, const char *);
LLVMTypeRef LLVMArrayType(LLVMTypeRef, unsigned);
LLVMTypeRef LLVMGetAllocatedType(LLVMValueRef);
LLVMValueRef LLVMIsAGetElementPtrInst(LLVMValueRef);
LLVMValueRef LLVMIsABitCastInst(LLVMValueRef);
LLVMValueRef LLVMIsAConstant(LLVMValueRef);
int LLVMIsDeclaration(LLVMValueRef);
int LLVMGetAttribute(LLVMValueRef);  // LLVMAttribute bits of an argument; LLVMByValAttribute = 1 << 7
unsigned LLVMGetArrayLength(LLVMTypeRef);
const char *LLVMGetStructName(LLVMTypeRef);
LLVMTypeRef LLVMInt64TypeInContext(LLVMContextRef);
LLVMValueRef LLVMBuildInBoundsGEP(LLVMBuilderRef, LLVMValueRef, LLVMValueRef *, unsigned, const char *);
LLVMValueRef LLVMBuildSelect(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, LLVMValueRef, const char *);
}
extern "C" int passManagerRun(void *self, LLVMModuleRef module) asm("__ZN4llvm6legacy11PassManager3runERNS_6ModuleE");

static bool logging() { return getenv("INTELTEX_LOG") != nullptr; }

// ---- IGIL intrinsic table (libIGIL-Metal, exported): name -> ID -> correctly typed declaration -------------------
static const char *const kIGILPath = "/System/Library/Extensions/AppleIntelGraphicsShared.bundle/Contents/MacOS/libIGIL-Metal.dylib";
static struct {
    void *object = nullptr;  // a stand-in IGILIntrinsicInfo: only its vtable pointer
    unsigned (*lookupName)(void *self, const char *name, unsigned length) = nullptr;
    LLVMValueRef (*getDeclaration)(void *self, LLVMModuleRef module, unsigned id, void **types, unsigned count) = nullptr;
} igil;

static bool installIntoBackEnd(void *igil);
static bool resolveIGIL() {
    static int state;
    if (state) return state > 0;
    void *h = dlopen(kIGILPath, RTLD_NOLOAD | RTLD_LAZY);
    if (!h) return false;  // not loaded yet: try again on the next module
    state = -1;
    char *vtable = (char *)dlsym(h, "_ZTVN4llvm17IGILIntrinsicInfoE");
    igil.lookupName = (unsigned (*)(void *, const char *, unsigned))dlsym(h, "_ZNK4llvm17IGILIntrinsicInfo10lookupNameEPKcj");
    igil.getDeclaration = (LLVMValueRef(*)(void *, LLVMModuleRef, unsigned, void **, unsigned))dlsym(
        h, "_ZNK4llvm17IGILIntrinsicInfo14getDeclarationEPNS_6ModuleEjPPNS_4TypeEj");
    if (!vtable || !igil.lookupName || !igil.getDeclaration) return false;
    static void *object[4];
    object[0] = vtable + 16;
    igil.object = object;
    if (!installIntoBackEnd(h)) return false;  // without the LowerImageAtomic hook the rewrite would miscompile
    state = 1;
    return true;
}

static LLVMValueRef igilIntrinsic(LLVMModuleRef module, const char *op) {
    char name[64];
    snprintf(name, sizeof name, "llvm.igil.atom.%s.image", op);
    unsigned id = igil.lookupName(igil.object, name, (unsigned)strlen(name));
    return id ? igil.getDeclaration(igil.object, module, id, nullptr, 0) : nullptr;
}

// ---- step 1: AIR ---------------------------------------------------------------------------------------------------
enum Kind { kFetch, kLoad, kStore, kCompareExchange };
static const struct { const char *air; const char *igilU, *igilS; bool negate; Kind kind; } kOps[] = {
    {"fetch_add", "addi32", "addi32", false, kFetch}, {"fetch_sub", "addi32", "addi32", true, kFetch},
    {"fetch_min", "minu32", "mini32", false, kFetch}, {"fetch_max", "maxu32", "maxi32", false, kFetch},
    {"fetch_and", "andi32", "andi32", false, kFetch}, {"fetch_or", "ori32", "ori32", false, kFetch},
    {"fetch_xor", "xori32", "xori32", false, kFetch}, {"exchange", "xchgi32", "xchgi32", false, kFetch},
    {"load", "ori32", "ori32", false, kLoad},         {"store", "xchgi32", "xchgi32", false, kStore},
    {"compare_exchange_weak", "cmpxchgi32", "cmpxchgi32", false, kCompareExchange},
};
static const char *const kDims[] = {"1d", "1d_array", "2d", "2d_array", "3d", "buffer_1d"};

// Coordinates as <4 x i32>: the scalar or vector coordinate, then the layer if any, zero-filled. ushort coordinates
// (the .i16 functions) are zero-extended.
static LLVMValueRef widen(LLVMBuilderRef b, LLVMTypeRef i32, LLVMValueRef value) {
    return LLVMTypeOf(value) == i32 ? value : LLVMBuildZExt(b, value, i32, "");
}
static LLVMValueRef packCoords(LLVMBuilderRef b, LLVMTypeRef i32, LLVMValueRef coord, LLVMValueRef layer) {
    LLVMValueRef out = LLVMConstNull(LLVMVectorType(i32, 4));
    unsigned n = 0;
    if (LLVMGetTypeKind(LLVMTypeOf(coord)) == 13 /* LLVMVectorTypeKind */) {
        for (unsigned k = 0, count = LLVMGetVectorSize(LLVMTypeOf(coord)); k < count && n < 4; k++)
            out = LLVMBuildInsertElement(b, out, widen(b, i32, LLVMBuildExtractElement(b, coord, LLVMConstInt(i32, k, 0), "")),
                                         LLVMConstInt(i32, n++, 0), "");
    } else {
        out = LLVMBuildInsertElement(b, out, widen(b, i32, coord), LLVMConstInt(i32, n++, 0), "");
    }
    if (layer && n < 4) out = LLVMBuildInsertElement(b, out, widen(b, i32, layer), LLVMConstInt(i32, n++, 0), "");
    return out;  // at most 3 lanes: w is free for the image tag
}

// The image tag, kImageTag | the texture's binding ([[texture(n)]], AIR air.location_index), goes in two places:
//  - the intrinsic's first spare i32 operand: the back end's LowerImageAtomic only finds a texture argument's UAV in
//    the entry block (elsewhere the argument is a copied virtual register and the atomic is silently dropped), so
//    hookedLowerImageAtomic replaces the image operand with the tag. The value (the new value for compare-exchange)
//    travels in the second spare operand and the last argument is 0: for graphics functions IGILTextureTypeEncode
//    overwrites the last argument of every call that takes a texture with encoded texture information;
//  - the coordinates' unused w lane: the IGIL printer can't show such an image operand, so the IGIL text fix finds
//    the texture through coords.w, writes the uN declared for that binding and clears w.
static const unsigned kImageTag = 0x7A100000, kImageTagMask = 0xFFF00000, kBindingMask = 0xFFFFF;
static std::vector<LLVMValueRef> metadataOperands(LLVMValueRef node) {
    std::vector<LLVMValueRef> out(LLVMIsAMDNode(node) ? LLVMGetMDNodeNumOperands(node) : 0);
    if (!out.empty()) LLVMGetMDNodeOperands(node, out.data());
    return out;
}
static bool isString(LLVMValueRef value, const char *text) {
    unsigned length = 0;
    const char *s = value && LLVMIsAMDString(value) ? LLVMGetMDString(value, &length) : nullptr;
    return s && length == strlen(text) && !memcmp(s, text, length);
}
// The binding of texture parameter `param` of `function`, from !air.kernel / !air.fragment / !air.vertex:
// !{fn, !outputs, !{..., !{i32 param, !"air.texture", !"air.location_index", i32 binding, i32 count, ...}, ...}}
static int textureBinding(LLVMModuleRef module, LLVMValueRef function, unsigned param) {
    for (const char *list : {"air.kernel", "air.fragment", "air.vertex"}) {
        std::vector<LLVMValueRef> entries(LLVMGetNamedMetadataNumOperands(module, list));
        if (entries.empty()) continue;
        LLVMGetNamedMetadataOperands(module, list, entries.data());
        for (LLVMValueRef entry : entries) {
            std::vector<LLVMValueRef> parts = metadataOperands(entry);
            if (parts.size() < 3 || parts[0] != function) continue;
            for (LLVMValueRef argument : metadataOperands(parts[2])) {
                std::vector<LLVMValueRef> fields = metadataOperands(argument);
                if (fields.size() < 5 || !LLVMIsAConstantInt(fields[0]) || LLVMConstIntGetZExtValue(fields[0]) != param ||
                    !isString(fields[1], "air.texture"))
                    continue;
                for (size_t k = 2; k + 1 < fields.size(); k++)
                    if (isString(fields[k], "air.location_index") && LLVMIsAConstantInt(fields[k + 1]))
                        return (int)LLVMConstIntGetZExtValue(fields[k + 1]);
            }
        }
    }
    return -1;
}
static LLVMValueRef imageTag(LLVMModuleRef module, LLVMTypeRef i32, LLVMValueRef texture) {
    if (!LLVMIsAArgument(texture)) return nullptr;
    LLVMValueRef function = LLVMGetParamParent(texture);
    for (unsigned k = 0, count = LLVMCountParams(function); k < count; k++) {
        if (LLVMGetParam(function, k) != texture) continue;
        int binding = textureBinding(module, function, k);
        return binding >= 0 && binding <= (int)kBindingMask ? LLVMConstInt(i32, kImageTag | binding, 0) : nullptr;
    }
    return nullptr;
}

static unsigned lowerTextureAtomics(LLVMModuleRef module) {
    unsigned lowered = 0;
    LLVMContextRef ctx = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(ctx), v4 = LLVMVectorType(i32, 4);
    LLVMBuilderRef b = nullptr;
    for (const char *dim : kDims)
    for (int s = 0; s < 4; s++)  // s & 1: signed; s & 2: ushort coordinates (.i16)
    for (const auto &op : kOps) {
        char name[128];
        snprintf(name, sizeof name, "air.atomic_%s_explicit_texture_%s%s.%c.v4i32", op.air, dim, s & 2 ? ".i16" : "", s & 1 ? 's' : 'u');
        LLVMValueRef atomic = LLVMGetNamedFunction(module, name);
        if (!atomic || !LLVMGetFirstUse(atomic)) continue;
        LLVMValueRef intrinsic = igilIntrinsic(module, s & 1 ? op.igilS : op.igilU);
        if (!intrinsic) continue;
        if (!b) b = LLVMCreateBuilderInContext(ctx);
        bool layered = strstr(dim, "_array") != nullptr;
        LLVMValueRef calls[256];
        unsigned count = 0;
        for (LLVMUseRef u = LLVMGetFirstUse(atomic); u && count < 256; u = LLVMGetNextUse(u)) calls[count++] = LLVMGetUser(u);
        for (unsigned i = 0; i < count; i++) {
            LLVMValueRef call = calls[i];
            // Operand layouts (callee last):
            //   fetch/exchange: texture, coord, [layer,] value, order, scope
            //   load:           texture, coord, [layer,] order, scope
            //   store:          texture, value, coord, [layer,] order, scope
            //   cmpxchg:        texture, coord, [layer,] expected*, desired, success, failure, scope
            unsigned extra = layered ? 1 : 0, expect = op.kind == kLoad ? 5 : op.kind == kCompareExchange ? 8 : 6;
            if ((unsigned)LLVMGetNumOperands(call) != expect + extra) continue;
            LLVMValueRef texture = LLVMGetOperand(call, 0), image = imageTag(module, i32, texture);
            if (!image) {  // not an argument with a binding (a texture array element, ...): left as is, the compile fails
                if (logging()) fprintf(stderr, "[inteltex] %s: texture is not a function argument with a binding, not lowered\n", name);
                continue;
            }
            unsigned c = op.kind == kStore ? 2 : 1;
            LLVMValueRef coord = LLVMGetOperand(call, c), layer = layered ? LLVMGetOperand(call, c + 1) : nullptr;
            LLVMPositionBuilderBefore(b, call);
            LLVMValueRef zero = LLVMConstInt(i32, 0, 0), texturePointer = LLVMBuildPtrToInt(b, texture, i32, "");
            LLVMValueRef coords = LLVMBuildInsertElement(b, packCoords(b, i32, coord, layer), image, LLVMConstInt(i32, 3, 0), ""), old;
            if (op.kind == kCompareExchange) {
                LLVMValueRef expectedPointer = LLVMGetOperand(call, 1 + extra + 1);
                LLVMValueRef expected = LLVMBuildLoad(b, expectedPointer, "");
                LLVMValueRef expectedX = LLVMBuildExtractElement(b, expected, zero, "");
                LLVMValueRef desiredX = LLVMBuildExtractElement(b, LLVMGetOperand(call, 1 + extra + 2), zero, "");
                LLVMValueRef args[6] = {texturePointer, image, desiredX, coords, expectedX, zero};  // see hookedLowerImageAtomic
                old = LLVMBuildCall(b, intrinsic, args, 6, "");
                LLVMValueRef oldVector = LLVMBuildInsertElement(b, expected, old, zero, "");
                LLVMBuildStore(b, oldVector, expectedPointer);
                LLVMReplaceAllUsesWith(call, LLVMBuildICmp(b, 32 /* LLVMIntEQ */, old, expectedX, ""));
            } else {
                LLVMValueRef value = op.kind == kLoad ? zero
                                   : LLVMBuildExtractElement(b, LLVMGetOperand(call, op.kind == kStore ? 1 : 1 + extra + 1), zero, "");
                if (op.negate) value = LLVMBuildNeg(b, value, "");
                LLVMValueRef args[5] = {texturePointer, image, value, coords, zero};  // see hookedLowerImageAtomic
                old = LLVMBuildCall(b, intrinsic, args, 5, "");
                if (op.kind != kStore) LLVMReplaceAllUsesWith(call, LLVMBuildInsertElement(b, LLVMGetUndef(v4), old, zero, ""));
            }
            LLVMInstructionEraseFromParent(call);
            lowered++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return lowered;
}

// ---- step 2: IGIL --------------------------------------------------------------------------------------------------
// IMM_ATOMIC_<OP> dst, rI, rC, ...  where rC = MOV_SWZ rC, x, y, z, rT.c and MOV rT.c, <kImageTag | binding>
//   ->  MOV rC.w, 0;  IMM_ATOMIC_<OP> dst, uM, rC, ...   (uM: the DCL_UAVTYPED with LOCATION_INDEX binding, 0)
// An atomic whose texture can't be found gets "unresolved_image", which fails the compile rather than address the
// wrong texture.
static std::string operandRegister(const std::string &token) {  // " r12.x" -> "r12"
    size_t a = token.find_first_not_of(' ');
    if (a == std::string::npos || token[a] != 'r') return "";
    size_t b = token.find_first_not_of("0123456789", a + 1);
    return token.substr(a, (b == std::string::npos ? token.size() : b) - a);
}
static std::vector<std::string> instructionOperands(const std::string &line, std::string *opcode) {  // "\tOP a, b;"
    std::vector<std::string> out;
    size_t a = line.find_first_not_of("\t "), sp = a == std::string::npos ? a : line.find(' ', a);
    if (sp == std::string::npos) return out;
    if (opcode) *opcode = line.substr(a, sp - a);
    size_t end = line.find(';', sp);
    std::string rest = line.substr(sp + 1, (end == std::string::npos ? line.size() : end) - sp - 1);
    for (size_t pos = 0; pos <= rest.size();) {
        size_t comma = rest.find(',', pos);
        if (comma == std::string::npos) comma = rest.size();
        out.push_back(rest.substr(pos, comma - pos));
        pos = comma + 1;
    }
    return out;
}
// The closest line before `before` whose first operand is register reg; its opcode and operands.
static long definition(const std::vector<std::string> &lines, size_t before, const std::string &reg, std::string &opcode,
                       std::vector<std::string> &operands) {
    for (size_t d = before; d-- > 0;) {
        std::vector<std::string> ops = instructionOperands(lines[d], &opcode);
        if (!ops.empty() && operandRegister(ops[0]) == reg && opcode.compare(0, 4, "DCL_")) { operands = ops; return (long)d; }
    }
    return -1;
}

// ---- immediates assembled into vectors with per-pixel values ---------------------------------------------------------
// In a long fragment function, a MOV_SWZ that puts an immediate and per-pixel values in one vector (the IGIL for
// `FragColor = vec4(1.0, a, b, 1.0)`) gets the immediate's lanes right in only one pixel of eight; the others read 0.
// Whether the immediate comes from a register set once (MOV r1219.x, 0x3F800000, what the back end writes) or is the
// operand itself makes no difference; a lane computed per pixel is right. dEQP's uniform-block shaders with 51
// comparisons end that way (uniformbuffers *_instance_array_*: red and alpha 0 in 7 of 8 pixels; 36 comparisons were
// fine). Such lanes are computed per pixel: FMAX(FMIN(p, -inf), c), with p one of the instruction's per-pixel sources, is
// c for any p (NaN too) and exact for a normal float or zero c. Other bit patterns (NaN or denormal as floats, as small
// integers are) are left as they are. Haswell only (the IGIL hooks don't match Ivy Bridge's plugin).
// INTEL_SWIZZLE_IMMEDIATE_FIX=0 turns it off.
static bool exactThroughFmax(const std::string &immediate) {  // "0x3F800000": a normal float or a zero
    if (immediate.compare(0, 2, "0x") || immediate.size() < 3 || immediate.size() > 10 ||
        immediate.find_first_not_of("0123456789abcdefABCDEF", 2) != std::string::npos)
        return false;
    uint32_t bits = (uint32_t)strtoul(immediate.c_str() + 2, nullptr, 16), exponent = (bits >> 23) & 0xff;
    return (bits & 0x7fffffff) == 0 || (exponent != 0 && exponent != 0xff);
}
static unsigned perPixelSwizzleImmediates(std::string &s) {
    const char *setting = getenv("INTEL_SWIZZLE_IMMEDIATE_FIX");
    if ((setting && !strcmp(setting, "0")) || s.find("MOV_SWZ") == std::string::npos) return 0;
    size_t temps = s.find("DCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned long next = strtoul(s.c_str() + temps + 15, nullptr, 10) + 1;
    std::vector<std::string> lines;
    for (size_t pos = 0; pos <= s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        lines.push_back(s.substr(pos, eol - pos));
        pos = eol + 1;
    }
    auto trim = [](const std::string &t) {
        size_t a = t.find_first_not_of(' '), b = t.find_last_not_of(' ');
        return a == std::string::npos ? std::string() : t.substr(a, b - a + 1);
    };
    std::map<std::string, std::string> immediate;  // registers set once, by MOV rN.x, 0x...: their value ("" otherwise)
    for (const std::string &line : lines) {
        std::string opcode;
        std::vector<std::string> ops = instructionOperands(line, &opcode);
        if (ops.empty() || !opcode.compare(0, 4, "DCL_")) continue;
        std::string dst = operandRegister(ops[0]);
        if (dst.empty()) continue;
        bool isImmediate = opcode == "MOV" && ops.size() == 2 && trim(ops[0]) == dst + ".x" && !trim(ops[1]).compare(0, 2, "0x");
        immediate[dst] = isImmediate && !immediate.count(dst) ? trim(ops[1]) : std::string();
    }
    std::vector<std::string> out;
    unsigned fixed = 0;
    for (std::string &line : lines) {
        std::string opcode;
        std::vector<std::string> ops = instructionOperands(line, &opcode);
        if (opcode != "MOV_SWZ" || ops.size() != 5) { out.push_back(line); continue; }
        std::string dst = trim(ops[0]), reg = operandRegister(dst);
        std::string mask = dst.size() > reg.size() + 1 && dst[reg.size()] == '.' ? dst.substr(reg.size() + 1) : "xyzw";
        std::vector<std::string> sources(ops.begin() + 1, ops.end());
        std::string perPixel;  // a per-pixel source: a register not set by an immediate, or an input
        for (std::string &src : sources) {
            src = trim(src);
            std::string r = operandRegister(src);
            bool input = src.size() > 1 && src[0] == 'i' && isdigit((unsigned char)src[1]);
            if (perPixel.empty() && ((!r.empty() && immediate[r].empty()) || input)) perPixel = src;
        }
        if (perPixel.empty()) { out.push_back(line); continue; }
        std::string indent = line.substr(0, line.find_first_not_of(" \t"));
        std::map<std::string, std::string> made;  // immediate -> its per-pixel register
        bool changed = false;
        for (size_t lane = 0; lane < 4; lane++) {
            if (mask.find("xyzw"[lane]) == std::string::npos) continue;
            std::string &src = sources[lane], r = operandRegister(src);
            std::string value = !r.empty() && src == r + ".x" ? immediate[r] : (src.compare(0, 2, "0x") ? std::string() : src);
            if (value.empty() || !exactThroughFmax(value)) continue;
            if (!made.count(value)) {
                std::string low = "r" + std::to_string(next++), computed = "r" + std::to_string(next++);
                out.push_back(indent + "FMIN " + low + ".x, " + perPixel + ", 0xFF800000;");
                out.push_back(indent + "FMAX " + computed + ".x, " + low + ".x, " + value + ";");
                made[value] = computed + ".x";
            }
            src = made[value];
            changed = true;
        }
        if (!changed) { out.push_back(line); continue; }
        out.push_back(indent + "MOV_SWZ " + dst + ", " + sources[0] + ", " + sources[1] + ", " + sources[2] + ", " + sources[3] + ";");
        fixed++;
    }
    if (!fixed) return 0;
    std::string result;
    for (size_t i = 0; i < out.size(); i++) result += out[i] + (i + 1 < out.size() ? "\n" : "");
    size_t t = result.find("DCL_TEMPS r0..r");
    result.replace(t, result.find(';', t) - t, "DCL_TEMPS r0..r" + std::to_string(next - 1));
    s = result;
    return fixed;
}

// ---- vertex IDs in indirect draws ---------------------------------------------------------------------------------
// In drawIndexedPrimitives:...indirectBuffer: the vertex ID ([[vertex_id]], IGIL's VERTEXID input) leaves out the base
// vertex, unless the vertex function also reads [[base_vertex]]: then its system-value constants (DCL_CONSTANTREGISTER
// c0) list BASE_VERTEX_ID and the driver sets the draw up so VERTEXID includes it (direct draws are right either way).
// WebGPU's drawIndexedIndirect with a base vertex drew from the wrong vertices wherever Dawn's shaders use the vertex
// index (CTS draw:arguments, robust_access_vertex). Vertex shaders that read VERTEXID get BASE_VERTEX_ID in a free slot
// of c0 (or a c0 of their own). Haswell only (the IGIL hook). INTEL_BASE_VERTEX_FIX=0 turns it off.
static bool disabled(const char *setting);
static bool declareBaseVertex(std::string &s) {
    if (s.find("VERTEXSHADER") == std::string::npos || s.find(", VERTEXID;") == std::string::npos ||
        s.find("BASE_VERTEX_ID") != std::string::npos || disabled("INTEL_BASE_VERTEX_FIX"))
        return false;
    size_t block = s.find("DCL_CONSTANTREGISTER c0 =");
    if (block != std::string::npos) {
        size_t end = s.find("};", block), unused = s.find("UNUSED", block);
        if (end == std::string::npos || unused == std::string::npos || unused > end) return false;
        s.replace(unused, 6, "BASE_VERTEX_ID");
        return true;
    }
    size_t input = s.find("\tDCL_INPUT");
    if (input == std::string::npos) return false;
    s.insert(input, "\tDCL_CONSTANTREGISTER c0 =\n\t{\n\t\tBASE_VERTEX_ID, 0, 0,\n\t\tUNUSED, 0, 0,\n\t\tUNUSED, 0, 0,\n\t\tUNUSED, 0, 0\n\t};\n");
    return true;
}

// ---- fine derivatives -------------------------------------------------------------------------------------------------
// MSL has one dfdx / dfdy (fine on Apple GPUs: each row of a 2x2 quad gets its own difference), and WGSL's dpdxFine,
// dpdyFine and fwidthFine compile to it. The IGIL back end writes them as GRADIENT_X / GRADIENT_Y, which iCBE evaluates
// coarse (one difference per quad), so fine derivatives were wrong wherever the rows differ (WebGPU CTS dpdxFine,
// dpdyFine, fwidthFine: 8 of 8 cases each; the coarse ones pass either way). iCBE also reads GRADIENT_X_FINE /
// GRADIENT_Y_FINE, which these become. INTEL_FINE_DERIVATIVES_FIX=0 turns it off.
static unsigned fineGradients(std::string &s) {
    if (disabled("INTEL_FINE_DERIVATIVES_FIX")) return 0;
    unsigned n = 0;
    for (size_t pos = 0; (pos = s.find("GRADIENT_", pos)) != std::string::npos; pos += 9) {
        if (pos && !isspace((unsigned char)s[pos - 1])) continue;
        if (s.compare(pos, 11, "GRADIENT_X ") && s.compare(pos, 11, "GRADIENT_Y ")) continue;
        s.insert(pos + 10, "_FINE");
        n++;
    }
    return n;
}

// ---- explicit-LOD sample coordinates ---------------------------------------------------------------------------------
// For a sample with an explicit LOD in a compute kernel the IGIL writer builds the message in the destination register
// (rD.xyz = the coordinates, rD.w = the LOD) and then names the coordinate register itself as the operand:
//     MOV r58.xyz, r56.xyzx;  MOV r58.w, r57.xxxx;  SAMPLE_LC r58, r56(0, 0, 0), t0, s0, r38.x, 2D;
// iCBE takes the LOD from the operand's w, which nothing wrote when the coordinates came from a select of 2-component
// values (Dawn loads them from a uniform array): whatever the register last held became the LOD, so the level, and with
// a linear mip filter the blend, changed from run to run (WebGPU CTS textureSampleCompareLevel in compute: 160 cases,
// with wrong results in different places on every run). The operand becomes the destination register, which holds
// the coordinates and the LOD. 2D samples only: a cube array's coordinate operand carries the array index in w, and the
// back end finds the LOD elsewhere there (the CTS's cube, 2D-array and cube-array cases passed already, a09 relies on
// it). INTEL_SAMPLE_LOD_OPERAND_FIX=0 turns it off.
static unsigned sampleLodOperands(std::string &s) {
    if (disabled("INTEL_SAMPLE_LOD_OPERAND_FIX") || s.find("\tSAMPLE_L") == std::string::npos) return 0;
    unsigned n = 0;
    size_t previous[2] = {std::string::npos, std::string::npos};  // starts of the two lines before this one
    for (size_t pos = 0; pos < s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        if (eol > pos) {
            char op[32];
            unsigned d, c;
            int at = 0;
            if (sscanf(s.c_str() + pos, "\t%31[A-Z_] r%u, r%u(%n", op, &d, &c, &at) == 3 && at && !strncmp(op, "SAMPLE_L", 8) && d != c &&
                previous[0] != std::string::npos) {
                char coords[64], lod[64];
                snprintf(coords, sizeof coords, "\tMOV r%u.xyz, r%u.xyzx;", d, c);
                snprintf(lod, sizeof lod, "\tMOV r%u.w, ", d);
                bool plain2D = eol >= pos + 5 && !s.compare(eol - 5, 5, ", 2D;");
                if (plain2D && !s.compare(previous[0], strlen(coords), coords) && !s.compare(previous[1], strlen(lod), lod)) {
                    size_t operand = s.find(" r", pos + strlen(op) + 1);  // the coordinate operand, after "rD,"
                    operand = s.find(" r", operand + 2);
                    std::string replacement = " r" + std::to_string(d) + "(";
                    size_t old = operand + 2 + std::to_string(c).size() + 1 - operand;
                    s.replace(operand, old, replacement);
                    eol = s.find('\n', pos);
                    if (eol == std::string::npos) eol = s.size();
                    n++;
                }
            }
            previous[0] = previous[1];
            previous[1] = pos;
            if (s.compare(pos, 1, "\t") || eol - pos < 2) previous[0] = previous[1] = std::string::npos;  // blank or label: no pattern across it
        }
        pos = eol + 1;
    }
    return n;
}

// ---- a narrow mask after a narrower one --------------------------------------------------------------------------------
// The IGIL writer re-truncates a 16-bit value after an operation (AND rC, rB, 0xFFFF), also right after an AND that
// already left it narrower (AND rB, rA, 255 for a uchar lane). iCBE takes AND 0xFFFF for a zero-extension from 16 bits,
// reads the word of rA instead of rB and drops the 255: in ushort2(...) & ushort2((uchar)x, ...) the uchar lane kept
// bits 8-15 of x (seen in the disassembly as and g93, g67<16,8,2>UW, 0xffff9a4b, folding 255, 0xFFFF and 0x9a4b into
// one mask; the MacBookPro11,5 session's narrow-vector fuzzing, seed 53). Such a second AND changes nothing, so it
// becomes a MOV. INTEL_NARROW_MASK_FIX=0 turns it off.
static unsigned redundantNarrowMasks(std::string &s) {
    if (disabled("INTEL_NARROW_MASK_FIX")) return 0;
    unsigned n = 0;
    size_t previous = std::string::npos;
    for (size_t pos = 0; pos < s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        if (eol == pos) { pos = eol + 1; continue; }
        unsigned c, b, b2, a;
        char mask[32], first[32];
        int at = 0;
        if (previous != std::string::npos && sscanf(s.c_str() + pos, "\tAND r%u.x, r%u.x, %31[0-9A-Fx];%n", &c, &b, mask, &at) == 3 && at &&
            sscanf(s.c_str() + previous, "\tAND r%u.x, r%u.x, %31[0-9A-Fx];", &b2, &a, first) == 3 && b2 == b) {
            unsigned long outer = strtoul(mask, nullptr, 0), inner = strtoul(first, nullptr, 0);
            if ((outer == 0xFFFF || outer == 0xFF) && inner && (inner & ~outer) == 0) {
                char replacement[64];
                int len = snprintf(replacement, sizeof replacement, "\tMOV r%u.x, r%u.x;", c, b);
                s.replace(pos, (size_t)at, replacement, (size_t)len);
                eol = s.find('\n', pos);
                if (eol == std::string::npos) eol = s.size();
                n++;
            }
        }
        previous = pos;
        pos = eol + 1;
    }
    return n;
}

// ---- sign extensions, in the IGIL text --------------------------------------------------------------------------------
// iCBE keeps the result of STOI / BTOI (a short / char sign-extended to 32 bits) in a 16- / 8-bit register and extends it
// where it is read, and a merge loses that: uint(short2(...).y) XORed into a vector lane, which a store at a variable
// index then merged (MOV_CND) with a 32-bit value, read back zero-extended, 0x0000fe13 for 0xfffffe13 (mslfuzz2 VEC=1
// seed 1865, i45). They become SHL 16 / SAR 16 (24 for bytes), which iCBE computes on 32 bits. INTEL_SIGN_EXTEND_FIX=0
// turns it off.
static unsigned signExtensions(std::string &s) {
    if (disabled("INTEL_SIGN_EXTEND_FIX") || (s.find("\tSTOI ") == std::string::npos && s.find("\tBTOI ") == std::string::npos)) return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    std::vector<std::string> lines;
    for (size_t pos = 0; pos <= s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        lines.push_back(s.substr(pos, eol - pos));
        pos = eol + 1;
    }
    unsigned n = 0;
    for (std::string &l : lines) {
        unsigned d, src;
        char op[8];
        int at = 0;
        // scalar (r.x) and whole-vector (r) forms: a vector STOI of AND results lost the sign the same way when the max
        // that read its lanes wrote them back (VEC=1 seed 4647, i57)
        bool scalar = sscanf(l.c_str(), "\t%7[A-Z] r%u.x, r%u.x;%n", op, &d, &src, &at) == 3 && at == (int)l.size();
        bool vector = !scalar && sscanf(l.c_str(), "\t%7[A-Z] r%u, r%u;%n", op, &d, &src, (at = 0, &at)) == 3 && at == (int)l.size();
        if (!scalar && !vector) continue;
        unsigned shift = !strcmp(op, "STOI") ? 16 : !strcmp(op, "BTOI") ? 24 : 0;
        if (!shift) continue;
        unsigned up = ++last;
        const char *c = scalar ? ".x" : "";
        char buffer[160];
        snprintf(buffer, sizeof buffer, "\tSHL r%u%s, r%u%s, %u;\n\tSAR r%u%s, r%u%s, %u;", up, c, src, c, shift, d, c, up, c, shift);
        l = buffer;
        n++;
    }
    if (!n) return 0;
    std::string out;
    for (size_t i = 0; i < lines.size(); i++) { out += lines[i]; if (i + 1 < lines.size()) out += '\n'; }
    size_t numberAt = out.find("\tDCL_TEMPS r0..r") + 16, numberEnd = out.find_first_not_of("0123456789", numberAt);
    out.replace(numberAt, numberEnd - numberAt, std::to_string(last));
    s = out;
    return n;
}

// ---- signed compares of a sum with zero, in the IGIL text ---------------------------------------------------------
// In pixel and vertex shaders iCBE folds the constant of an add into a signed compare of the sum with zero, as if the add
// couldn't overflow: (x + C) < 0 became x < -C (cmp g20, -902107310 in the EU code), and likewise (x + C) > 0. MSL's
// unsigned add wraps, so where x + C wrapped past the sign bit the compare went the wrong way: in
// `if (c) v += (int)(x + 902107310u) < 0 ? y % 1000 : 777u` the 14 pixels whose x was in [2^31 - C, 2^31) got 777
// (fragment fuzzing on the Iris Pro, VEC=1 seed 445; also with a negative constant; compute functions, >= 0, <= -7,
// other constants and unsigned compares were right). ICMP.lt / ge / gt / le of an IADD result and a zero register, either
// way round, become tests of the sum's sign bit (SHR 31) and, for > 0 and <= 0, of the sum being 0 (ICMP.eq, which is
// exact either way).
// INTEL_SUM_SIGN_TEST_FIX=0 turns it off. Test: i65.
static unsigned signTestsOfSums(std::string &s) {
    if (disabled("INTEL_SUM_SIGN_TEST_FIX") || (s.find("\tPIXELSHADER") == std::string::npos && s.find("\tVERTEXSHADER") == std::string::npos))
        return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    std::vector<std::string> lines;
    for (size_t pos = 0; pos <= s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        lines.push_back(s.substr(pos, eol - pos));
        pos = eol + 1;
    }
    std::set<unsigned> zeros, sums;  // registers last set by MOV r.x, 0 / by an IADD
    unsigned n = 0;
    for (std::string &l : lines) {
        unsigned d, a, b;
        int at = 0;
        char op[16], pred[4];
        if (sscanf(l.c_str(), "\tICMP.%3[a-z] r%u.x, r%u.x, r%u.x;%n", pred, &d, &a, &b, &at) == 4 && at == (int)l.size()) {
            static const char *const kPreds[4] = {"lt", "ge", "gt", "le"}, *const kSwapped[4] = {"gt", "le", "lt", "ge"};
            int k = 0;
            while (k < 4 && strcmp(pred, kPreds[k])) k++;
            bool sumFirst = sums.count(a) && zeros.count(b), sumSecond = zeros.count(a) && sums.count(b);
            if (k < 4 && (sumFirst || sumSecond)) {
                unsigned sum = sumFirst ? a : b, zero = sumFirst ? b : a, sign = ++last;
                const char *p = sumFirst ? kPreds[k] : kSwapped[k];  // as sum <p> 0
                char buffer[320];
                if (!strcmp(p, "lt") || !strcmp(p, "ge"))  // negative: the sign bit set; >= 0: clear
                    snprintf(buffer, sizeof buffer, "\tSHR r%u.x, r%u.x, 31;\n\tICMP.%s r%u.x, r%u.x, r%u.x;", sign, sum, !strcmp(p, "lt") ? "ne" : "eq", d, sign, zero);
                else {  // > 0: neither negative nor zero; <= 0: either
                    unsigned isZero = ++last, either = ++last;
                    snprintf(buffer, sizeof buffer,
                             "\tSHR r%u.x, r%u.x, 31;\n\tICMP.eq r%u.x, r%u.x, r%u.x;\n\tAND r%u.x, r%u.x, 0x1;\n\tOR r%u.x, r%u.x, r%u.x;\n\tICMP.%s r%u.x, r%u.x, r%u.x;",
                             sign, sum, isZero, sum, zero, isZero, isZero, either, sign, isZero, !strcmp(p, "gt") ? "eq" : "ne", d, either, zero);
                }
                l = buffer;
                n++;
            }
        }
        // what the line leaves in its destination register
        if (sscanf(l.c_str(), "\t%15s r%u", op, &d) == 2) {
            zeros.erase(d), sums.erase(d);
            if (!strcmp(op, "IADD")) sums.insert(d);
            else if (!strcmp(op, "MOV") && sscanf(l.c_str(), "\tMOV r%u.x, 0;%n", &d, (at = 0, &at)) == 1 && at == (int)l.size()) zeros.insert(d);
        }
    }
    if (!n) return 0;
    std::string out;
    for (size_t i = 0; i < lines.size(); i++) { out += lines[i]; if (i + 1 < lines.size()) out += '\n'; }
    size_t numberAt = out.find("\tDCL_TEMPS r0..r") + 16, numberEnd = out.find_first_not_of("0123456789", numberAt);
    out.replace(numberAt, numberEnd - numberAt, std::to_string(last));
    s = out;
    return n;
}

// ---- negations feeding a signed divide, in the IGIL text ------------------------------------------------------------
// i26's bug again, from a negation the IR doesn't show: the front end wrote (short)(-(int)v) % d as (v * -65536) >> 16,
// and the back end, knowing v was 0 or 1, made that IADD r, 0, -v; iCBE folds that into the IDIV as a source modifier
// and drops it, so the remainder came out as v % d in every thread (mslfuzz2 VEC=1 seed 917). Such an IADD rA, rZero, -rX
// becomes XOR rT, rX, -1 and IADD rA, rT, 1, which iCBE leaves alone. The negation also reaches the divide through
// copies, merges included (v2 = -(int)x in one case of a switch, the loop that divides it made a subroutine reading a
// copy of a copy: mslfuzz2 LONG=1 seed 2592, i60), and through operations iCBE folds into copies: v0 = -(int)(x &
// 0x7fffffff); v0 -= min(mulhi(..., 0u), 0u) reached the back end as IADD r80, r78, -r79 with r79 = UMIN r19, r19 of
// zeros, and (int)v0 / d dropped the sign (mslfuzz2 plain seed 7727, i61; the stock compiler is wrong in all three). So
// every such negation in a shader with an IDIV is rewritten, whatever leads it to the divide. INTEL_SIGNED_DIV_NEG_FIX=0
// turns it off with i26.
static unsigned negatedDivideOperands(std::string &s) {
    if (disabled("INTEL_SIGNED_DIV_NEG_FIX") || s.find("\tIDIV ") == std::string::npos) return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    std::vector<std::string> lines;
    for (size_t pos = 0; pos <= s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        lines.push_back(s.substr(pos, eol - pos));
        pos = eol + 1;
    }
    std::map<unsigned, int> definitions;
    std::set<unsigned> zeros;  // registers whose only definition is MOV rN.x, 0
    for (const std::string &l : lines) {
        unsigned d;
        if (sscanf(l.c_str(), "\t%*[A-Za-z_0-9.] r%u", &d) != 1) continue;
        definitions[d]++;
        int at = 0;
        if (sscanf(l.c_str(), "\tMOV r%u.x, 0;%n", &d, &at) == 1 && at == (int)l.size()) zeros.insert(d);
    }
    unsigned n = 0;
    for (std::string &l : lines) {
        unsigned d, z, x;
        int at = 0;
        if (sscanf(l.c_str(), "\tIADD r%u.x, r%u.x, -r%u.x;%n", &d, &z, &x, &at) != 3 || at != (int)l.size()) continue;
        if (!zeros.count(z) || definitions[z] != 1) continue;
        unsigned flipped = ++last;
        char buffer[160];
        snprintf(buffer, sizeof buffer, "\tXOR r%u.x, r%u.x, -1;\n\tIADD r%u.x, r%u.x, 1;", flipped, x, d, flipped);
        l = buffer;
        n++;
    }
    if (!n) return 0;
    std::string out;
    for (size_t i = 0; i < lines.size(); i++) { out += lines[i]; if (i + 1 < lines.size()) out += '\n'; }
    size_t numberAt = out.find("\tDCL_TEMPS r0..r") + 16, numberEnd = out.find_first_not_of("0123456789", numberAt);
    out.replace(numberAt, numberEnd - numberAt, std::to_string(last));
    s = out;
    return n;
}

// ---- loop-carried copies before a loop's exit ------------------------------------------------------------------------
// The back end ends a loop body with the copies that carry values into the next iteration (MOV rNext, value) and then
// BREAK_CND. A register that took the previous value at the top of the body (MOV rOld, rNext) and is read after the
// loop then gets the new value from iCBE, as if the copy had been propagated past the redefinition: with i07's private
// array rewrite, `p[...] = pc[addsat(0x7fffffff, v4 ^ t) & 7]; v4 = 0;` in a loop that the store is sunk out of read
// with v4 = 0 also in threads that left in the first iteration (mslfuzz2 plain seed 565). Copying with IADD or OR
// instead of MOV changed nothing. Copies whose register isn't read outside the loop move after the BREAK_CND, where
// they do the same for the next iteration and nothing on the way out. INTEL_LOOP_EXIT_COPY_FIX=0 turns it off.
static unsigned loopExitCopies(std::string &s) {
    if (disabled("INTEL_LOOP_EXIT_COPY_FIX") || s.find("\tBREAK_CND") == std::string::npos) return 0;
    std::vector<std::string> lines;
    for (size_t pos = 0; pos <= s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        lines.push_back(s.substr(pos, eol - pos));
        pos = eol + 1;
    }
    // registers each line mentions, and the register a line only sets (MOV rN.x, <operand>)
    std::vector<std::set<unsigned>> mentions(lines.size());
    std::vector<int> moveTarget(lines.size(), -1);
    std::vector<std::string> moveSource(lines.size());
    for (size_t i = 0; i < lines.size(); i++) {
        const std::string &l = lines[i];
        for (size_t k = 0; k + 1 < l.size(); k++)
            if (l[k] == 'r' && isdigit((unsigned char)l[k + 1]) && (k == 0 || !isalnum((unsigned char)l[k - 1])))
                mentions[i].insert((unsigned)strtoul(l.c_str() + k + 1, nullptr, 10));
        unsigned d;
        char source[64];
        int at = 0;
        if (sscanf(l.c_str(), "\tMOV r%u.x, %63[^;];%n", &d, source, &at) == 2 && at == (int)l.size())
            moveTarget[i] = (int)d, moveSource[i] = source;
    }
    auto readOutside = [&](unsigned r, size_t top, size_t end) {  // outside lines [top, end], other than MOV r.x, <not r>
        for (size_t i = 0; i < lines.size(); i++) {
            if ((i >= top && i <= end) || !mentions[i].count(r)) continue;
            bool onlySets = moveTarget[i] == (int)r &&
                            !(moveSource[i][0] == 'r' && strtoul(moveSource[i].c_str() + 1, nullptr, 10) == r);
            if (!onlySets) return true;
        }
        return false;
    };
    std::vector<size_t> loops;
    std::vector<std::pair<size_t, std::vector<size_t>>> moves;  // BREAK_CND line, the copies to put after it
    for (size_t i = 0; i < lines.size(); i++) {
        if (lines[i] == "\tLOOP;") { loops.push_back(i); continue; }
        if (lines[i] != "\tENDLOOP;" || loops.empty()) continue;
        size_t top = loops.back();
        loops.pop_back();
        size_t b = i;
        while (b > top + 1 && lines[b - 1].empty()) b--;
        unsigned condition;
        char kind;
        if (b <= top + 1 || sscanf(lines[--b].c_str(), "\tBREAK_CND.%c r%u.x;", &kind, &condition) != 2) continue;
        std::vector<size_t> block;  // the MOVs right before the BREAK_CND, in order
        for (size_t k = b; k > top + 1 && (moveTarget[k - 1] >= 0 || lines[k - 1].empty()); k--)
            if (moveTarget[k - 1] >= 0) block.insert(block.begin(), k - 1);
        std::vector<size_t> moved;
        std::set<unsigned> staying;  // registers written by the copies that stay
        for (size_t c = block.size(); c-- > 0;) {  // from the last copy back, so later copies are already decided
            unsigned d = (unsigned)moveTarget[block[c]];
            bool ok = d != condition && !readOutside(d, top, i);
            for (size_t later = c + 1; ok && later < block.size(); later++) {
                bool laterMoved = std::find(moved.begin(), moved.end(), block[later]) != moved.end();
                if (!laterMoved && mentions[block[later]].count(d)) ok = false;  // a copy that stays reads or writes it
            }
            for (unsigned r : mentions[block[c]])
                if (r != d && staying.count(r)) ok = false;  // its source is overwritten by a copy that stays
            if (ok) moved.insert(moved.begin(), block[c]);
            else staying.insert(d);
        }
        if (!moved.empty()) moves.push_back({b, moved});
    }
    if (moves.empty()) return 0;
    unsigned n = 0;
    std::vector<bool> drop(lines.size(), false);
    std::map<size_t, std::string> after;
    for (auto &m : moves)
        for (size_t c : m.second) drop[c] = true, after[m.first] += '\n' + lines[c], n++;
    std::string out;
    for (size_t i = 0; i < lines.size(); i++) {
        if (drop[i]) continue;
        if (!out.empty() || i) out += '\n';
        out += lines[i];
        if (after.count(i)) out += after[i];
    }
    s = out;
    return n;
}

// ---- right shifts of narrow values ----------------------------------------------------------------------------------
// iCBE gives SHR / SAR of a value it knows is narrow, a constant below 65536 or an AND with such a mask (a uchar or
// ushort cast), a result register as narrow as that value: a byte for 1 or x & 255, a word for 300 or x & 65535. It can
// then merge that register with another copy of the same variable and drop its high bits: v0 = (uint)(x / y), replaced
// by (uchar)1 >> s in a loop, came out as the quotient's low byte in all 256 threads, also where the loop never ran
// (mslfuzz2 LONG=1 seed 6; the 64-bit division's loops only set up the merge), and a vector lane lost its high bits
// the same way (VEC=1 seed 526). Constants from 65536 up, SHL, and AND / UMIN with a constant in a register were right.
// Such a shift is done on the value with bit 31 set, and the shifted bit 31 is XORed away, so every register involved is
// 32 bits wide (the shift count is masked to 5 bits on both). An AND with an immediate mask below 65536 is narrow too:
// (ushort)(x >> s), merged with a 64-bit quotient in the other arm of a select, kept the quotient's low 16 bits (LONG=1
// seed 314). Where such an AND's result is copied into a register that two or more MOVs set (the back end's phi
// copies), or read by a min / max or a signed operation (IMAX / IMIN / UMAX / UMIN / ICMP / IDIV; IMAX took it as a
// signed narrow value, i46) or a 32-bit saturating add / subtract (UADD_sat read other SIMD lanes' bytes, i48), it
// becomes (x | bit 31) & (mask | bit 31), XOR bit 31. INTEL_NARROW_SHIFT_FIX=0 turns both off.
static unsigned narrowShifts(std::string &s) {
    if (disabled("INTEL_NARROW_SHIFT_FIX") ||
        (s.find("\tSHR ") == std::string::npos && s.find("\tSAR ") == std::string::npos && s.find("\tAND ") == std::string::npos))
        return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    std::vector<std::string> lines;
    for (size_t pos = 0; pos <= s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        lines.push_back(s.substr(pos, eol - pos));
        pos = eol + 1;
    }
    // registers with a single definition, which is MOV rN.x, <immediate> or AND rN.x, <source>, <immediate>
    auto immediate = [](const char *text, long &value) {
        char *end;
        value = strtol(text, &end, 0);
        return end != text && *end == 0;
    };
    std::map<unsigned, long> bound;  // register -> the immediate (the value, or the mask)
    std::map<unsigned, int> definitions;
    std::set<unsigned> widened;  // USTOI / UBTOI results: a 16- / 8-bit value zero-extended (VEC=1 seed 3325, i54: the
                                 // shift of USTOI of a constant 7 by 8 came out 7, so (ushort)7 << 5 >> 13 gave 7, not 0)
    for (const std::string &l : lines) {
        unsigned d;
        char source[64], mask[32];
        int at = 0;
        long value;
        if (sscanf(l.c_str(), "\t%*[A-Za-z_0-9.] r%u", &d) != 1) continue;
        definitions[d]++;
        if ((!l.compare(0, 7, "\tUSTOI ") || !l.compare(0, 7, "\tUBTOI ")) && sscanf(l.c_str() + 7, "r%u.x, %63[^;];%n", &d, source, &at) == 2 &&
            at == (int)l.size() - 7)
            widened.insert(d);
        if (sscanf(l.c_str(), "\tMOV r%u.x, %31[-0-9A-Fa-fx];%n", &d, mask, &at) == 2 && at == (int)l.size() && immediate(mask, value))
            bound[d] = value;
        else if (sscanf(l.c_str(), "\tAND r%u.x, %63[^,], %31[-0-9A-Fa-fx];%n", &d, source, mask, &at) == 3 && at == (int)l.size() &&
                 immediate(mask, value))
            bound[d] = value;
    }
    // merge registers: set by two or more MOVs (the back end's phi copies), and the registers copied into one
    std::map<unsigned, int> moves;
    std::vector<std::pair<unsigned, unsigned>> copies;  // (destination, source register) of MOV rD.x, rS.x
    for (const std::string &l : lines) {
        unsigned d, r;
        char source[64];
        int at = 0, at2 = 0;
        if (sscanf(l.c_str(), "\tMOV r%u.x, %63[^;];%n", &d, source, &at) != 2 || at != (int)l.size()) continue;
        moves[d]++;
        if (sscanf(source, "r%u.x%n", &r, &at2) == 1 && at2 == (int)strlen(source)) copies.push_back({d, r});
    }
    std::set<unsigned> intoMerge;
    for (auto &c : copies) if (moves[c.first] >= 2) intoMerge.insert(c.second);
    // registers read by a min / max or a signed operation, which takes a narrow source as a signed narrow value:
    // IMAX r, 0, (x AND 255) returned 0 for x & 255 >= 128 (mslfuzz2 VEC=1 seed 1889, i46); and by a 32-bit saturating
    // add / subtract: UADD_sat of two such registers came out as other SIMD lanes' bytes (VEC=1 seed 1568, i48; the
    // narrow saturating forms are their own opcodes, UBADD / USADD / BADD / SADD, and are left alone)
    auto saturating = [](const std::string &l) {
        return (!l.compare(0, 6, "\tUADD ") || !l.compare(0, 6, "\tIADD ") || !l.compare(0, 6, "\tUSUB ") || !l.compare(0, 6, "\tISUB ")) &&
               l.find("_sat.") != std::string::npos;
    };
    // Such a register can also reach the operation through copies, the AND's lane moved into a vector and back out:
    // AND r56.x, r54.x, 255; MOV_SWZ r96, r89.x, r56.x, ...; MOV r97.x, r96.y; IDIV ..., r97.x, ... divided a negative
    // byte for bytes 128-255 (VEC=1 seed 2387, i52). Single-definition MOV and MOV_SWZ copies are followed, lane by lane,
    // to the register that computed the value.
    std::map<unsigned, const std::string *> definition;  // registers defined once
    for (const std::string &l : lines) {
        unsigned d;
        if (sscanf(l.c_str(), "\t%*[A-Za-z_0-9.] r%u", &d) == 1 && definitions[d] == 1) definition[d] = &l;
    }
    auto origin = [&](unsigned r, char lane) {
        for (int depth = 0; depth < 16 && definition.count(r); depth++) {
            const std::string &l = *definition[r];
            unsigned d, src[4];
            char c[4];
            int at = 0;
            if (sscanf(l.c_str(), "\tMOV r%u.x, r%u.%c;%n", &d, &src[0], &c[0], &at) == 3 && at == (int)l.size() && lane == 'x')
                r = src[0], lane = c[0];
            else if (sscanf(l.c_str(), "\tMOV r%u, r%u;%n", &d, &src[0], &at) == 2 && at == (int)l.size())
                r = src[0];
            else if (sscanf(l.c_str(), "\tMOV_SWZ r%u, r%u.%c, r%u.%c, r%u.%c, r%u.%c;%n", &d, &src[0], &c[0], &src[1], &c[1], &src[2],
                            &c[2], &src[3], &c[3], &at) == 9 && at == (int)l.size() && lane >= 'w' && lane <= 'z') {
                int k = lane == 'w' ? 3 : lane - 'x';
                r = src[k], lane = c[k];
            } else
                break;
        }
        return r;
    };
    for (const std::string &l : lines) {
        // UDIV too: the AND 255 of (ushort)(uchar)x / 1, divided by 1 and masked with 0xFFFF in a vector, lost its 255 as
        // i29's does (VEC=1 seed 4614, i55; the stock compiler too)
        int skip = (!l.compare(0, 6, "\tIDIV ") || !l.compare(0, 6, "\tUDIV ")) ? 2 : (!l.compare(0, 6, "\tIMAX ") || !l.compare(0, 6, "\tIMIN ") || !l.compare(0, 6, "\tUMAX ") ||
                                                       !l.compare(0, 6, "\tUMIN ") || !l.compare(0, 5, "\tICMP") || saturating(l)) ? 1 : 0;
        if (!skip) continue;
        int seen = 0;
        for (size_t k = 0; k + 1 < l.size(); k++)
            if (l[k] == 'r' && isdigit((unsigned char)l[k + 1]) && (k == 0 || !isalnum((unsigned char)l[k - 1]))) {
                if (seen++ < skip) continue;
                char *end;
                unsigned r = (unsigned)strtoul(l.c_str() + k + 1, &end, 10);
                intoMerge.insert(r);
                if (*end == '.' && end[1]) intoMerge.insert(origin(r, end[1]));
            }
    }
    auto small = [&](const std::string &operand) {
        long value;
        unsigned r;
        int at = 0;
        if (sscanf(operand.c_str(), "r%u.x%n", &r, &at) == 1 && at == (int)operand.size())
            return definitions[r] == 1 && ((bound.count(r) && bound[r] >= 0 && bound[r] < 65536) || widened.count(r));
        return immediate(operand.c_str(), value) && value >= 0 && value < 65536;
    };
    unsigned n = 0;
    for (std::string &l : lines) {
        unsigned d;
        char op[4], source[64], count[64];
        int at = 0;
        if (sscanf(l.c_str(), "\t%3[A-Z] r%u.x, %63[^,], %63[^;];%n", op, &d, source, count, &at) != 4 || at != (int)l.size())
            continue;
        long mask;
        char self[16];
        snprintf(self, sizeof self, "r%u.x", d);
        if (!strcmp(op, "AND") && intoMerge.count(d) && strcmp(source, self) && immediate(count, mask) && mask >= 0 && mask < 65536) {
            // x & mask, copied into a merge register: (x | bit 31) & (mask | bit 31), then bit 31 XORed away
            unsigned high = ++last, masked = ++last;
            char buffer[256];
            snprintf(buffer, sizeof buffer, "\tOR r%u.x, %s, -2147483648;\n\tAND r%u.x, r%u.x, %d;\n\tXOR r%u.x, r%u.x, -2147483648;", high,
                     source, masked, high, (int32_t)((uint32_t)mask | 0x80000000u), d, masked);
            l = buffer;
            n++;
            continue;
        }
        if ((strcmp(op, "SHR") && strcmp(op, "SAR")) || !small(source)) continue;
        unsigned high = ++last, shifted = ++last, bit = ++last, bitShifted = ++last;
        char setHigh[96], buffer[384];
        long value;
        if (source[0] == 'r') snprintf(setHigh, sizeof setHigh, "\tOR r%u.x, %s, -2147483648;", high, source);
        else immediate(source, value), snprintf(setHigh, sizeof setHigh, "\tMOV r%u.x, %d;", high, (int32_t)((uint32_t)value | 0x80000000u));
        snprintf(buffer, sizeof buffer,
                 "%s\n\tSHR r%u.x, r%u.x, %s;\n\tMOV r%u.x, -2147483648;\n\tSHR r%u.x, r%u.x, %s;\n\tXOR r%u.x, r%u.x, r%u.x;",
                 setHigh, shifted, high, count, bit, bitShifted, bit, count, d, shifted, bitShifted);
        l = buffer;
        n++;
    }
    if (!n) return 0;
    std::string out;
    for (size_t i = 0; i < lines.size(); i++) { out += lines[i]; if (i + 1 < lines.size()) out += '\n'; }
    size_t numberAt = out.find("\tDCL_TEMPS r0..r") + 16, numberEnd = out.find_first_not_of("0123456789", numberAt);
    out.replace(numberAt, numberEnd - numberAt, std::to_string(last));
    s = out;
    return n;
}

// ---- narrow negations ----------------------------------------------------------------------------------------------
// The back end writes the negation of a char lane as BADD rD, rZ, -rX with rZ = MOV 0, and the sign extension that
// follows as BTOI rD. iCBE folds the two into the negation of the sign-extended lane, -(sext x) instead of
// sext(-x), which differs for x = 0x80 only: -(char)-128 came out +128 instead of -128 (the MacBookPro11,5 session's
// narrow-vector fuzzing, seeds 70 and 110). Scalar chars and zero extensions were right. Swapping the operands doesn't help, and
// a 32-bit IADD loses the sign extension (iCBE then takes BTOI for a no-op), so the negation becomes XOR 0xFF (0xFFFF
// for SADD) and an add of 1 of the same width, in two new registers. INTEL_NARROW_NEGATE_FIX=0 turns it off.
static unsigned narrowNegations(std::string &s) {
    if (disabled("INTEL_NARROW_NEGATE_FIX") || (s.find("\tBADD ") == std::string::npos && s.find("\tSADD ") == std::string::npos)) return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    unsigned n = 0;
    std::string out;
    out.reserve(s.size() + 256);
    for (size_t pos = 0; pos < s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        std::string line = s.substr(pos, eol - pos);
        char width, cd, cz, cx;
        unsigned d, z, x;
        int at = 0;
        if (sscanf(line.c_str(), "\t%cADD r%u.%c, r%u.%c, -r%u.%c;%n", &width, &d, &cd, &z, &cz, &x, &cx, &at) == 7 && at &&
            (width == 'B' || width == 'S')) {
            char zero[48];
            snprintf(zero, sizeof zero, "\tMOV r%u.%c, 0;\n", z, cz);
            if (s.rfind(zero, pos) != std::string::npos) {
                unsigned flipped = ++last, one = ++last;
                char buffer[256];
                snprintf(buffer, sizeof buffer, "\tXOR r%u.x, r%u.%c, %s;\n\tMOV r%u.x, 1;\n\t%cADD r%u.%c, r%u.x, r%u.x;", flipped, x, cx,
                         width == 'B' ? "0xFF" : "0xFFFF", one, width, d, cd, flipped, one);
                line = buffer;
                n++;
            }
        }
        out += line;
        if (eol < s.size()) out += '\n';
        pos = eol + 1;
    }
    if (!n) return 0;
    size_t numberAt = out.find("\tDCL_TEMPS r0..r") + 16, numberEnd = out.find_first_not_of("0123456789", numberAt);
    out.replace(numberAt, numberEnd - numberAt, std::to_string(last));
    s = out;
    return n;
}

// ---- narrow unsigned divides ---------------------------------------------------------------------------------------
// The back end writes division of 8- and 16-bit unsigned lanes as UBDIV / USDIV. iCBE drops the AND 0xFF / 0xFFFF that
// zero-extends such an operand (it takes the divide to read only the low byte or word) while the divide uses the whole
// register: a uchar lane built from a select of 32-bit values was divided with its upper bits still in place (the
// MacBookPro11,5 session's narrow-vector fuzzing, seed 31), and narrow constants arrive sign-extended (MOV r, -30467
// for 35069). Each becomes a 32-bit UDIV of copies masked to the lane's width, in two new registers per divide.
// INTEL_NARROW_UDIV_FIX=0 turns it off.
static unsigned narrowUnsignedDivides(std::string &s) {
    if (disabled("INTEL_NARROW_UDIV_FIX") || (s.find("\tUBDIV ") == std::string::npos && s.find("\tUSDIV ") == std::string::npos)) return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    unsigned n = 0;
    std::string out;
    out.reserve(s.size() + 256);
    for (size_t pos = 0; pos < s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        std::string line = s.substr(pos, eol - pos);
        char width;
        unsigned q, r, a, b;
        char cq, cr, ca, cb;
        int at = 0;
        if (sscanf(line.c_str(), "\tU%cDIV r%u.%c, r%u.%c, r%u.%c, r%u.%c;%n", &width, &q, &cq, &r, &cr, &a, &ca, &b, &cb, &at) == 9 && at &&
            (width == 'B' || width == 'S')) {
            const char *mask = width == 'B' ? "0xFF" : "0xFFFF";
            unsigned t1 = ++last, t2 = ++last;
            char buffer[256];
            snprintf(buffer, sizeof buffer, "\tAND r%u.x, r%u.%c, %s;\n\tAND r%u.x, r%u.%c, %s;\n\tUDIV r%u.%c, r%u.%c, r%u.x, r%u.x;", t1, a, ca, mask,
                     t2, b, cb, mask, q, cq, r, cr, t1, t2);
            line = buffer;
            n++;
        }
        out += line;
        if (eol < s.size()) out += '\n';
        pos = eol + 1;
    }
    if (!n) return 0;
    size_t numberAt = out.find("\tDCL_TEMPS r0..r") + 16, numberEnd = out.find_first_not_of("0123456789", numberAt);
    out.replace(numberAt, numberEnd - numberAt, std::to_string(last));
    s = out;
    return n;
}

// ---- a narrow mask reached through copies ----------------------------------------------------------------------------
// The same iCBE fold as above, when the narrower AND reaches the 16-bit one through MOVs, including the copy into a
// shared case of a switch (AND r45, r388, 255; MOV r420, r45; CALL 9 ... MOV r46, r420; AND r389, r46, 65535): a uchar
// read from a private array came out with bits 8-15 (mslfuzz2 seed 330). There the register is also set from a 32-bit
// value on another path, so the AND can't go. It used to become SHL 16 / SHR 16 into a new register, but where the
// source is itself a narrow AND (AND 0xFF over x & 3), iCBE keeps that source in a byte register and the SHL 24 lost it,
// so the result was always 0 (VEC=1 seed 1111). It becomes i40's 32-bit form instead: (x | bit 31) & (mask | bit 31),
// then bit 31 XORed away. INTEL_NARROW_MASK_FIX=0 turns it off with the above.
static unsigned narrowMasksThroughCopies(std::string &s) {
    if (disabled("INTEL_NARROW_MASK_FIX")) return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    std::vector<std::string> lines;
    for (size_t pos = 0; pos <= s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        lines.push_back(s.substr(pos, eol - pos));
        pos = eol + 1;
    }
    // every definition of rN.x: a MOV from rM.x (source M), an AND with an immediate (mask), or anything else
    struct Def { int source; unsigned long mask; };
    std::map<unsigned, std::vector<Def>> defs;
    for (const std::string &l : lines) {
        unsigned d, src;
        char imm[32];
        if (sscanf(l.c_str(), "\tMOV r%u.x, r%u.x;", &d, &src) == 2) defs[d].push_back({(int)src, 0});
        else if (sscanf(l.c_str(), "\tAND r%u.x, r%u.x, %31[0-9A-Fx];", &d, &src, imm) == 3) defs[d].push_back({-1, strtoul(imm, nullptr, 0)});
        else if (sscanf(l.c_str(), "\t%*[A-Z_] r%u.", &d) == 1) defs[d].push_back({-1, 0});
    }
    std::function<bool(unsigned, unsigned long, int)> narrower = [&](unsigned r, unsigned long outer, int depth) {
        if (depth > 8) return false;
        auto it = defs.find(r);
        if (it == defs.end()) return false;
        for (const Def &d : it->second) {
            if (d.source >= 0 && narrower((unsigned)d.source, outer, depth + 1)) return true;
            if (d.source < 0 && d.mask && d.mask != outer && (d.mask & ~outer) == 0) return true;
        }
        return false;
    };
    unsigned n = 0;
    std::string out;
    for (size_t i = 0; i < lines.size(); i++) {
        unsigned c, b;
        char imm[32];
        int at = 0;
        if (sscanf(lines[i].c_str(), "\tAND r%u.x, r%u.x, %31[0-9A-Fx];%n", &c, &b, imm, &at) == 3 && at) {
            unsigned long outer = strtoul(imm, nullptr, 0);
            if ((outer == 0xFFFF || outer == 0xFF) && narrower(b, outer, 0)) {
                unsigned high = ++last, masked = ++last;
                char buffer[200];
                snprintf(buffer, sizeof buffer, "\tOR r%u.x, r%u.x, -2147483648;\n\tAND r%u.x, r%u.x, %d;\n\tXOR r%u.x, r%u.x, -2147483648;", high, b,
                         masked, high, (int32_t)((uint32_t)outer | 0x80000000u), c, masked);
                lines[i] = buffer;
                n++;
            }
        }
    }
    if (!n) return 0;
    for (size_t i = 0; i < lines.size(); i++) { out += lines[i]; if (i + 1 < lines.size()) out += '\n'; }
    size_t numberAt = out.find("\tDCL_TEMPS r0..r") + 16, numberEnd = out.find_first_not_of("0123456789", numberAt);
    out.replace(numberAt, numberEnd - numberAt, std::to_string(last));
    s = out;
    return n;
}

static thread_local std::string lastIGILForDump;  // INTELTEX_DUMP_KERNELS: the IGIL text iCBE compiles next on this thread
extern "C" void intelatomicsFixIGIL(std::string *text) {
    if (getenv("INTELTEX_DUMP_KERNELS")) lastIGILForDump = *text;
    std::string &s = *text;
    if (getenv("INTELTEX_DUMP")) {  // debugging: the IGIL text as the back end produced it
        static int serial;
        char path[1024];
        snprintf(path, sizeof path, "%s/igil-%d.txt", getenv("INTELTEX_DUMP"), serial++);
        if (FILE *f = fopen(path, "w")) { fwrite(s.data(), 1, s.size(), f); fclose(f); }
    }
    if (s.find("PIXELSHADER") != std::string::npos) {
        unsigned n = perPixelSwizzleImmediates(s);
        if (n && logging()) fprintf(stderr, "[inteltex] %u MOV_SWZ with immediate and per-pixel lanes: immediate lanes computed per pixel\n", n);
        if (n && getenv("INTELTEX_DUMP")) {
            static int serial;
            char path[1024];
            snprintf(path, sizeof path, "%s/igil-fixed-%d.txt", getenv("INTELTEX_DUMP"), serial++);
            if (FILE *f = fopen(path, "w")) { fwrite(s.data(), 1, s.size(), f); fclose(f); }
        }
    }
    if (declareBaseVertex(s) && logging()) fprintf(stderr, "[inteltex] vertex shader reads VERTEXID: BASE_VERTEX_ID declared\n");
    if (unsigned n = fineGradients(s); n && logging()) fprintf(stderr, "[inteltex] %u derivative(s) made fine\n", n);
    if (unsigned n = narrowMasksThroughCopies(s); n && logging()) fprintf(stderr, "[inteltex] %u AND 0xFFFF / 0xFF over a narrower AND done on 32 bits\n", n);
    if (unsigned n = narrowUnsignedDivides(s); n && logging()) fprintf(stderr, "[inteltex] %u UBDIV / USDIV done as UDIV of masked copies\n", n);
    if (unsigned n = redundantNarrowMasks(s); n && logging()) fprintf(stderr, "[inteltex] %u AND 0xFFFF after a narrower AND made a MOV\n", n);
    if (unsigned n = narrowNegations(s); n && logging()) fprintf(stderr, "[inteltex] %u BADD / SADD negation(s) done as XOR and add\n", n);
    if (unsigned n = narrowShifts(s); n && logging()) fprintf(stderr, "[inteltex] %u SHR / SAR of a narrow value done on 32 bits\n", n);
    if (unsigned n = loopExitCopies(s); n && logging()) fprintf(stderr, "[inteltex] %u loop-carried copies moved after the loop's BREAK_CND\n", n);
    if (unsigned n = negatedDivideOperands(s); n && logging()) fprintf(stderr, "[inteltex] %u negation(s) in a shader with an IDIV done as XOR and add\n", n);
    if (unsigned n = signTestsOfSums(s); n && logging()) fprintf(stderr, "[inteltex] %u signed compare(s) of a sum with zero done on its sign bit\n", n);
    if (unsigned n = signExtensions(s); n && logging()) fprintf(stderr, "[inteltex] %u STOI / BTOI done as shift pairs\n", n);
    if (unsigned n = sampleLodOperands(s); n && logging()) fprintf(stderr, "[inteltex] %u explicit-LOD sample(s) given the register holding the LOD\n", n);
    if (getenv("INTELTEX_DUMP")) {  // debugging: the IGIL text after the fixes above
        static int serial;
        char path[1024];
        snprintf(path, sizeof path, "%s/igil-after-%d.txt", getenv("INTELTEX_DUMP"), serial++);
        if (FILE *f = fopen(path, "w")) { fwrite(s.data(), 1, s.size(), f); fclose(f); }
    }
    if (s.find("IMM_ATOMIC_") == std::string::npos) return;
    std::vector<std::string> lines;
    for (size_t pos = 0; pos <= s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        lines.push_back(s.substr(pos, eol - pos));
        pos = eol + 1;
    }
    std::vector<int> uavOfBinding;  // DCL_UAVTYPED uM = { ... LOCATION_INDEX, binding, element ... }
    for (size_t i = 0; i < lines.size(); i++) {
        unsigned u, binding, element;
        if (sscanf(lines[i].c_str(), " DCL_UAVTYPED u%u", &u) != 1) continue;
        for (size_t k = i + 1; k < lines.size() && lines[k].find("};") == std::string::npos; k++)
            if (sscanf(lines[k].c_str(), " LOCATION_INDEX, %u, %u", &binding, &element) == 2) {
                if (element == 0 && binding <= kBindingMask) {
                    if (uavOfBinding.size() <= binding) uavOfBinding.resize(binding + 1, -1);
                    uavOfBinding[binding] = (int)u;
                }
                break;
            }
    }
    unsigned fixed = 0, failed = 0;
    std::vector<std::string> out;
    for (size_t i = 0; i < lines.size(); i++) {
        std::string opcode, defOpcode;
        std::vector<std::string> ops = instructionOperands(lines[i], &opcode), def;
        if (opcode.compare(0, 11, "IMM_ATOMIC_") || ops.size() < 4) {
            out.push_back(lines[i]);
            continue;
        }
        std::string coords = operandRegister(ops[2]);
        int u = -1;
        if (!coords.empty() && definition(lines, i, coords, defOpcode, def) >= 0 && defOpcode == "MOV_SWZ" && def.size() == 5) {
            std::string lane = operandRegister(def[4]), movOpcode;
            std::vector<std::string> mov;
            if (!lane.empty() && definition(lines, i, lane, movOpcode, mov) >= 0 && movOpcode == "MOV" && mov.size() == 2) {
                unsigned long long value = strtoull(mov[1].c_str(), nullptr, 0);
                if ((value & kImageTagMask) == kImageTag && (value & kBindingMask) < uavOfBinding.size()) u = uavOfBinding[value & kBindingMask];
            }
        }
        if (u < 0 && ops[1].find("unresolved_image") == std::string::npos) {  // not one of ours
            out.push_back(lines[i]);
            continue;
        }
        if (u >= 0) {
            size_t indent = lines[i].find_first_not_of("\t ");
            out.push_back(lines[i].substr(0, indent) + "MOV " + coords + ".w, 0;");
            ops[1] = " u" + std::to_string(u);
            fixed++;
        } else {
            ops[1] = " unresolved_image";
            failed++;
        }
        std::string line = lines[i].substr(0, lines[i].find_first_not_of("\t ")) + opcode + " ";
        for (size_t k = 0; k < ops.size(); k++) line += (k ? "," : "") + ops[k];
        out.push_back(line + ";");
    }
    std::string joined;
    joined.reserve(s.size() + 64 * fixed);
    for (size_t i = 0; i < out.size(); i++) joined += out[i] + (i + 1 < out.size() ? "\n" : "");
    s.swap(joined);
    if (logging() || failed) fprintf(stderr, "[inteltex] IGIL: %u image atomic operand(s) resolved, %u unresolved\n", fixed, failed);
}

// ---- installation --------------------------------------------------------------------------------------------------
static const char *const kPluginSuffix = "libMTLIntelCompilerPlugin.dylib";
static const unsigned char kPrologue[12] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x41, 0x55, 0x41, 0x54};
// compile*FunctionIGILtoBinary(this, std::string &igil, ...): the IGIL text is the second argument (rsi).
static const char *const kIGILEntryPoints[] = {
    "_ZN16MTLIntelCompiler33compileVertexFunctionIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEERPN3AIR13Serialization25SSerializedCompilerOutputINS8_27SCompilerOutputVertexShaderEEEjP21MTLIntelCompilerInputS7_",
    "_ZN16MTLIntelCompiler34compileComputeFunctionIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEEP22MTLIntelCSDeviceBinaryRPN3AIR13Serialization25SSerializedCompilerOutputINSA_28SCompilerOutputComputeShaderEEEjS7_",
    "_ZN16MTLIntelCompiler35compileFragmentFunctionIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEERPN3AIR13Serialization25SSerializedCompilerOutputINS8_26SCompilerOutputPixelShaderEEEjS7_",
    "_ZN16MTLIntelCompiler40compileTessellationFunctionsIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEERPN3AIR13Serialization25SSerializedCompilerOutputINS8_25SCompilerOutputHullShaderEEERPNSA_INS8_27SCompilerOutputDomainShaderEEEjS7_",
};

static int hookedRun(void *self, LLVMModuleRef module);
static unsigned char *emit(unsigned char *p, const void *bytes, size_t n) { memcpy(p, bytes, n); return p + n; }
static unsigned char *emitMovRax(unsigned char *p, const void *value) {
    *p++ = 0x48; *p++ = 0xb8;
    memcpy(p, &value, 8);
    return p + 8;
}

// ---- LowerImageAtomic (libIGIL-Metal) ------------------------------------------------------------------------------
struct SDValue { char *node; unsigned resno; };
static SDValue (*originalLowerImageAtomic)(const void *self, unsigned id, SDValue op, void *dag);
static uint64_t (*constantValue)(const void *self, const SDValue &value, void *dag, bool &flag);
static const unsigned short kISDConstant = 0xa;
struct EVT { unsigned char simple; void *type; };
struct SDLoc { void *debugLoc; unsigned order; };
extern "C" SDValue dagGetConstant(void *dag, uint64_t value, const SDLoc &dl, EVT vt, bool isTarget, bool isOpaque)
    asm("__ZN4llvm12SelectionDAG11getConstantEyRKNS_5SDLocENS_3EVTEbb");
extern "C" char *dagUpdateNodeOperands(void *dag, char *node, const SDValue *ops, size_t count)
    asm("__ZN4llvm12SelectionDAG18UpdateNodeOperandsEPNS_6SDNodeENS_8ArrayRefINS_7SDValueEEE");

// SDNode (3802 LLVM): +0x18 opcode, +0x20 operand list (0x28-byte SDUse, SDValue first). Operand 2 is the image.
static bool isTag(const void *self, SDValue value, void *dag) {
    bool flag = true;
    return *(unsigned short *)(value.node + 0x18) == kISDConstant && (constantValue(self, value, dag, flag) & kImageTagMask) == kImageTag;
}
static SDValue hookedLowerImageAtomic(const void *self, unsigned id, SDValue op, void *dag) {
    char *operands = *(char **)(op.node + 0x20);
    unsigned count = *(unsigned short *)(op.node + 0x38);
    SDValue image = *(SDValue *)(operands + 2 * 0x28), tag = *(SDValue *)(operands + 3 * 0x28);
    if (count > 16) return originalLowerImageAtomic(self, id, op, dag);
    if (isTag(self, image, dag)) return op;  // done already (the legalizer revisits updated nodes)
    if (!isTag(self, tag, dag)) return originalLowerImageAtomic(self, id, op, dag);
    // The image operand becomes the tag constant (valid in every block); the IGIL text fix puts the UAV in its place.
    SDLoc dl = {nullptr, *(unsigned *)(op.node + 0x3c)};
    EVT vt = ((EVT *)*(char **)(tag.node + 0x28))[tag.resno];
    SDValue ops[16];
    for (unsigned k = 0; k < count; k++) ops[k] = *(SDValue *)(operands + k * 0x28);
    ops[2] = tag;
    ops[3] = ops[4] = dagGetConstant(dag, 0, dl, vt, false, false);
    ops[count - 1] = *(SDValue *)(operands + 4 * 0x28);  // the value, back from the second spare operand
    return {dagUpdateNodeOperands(dag, op.node, ops, count), op.resno};
}

// IGILUAVSurface::PrintOperand throws for a register that isn't a UAV, which our image operand (a temporary holding
// the tag) is: print a placeholder instead, which the IGIL text fix replaces (or the IGIL compile rejects).
static void (*originalPrintUAVOperand)(void *self, void *stream, unsigned reg, void *registerInfo);
extern "C" void *streamWrite(void *stream, const char *text, size_t length) asm("__ZN4llvm11raw_ostream5writeEPKcm");
static void hookedPrintUAVOperand(void *self, void *stream, unsigned reg, void *registerInfo) {
    try {
        originalPrintUAVOperand(self, stream, reg, registerInfo);
    } catch (...) {
        streamWrite(stream, "nresolved_image", 15);  // after the 'u' already written
    }
}

// Inline hook: entry -> replacement; returns a trampoline that runs the relocated prologue and continues. The prologue
// (whole instructions, none RIP-relative, at least the 12 bytes the jump takes) is checked byte for byte.
static void *hookFunction(unsigned char *entry, void *replacement, const unsigned char *prologue = kPrologue,
                          size_t length = sizeof kPrologue) {
    if (length < 12 || memcmp(entry, prologue, length)) return nullptr;
    unsigned char *stub = (unsigned char *)mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (stub == MAP_FAILED) return nullptr;
    static const unsigned char jump[] = {0xff, 0xe0};  // jmp rax
    unsigned char *p = emit(stub, entry, length);
    p = emitMovRax(p, entry + length);
    emit(p, jump, sizeof jump);
    if (mprotect(stub, 4096, PROT_READ | PROT_EXEC)) return nullptr;
    vm_address_t page = (vm_address_t)entry & ~(vm_address_t)(vm_page_size - 1);
    if (vm_protect(mach_task_self(), page, vm_page_size * 2, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)) return nullptr;
    unsigned char patch[12];
    emit(emitMovRax(patch, replacement), jump, sizeof jump);
    memcpy(entry, patch, sizeof patch);
    vm_protect(mach_task_self(), page, vm_page_size * 2, false, VM_PROT_READ | VM_PROT_EXECUTE);
    return stub;
}


// Entry stub: save the argument registers, intelatomicsFixIGIL(rsi), restore, run the 12 relocated prologue bytes,
// continue at entry + 12. The function's other arguments, including stack ones, are untouched.
static bool hookIGILEntry(unsigned char *entry) {
    if (memcmp(entry, kPrologue, sizeof kPrologue)) return false;
    unsigned char *stub = (unsigned char *)mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (stub == MAP_FAILED) return false;
    static const unsigned char save[] = {0x57, 0x56, 0x52, 0x51, 0x41, 0x50, 0x41, 0x51, 0x50};  // push rdi rsi rdx rcx r8 r9 rax
    static const unsigned char argument[] = {0x48, 0x89, 0xf7};                                 // mov rdi, rsi
    static const unsigned char call[] = {0xff, 0xd0};                                           // call rax
    static const unsigned char restore[] = {0x58, 0x41, 0x59, 0x41, 0x58, 0x59, 0x5a, 0x5e, 0x5f};  // pop rax r9 r8 rcx rdx rsi rdi
    static const unsigned char jump[] = {0xff, 0xe0};                                           // jmp rax
    unsigned char *p = stub;
    p = emit(p, save, sizeof save);  // 7 pushes: rsp is 16-byte aligned for the call
    p = emit(p, argument, sizeof argument);
    p = emitMovRax(p, (void *)intelatomicsFixIGIL);
    p = emit(p, call, sizeof call);
    p = emit(p, restore, sizeof restore);
    p = emit(p, entry, sizeof kPrologue);
    p = emitMovRax(p, entry + sizeof kPrologue);
    p = emit(p, jump, sizeof jump);
    if (mprotect(stub, 4096, PROT_READ | PROT_EXEC)) return false;
    vm_address_t page = (vm_address_t)entry & ~(vm_address_t)(vm_page_size - 1);
    if (vm_protect(mach_task_self(), page, vm_page_size * 2, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)) return false;
    unsigned char patch[12];
    unsigned char *q = emitMovRax(patch, stub);
    emit(q, jump, sizeof jump);
    memcpy(entry, patch, sizeof patch);
    vm_protect(mach_task_self(), page, vm_page_size * 2, false, VM_PROT_READ | VM_PROT_EXECUTE);
    return true;
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

// Installs into the loaded plugin once: import redirect (unless interposed already) and the IGIL entry hooks.
static pthread_mutex_t installLock = PTHREAD_MUTEX_INITIALIZER;
static bool textFixInstalled;
static bool ivyBridgePlugin;  // OCLP's 11.7.10 AppleIntelHD4000GraphicsMTLDriver plugin: compiler fixes only, no Haswell workarounds
static void installIntoPlugin(bool redirectImport) {
    static bool done;
    if (done) return;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0, suffix = strlen(kPluginSuffix);
        if (len < suffix || strcmp(name + len - suffix, kPluginSuffix)) continue;
        done = true;
        ivyBridgePlugin = strstr(name, "AppleIntelHD4000GraphicsMTLDriver") != nullptr;
        void *h = dlopen(name, RTLD_NOLOAD | RTLD_LAZY);
        unsigned imports = redirectImport ? redirectPassManager((const mach_header_64 *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i)) : 0;
        unsigned hooks = 0;
        for (const char *symbol : kIGILEntryPoints) {
            unsigned char *entry = h ? (unsigned char *)dlsym(h, symbol) : nullptr;
            if (entry && hookIGILEntry(entry)) hooks++;
        }
        textFixInstalled = hooks == sizeof kIGILEntryPoints / sizeof *kIGILEntryPoints;
        if (logging()) fprintf(stderr, "[inteltex] %s: %u import(s) redirected, %u IGIL entry point(s) hooked\n", name, imports, hooks);
    }
}

// ---- IGILUniformAnalysis::getDependency (libIGIL-Metal) ---------------------------------------------------------------
// The uniformity analysis keeps a value -> dependency map (0 uniform ... 4 varying) that it fills in layout order and
// then by a worklist. Its getDependency(V) returns the entry, 0 for constants and arguments, and for an instruction
// with no entry yet reads past the end of the map's buckets: garbage, or a crash when the map ends at a page. That
// happens: calculate_dep(BinaryOperator) matches ashr (add (shl x, c), y), c and asks for y's dependency, two levels
// below the instruction whose operands it checked, and a recomputed instruction asks for its operands' without
// checking them. In mslfuzz2 LONG=1 seed 741, ashr (add %v3, %t), 31 (from select (icmp slt ..., 0), 15, 0) came
// before %t, a truncated 64-bit product, had an entry, and the compiler service crashed (the stock compiler too).
// An instruction with no entry yet counts as varying (4); the worklist recomputes its users once it gets one.
// INTEL_UNIFORM_DEPENDENCY_FIX=0 turns it off.
static const unsigned char kGetDependencyPrologue[13] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x53, 0x48, 0x83, 0xec, 0x18};
static unsigned (*originalGetDependency)(void *self, const void *value);
static bool (*uniformHasDependency)(void *self, const void *value);
static std::atomic<unsigned> uniformMisses;
static unsigned hookedGetDependency(void *self, const void *value) {
    if (((const unsigned char *)value)[0x18] >= 0x18 && !uniformHasDependency(self, value)) return uniformMisses++, 4;  // an instruction
    return originalGetDependency(self, value);
}

// The back-end hooks, once libIGIL-Metal is loaded (the plugin loads it on demand).
static bool installIntoBackEnd(void *igil) {
    unsigned char *dependency = (unsigned char *)dlsym(igil, "_ZN4llvm19IGILUniformAnalysis13getDependencyEPKNS_5ValueE");
    uniformHasDependency = (bool (*)(void *, const void *))dlsym(igil, "_ZN4llvm19IGILUniformAnalysis13hasDependencyEPKNS_5ValueE");
    if (dependency && uniformHasDependency && !disabled("INTEL_UNIFORM_DEPENDENCY_FIX"))
        originalGetDependency = (unsigned (*)(void *, const void *))hookFunction(dependency, (void *)hookedGetDependency,
                                                                                 kGetDependencyPrologue, sizeof kGetDependencyPrologue);
    if (logging()) fprintf(stderr, "[inteltex] libIGIL-Metal: getDependency %s\n", originalGetDependency ? "hooked" : "NOT hooked");
    unsigned char *lower = (unsigned char *)dlsym(igil, "_ZNK4llvm18IGILTargetLowering16LowerImageAtomicEjNS_7SDValueERNS_12SelectionDAGE");
    unsigned char *print = (unsigned char *)dlsym(igil, "_ZN4llvm14IGILUAVSurface12PrintOperandERNS_11raw_ostreamEjPNS_16IGILRegisterInfoE");
    constantValue = (uint64_t(*)(const void *, const SDValue &, void *, bool &))dlsym(
        igil, "_ZNK4llvm18IGILTargetLowering27get64bitConstantFromSDValueERKNS_7SDValueERNS_12SelectionDAGERb");
    if (!lower || !print || !constantValue) return false;
    originalPrintUAVOperand = (void (*)(void *, void *, unsigned, void *))hookFunction(print, (void *)hookedPrintUAVOperand);
    if (originalPrintUAVOperand)
        originalLowerImageAtomic = (SDValue(*)(const void *, unsigned, SDValue, void *))hookFunction(lower, (void *)hookedLowerImageAtomic);
    if (logging()) fprintf(stderr, "[inteltex] libIGIL-Metal: LowerImageAtomic %s\n", originalLowerImageAtomic ? "hooked" : "NOT hooked");
    return originalLowerImageAtomic != nullptr;
}

// ---- kernel attributes the IGIL back end rejects ---------------------------------------------------------------------
// [[max_total_threads_per_threadgroup(N)]] puts !{!"air.max_work_group_size", i32 N} into the kernel's !air.kernel
// node; IGILParseMetadata aborts the compiler service on it ("Encountered unsupported air.max_work_group_size"), so
// e.g. every Firefox WebGPU device on the Intel GPU is lost. The value is only a hint (the pipeline still reports the
// device limit), and the parser skips empty attribute nodes: replace it with !{}.
extern "C" void mdNodeReplaceOperand(void *node, unsigned index, void *replacement) asm("__ZN4llvm6MDNode18replaceOperandWithEjPNS_8MetadataE");
static void *metadataOf(LLVMValueRef value) {  // MetadataAsValue::MD: +0x20 in this LLVM, as LLVMGetMDNodeNumOperands reads it
    if (!value || !LLVMIsAMDNode(value)) return nullptr;
    void *md = *(void **)((char *)value + 0x20);
    return md && *(unsigned *)((char *)md + 8) == LLVMGetMDNodeNumOperands(value) ? md : nullptr;
}
static unsigned dropMaxWorkGroupSize(LLVMModuleRef module) {
    unsigned dropped = 0;
    std::vector<LLVMValueRef> kernels(LLVMGetNamedMetadataNumOperands(module, "air.kernel"));
    if (kernels.empty()) return 0;
    LLVMGetNamedMetadataOperands(module, "air.kernel", kernels.data());
    void *empty = nullptr;
    for (LLVMValueRef kernel : kernels) {
        std::vector<LLVMValueRef> parts = metadataOperands(kernel);
        for (unsigned i = 1; i < parts.size(); i++) {
            std::vector<LLVMValueRef> attribute = metadataOperands(parts[i]);
            if (attribute.empty() || !isString(attribute[0], "air.max_work_group_size")) continue;
            void *node = metadataOf(kernel);
            if (!empty) empty = metadataOf(LLVMMDNodeInContext(LLVMGetModuleContext(module), nullptr, 0));
            if (!node || !empty) continue;
            mdNodeReplaceOperand(node, i, empty);
            dropped++;
        }
    }
    return dropped;
}

// Newer front ends describe a `device T (&)[N]` buffer argument (naga/wgpu writes them) as a pointer to an array of
// structs with the struct's air.struct_type_info. The plugin's argument-buffer emulation (MetadataParser::parseArgument)
// asserts that an argument with struct info points to a struct ("isa<StructType>(elementType)"), which aborts
// MTLCompilerService. For plain-data structs (nested plain structs included: wgpu's timestamp normalization) the info is
// reflection only, so drop it from such arguments.
// Struct info that describes plain data only: members are scalars/vectors, or structs (!"air.struct_type_info", !{...})
// that are plain data themselves. Any other air.* marker (indirect arguments: buffers, textures, samplers) is not.
static bool plainStructInfo(LLVMValueRef info, int depth) {
    if (!info || depth > 8) return false;
    std::vector<LLVMValueRef> members = metadataOperands(info);
    for (size_t i = 0; i < members.size(); i++) {
        LLVMValueRef m = members[i];
        if (m && LLVMIsAMDNode(m)) {
            if (i == 0 || !isString(members[i - 1], "air.struct_type_info") || !plainStructInfo(m, depth + 1)) return false;
            continue;
        }
        unsigned length = 0;
        const char *text = m && LLVMIsAMDString(m) ? LLVMGetMDString(m, &length) : nullptr;
        if (text && length >= 4 && !memcmp(text, "air.", 4) && !isString(m, "air.struct_type_info")) return false;
    }
    return true;
}

static unsigned dropArrayStructInfo(LLVMModuleRef module) {
    enum { kPointerKind = 12, kArrayKind = 11 };  // LLVMTypeKind
    unsigned dropped = 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    for (const char *list : {"air.kernel", "air.fragment", "air.vertex"}) {
        std::vector<LLVMValueRef> entries(LLVMGetNamedMetadataNumOperands(module, list));
        if (entries.empty()) continue;
        LLVMGetNamedMetadataOperands(module, list, entries.data());
        for (LLVMValueRef entry : entries) {
            std::vector<LLVMValueRef> parts = metadataOperands(entry);
            if (parts.empty() || !parts[0]) continue;
            LLVMValueRef function = parts[0];
            unsigned params = LLVMCountParams(function);
            for (unsigned i = 1; i < parts.size(); i++) {
                std::vector<LLVMValueRef> args = metadataOperands(parts[i]);
                for (unsigned a = 0; a < args.size(); a++) {
                    std::vector<LLVMValueRef> arg = metadataOperands(args[a]);
                    if (arg.empty() || !LLVMIsAConstantInt(arg[0])) continue;
                    unsigned param = (unsigned)LLVMConstIntGetZExtValue(arg[0]);
                    unsigned k = 0;
                    while (k + 1 < arg.size() && !isString(arg[k], "air.struct_type_info")) k++;
                    if (k + 1 >= arg.size() || param >= params) continue;
                    LLVMTypeRef type = LLVMTypeOf(LLVMGetParam(function, param));
                    if (LLVMGetTypeKind(type) != kPointerKind || LLVMGetTypeKind(LLVMGetElementType(type)) != kArrayKind) continue;
                    if (!plainStructInfo(arg[k + 1], 0)) continue;  // resources inside (indirect arguments): leave it alone
                    std::vector<LLVMValueRef> kept;
                    for (unsigned j = 0; j < arg.size(); j++)
                        if (j != k && j != k + 1) kept.push_back(arg[j]);
                    void *list_node = metadataOf(parts[i]);
                    void *replacement = metadataOf(LLVMMDNodeInContext(context, kept.data(), (unsigned)kept.size()));
                    if (!list_node || !replacement) continue;
                    mdNodeReplaceOperand(list_node, a, replacement);
                    dropped++;
                }
            }
        }
    }
    return dropped;
}


// ---- texture/sampler loads through escaped pointers -----------------------------------------------------------------
// MSL texture/sampler array arguments are byval arrays of handles in AIR. IGILTextureTypeEncode follows each such
// argument's binding forward through its uses (GEPs with constant indices, loads, stores into allocas at constant
// paths) and gives every texture call the binding of its texture operand. A handle loaded through a pointer that was
// stored to memory and loaded back with a runtime index (ANGLE's `thread texture2d *` / `thread sampler *` pairs for a
// WebGL sampler array indexed in a loop) defeats that: the pass dereferences a missing GEP-tree node and the compiler
// service crashes (null + 0x20 in runOnFunction), so the pipeline fails. A runtime index straight into the argument
// (`t[i].sample(s[i], ..)`) works. So: every handle load `load p` whose pointer was itself loaded from memory, in a
// function with exactly one byval array `a` of that handle type, becomes `load &a[idx]` with
// idx = select(p == &a[1], 1, select(p == &a[2], 2, ... 0)): only integers are selected, never a handle (the pass
// gives each value one binding). INTEL_HANDLE_FIX=0 turns it off.
enum { kTypeKindStruct = 10, kTypeKindArray = 11, kTypeKindPointer = 12, kByValAttribute = 1 << 7, kICmpEQ = 32 };

static bool isHandleType(LLVMTypeRef type) {
    if (LLVMGetTypeKind(type) != kTypeKindPointer) return false;
    LLVMTypeRef pointee = LLVMGetElementType(type);
    if (LLVMGetTypeKind(pointee) != kTypeKindStruct) return false;
    const char *name = LLVMGetStructName(pointee);
    return name && (!strncmp(name, "struct._texture", 15) || !strncmp(name, "struct._depth", 13) ||
                    !strncmp(name, "struct._sampler", 15));
}

// True if the pointer was loaded from memory (through GEPs and bitcasts): the shape ANGLE produces. Selects of
// pointers (`cond ? &t[1] : &t[0]`) crash the pass too, but are left alone: rewritten, the optimizer can fold the
// index back into a select of handles, which the pass gives a single binding (wrong texture instead of a failed
// compile).
static bool loadedPointer(LLVMValueRef pointer) {
    for (int steps = 0; steps < 64; steps++) {
        if (LLVMIsALoadInst(pointer)) return true;
        if (!LLVMIsAGetElementPtrInst(pointer) && !LLVMIsABitCastInst(pointer)) return false;
        pointer = LLVMGetOperand(pointer, 0);
    }
    return false;
}

static unsigned fixEscapedHandleLoads(LLVMModuleRef module) {
    const char *setting = getenv("INTEL_HANDLE_FIX");
    if (setting && !strcmp(setting, "0")) return 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i64 = LLVMInt64TypeInContext(context);
    unsigned fixed = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (LLVMIsDeclaration(f)) continue;
        std::vector<LLVMValueRef> arrays;  // byval arrays of handles
        for (unsigned i = 0, n = LLVMCountParams(f); i < n; i++) {
            LLVMValueRef arg = LLVMGetParam(f, i);
            LLVMTypeRef type = LLVMTypeOf(arg);
            if (LLVMGetTypeKind(type) != kTypeKindPointer || !(LLVMGetAttribute(arg) & kByValAttribute)) continue;
            LLVMTypeRef array = LLVMGetElementType(type);
            if (LLVMGetTypeKind(array) == kTypeKindArray && isHandleType(LLVMGetElementType(array)) &&
                LLVMGetArrayLength(array) >= 1 && LLVMGetArrayLength(array) <= 64)
                arrays.push_back(arg);
        }
        if (arrays.empty()) continue;
        std::vector<std::pair<LLVMValueRef, LLVMValueRef>> loads;  // (load, its array)
        for (LLVMBasicBlockRef b = LLVMGetFirstBasicBlock(f); b; b = LLVMGetNextBasicBlock(b))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(b); inst; inst = LLVMGetNextInstruction(inst)) {
                if (!LLVMIsALoadInst(inst)) continue;
                LLVMTypeRef handle = LLVMTypeOf(inst);
                LLVMValueRef match = nullptr;
                unsigned matches = 0;
                for (LLVMValueRef a : arrays)
                    if (LLVMGetElementType(LLVMGetElementType(LLVMTypeOf(a))) == handle) { match = a; matches++; }
                if (matches == 1 && loadedPointer(LLVMGetOperand(inst, 0))) loads.push_back({inst, match});
            }
        if (loads.empty()) continue;
        LLVMBuilderRef b = LLVMCreateBuilderInContext(context);
        for (auto &[load, array] : loads) {
            LLVMValueRef pointer = LLVMGetOperand(load, 0);
            unsigned length = LLVMGetArrayLength(LLVMGetElementType(LLVMTypeOf(array)));
            LLVMPositionBuilderBefore(b, load);
            LLVMValueRef zero = LLVMConstInt(i64, 0, false), index = zero;
            bool typesMatch = true;
            for (unsigned k = 1; k < length && typesMatch; k++) {
                LLVMValueRef indices[2] = {zero, LLVMConstInt(i64, k, false)};
                LLVMValueRef element = LLVMBuildInBoundsGEP(b, array, indices, 2, "");
                typesMatch = LLVMTypeOf(element) == LLVMTypeOf(pointer);
                if (typesMatch)
                    index = LLVMBuildSelect(b, LLVMBuildICmp(b, kICmpEQ, pointer, element, ""), LLVMConstInt(i64, k, false), index, "");
            }
            LLVMValueRef indices[2] = {zero, index};
            LLVMValueRef element = LLVMBuildInBoundsGEP(b, array, indices, 2, "");
            if (!typesMatch || LLVMTypeOf(element) != LLVMTypeOf(pointer)) continue;  // dead helpers; removed later
            LLVMValueRef direct = LLVMBuildLoad(b, element, "");
            LLVMReplaceAllUsesWith(load, direct);
            LLVMInstructionEraseFromParent(load);
            fixed++;
        }
        LLVMDisposeBuilder(b);
    }
    return fixed;
}

// ---- signed bytes and halfwords in vertex functions -----------------------------------------------------------------
// In vertex functions (SIMD4x2 "vec4" mode on these GPUs; fragment and compute functions are right), the back end gets
// the sign-extended top lane of a word read from a constant buffer wrong when the word isn't the first in its 16 bytes:
// char4(x).w, short2(x).y, unpack_snorm4x8_to_float(x).w and unpack_snorm2x16_to_float(x).y come from the first word of
// those 16 bytes instead. Other lanes, zero extension and 32-bit shifts are right. ANGLE's vertex shaders unpack their
// Y flip, at byte 12 of their uniform block, with unpack_snorm4x8_to_float(...).w, so on these GPUs every WebGL draw got
// the flip of another field and collapsed (nothing drawn). In vertex functions, sext / sitofp / air.convert.*.s.i8|i16
// of a packed vector of i8 or i16 (32 or 16 bits), or of a lane extracted from one, become shl + ashr on the packed
// word, and air.unpack.snorm4x8 / snorm2x16 become the same, then air.convert to float, / 127 or / 32767 and max(-1)
// (the MSL definition). Test: i02.
// INTEL_SIGNED_SUBWORD_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMBuildShl(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildAShr(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildSExt(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMBuildTrunc(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMBuildSIToFP(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMBuildFDiv(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildFCmp(LLVMBuilderRef, int, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildShuffleVector(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMConstReal(LLVMTypeRef, double);
LLVMValueRef LLVMConstVector(LLVMValueRef *, unsigned);
LLVMTypeRef LLVMFloatTypeInContext(LLVMContextRef);
LLVMTypeRef LLVMHalfTypeInContext(LLVMContextRef);
LLVMTypeRef LLVMFunctionType(LLVMTypeRef, LLVMTypeRef *, unsigned, int);
LLVMValueRef LLVMAddFunction(LLVMModuleRef, const char *, LLVMTypeRef);
LLVMValueRef LLVMGetCalledValue(LLVMValueRef);
LLVMValueRef LLVMIsACallInst(LLVMValueRef);
int LLVMGetInstructionOpcode(LLVMValueRef);
unsigned LLVMGetIntTypeWidth(LLVMTypeRef);
LLVMValueRef LLVMBuildBitCast(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMTypeRef LLVMIntTypeInContext(LLVMContextRef, unsigned);
LLVMContextRef LLVMGetTypeContext(LLVMTypeRef);
LLVMValueRef LLVMIsAExtractElementInst(LLVMValueRef);
}
enum { kTypeKindHalf = 1, kTypeKindFloat = 2, kTypeKindInteger = 8, kTypeKindVector = 13, kOpcodeSExt = 32,
       kOpcodeSIToFP = 36, kRealOLT = 4 };

static unsigned lanes(LLVMTypeRef type) { return LLVMGetTypeKind(type) == kTypeKindVector ? LLVMGetVectorSize(type) : 0; }

extern "C" {
LLVMValueRef LLVMIsAInsertElementInst(LLVMValueRef);
LLVMValueRef LLVMConstZExt(LLVMValueRef, LLVMTypeRef);
LLVMValueRef LLVMConstSExt(LLVMValueRef, LLVMTypeRef);
}

// Extends a narrow integer (vector) value to i32 lanes for the widening rewrites below. A vector put together from a
// constant with insertelement is extended lane by lane, the constant folded here: the back end sign-extends the constant
// lanes of a zext <N x i8> of such a vector (zext (insertelement <undef, i8 -100, 0, 0>, x, 0) gave lane 1 0xffffff9c,
// not 156), so min(uchar4(x, 157, ...), uchar4(y, 156, ...)) still kept 157 after i22's widening (i35).
// The same through bitwise operations with a constant operand, which commute with either extension: the constant
// uchar2(199, 32) ORed into a vector reached the back end as MOV r, -57 and came out of max(uchar2, uchar2) as
// 0xffffffc7, so the max always picked it over bytes 200-255 (mslfuzz2 VEC=1 seed 2464, i51).
// INTEL_NARROW_CONSTANT_LANES_FIX=0 extends the whole vector instead.
extern "C" {
LLVMValueRef LLVMIsABinaryOperator(LLVMValueRef);
LLVMValueRef LLVMBuildAnd(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildOr(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildXor(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
}
static LLVMValueRef extendLanes(LLVMBuilderRef b, LLVMValueRef v, LLVMTypeRef wide, bool sign) {
    static const bool off = disabled("INTEL_NARROW_CONSTANT_LANES_FIX");
    if (off) return sign ? LLVMBuildSExt(b, v, wide, "") : LLVMBuildZExt(b, v, wide, "");
    if (LLVMIsAConstant(v)) return sign ? LLVMConstSExt(v, wide) : LLVMConstZExt(v, wide);
    // (zero extension only, and only where the constant has a lane with its sign bit set: sign-extending it is what the
    // back end does anyway, and changing the shape of other code brought back i47's misread)
    enum { kOpcodeAnd = 23, kOpcodeOr = 24, kOpcodeXor = 25 };
    int op = !sign && lanes(LLVMTypeOf(v)) && LLVMIsABinaryOperator(v) ? LLVMGetInstructionOpcode(v) : 0;
    auto signedLanes = [&](LLVMValueRef c) { return LLVMIsAConstant(c) && LLVMConstZExt(c, wide) != LLVMConstSExt(c, wide); };
    if ((op == kOpcodeAnd || op == kOpcodeOr || op == kOpcodeXor) && (signedLanes(LLVMGetOperand(v, 0)) || signedLanes(LLVMGetOperand(v, 1)))) {
        LLVMValueRef x = extendLanes(b, LLVMGetOperand(v, 0), wide, sign), y = extendLanes(b, LLVMGetOperand(v, 1), wide, sign);
        return op == kOpcodeAnd ? LLVMBuildAnd(b, x, y, "") : op == kOpcodeOr ? LLVMBuildOr(b, x, y, "") : LLVMBuildXor(b, x, y, "");
    }
    if (lanes(LLVMTypeOf(v)) && LLVMIsAInsertElementInst(v)) {
        LLVMValueRef base = extendLanes(b, LLVMGetOperand(v, 0), wide, sign);
        LLVMValueRef element = LLVMGetOperand(v, 1);
        LLVMTypeRef i32 = LLVMGetElementType(wide);
        element = sign ? LLVMBuildSExt(b, element, i32, "") : LLVMBuildZExt(b, element, i32, "");
        return LLVMBuildInsertElement(b, base, element, LLVMGetOperand(v, 2), "");
    }
    return sign ? LLVMBuildSExt(b, v, wide, "") : LLVMBuildZExt(b, v, wide, "");
}
static LLVMTypeRef scalarOf(LLVMTypeRef type) { return lanes(type) ? LLVMGetElementType(type) : type; }
static LLVMTypeRef shaped(LLVMTypeRef scalar, unsigned n) { return n ? LLVMVectorType(scalar, n) : scalar; }
static LLVMValueRef splat(LLVMValueRef scalar, unsigned n) {
    if (!n) return scalar;
    LLVMValueRef elements[16];
    for (unsigned i = 0; i < n && i < 16; i++) elements[i] = scalar;
    return LLVMConstVector(elements, n < 16 ? n : 16);
}
static unsigned subwordBits(LLVMTypeRef type) {  // 8 or 16 for i8 / i16 (or vectors of them), else 0
    LLVMTypeRef scalar = scalarOf(type);
    if (LLVMGetTypeKind(scalar) != kTypeKindInteger) return 0;
    unsigned bits = LLVMGetIntTypeWidth(scalar);
    return bits == 8 || bits == 16 ? bits : 0;
}
// Lanes of a 32-bit word packed with K-bit integers, sign-extended to i32: lane `first` (n = 0) or lanes 0..n-1 as <n x i32>,
// each ashr(shl(word, 32 - K(k + 1)), 32 - K). Shifting the whole word is what the back end gets right; shifts of a
// zero-extended lane would be folded back into the sign extension by the optimizer that runs next.
static LLVMValueRef signedLanes(LLVMBuilderRef b, LLVMTypeRef i32, LLVMValueRef word, unsigned n, unsigned bits, unsigned first) {
    if (!n)
        return LLVMBuildAShr(b, LLVMBuildShl(b, word, LLVMConstInt(i32, 32 - bits * (first + 1), false), ""),
                             LLVMConstInt(i32, 32 - bits, false), "");
    LLVMTypeRef words = LLVMVectorType(i32, n);
    LLVMValueRef zero[16], left[16], right[16];
    for (unsigned k = 0; k < n && k < 16; k++)
        zero[k] = LLVMConstInt(i32, 0, false), left[k] = LLVMConstInt(i32, 32 - bits * (k + 1), false), right[k] = LLVMConstInt(i32, 32 - bits, false);
    LLVMValueRef v = LLVMBuildShuffleVector(b, LLVMBuildInsertElement(b, LLVMGetUndef(words), word, LLVMConstInt(i32, 0, false), ""),
                                            LLVMGetUndef(words), LLVMConstVector(zero, n), "");
    return LLVMBuildAShr(b, LLVMBuildShl(b, v, LLVMConstVector(left, n), ""), LLVMConstVector(right, n), "");
}
// A vector of i8 / i16 that fills 16 or 32 bits, as an i32 word (nullptr otherwise)
static LLVMValueRef wordOf(LLVMBuilderRef b, LLVMTypeRef i32, LLVMValueRef vector) {
    LLVMTypeRef type = LLVMTypeOf(vector);
    unsigned total = lanes(type) * subwordBits(type);
    if (total != 16 && total != 32) return nullptr;
    LLVMValueRef bits = LLVMBuildBitCast(b, vector, LLVMIntTypeInContext(LLVMGetTypeContext(i32), total), "");
    return total == 32 ? bits : LLVMBuildZExt(b, bits, i32, "");
}
// x as a signed i32 (or <n x i32>) when x is a packed vector of i8 / i16 or a lane extracted from one with a constant
// index; nullptr for other values (a lone char or short sits in the low part of its register, which is right)
static LLVMValueRef signedValue(LLVMBuilderRef b, LLVMTypeRef i32, LLVMValueRef x) {
    unsigned bits = subwordBits(LLVMTypeOf(x)), n = lanes(LLVMTypeOf(x));
    if (n) {
        LLVMValueRef word = wordOf(b, i32, x);
        return word ? signedLanes(b, i32, word, n, bits, 0) : nullptr;
    }
    if (!LLVMIsAExtractElementInst(x) || !LLVMIsAConstantInt(LLVMGetOperand(x, 1))) return nullptr;
    LLVMValueRef word = wordOf(b, i32, LLVMGetOperand(x, 0));
    return word ? signedLanes(b, i32, word, 0, bits, (unsigned)LLVMConstIntGetZExtValue(LLVMGetOperand(x, 1))) : nullptr;
}
static LLVMValueRef resized(LLVMBuilderRef b, LLVMValueRef word, LLVMTypeRef type) {  // the signed i32 word as `type`
    unsigned bits = LLVMGetIntTypeWidth(scalarOf(type));
    return bits == 32 ? word : bits < 32 ? LLVMBuildTrunc(b, word, type, "") : LLVMBuildSExt(b, word, type, "");
}
static LLVMValueRef function(LLVMModuleRef module, const char *name, LLVMTypeRef result, LLVMTypeRef param) {
    LLVMValueRef f = LLVMGetNamedFunction(module, name);
    return f ? f : LLVMAddFunction(module, name, LLVMFunctionType(result, &param, 1, 0));
}
static std::string typeSuffix(unsigned n, char kind, unsigned bits) {  // "i32", "v4f32", ...
    char text[16];
    if (n) snprintf(text, sizeof text, "v%u%c%u", n, kind, bits);
    else snprintf(text, sizeof text, "%c%u", kind, bits);
    return text;
}
// air.convert.<to>.s.<from> with an i8 / i16 (or vector) argument: "air.convert.f.f32.s.i8", "air.convert.s.v4i32.s.v4i8"
static bool signedSubwordConvert(LLVMValueRef call, const char *name) {
    if (strncmp(name, "air.convert.", 12) || LLVMGetNumOperands(call) != 2 || !subwordBits(LLVMTypeOf(LLVMGetOperand(call, 0)))) return false;
    const char *last = strrchr(name, '.');
    return last - name >= 2 && last[-1] == 's' && last[-2] == '.';
}

static unsigned fixVertexSignedSubwords(LLVMModuleRef module) {
    const char *setting = getenv("INTEL_SIGNED_SUBWORD_FIX");
    if ((setting && !strcmp(setting, "0")) || !LLVMGetNamedMetadataNumOperands(module, "air.vertex")) return 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context), f32 = LLVMFloatTypeInContext(context);
    std::vector<LLVMValueRef> found;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int opcode = LLVMGetInstructionOpcode(inst);
                if ((opcode == kOpcodeSExt || opcode == kOpcodeSIToFP) && subwordBits(LLVMTypeOf(LLVMGetOperand(inst, 0)))) {
                    found.push_back(inst);
                    continue;
                }
                if (!LLVMIsACallInst(inst)) continue;
                LLVMValueRef callee = LLVMGetCalledValue(inst);
                const char *name = callee ? LLVMGetValueName(callee) : "";
                if (!strncmp(name, "air.unpack.snorm4x8.", 20) || !strncmp(name, "air.unpack.snorm2x16.", 21) || signedSubwordConvert(inst, name))
                    found.push_back(inst);
            }
    if (found.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(context);
    unsigned fixed = 0;
    for (LLVMValueRef inst : found) {
        LLVMPositionBuilderBefore(b, inst);
        LLVMTypeRef result = LLVMTypeOf(inst);
        LLVMValueRef replacement = nullptr;
        int opcode = LLVMGetInstructionOpcode(inst);
        if (opcode == kOpcodeSExt || opcode == kOpcodeSIToFP) {
            LLVMValueRef value = signedValue(b, i32, LLVMGetOperand(inst, 0));
            if (!value) continue;
            replacement = opcode == kOpcodeSExt ? resized(b, value, result) : LLVMBuildSIToFP(b, value, result, "");
        } else {
            const char *name = LLVMGetValueName(LLVMGetCalledValue(inst));
            LLVMValueRef x = LLVMGetOperand(inst, 0);
            if (!strncmp(name, "air.unpack.", 11)) {
                // air.unpack.snorm4x8.v4f32(i32 x): lane k = clamp(float(int(x << (32 - K(k+1))) >> (32 - K)) / max, -1, 1)
                unsigned bits = !strncmp(name, "air.unpack.snorm4x8.", 20) ? 8 : 16, n = 32 / bits;
                if (lanes(result) != n || LLVMTypeOf(x) != i32) continue;
                LLVMTypeRef words = LLVMVectorType(i32, n), floats = LLVMVectorType(f32, n);
                LLVMValueRef s = signedLanes(b, i32, x, n, bits, 0);
                std::string convert = "air.convert.f." + typeSuffix(n, 'f', 32) + ".s." + typeSuffix(n, 'i', 32);
                LLVMValueRef args[1] = {s};
                LLVMValueRef f = LLVMBuildCall(b, function(module, convert.c_str(), floats, words), args, 1, "");
                f = LLVMBuildFDiv(b, f, splat(LLVMConstReal(f32, bits == 8 ? 127.0 : 32767.0), n), "");
                LLVMValueRef minusOne = splat(LLVMConstReal(f32, -1.0), n);
                f = LLVMBuildSelect(b, LLVMBuildFCmp(b, kRealOLT, f, minusOne, ""), minusOne, f, "");
                if (LLVMGetTypeKind(scalarOf(result)) == kTypeKindHalf) {
                    std::string narrow = "air.convert.f." + typeSuffix(n, 'f', 16) + ".f." + typeSuffix(n, 'f', 32);
                    LLVMValueRef narrowArgs[1] = {f};
                    f = LLVMBuildCall(b, function(module, narrow.c_str(), result, floats), narrowArgs, 1, "");
                } else if (LLVMGetTypeKind(scalarOf(result)) != kTypeKindFloat) {
                    continue;
                }
                replacement = f;
            } else {
                // air.convert.<to>.s.i8|i16|vNi8|vNi16(x): the same conversion of the signed i32 value(s)
                LLVMValueRef word = signedValue(b, i32, x);
                if (!word) continue;
                unsigned n = lanes(LLVMTypeOf(x));
                if (LLVMGetTypeKind(scalarOf(result)) == kTypeKindInteger && !strncmp(name, "air.convert.s.", 14)) {
                    replacement = resized(b, word, result);
                } else {
                    std::string wide(name, strrchr(name, '.') - name);
                    wide += "." + typeSuffix(n, 'i', 32);
                    LLVMValueRef args[1] = {word};
                    replacement = LLVMBuildCall(b, function(module, wide.c_str(), result, shaped(i32, n)), args, 1, "");
                }
            }
        }
        if (!replacement) continue;
        LLVMReplaceAllUsesWith(inst, replacement);
        LLVMInstructionEraseFromParent(inst);
        fixed++;
    }
    LLVMDisposeBuilder(b);
    return fixed;
}

// ---- sample_compare with a bias ------------------------------------------------------------------------------------
// The back end can't select a depth comparison with an LOD bias (sample_compare(s, coord, ref, bias(b)), from GLSL's
// texture(sampler2DShadow, coord, bias)): "Cannot select" aborts MTLCompilerService, which takes the page's WebGL
// context and, in Chrome, the GPU process with it. Nor can it compute an LOD (calculate_clamped_lod), so the bias can't
// be turned into an explicit level. The bias is dropped instead: air.sample_compare_depth_* calls whose level flag (the
// i1 before the float) is false get 0 for that float. Shadow maps with one level, the usual kind, are unaffected.
// INTEL_COMPARE_BIAS_FIX=0 turns it off.
extern "C" {
void LLVMSetOperand(LLVMValueRef, unsigned, LLVMValueRef);
LLVMValueRef LLVMIsAConstantFP(LLVMValueRef);
double LLVMConstRealGetDouble(LLVMValueRef, int *);
}

static unsigned dropSampleCompareBias(LLVMModuleRef module) {
    const char *setting = getenv("INTEL_COMPARE_BIAS_FIX");
    if (setting && !strcmp(setting, "0")) return 0;
    LLVMTypeRef f32 = LLVMFloatTypeInContext(LLVMGetModuleContext(module));
    unsigned fixed = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (strncmp(name, "air.sample_compare_depth_", 25) || strstr(name, "_grad")) continue;
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
        for (LLVMValueRef call : calls) {
            int n = LLVMGetNumOperands(call);  // arguments, then the callee
            if (!LLVMIsACallInst(call) || n < 4 || LLVMGetOperand(call, n - 1) != f) continue;
            LLVMValueRef flag = LLVMGetOperand(call, n - 4), value = LLVMGetOperand(call, n - 3);
            if (!LLVMIsAConstantInt(flag) || LLVMConstIntGetZExtValue(flag) || LLVMTypeOf(value) != f32) continue;
            int lossy = 0;
            if (LLVMIsAConstantFP(value) && LLVMConstRealGetDouble(value, &lossy) == 0.0) continue;
            LLVMSetOperand(call, n - 3, LLVMConstReal(f32, 0.0));
            fixed++;
        }
    }
    return fixed;
}

// ---- integer textures: gradient samples and texel offsets -----------------------------------------------------------
// Two rewrites of samples from integer textures (air.sample_texture_*.{s,u}.v4i32 and air.gather_texture_*), which are
// only ever sampled with nearest filtering, where the LOD does nothing but pick the level:
// - A gradient sample in a compute kernel (texture2d<int>::sample(s, coord, gradient2d(dx, dy))) crashes the back end
//   (null dereference in IGILTargetLowering::LowerReadImage_Int), offset or not; vertex and fragment functions are right.
//   Such calls become explicit-level samples (lowerIntegerGradients). INTEL_KERNEL_GRADIENT_FIX=0 turns that off.
// - The back end ignores the texel offset of a sample or gather (GLSL textureOffset, textureLodOffset, textureGradOffset
//   and textureProj*Offset on isampler2D, usampler2D and the like; a08's offset case): the texel at the coordinate comes
//   back. Float textures are right. The offset goes into the coordinates instead, in texels of the level the sample
//   reads: coord + offset / size, the size from air.get_{width,height,depth}_texture_* (foldIntegerSampleOffsets).
//   Where the GPU would pick the level (gradients; implicit LODs in fragment functions, from the coordinate's
//   derivatives, plus the bias: the compiler can't compute an LOD, calculate_clamped_lod aborts it), the level is
//   computed in the shader and the sample made explicit at it, so the offset and the texels come from the same level.
//   Gathers and implicit LODs in other functions read level 0. INTEL_INTEGER_OFFSET_FIX=0 turns it off.
// - In compute kernels the back end adds a gather's texel offset to the normalized coordinate as is (FADD coord, 1.0
//   for an offset of 1), so offsets come out a whole texture size per texel, on any texture format (WebGPU CTS
//   textureGather sampled_*_coords with offsets in compute, 639 cases; depth_*_coords, 45); vertex and fragment functions
//   are right; textureGatherCompare, 120). Those gathers (color, depth and compare) get the same rewrite at level 0.
//   INTEL_KERNEL_GATHER_OFFSET_FIX=0 turns that off.
// The level computed for gradients is log2 of the longer gradient in texels of level 0 (+ the bias), rounded and clamped
// to the texture's levels: a nearest mip filter's. A sampler that doesn't mipmap reads level 0 regardless (a mipmapped
// integer texture with such a sampler, sampled minified: the offset is then in the wrong level's texels).
extern "C" {
LLVMValueRef LLVMBuildFAdd(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildFPToSI(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMBuildUIToFP(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMIsAConstantAggregateZero(LLVMValueRef);
LLVMTypeRef LLVMInt1TypeInContext(LLVMContextRef);
LLVMBasicBlockRef LLVMGetInstructionParent(LLVMValueRef);
LLVMValueRef LLVMGetBasicBlockParent(LLVMBasicBlockRef);
LLVMValueRef LLVMBuildFMul(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildSub(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
}

static bool runtimeNamesBound(LLVMModuleRef module);
static bool disabled(const char *setting) {
    const char *value = getenv(setting);
    return value && !strcmp(value, "0");
}
static LLVMValueRef declared(LLVMModuleRef module, const char *name, LLVMTypeRef result, LLVMTypeRef param) {
    LLVMValueRef f = LLVMGetNamedFunction(module, name);
    return f ? f : LLVMAddFunction(module, name, LLVMFunctionType(result, &param, 1, 0));
}
static bool isEntry(LLVMModuleRef module, const char *list, LLVMValueRef function) {
    std::vector<LLVMValueRef> entries(LLVMGetNamedMetadataNumOperands(module, list));
    if (!entries.empty()) LLVMGetNamedMetadataOperands(module, list, entries.data());
    for (LLVMValueRef entry : entries) {
        std::vector<LLVMValueRef> parts = metadataOperands(entry);
        if (!parts.empty() && parts[0] == function) return true;
    }
    return false;
}
static LLVMValueRef callerOf(LLVMValueRef call) { return LLVMGetBasicBlockParent(LLVMGetInstructionParent(call)); }
// Whether a function only runs in one kind of entry point (list: "air.kernel", "air.vertex" or "air.fragment"): such an
// entry, or a function (Tint's and ANGLE's helpers) whose every call is from such a function
static bool onlyIn(LLVMModuleRef module, const char *list, LLVMValueRef function, int depth = 0) {
    if (isEntry(module, list, function)) return true;
    static const char *const kLists[3] = {"air.kernel", "air.vertex", "air.fragment"};
    for (const char *other : kLists)
        if (strcmp(other, list) && isEntry(module, other, function)) return false;
    if (depth > 8) return false;
    bool called = false;
    for (LLVMUseRef u = LLVMGetFirstUse(function); u; u = LLVMGetNextUse(u)) {
        LLVMValueRef user = LLVMGetUser(u);
        if (!LLVMIsACallInst(user) || LLVMGetOperand(user, LLVMGetNumOperands(user) - 1) != function) return false;
        if (!onlyIn(module, list, callerOf(user), depth + 1)) return false;
        called = true;
    }
    return called;
}
static bool kernelOnly(LLVMModuleRef module, LLVMValueRef function) { return onlyIn(module, "air.kernel", function); }
// air.get_{width,height,depth}_<type>(texture, lod) as a float
static LLVMValueRef textureSize(LLVMBuilderRef b, LLVMModuleRef module, LLVMValueRef texture, const char *type, unsigned d, LLVMValueRef lod) {
    static const char *const kSizes[3] = {"width", "height", "depth"};
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context);
    char name[64];
    snprintf(name, sizeof name, "air.get_%s_%s", kSizes[d], type);
    LLVMTypeRef params[2] = {LLVMTypeOf(texture), i32};
    LLVMValueRef getSize = LLVMGetNamedFunction(module, name);
    if (!getSize) getSize = LLVMAddFunction(module, name, LLVMFunctionType(i32, params, 2, 0));
    LLVMValueRef args[2] = {texture, lod};
    return LLVMBuildUIToFP(b, LLVMBuildCall(b, getSize, args, 2, ""), LLVMFloatTypeInContext(context), "");
}
// rounded (a level + 0.5) clamped to [0, levels - 1] (NaN: 0) and truncated: an i32 level
static LLVMValueRef clampedLevel(LLVMBuilderRef b, LLVMModuleRef module, LLVMValueRef texture, const char *type, LLVMValueRef rounded) {
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context), f32 = LLVMFloatTypeInContext(context);
    char name[64];
    snprintf(name, sizeof name, "air.get_num_mip_levels_%s", type);
    LLVMValueRef levels = LLVMBuildCall(b, declared(module, name, i32, LLVMTypeOf(texture)), &texture, 1, "");
    LLVMValueRef top = LLVMBuildUIToFP(b, LLVMBuildSub(b, levels, LLVMConstInt(i32, 1, false), ""), f32, "");
    LLVMValueRef zero = LLVMConstReal(f32, 0.0);
    rounded = LLVMBuildSelect(b, LLVMBuildFCmp(b, 2 /* OGT */, rounded, zero, ""), rounded, zero, "");
    rounded = LLVMBuildSelect(b, LLVMBuildFCmp(b, 4 /* OLT */, rounded, top, ""), rounded, top, "");
    return LLVMBuildFPToSI(b, rounded, i32, "");
}
// The level gradients dPdx and dPdy (normalized coordinates) select with a nearest mip filter, plus bias (or null):
// 0.5 * log2(max(|dPdx * size|^2, |dPdy * size|^2)) + bias, the size level 0's, rounded and clamped; an i32
static LLVMValueRef selectedLevel(LLVMBuilderRef b, LLVMModuleRef module, LLVMValueRef texture, const char *type, unsigned dims,
                                  LLVMValueRef dPdx, LLVMValueRef dPdy, LLVMValueRef bias) {
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context), f32 = LLVMFloatTypeInContext(context);
    LLVMValueRef rho[2] = {LLVMConstReal(f32, 0.0), LLVMConstReal(f32, 0.0)};
    for (unsigned d = 0; d < dims; d++) {
        LLVMValueRef size = textureSize(b, module, texture, type, d, LLVMConstInt(i32, 0, false));
        for (int k = 0; k < 2; k++) {
            LLVMValueRef texels = LLVMBuildFMul(b, LLVMBuildExtractElement(b, k ? dPdy : dPdx, LLVMConstInt(i32, d, false), ""), size, "");
            rho[k] = LLVMBuildFAdd(b, rho[k], LLVMBuildFMul(b, texels, texels, ""), "");
        }
    }
    LLVMValueRef longer = LLVMBuildSelect(b, LLVMBuildFCmp(b, 2 /* OGT */, rho[0], rho[1], ""), rho[0], rho[1], "");
    LLVMValueRef log = LLVMBuildCall(b, declared(module, "air.fast_log2.f32", f32, f32), &longer, 1, "");
    LLVMValueRef rounded = LLVMBuildFAdd(b, LLVMBuildFMul(b, log, LLVMConstReal(f32, 0.5), ""), LLVMConstReal(f32, 0.5), "");
    if (bias) rounded = LLVMBuildFAdd(b, rounded, bias, "");
    return clampedLevel(b, module, texture, type, rounded);
}
static bool integerResult(const char *name, size_t length) {
    return length >= 8 && (!strcmp(name + length - 8, ".s.v4i32") || !strcmp(name + length - 8, ".u.v4i32"));
}

// Gradient samples from integer textures in compute kernels, and those with an offset anywhere: explicit-level samples
// at the level the gradients select.
static unsigned lowerIntegerGradients(LLVMModuleRef module) {
    bool kernels = !disabled("INTEL_KERNEL_GRADIENT_FIX"), offsets = !disabled("INTEL_INTEGER_OFFSET_FIX");
    if ((!kernels && !offsets) || runtimeNamesBound(module)) return 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef f32 = LLVMFloatTypeInContext(context), i1 = LLVMInt1TypeInContext(context);
    // gradient: the index of dPdx (dPdy follows, then i1, offset, i32); the explicit-level form takes the operands before
    // it, then i1, offset, i1 true, float level, i32
    static const struct { const char *prefix, *plain, *size; unsigned dims, gradient; } kKinds[] = {
        {"air.sample_texture_2d_grad.", "air.sample_texture_2d.", "texture_2d", 2, 3},                    // tex, sampler, coord, dPdx, ...
        {"air.sample_texture_2d_array_grad.", "air.sample_texture_2d_array.", "texture_2d_array", 2, 4},  // ..., coord, layer, dPdx, ...
        {"air.sample_texture_3d_grad.", "air.sample_texture_3d.", "texture_3d", 3, 3},
    };
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    std::vector<LLVMValueRef> functions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) functions.push_back(f);
    for (LLVMValueRef f : functions) {
        const char *name = LLVMGetValueName(f);
        size_t length = strlen(name);
        if (!integerResult(name, length)) continue;
        for (const auto &kind : kKinds) {
            size_t prefix = strlen(kind.prefix);
            if (strncmp(name, kind.prefix, prefix) || strchr(name + prefix, '_')) continue;
            std::vector<LLVMValueRef> calls;
            for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
            for (LLVMValueRef call : calls) {
                int n = LLVMGetNumOperands(call);
                if (!LLVMIsACallInst(call) || n != (int)kind.gradient + 6 || LLVMGetOperand(call, n - 1) != f) continue;
                LLVMValueRef texture = LLVMGetOperand(call, 0), dPdx = LLVMGetOperand(call, kind.gradient), dPdy = LLVMGetOperand(call, kind.gradient + 1);
                bool offset = !LLVMIsAConstantAggregateZero(LLVMGetOperand(call, kind.gradient + 3));
                if (lanes(LLVMTypeOf(dPdx)) != kind.dims || lanes(LLVMTypeOf(dPdy)) != kind.dims ||
                    !((kernels && isEntry(module, "air.kernel", callerOf(call))) || (offsets && offset)))
                    continue;
                if (!b) b = LLVMCreateBuilderInContext(context);
                LLVMPositionBuilderBefore(b, call);
                LLVMValueRef level = LLVMBuildSIToFP(b, selectedLevel(b, module, texture, kind.size, kind.dims, dPdx, dPdy, nullptr), f32, "");
                std::vector<LLVMValueRef> args;
                for (unsigned k = 0; k < kind.gradient; k++) args.push_back(LLVMGetOperand(call, k));
                args.push_back(LLVMGetOperand(call, kind.gradient + 2));  // i1 (offset)
                args.push_back(LLVMGetOperand(call, kind.gradient + 3));  // offset
                args.push_back(LLVMConstInt(i1, 1, false));
                args.push_back(level);
                args.push_back(LLVMGetOperand(call, kind.gradient + 4));  // i32
                std::vector<LLVMTypeRef> params;
                for (LLVMValueRef arg : args) params.push_back(LLVMTypeOf(arg));
                char plain[96];
                snprintf(plain, sizeof plain, "%s%s", kind.plain, name + length - 7);  // s.v4i32 / u.v4i32
                LLVMValueRef target = LLVMGetNamedFunction(module, plain);
                if (!target) target = LLVMAddFunction(module, plain, LLVMFunctionType(LLVMTypeOf(call), params.data(), (unsigned)params.size(), 0));
                LLVMValueRef replacement = LLVMBuildCall(b, target, args.data(), (unsigned)args.size(), "");
                LLVMReplaceAllUsesWith(call, replacement);
                LLVMInstructionEraseFromParent(call);
                fixed++;
            }
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- green gathers from R32G32 textures ---------------------------------------------------------------------------
// Haswell's gather4 returns red for the green component of R32G32 formats (rg32float, rg32uint, rg32sint): a hardware
// erratum that Mesa works around with a separate surface state for gathers, which this driver doesn't have, and the
// shader can't tell an R32G32 texture from any other (WebGPU CTS textureGather rg32float: 252 cases, 216 of them 2D and
// 2D array). A green gather from a 2D texture or 2D array is also done as a red one, and where the two agree in all four
// texels (the erratum, or a texture whose red equals its green there) the green values come from four level-0 samples
// at the footprint's texel centers instead, through the same sampler (its address modes; at a texel center a linear
// filter returns that texel), in gather order: (u0, v1), (u1, v1), (u1, v0), (u0, v0), u0 = floor(u * width - 0.5) plus
// the offset. Cube gathers keep the erratum. INTEL_GATHER_GREEN_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMBuildFSub(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildAnd(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildAdd(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildZExt(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
}
static unsigned greenGathers(LLVMModuleRef module) {
    if (disabled("INTEL_GATHER_GREEN_FIX") || ivyBridgePlugin || runtimeNamesBound(module)) return 0;
    enum { kIntEQ = 32, kRealOGT = 2 };
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context), f32 = LLVMFloatTypeInContext(context), i1 = LLVMInt1TypeInContext(context);
    std::vector<LLVMValueRef> gathers;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (!strncmp(name, "air.gather_texture_2d.", 22) || !strncmp(name, "air.gather_texture_2d_array.", 28)) gathers.push_back(f);
    }
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef f : gathers) {
        std::string name = LLVMGetValueName(f);
        bool array = !name.compare(0, 28, "air.gather_texture_2d_array.");
        // tex, sampler, coord, [i32 layer,] i1, offset, i32 component, i32; a sample: ..., offset, i1 level, float, i32
        unsigned offsetIndex = array ? 5 : 4, count = offsetIndex + 3;
        std::string sampleName = "air.sample" + name.substr(strlen("air.gather"));
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
        for (LLVMValueRef call : calls) {
            if (!LLVMIsACallInst(call) || LLVMGetNumOperands(call) != (int)count + 1 || LLVMGetOperand(call, count) != f) continue;
            LLVMValueRef component = LLVMGetOperand(call, offsetIndex + 1), coord = LLVMGetOperand(call, 2);
            LLVMTypeRef result = LLVMTypeOf(call);
            if (!LLVMIsAConstantInt(component) || LLVMConstIntGetZExtValue(component) != 1 || lanes(result) != 4 ||
                lanes(LLVMTypeOf(coord)) != 2 || lanes(LLVMTypeOf(LLVMGetOperand(call, offsetIndex))) != 2)
                continue;
            std::vector<LLVMTypeRef> params;
            for (unsigned i = 0; i <= offsetIndex; i++) params.push_back(LLVMTypeOf(LLVMGetOperand(call, i)));
            params.push_back(i1), params.push_back(f32), params.push_back(i32);
            LLVMValueRef sample = LLVMGetNamedFunction(module, sampleName.c_str());
            if (!sample) sample = LLVMAddFunction(module, sampleName.c_str(), LLVMFunctionType(result, params.data(), (unsigned)params.size(), 0));
            if (!b) b = LLVMCreateBuilderInContext(context);
            LLVMPositionBuilderBefore(b, call);
            std::vector<LLVMValueRef> args(count);
            for (unsigned i = 0; i < count; i++) args[i] = LLVMGetOperand(call, i);
            LLVMValueRef green = LLVMBuildCall(b, f, args.data(), count, "");
            args[offsetIndex + 1] = LLVMConstInt(i32, 0, false);
            LLVMValueRef red = LLVMBuildCall(b, f, args.data(), count, "");
            // compared as integers of the lanes' own width: MetalFX's spatial scaler gathers half4 (a <4 x i32> bitcast of
            // those failed the verifier, and the compiler service aborted on MFX_Scale)
            LLVMTypeRef element = LLVMGetElementType(result);
            int elementKind = LLVMGetTypeKind(element);
            unsigned bits = elementKind == kTypeKindHalf ? 16 : elementKind == kTypeKindInteger ? LLVMGetIntTypeWidth(element) : 32;
            LLVMTypeRef words = LLVMVectorType(LLVMIntTypeInContext(context, bits), 4);
            LLVMValueRef same = LLVMBuildICmp(b, kIntEQ, LLVMBuildBitCast(b, green, words, ""), LLVMBuildBitCast(b, red, words, ""), "");
            LLVMValueRef all = LLVMBuildExtractElement(b, same, LLVMConstInt(i32, 0, false), "");
            for (unsigned k = 1; k < 4; k++) all = LLVMBuildAnd(b, all, LLVMBuildExtractElement(b, same, LLVMConstInt(i32, k, false), ""), "");
            // the footprint's first texel, floor(coord * size - 0.5) + offset, and the texel centers around it
            const char *type = array ? "texture_2d_array" : "texture_2d";
            LLVMValueRef texture = args[0], offset = args[offsetIndex], centers[2][2];
            for (unsigned d = 0; d < 2; d++) {
                LLVMValueRef index = LLVMConstInt(i32, d, false);
                LLVMValueRef size = textureSize(b, module, texture, type, d, LLVMConstInt(i32, 0, false));
                LLVMValueRef p = LLVMBuildFSub(b, LLVMBuildFMul(b, LLVMBuildExtractElement(b, coord, index, ""), size, ""), LLVMConstReal(f32, 0.5), "");
                LLVMValueRef t = LLVMBuildFPToSI(b, p, i32, "");  // toward zero: one less where that was above p
                t = LLVMBuildSub(b, t, LLVMBuildZExt(b, LLVMBuildFCmp(b, kRealOGT, LLVMBuildSIToFP(b, t, f32, ""), p, ""), i32, ""), "");
                t = LLVMBuildAdd(b, t, LLVMBuildExtractElement(b, offset, index, ""), "");
                LLVMValueRef first = LLVMBuildSIToFP(b, t, f32, "");
                for (unsigned k = 0; k < 2; k++)
                    centers[d][k] = LLVMBuildFDiv(b, LLVMBuildFAdd(b, first, LLVMConstReal(f32, k + 0.5), ""), size, "");
            }
            static const unsigned kOrder[4][2] = {{0, 1}, {1, 1}, {1, 0}, {0, 0}};  // (u, v) of the gather's x, y, z, w
            LLVMValueRef emulated = LLVMGetUndef(result);
            std::vector<LLVMValueRef> sampleArgs(args.begin(), args.begin() + offsetIndex + 1);
            sampleArgs[offsetIndex] = LLVMConstNull(LLVMTypeOf(offset));
            sampleArgs.push_back(LLVMConstInt(i1, 1, false)), sampleArgs.push_back(LLVMConstReal(f32, 0)), sampleArgs.push_back(args[count - 1]);
            for (unsigned k = 0; k < 4; k++) {
                LLVMValueRef at = LLVMBuildInsertElement(b, LLVMGetUndef(LLVMTypeOf(coord)), centers[0][kOrder[k][0]], LLVMConstInt(i32, 0, false), "");
                sampleArgs[2] = LLVMBuildInsertElement(b, at, centers[1][kOrder[k][1]], LLVMConstInt(i32, 1, false), "");
                LLVMValueRef texel = LLVMBuildCall(b, sample, sampleArgs.data(), (unsigned)sampleArgs.size(), "");
                emulated = LLVMBuildInsertElement(b, emulated, LLVMBuildExtractElement(b, texel, LLVMConstInt(i32, 1, false), ""),
                                                  LLVMConstInt(i32, k, false), "");
            }
            LLVMReplaceAllUsesWith(call, LLVMBuildSelect(b, all, emulated, green, ""));
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// Texel offsets on integer textures: into the coordinates.
static unsigned foldIntegerSampleOffsets(LLVMModuleRef module) {
    bool integers = !disabled("INTEL_INTEGER_OFFSET_FIX"), kernelGathers = !disabled("INTEL_KERNEL_GATHER_OFFSET_FIX");
    if (!integers && !kernelGathers) return 0;
    bool bound = runtimeNamesBound(module);  // no air.* calls can be added (see fixFloat3Inputs)
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context), f32 = LLVMFloatTypeInContext(context), i1 = LLVMInt1TypeInContext(context);
    // after: operands after the offset (the level flag, level or bias and i32 of a sample; component and i32 of a gather;
    // i32 of a gradient sample, left by lowerIntegerGradients only where no calls can be added: level 0)
    static const struct { const char *prefix, *size; unsigned dims, coordIndex, offsetIndex, after; } kKinds[] = {
        {"air.sample_texture_2d.", "texture_2d", 2, 2, 4, 3},                   // tex, sampler, coord, i1, offset, i1 lod, float, i32
        {"air.sample_texture_2d_array.", "texture_2d_array", 2, 2, 5, 3},       // ..., coord, i32 layer, i1, offset, ...
        {"air.sample_texture_3d.", "texture_3d", 3, 2, 4, 3},
        {"air.gather_texture_2d.", "texture_2d", 2, 2, 4, 2},                   // tex, sampler, coord, i1, offset, i32 component, i32
        {"air.gather_texture_2d_array.", "texture_2d_array", 2, 2, 5, 2},       // ..., coord, i32 layer, i1, offset, ...
        {"air.gather_depth_2d.", "depth_2d", 2, 3, 5, 1},                       // tex, sampler, i32, coord, i1, offset, i32
        {"air.gather_depth_2d_array.", "depth_2d_array", 2, 3, 6, 1},           // ..., coord, i32 layer, i1, offset, i32
        {"air.gather_compare_depth_2d.", "depth_2d", 2, 3, 6, 1},               // tex, sampler, i32, coord, float ref, i1, offset, i32
        {"air.gather_compare_depth_2d_array.", "depth_2d_array", 2, 3, 7, 1},   // ..., coord, i32 layer, float ref, i1, offset, i32
        {"air.sample_texture_2d_grad.", "texture_2d", 2, 2, 6, 1},              // tex, sampler, coord, dPdx, dPdy, i1, offset, i32
        {"air.sample_texture_2d_array_grad.", "texture_2d_array", 2, 2, 7, 1},  // ..., coord, i32 layer, dPdx, dPdy, i1, offset, i32
        {"air.sample_texture_3d_grad.", "texture_3d", 3, 2, 6, 1},
    };
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        bool integer = integerResult(name, strlen(name));
        if (!(integer && integers) &&
            !(kernelGathers && (!strncmp(name, "air.gather_texture_", 19) || !strncmp(name, "air.gather_depth_", 17) ||
                                !strncmp(name, "air.gather_compare_depth_", 25))))
            continue;
        for (const auto &kind : kKinds) {
            size_t prefix = strlen(kind.prefix);
            if (strncmp(name, kind.prefix, prefix) || strchr(name + prefix, '_')) continue;  // not 2d_array for 2d, no _grad
            std::vector<LLVMValueRef> calls;
            for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
            for (LLVMValueRef call : calls) {
                int n = LLVMGetNumOperands(call);  // arguments, then the callee
                if (!LLVMIsACallInst(call) || n != (int)(kind.offsetIndex + kind.after + 2) || LLVMGetOperand(call, n - 1) != f) continue;
                LLVMValueRef offset = LLVMGetOperand(call, kind.offsetIndex), coord = LLVMGetOperand(call, kind.coordIndex);
                bool sample = kind.after == 3;
                LLVMValueRef hasLevel = sample ? LLVMGetOperand(call, kind.offsetIndex + 1) : LLVMConstInt(i1, 0, false);
                LLVMValueRef level = sample ? LLVMGetOperand(call, kind.offsetIndex + 2) : nullptr;  // or the bias
                if (LLVMIsAConstantAggregateZero(offset) || lanes(LLVMTypeOf(offset)) != kind.dims || lanes(LLVMTypeOf(coord)) != kind.dims ||
                    !LLVMIsAConstantInt(hasLevel))
                    continue;
                if (!(integer && integers) && !kernelOnly(module, callerOf(call))) continue;  // float: kernel gathers only
                if (!b) b = LLVMCreateBuilderInContext(context);
                LLVMPositionBuilderBefore(b, call);
                LLVMValueRef texture = LLVMGetOperand(call, 0), lod = LLVMConstInt(i32, 0, false);
                if (sample && LLVMConstIntGetZExtValue(hasLevel)) {
                    lod = clampedLevel(b, module, texture, kind.size, LLVMBuildFAdd(b, level, LLVMConstReal(f32, 0.5), ""));
                } else if (sample && !bound && isEntry(module, "air.fragment", callerOf(call))) {  // made explicit
                    char name[32];
                    snprintf(name, sizeof name, "air.dfdx.v%uf32", kind.dims);
                    LLVMValueRef dPdx = LLVMBuildCall(b, declared(module, name, LLVMTypeOf(coord), LLVMTypeOf(coord)), &coord, 1, "");
                    name[7] = 'y';
                    LLVMValueRef dPdy = LLVMBuildCall(b, declared(module, name, LLVMTypeOf(coord), LLVMTypeOf(coord)), &coord, 1, "");
                    lod = selectedLevel(b, module, texture, kind.size, kind.dims, dPdx, dPdy, level);
                    LLVMSetOperand(call, kind.offsetIndex + 1, LLVMConstInt(i1, 1, false));
                    LLVMSetOperand(call, kind.offsetIndex + 2, LLVMBuildSIToFP(b, lod, f32, ""));
                }
                LLVMValueRef shifted = coord;
                for (unsigned d = 0; d < kind.dims; d++) {
                    LLVMValueRef size = textureSize(b, module, texture, kind.size, d, lod);
                    LLVMValueRef index = LLVMConstInt(i32, d, false);
                    LLVMValueRef texels = LLVMBuildSIToFP(b, LLVMBuildExtractElement(b, offset, index, ""), f32, "");
                    LLVMValueRef component = LLVMBuildFAdd(b, LLVMBuildExtractElement(b, shifted, index, ""), LLVMBuildFDiv(b, texels, size, ""), "");
                    shifted = LLVMBuildInsertElement(b, shifted, component, index, "");
                }
                LLVMSetOperand(call, kind.coordIndex, shifted);
                LLVMSetOperand(call, kind.offsetIndex, LLVMConstNull(LLVMTypeOf(offset)));
                fixed++;
            }
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- saturating multiply-add ----------------------------------------------------------------------------------------
// The back end's lowering of madsat (air.mad_sat.{u,s}.*) is wrong: it multiplies into a 64-bit pair, adds c to one half
// and checks a bit-masked half against 0, missing the carry out of the addition, so madsat(a, 3u, b) returned the wrapped
// a * 3 + b instead of 0xffffffff for most inputs (differential fuzzing, mslfuzz2: 162 of 195 disagreements; a unit
// kernel: 180 of 256 threads). It's done with 32-bit operations instead, per lane: lo = a * b, hi = mulhi(a, b),
// sum = lo + c with its carry; unsigned: saturate to 0xffffffff when hi != 0 or the sum carries; signed: the 64-bit sum's
// high word hi + (c >> 31) + carry must equal sum >> 31, else saturate to INT_MIN / INT_MAX by its sign. 32-bit elements
// only. mulhi (air.mul_hi) and madhi (air.mad_hi) are wrong too, with a constant operand or signed (mulhi(a, 3u)
// returned 0): those take the same high word, buildMulHi below. INTEL_MAD_SAT_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMBuildMul(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildAdd(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildOr(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildAShr(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildZExt(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMBuildLShr(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildAnd(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildSub(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
}
// The high word of a 32 x 32-bit product from 16-bit halves (every partial product fits in 32 bits): unsigned, then
// corrected for signed operands (hi_s = hi_u - (a < 0 ? b : 0) - (b < 0 ? a : 0)). The back end's own mul_hi is wrong
// with a constant operand (mulhi(a, 3u) returned 0) and for signed operands (177 of 256 threads wrong).
static LLVMValueRef buildMulHi(LLVMBuilderRef b, LLVMTypeRef i32, LLVMValueRef x, LLVMValueRef y, bool sign) {
    LLVMValueRef sixteen = LLVMConstInt(i32, 16, false), mask = LLVMConstInt(i32, 0xffff, false);
    LLVMValueRef xl = LLVMBuildAnd(b, x, mask, ""), xh = LLVMBuildLShr(b, x, sixteen, "");
    LLVMValueRef yl = LLVMBuildAnd(b, y, mask, ""), yh = LLVMBuildLShr(b, y, sixteen, "");
    LLVMValueRef ll = LLVMBuildMul(b, xl, yl, ""), lh = LLVMBuildMul(b, xl, yh, ""), hl = LLVMBuildMul(b, xh, yl, ""), hh = LLVMBuildMul(b, xh, yh, "");
    LLVMValueRef mid = LLVMBuildAdd(b, LLVMBuildAdd(b, LLVMBuildLShr(b, ll, sixteen, ""), LLVMBuildAnd(b, lh, mask, ""), ""),
                                    LLVMBuildAnd(b, hl, mask, ""), "");
    LLVMValueRef hi = LLVMBuildAdd(b, LLVMBuildAdd(b, hh, LLVMBuildLShr(b, lh, sixteen, ""), ""),
                                   LLVMBuildAdd(b, LLVMBuildLShr(b, hl, sixteen, ""), LLVMBuildLShr(b, mid, sixteen, ""), ""), "");
    if (!sign) return hi;
    LLVMValueRef zero = LLVMConstInt(i32, 0, false);
    LLVMValueRef fromX = LLVMBuildSelect(b, LLVMBuildICmp(b, 40 /* SLT */, x, zero, ""), y, zero, "");
    LLVMValueRef fromY = LLVMBuildSelect(b, LLVMBuildICmp(b, 40 /* SLT */, y, zero, ""), x, zero, "");
    return LLVMBuildSub(b, LLVMBuildSub(b, hi, fromX, ""), fromY, "");
}

static unsigned exactMadSat(LLVMModuleRef module) {
    if (disabled("INTEL_MAD_SAT_FIX") || runtimeNamesBound(module)) return 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    std::vector<LLVMValueRef> functions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) functions.push_back(f);
    for (LLVMValueRef f : functions) {
        const char *name = LLVMGetValueName(f);
        int kind = !strncmp(name, "air.mad_sat.", 12) ? 0 : !strncmp(name, "air.mul_hi.", 11) ? 1 : !strncmp(name, "air.mad_hi.", 11) ? 2 : -1;
        if (kind < 0) continue;
        size_t at = kind == 0 ? 12 : 11;  // the u / s after the prefix
        if ((name[at] != 'u' && name[at] != 's') || name[at + 1] != '.') continue;
        bool sign = name[at] == 's';
        int operands = kind == 1 ? 2 : 3;
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
        for (LLVMValueRef call : calls) {
            if (!LLVMIsACallInst(call) || LLVMGetNumOperands(call) != operands + 1 || LLVMGetOperand(call, operands) != f) continue;
            LLVMTypeRef type = LLVMTypeOf(call);
            unsigned n = lanes(type);
            LLVMTypeRef element = n ? LLVMGetElementType(type) : type;
            if (LLVMGetTypeKind(element) != kTypeKindInteger || LLVMGetIntTypeWidth(element) != 32) continue;
            if (!b) b = LLVMCreateBuilderInContext(context);
            LLVMPositionBuilderBefore(b, call);
            LLVMValueRef zero = LLVMConstInt(i32, 0, false), all = LLVMConstInt(i32, 0xffffffffu, false);
            LLVMValueRef result = n ? LLVMGetUndef(type) : nullptr;
            for (unsigned lane = 0; lane < (n ? n : 1); lane++) {
                LLVMValueRef v[3];
                for (int k = 0; k < operands; k++)
                    v[k] = n ? LLVMBuildExtractElement(b, LLVMGetOperand(call, k), LLVMConstInt(i32, lane, false), "") : LLVMGetOperand(call, k);
                LLVMValueRef hi = buildMulHi(b, i32, v[0], v[1], sign);
                if (kind) {  // mulhi(a, b); madhi(a, b, c) = mulhi(a, b) + c
                    LLVMValueRef r = kind == 1 ? hi : LLVMBuildAdd(b, hi, v[2], "");
                    result = n ? LLVMBuildInsertElement(b, result, r, LLVMConstInt(i32, lane, false), "") : r;
                    continue;
                }
                LLVMValueRef lo = LLVMBuildMul(b, v[0], v[1], "");
                LLVMValueRef sum = LLVMBuildAdd(b, lo, v[2], "");
                LLVMValueRef carry = LLVMBuildICmp(b, 36 /* ULT */, sum, lo, "");
                LLVMValueRef r;
                if (!sign) {
                    LLVMValueRef saturate = LLVMBuildOr(b, LLVMBuildICmp(b, 33 /* NE */, hi, zero, ""), carry, "");
                    r = LLVMBuildSelect(b, saturate, all, sum, "");
                } else {
                    LLVMValueRef thirtyOne = LLVMConstInt(i32, 31, false);
                    LLVMValueRef high = LLVMBuildAdd(b, LLVMBuildAdd(b, hi, LLVMBuildAShr(b, v[2], thirtyOne, ""), ""),
                                                     LLVMBuildZExt(b, carry, i32, ""), "");
                    LLVMValueRef fits = LLVMBuildICmp(b, 32 /* EQ */, high, LLVMBuildAShr(b, sum, thirtyOne, ""), "");
                    LLVMValueRef bound = LLVMBuildSelect(b, LLVMBuildICmp(b, 40 /* SLT */, high, zero, ""), LLVMConstInt(i32, 0x80000000u, false),
                                                         LLVMConstInt(i32, 0x7fffffffu, false), "");
                    r = LLVMBuildSelect(b, fits, sum, bound, "");
                }
                result = n ? LLVMBuildInsertElement(b, result, r, LLVMConstInt(i32, lane, false), "") : r;
            }
            LLVMReplaceAllUsesWith(call, result);
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- narrow integer division -----------------------------------------------------------------------------------------
// Division and remainder of 8- and 16-bit integers become the back end's narrow divides (USDIV and the like), which
// expect operands extended from 16 bits the way the operation's signedness says. Constants and lanes built from them
// arrive sign-extended instead (a lane of 0xffff is -1 in its 32-bit register): ushort2(35069, 25597) / (ushort2(65535,
// x) | 1) gave 0x1200 in the first lane, not 0 (the MacBookPro11,5 session's narrow-vector fuzzing, VEC=1 ASTYPE=1,
// seed 53). udiv / urem / sdiv / srem on i8 and i16, scalar or vector, are done on 32-bit lanes: operands zero- or
// sign-extended, the i32 operation, the result truncated. INTEL_NARROW_DIV_FIX=0 turns it off.
// In vertex and fragment functions a vector operand made with as_type went wrong when extended as a whole vector:
// as_type<uchar4>(x) % uchar4(41, 23, 33, 100) crashed the compiler service and as_type<char4>(x) % char4(41, -23, ...)
// came out as the unsigned remainder (fragment fuzzing with as_type, seed 55). There vector operands are widened with
// renderLanes32 instead, and so are those of the 8/16-bit min / max / clamp below (a signed max(char4(...),
// as_type<char4>(y)) was wrong, seed 245). INTEL_NARROW_VECTOR_OPERAND_FIX=0 turns that part off (both). Test: i70.
extern "C" {
LLVMValueRef LLVMBuildUDiv(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildURem(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildSDiv(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildSRem(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
}
static LLVMValueRef unsignedValue(LLVMBuilderRef b, LLVMTypeRef i32, LLVMValueRef x);
extern "C" LLVMValueRef LLVMIsAInstruction(LLVMValueRef);
// The lanes of an i8 / i16 vector as <N x i32>, zero- or sign-extended, for vertex and fragment functions, where the back
// end's legalization of a narrow vector depends on how it was made: put together with insertelement or a constant, lane
// by lane (extendLanes); a 16 / 32-bit vector made otherwise (as_type, a load), from its word with shifts (signedValue,
// unsignedValue: sext of an as_type<char4> came out wrong and zext of one crashed); a trunc of 32-bit lanes, those lanes
// masked or sign-extended; anything else (ushort3, ushort4, uchar3), lane by lane: extending the whole vector crashed for
// as_type<ushort3>(half3) (i69).
static LLVMValueRef renderLanes32(LLVMBuilderRef b, LLVMTypeRef i32, LLVMValueRef v, bool sign) {
    unsigned n = lanes(LLVMTypeOf(v)), bits = subwordBits(LLVMTypeOf(v));
    LLVMTypeRef wide = LLVMVectorType(i32, n);
    if (LLVMIsAConstant(v) || LLVMIsAInsertElementInst(v)) return extendLanes(b, v, wide, sign);
    if (LLVMValueRef x = sign ? signedValue(b, i32, v) : unsignedValue(b, i32, v)) return x;
    enum { kTrunc = 30 };
    if (LLVMIsAInstruction(v) && LLVMGetInstructionOpcode(v) == kTrunc && LLVMTypeOf(LLVMGetOperand(v, 0)) == wide) {
        LLVMValueRef w = LLVMGetOperand(v, 0), s = splat(LLVMConstInt(i32, 32 - bits, false), n);
        return sign ? LLVMBuildAShr(b, LLVMBuildShl(b, w, s, ""), s, "") : LLVMBuildAnd(b, w, splat(LLVMConstInt(i32, (1u << bits) - 1, false), n), "");
    }
    LLVMValueRef x = LLVMGetUndef(wide);
    for (unsigned k = 0; k < n; k++) {
        LLVMValueRef lane = LLVMBuildExtractElement(b, v, LLVMConstInt(i32, k, false), "");
        lane = sign ? LLVMBuildSExt(b, lane, i32, "") : LLVMBuildZExt(b, lane, i32, "");
        x = LLVMBuildInsertElement(b, x, lane, LLVMConstInt(i32, k, false), "");
    }
    return x;
}
static unsigned widenNarrowDivisions(LLVMModuleRef module) {
    if (disabled("INTEL_NARROW_DIV_FIX") || runtimeNamesBound(module)) return 0;
    enum { kOpcodeUDiv = 14, kOpcodeSDiv = 15, kOpcodeURem = 17, kOpcodeSRem = 18 };
    bool render = LLVMGetNamedMetadataNumOperands(module, "air.vertex") || LLVMGetNamedMetadataNumOperands(module, "air.fragment");
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context);
    std::vector<LLVMValueRef> divisions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int opcode = LLVMGetInstructionOpcode(inst);
                if (opcode != kOpcodeUDiv && opcode != kOpcodeSDiv && opcode != kOpcodeURem && opcode != kOpcodeSRem) continue;
                LLVMTypeRef type = LLVMTypeOf(inst);
                LLVMTypeRef element = lanes(type) ? LLVMGetElementType(type) : type;
                if (LLVMGetTypeKind(element) == kTypeKindInteger && LLVMGetIntTypeWidth(element) < 32) divisions.push_back(inst);
            }
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef division : divisions) {
        int opcode = LLVMGetInstructionOpcode(division);
        bool sign = opcode == kOpcodeSDiv || opcode == kOpcodeSRem;
        LLVMTypeRef type = LLVMTypeOf(division);
        unsigned n = lanes(type);
        LLVMTypeRef wide = n ? LLVMVectorType(i32, n) : i32;
        if (!b) b = LLVMCreateBuilderInContext(context);
        LLVMPositionBuilderBefore(b, division);
        LLVMValueRef x = LLVMGetOperand(division, 0), y = LLVMGetOperand(division, 1);
        if (n && render && !disabled("INTEL_NARROW_VECTOR_OPERAND_FIX")) {  // i70: as_type<uchar4>(x) % uchar4(41, ...) crashed, char4 % was unsigned
            x = renderLanes32(b, i32, x, sign);
            y = renderLanes32(b, i32, y, sign);
        } else {
            x = extendLanes(b, x, wide, sign);
            y = extendLanes(b, y, wide, sign);
        }
        LLVMValueRef r = opcode == kOpcodeUDiv ? LLVMBuildUDiv(b, x, y, "") : opcode == kOpcodeURem ? LLVMBuildURem(b, x, y, "")
                       : opcode == kOpcodeSDiv ? LLVMBuildSDiv(b, x, y, "") : LLVMBuildSRem(b, x, y, "");
        LLVMValueRef result = LLVMBuildTrunc(b, r, type, "");
        LLVMReplaceAllUsesWith(division, result);
        LLVMInstructionEraseFromParent(division);
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- signed division by a power of two --------------------------------------------------------------------------------
// iCBE turns a signed divide by a constant 2^k (or -2^k) into an arithmetic shift, which rounds toward minus infinity:
// -7 / 4 came out -2, not -1, for every negative dividend that isn't a multiple (int / 2 on negative values; the
// MacBookPro11,5 session's narrow-vector fuzzing found it through char4(...) / char4(-3, 7, -128, 5)). Remainders are
// right. Such divides are done as (x + ((x >> (w - 1)) >>> (w - k))) >> k, negated for -2^k, lane by lane for constant
// vectors (other lanes keep the divide). INTEL_SDIV_POW2_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMGetElementAsConstant(LLVMValueRef, unsigned);
LLVMValueRef LLVMIsAConstantDataSequential(LLVMValueRef);
}
static unsigned signedPowerOfTwoDivisions(LLVMModuleRef module) {
    if (disabled("INTEL_SDIV_POW2_FIX") || runtimeNamesBound(module)) return 0;
    enum { kOpcodeSDiv = 15 };
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context);
    auto powerOfTwo = [](LLVMValueRef c, unsigned width, int &k, bool &negative) {  // c = +-2^k, 1 <= k < width
        if (!LLVMIsAConstantInt(c)) return false;
        uint64_t mask = width == 64 ? ~0ull : (1ull << width) - 1, v = LLVMConstIntGetZExtValue(c) & mask;
        negative = (v >> (width - 1)) & 1;
        uint64_t magnitude = negative ? ((~v + 1) & mask) : v;
        if (negative && magnitude == (1ull << (width - 1))) magnitude = 1ull << (width - 1);  // INT_MIN
        if (magnitude < 2 || (magnitude & (magnitude - 1))) return false;
        k = __builtin_ctzll(magnitude);
        return true;
    };
    std::vector<LLVMValueRef> divisions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (LLVMGetInstructionOpcode(inst) != kOpcodeSDiv) continue;
                LLVMTypeRef type = LLVMTypeOf(inst);
                unsigned n = lanes(type);
                LLVMTypeRef element = n ? LLVMGetElementType(type) : type;
                if (LLVMGetTypeKind(element) != kTypeKindInteger || LLVMGetIntTypeWidth(element) > 32) continue;
                unsigned width = LLVMGetIntTypeWidth(element);
                LLVMValueRef divisor = LLVMGetOperand(inst, 1);
                bool any = false;
                for (unsigned lane = 0; lane < (n ? n : 1) && !any; lane++) {
                    LLVMValueRef c = n ? (LLVMIsAConstantDataSequential(divisor) ? LLVMGetElementAsConstant(divisor, lane) : nullptr) : divisor;
                    int k;
                    bool negative;
                    any = c && powerOfTwo(c, width, k, negative);
                }
                if (any) divisions.push_back(inst);
            }
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef division : divisions) {
        LLVMTypeRef type = LLVMTypeOf(division);
        unsigned n = lanes(type);
        LLVMTypeRef element = n ? LLVMGetElementType(type) : type;
        unsigned width = LLVMGetIntTypeWidth(element);
        if (!b) b = LLVMCreateBuilderInContext(context);
        LLVMPositionBuilderBefore(b, division);
        LLVMValueRef dividend = LLVMGetOperand(division, 0), divisor = LLVMGetOperand(division, 1);
        LLVMValueRef result = n ? LLVMGetUndef(type) : nullptr;
        for (unsigned lane = 0; lane < (n ? n : 1); lane++) {
            LLVMValueRef index = LLVMConstInt(i32, lane, false);
            LLVMValueRef x = n ? LLVMBuildExtractElement(b, dividend, index, "") : dividend;
            LLVMValueRef c = n ? (LLVMIsAConstantDataSequential(divisor) ? LLVMGetElementAsConstant(divisor, lane)
                                                                          : LLVMBuildExtractElement(b, divisor, index, ""))
                               : divisor;
            int k;
            bool negative;
            LLVMValueRef q;
            if (powerOfTwo(c, width, k, negative)) {
                LLVMValueRef sign = LLVMBuildAShr(b, x, LLVMConstInt(element, width - 1, false), "");
                LLVMValueRef bias = LLVMBuildLShr(b, sign, LLVMConstInt(element, width - k, false), "");
                q = LLVMBuildAShr(b, LLVMBuildAdd(b, x, bias, ""), LLVMConstInt(element, k, false), "");
                if (negative) q = LLVMBuildNeg(b, q, "");
            } else {
                q = LLVMBuildSDiv(b, x, c, "");
            }
            result = n ? LLVMBuildInsertElement(b, result, q, index, "") : q;
        }
        LLVMReplaceAllUsesWith(division, result);
        LLVMInstructionEraseFromParent(division);
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- 64-bit multiplies ----------------------------------------------------------------------------------------------
// The back end splits a 64-bit multiply into 32-bit ones, and the high word of a 32-bit product is wrong when one factor
// is a constant (see buildMulHi): a factor whose low word is a known constant, (x << 32) | 139, came out with a wrong
// high word for a * b and a wrong mulhi(a, b) (the 11,5 session's 64-bit fuzzing, LONG=1: 3 of 6 random kernels).
// Multiplies whose factors are both 32-bit values widened (zext / sext, or constants below 2^32) stay as they are: that
// is a single widening multiply, and every buffer index is one. The others are built from 32-bit limbs: the low 64
// bits of a * b from one exact 32-bit high word and three 32-bit products; mulhi / madhi of 64-bit integers
// (air.mul_hi / air.mad_hi .i64) from the four limb products with exact high words, the carries summed in 64 bits, then
// corrected for signed factors (hi_s = hi_u - (a < 0 ? b : 0) - (b < 0 ? a : 0)). Scalars and vectors (lane by lane).
// INTEL_MUL64_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMIsAInstruction(LLVMValueRef);
}
static bool widened32(LLVMValueRef v) {  // a 64-bit value that is a 32-bit one zero- or sign-extended
    if (LLVMIsAConstantInt(v)) return LLVMConstIntGetZExtValue(v) < (1ull << 32);
    if (!LLVMIsAInstruction(v)) return false;
    int opcode = LLVMGetInstructionOpcode(v);
    return (opcode == 31 /* ZExt */ || opcode == 32 /* SExt */) && LLVMGetIntTypeWidth(LLVMTypeOf(LLVMGetOperand(v, 0))) <= 32;
}

static unsigned exact64BitMultiplies(LLVMModuleRef module) {
    if (disabled("INTEL_MUL64_FIX") || runtimeNamesBound(module)) return 0;
    enum { kOpcodeMul = 12 };
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context), i64 = LLVMInt64TypeInContext(context);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    LLVMValueRef c32 = LLVMConstInt(i64, 32, false);
    auto lo = [&](LLVMValueRef v) { return LLVMBuildTrunc(b, v, i32, ""); };
    auto hi = [&](LLVMValueRef v) { return LLVMBuildTrunc(b, LLVMBuildLShr(b, v, c32, ""), i32, ""); };
    auto join = [&](LLVMValueRef l, LLVMValueRef h) {
        return LLVMBuildOr(b, LLVMBuildZExt(b, l, i64, ""), LLVMBuildShl(b, LLVMBuildZExt(b, h, i64, ""), c32, ""), "");
    };
    auto z = [&](LLVMValueRef v) { return LLVMBuildZExt(b, v, i64, ""); };
    auto mul64 = [&](LLVMValueRef x, LLVMValueRef y) {  // the low 64 bits of x * y
        LLVMValueRef x0 = lo(x), x1 = hi(x), y0 = lo(y), y1 = hi(y);
        LLVMValueRef h = LLVMBuildAdd(b, LLVMBuildAdd(b, buildMulHi(b, i32, x0, y0, false), LLVMBuildMul(b, x0, y1, ""), ""),
                                      LLVMBuildMul(b, x1, y0, ""), "");
        return join(LLVMBuildMul(b, x0, y0, ""), h);
    };
    auto mulhi64 = [&](LLVMValueRef x, LLVMValueRef y, bool sign) {  // the high 64 bits of x * y
        LLVMValueRef x0 = lo(x), x1 = hi(x), y0 = lo(y), y1 = hi(y);
        LLVMValueRef s1 = LLVMBuildAdd(b, LLVMBuildAdd(b, z(buildMulHi(b, i32, x0, y0, false)), z(LLVMBuildMul(b, x0, y1, "")), ""),
                                       z(LLVMBuildMul(b, x1, y0, "")), "");
        LLVMValueRef s2 = LLVMBuildAdd(b, LLVMBuildAdd(b, z(buildMulHi(b, i32, x0, y1, false)), z(buildMulHi(b, i32, x1, y0, false)), ""),
                                       LLVMBuildAdd(b, z(LLVMBuildMul(b, x1, y1, "")), LLVMBuildLShr(b, s1, c32, ""), ""), "");
        LLVMValueRef top = LLVMBuildAdd(b, buildMulHi(b, i32, x1, y1, false), hi(s2), "");
        LLVMValueRef r = join(lo(s2), top);
        if (!sign) return r;
        LLVMValueRef zero = LLVMConstInt(i64, 0, false);
        LLVMValueRef fromX = LLVMBuildSelect(b, LLVMBuildICmp(b, 40 /* SLT */, x, zero, ""), y, zero, "");
        LLVMValueRef fromY = LLVMBuildSelect(b, LLVMBuildICmp(b, 40 /* SLT */, y, zero, ""), x, zero, "");
        return LLVMBuildSub(b, LLVMBuildSub(b, r, fromX, ""), fromY, "");
    };
    auto lanewise = [&](LLVMValueRef inst, int operands, auto &&scalar) {  // scalar(x, y[, z]) per lane
        LLVMTypeRef type = LLVMTypeOf(inst);
        unsigned n = lanes(type);
        LLVMValueRef result = n ? LLVMGetUndef(type) : nullptr;
        for (unsigned lane = 0; lane < (n ? n : 1); lane++) {
            LLVMValueRef v[3];
            for (int k = 0; k < operands; k++)
                v[k] = n ? LLVMBuildExtractElement(b, LLVMGetOperand(inst, k), LLVMConstInt(i32, lane, false), "") : LLVMGetOperand(inst, k);
            LLVMValueRef r = scalar(v);
            result = n ? LLVMBuildInsertElement(b, result, r, LLVMConstInt(i32, lane, false), "") : r;
        }
        return result;
    };
    auto is64 = [&](LLVMTypeRef type) {
        LLVMTypeRef element = lanes(type) ? LLVMGetElementType(type) : type;
        return LLVMGetTypeKind(element) == kTypeKindInteger && LLVMGetIntTypeWidth(element) == 64;
    };
    // a * b
    std::vector<LLVMValueRef> muls;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMGetInstructionOpcode(inst) == kOpcodeMul && is64(LLVMTypeOf(inst)) &&
                    (lanes(LLVMTypeOf(inst)) || !widened32(LLVMGetOperand(inst, 0)) || !widened32(LLVMGetOperand(inst, 1))))
                    muls.push_back(inst);
    for (LLVMValueRef mul : muls) {
        if (!b) b = LLVMCreateBuilderInContext(context);
        LLVMPositionBuilderBefore(b, mul);
        LLVMValueRef r = lanewise(mul, 2, [&](LLVMValueRef *v) { return mul64(v[0], v[1]); });
        LLVMReplaceAllUsesWith(mul, r);
        LLVMInstructionEraseFromParent(mul);
        fixed++;
    }
    // mulhi / madhi
    std::vector<LLVMValueRef> functions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) functions.push_back(f);
    for (LLVMValueRef f : functions) {
        const char *name = LLVMGetValueName(f);
        int kind = !strncmp(name, "air.mul_hi.", 11) ? 1 : !strncmp(name, "air.mad_hi.", 11) ? 2 : -1;
        if (kind < 0 || (name[11] != 'u' && name[11] != 's') || name[12] != '.') continue;
        bool sign = name[11] == 's';
        int operands = kind == 1 ? 2 : 3;
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
        for (LLVMValueRef call : calls) {
            if (!LLVMIsACallInst(call) || LLVMGetNumOperands(call) != operands + 1 || LLVMGetOperand(call, operands) != f || !is64(LLVMTypeOf(call)))
                continue;
            if (!b) b = LLVMCreateBuilderInContext(context);
            LLVMPositionBuilderBefore(b, call);
            LLVMValueRef r = lanewise(call, operands, [&](LLVMValueRef *v) {
                LLVMValueRef h = mulhi64(v[0], v[1], sign);
                return kind == 1 ? h : LLVMBuildAdd(b, h, v[2], "");
            });
            LLVMReplaceAllUsesWith(call, r);
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- vector lanes picked by a 64-bit quotient ------------------------------------------------------------------------
// The back end expands 64-bit division into loops. A vector lane picked with a dynamic index computed from such a
// quotient, w[q & 3], read the index from a register the loop hadn't written yet: with a constant dividend
// (0x200000002 / d) the lane picked was the dividend's low word, & 3, whatever q was; q itself, and a select on q & 3,
// were right (the MacBookPro11,5 session's 64-bit fuzzing, LONG=1 seed 6). An extractelement or insertelement whose
// index comes (through casts, masks and arithmetic) from a 64-bit div / rem becomes selects on the index. So does one
// from a 64-bit shift of a constant by a variable, w[(uint)(4151055293ul >> s) & 3]: the stock back end crashes in its
// DAG legalizer on that index (mslfuzz2 LONG=1 seed 378; a variable shifted, or a select on the index, compiles).
// INTEL_WIDE_DIV_INDEX_FIX=0 turns it off.
static bool fromWideDivision(LLVMValueRef v, int depth = 0) {
    if (depth > 6 || !LLVMIsAInstruction(v)) return false;
    int opcode = LLVMGetInstructionOpcode(v);
    LLVMTypeRef type = LLVMTypeOf(v);
    bool wide = LLVMGetTypeKind(type) == kTypeKindInteger && LLVMGetIntTypeWidth(type) == 64;
    if (opcode == 14 || opcode == 15 || opcode == 17 || opcode == 18) return wide;  // udiv, sdiv, urem, srem
    if ((opcode == 20 || opcode == 21 || opcode == 22) && wide && LLVMIsAConstant(LLVMGetOperand(v, 0)) &&
        !LLVMIsAConstant(LLVMGetOperand(v, 1)))  // shl, lshr, ashr of a constant by a variable
        return true;
    bool passes = (opcode >= 8 && opcode <= 25 && opcode != 9 && opcode != 11 && opcode != 13 && opcode != 16 && opcode != 19) ||
                  opcode == 30 || opcode == 31 || opcode == 32 || opcode == 46;  // integer arithmetic, trunc / zext / sext, select
    if (!passes) return false;
    for (int k = 0; k < LLVMGetNumOperands(v); k++)
        if (fromWideDivision(LLVMGetOperand(v, k), depth + 1)) return true;
    return false;
}

static unsigned selectWideDivisionLanes(LLVMModuleRef module) {
    if (disabled("INTEL_WIDE_DIV_INDEX_FIX") || runtimeNamesBound(module)) return 0;
    enum { kOpcodeExtractElement = 50, kOpcodeInsertElement = 51, kIntEQ = 32 };
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context);
    std::vector<LLVMValueRef> picks;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int opcode = LLVMGetInstructionOpcode(inst);
                if (opcode != kOpcodeExtractElement && opcode != kOpcodeInsertElement) continue;
                LLVMValueRef index = LLVMGetOperand(inst, opcode == kOpcodeExtractElement ? 1 : 2);
                if (!LLVMIsAConstantInt(index) && fromWideDivision(index)) picks.push_back(inst);
            }
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef pick : picks) {
        bool extract = LLVMGetInstructionOpcode(pick) == kOpcodeExtractElement;
        LLVMValueRef vector = LLVMGetOperand(pick, 0), index = LLVMGetOperand(pick, extract ? 1 : 2);
        unsigned n = LLVMGetVectorSize(LLVMTypeOf(vector));
        if (n < 2 || n > 16) continue;
        if (!b) b = LLVMCreateBuilderInContext(context);
        LLVMPositionBuilderBefore(b, pick);
        LLVMTypeRef indexType = LLVMTypeOf(index);
        LLVMValueRef result;
        if (extract) {
            result = LLVMBuildExtractElement(b, vector, LLVMConstInt(i32, n - 1, false), "");
            for (int k = (int)n - 2; k >= 0; k--)
                result = LLVMBuildSelect(b, LLVMBuildICmp(b, kIntEQ, index, LLVMConstInt(indexType, (unsigned)k, false), ""),
                                         LLVMBuildExtractElement(b, vector, LLVMConstInt(i32, (unsigned)k, false), ""), result, "");
        } else {
            LLVMValueRef value = LLVMGetOperand(pick, 1);
            result = vector;
            for (unsigned k = 0; k < n; k++) {
                LLVMValueRef lane = LLVMConstInt(i32, k, false);
                LLVMValueRef chosen = LLVMBuildSelect(b, LLVMBuildICmp(b, kIntEQ, index, LLVMConstInt(indexType, k, false), ""), value,
                                                      LLVMBuildExtractElement(b, vector, lane, ""), "");
                result = LLVMBuildInsertElement(b, result, chosen, lane, "");
            }
        }
        LLVMReplaceAllUsesWith(pick, result);
        LLVMInstructionEraseFromParent(pick);
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- narrow integer min / max / clamp ---------------------------------------------------------------------------------
// min, max and clamp on 8- and 16-bit integers (air.{min,max,clamp}.{u,s}.{i8,i16,vNi8,vNi16}) compare a lane the back end
// zero-extended against a constant it sign-extended: min(uchar2 a, uchar2(130, 183)) returned a (UBMIN of a & 0xff and
// -126), and max returned the constant; clamp((uchar)y, 100, 200) returned y (the MacBookPro11,5 session's narrow-vector
// fuzzing; the 16-bit forms came out right but go the same way). They're done on 32-bit lanes: operands zero- or
// sign-extended, the i32 function called, the result truncated. INTEL_NARROW_MINMAX_FIX=0 turns it off.
static unsigned widenNarrowMinMax(LLVMModuleRef module) {
    if (disabled("INTEL_NARROW_MINMAX_FIX") || runtimeNamesBound(module)) return 0;
    bool render = (LLVMGetNamedMetadataNumOperands(module, "air.vertex") || LLVMGetNamedMetadataNumOperands(module, "air.fragment")) &&
                  !disabled("INTEL_NARROW_VECTOR_OPERAND_FIX");  // signed max(char4, as_type<char4>(x)) was wrong there (seed 245, i70)
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    std::vector<LLVMValueRef> functions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) functions.push_back(f);
    for (LLVMValueRef f : functions) {
        const char *name = LLVMGetValueName(f);
        static const char *const kOps[3] = {"air.min.", "air.max.", "air.clamp."};
        int op = -1;
        for (int k = 0; k < 3; k++) if (!strncmp(name, kOps[k], strlen(kOps[k]))) op = k;
        if (op < 0) continue;
        size_t at = strlen(kOps[op]);
        if ((name[at] != 'u' && name[at] != 's') || name[at + 1] != '.') continue;
        bool sign = name[at] == 's';
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
        for (LLVMValueRef call : calls) {
            int operands = op == 2 ? 3 : 2;
            if (!LLVMIsACallInst(call) || LLVMGetNumOperands(call) != operands + 1 || LLVMGetOperand(call, operands) != f) continue;
            LLVMTypeRef type = LLVMTypeOf(call);
            unsigned n = lanes(type);
            LLVMTypeRef element = n ? LLVMGetElementType(type) : type;
            if (LLVMGetTypeKind(element) != kTypeKindInteger) continue;
            unsigned bits = LLVMGetIntTypeWidth(element);
            if (bits != 8 && bits != 16) continue;
            if (!b) b = LLVMCreateBuilderInContext(context);
            LLVMPositionBuilderBefore(b, call);
            LLVMTypeRef wide = n ? LLVMVectorType(i32, n) : i32;
            std::vector<LLVMValueRef> args;
            std::vector<LLVMTypeRef> params;
            for (int k = 0; k < operands; k++) {
                LLVMValueRef v = LLVMGetOperand(call, k);
                args.push_back(n && render ? renderLanes32(b, i32, v, sign) : extendLanes(b, v, wide, sign));
                params.push_back(wide);
            }
            char wideName[64];
            if (n) snprintf(wideName, sizeof wideName, "%s%c.v%ui32", kOps[op], name[at], n);
            else snprintf(wideName, sizeof wideName, "%s%c.i32", kOps[op], name[at]);
            LLVMValueRef target = LLVMGetNamedFunction(module, wideName);
            if (!target) target = LLVMAddFunction(module, wideName, LLVMFunctionType(wide, params.data(), (unsigned)params.size(), 0));
            LLVMValueRef result = LLVMBuildTrunc(b, LLVMBuildCall(b, target, args.data(), (unsigned)args.size(), ""), type, "");
            LLVMReplaceAllUsesWith(call, result);
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- signed division of a negated value ------------------------------------------------------------------------------
// iCBE folds a negation (0 - v) into the operand of the integer divide that uses it, as a source modifier, and the
// divide drops it: (-v) % d came out as v % d, (-v) / d and v / (-d) as v / d (mslfuzz2 seed 223: a remainder of a
// negated product picked a vector lane, so the loop accumulated the wrong lane; unsigned division is right). A signed
// divide or remainder of 0 - v is done on v and the result negated, and a divide by 0 - d is done by d and negated:
// select(v == INT_MIN, r, 0 - r), since 0 - INT_MIN is INT_MIN again. A remainder by 0 - d is a remainder by d.
// Integers up to 32 bits, scalar or vector. INTEL_SIGNED_DIV_NEG_FIX=0 turns it off.
extern "C" {
int LLVMIsNull(LLVMValueRef);
LLVMValueRef LLVMIsABinaryOperator(LLVMValueRef);
}
static unsigned signedDivisionNegations(LLVMModuleRef module) {
    if (disabled("INTEL_SIGNED_DIV_NEG_FIX") || runtimeNamesBound(module)) return 0;
    enum { kOpcodeSub = 10, kOpcodeSDiv = 15, kOpcodeSRem = 18, kIntEQ = 32 };
    std::vector<LLVMValueRef> divisions;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int opcode = LLVMGetInstructionOpcode(inst);
                if (opcode != kOpcodeSDiv && opcode != kOpcodeSRem) continue;
                LLVMTypeRef type = LLVMTypeOf(inst);
                LLVMTypeRef element = lanes(type) ? LLVMGetElementType(type) : type;
                if (LLVMGetTypeKind(element) == kTypeKindInteger && LLVMGetIntTypeWidth(element) <= 32) divisions.push_back(inst);
            }
    auto negated = [](LLVMValueRef v) -> LLVMValueRef {  // v = 0 - x: x, else null
        if (!LLVMIsABinaryOperator(v) || LLVMGetInstructionOpcode(v) != kOpcodeSub || !LLVMIsNull(LLVMGetOperand(v, 0))) return nullptr;
        return LLVMGetOperand(v, 1);
    };
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef division : divisions) {
        bool remainder = LLVMGetInstructionOpcode(division) == kOpcodeSRem;
        LLVMValueRef dividend = negated(LLVMGetOperand(division, 0)), divisor = negated(LLVMGetOperand(division, 1));
        if (divisor && remainder) {  // the remainder takes the dividend's sign: the divisor's doesn't matter
            LLVMSetOperand(division, 1, divisor);
            divisor = nullptr;
            fixed++;
        }
        if (!dividend && !divisor) continue;
        if (dividend && divisor) {  // (-v) / (-d) = v / d, the INT_MIN cases included
            LLVMSetOperand(division, 0, dividend);
            LLVMSetOperand(division, 1, divisor);
            fixed++;
            continue;
        }
        LLVMValueRef x = dividend ? dividend : divisor;
        LLVMSetOperand(division, dividend ? 0 : 1, x);
        if (!b) b = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
        LLVMPositionBuilderBefore(b, LLVMGetNextInstruction(division));
        LLVMTypeRef type = LLVMTypeOf(division);
        unsigned n = lanes(type);
        LLVMTypeRef element = n ? LLVMGetElementType(type) : type;
        LLVMValueRef intMin = LLVMConstInt(element, 1ull << (LLVMGetIntTypeWidth(element) - 1), false);
        if (n) {
            std::vector<LLVMValueRef> splat(n, intMin);
            intMin = LLVMConstVector(splat.data(), n);
        }
        LLVMValueRef isMin = LLVMBuildICmp(b, kIntEQ, x, intMin, "");
        LLVMValueRef negative = LLVMBuildNeg(b, division, "");
        LLVMValueRef result = LLVMBuildSelect(b, isMin, division, negative, "");
        LLVMReplaceAllUsesWith(division, result);
        LLVMSetOperand(negative, 1, division);  // the replacement reached them too
        LLVMSetOperand(result, 1, division);
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- integer functions of constants -----------------------------------------------------------------------------------
// The front end leaves calls like max(0, 0x04030201) or popcount(0xF0u) for the back end, and iCBE folds them itself;
// what it builds from the folded value can then be wrong: the uchar lanes of as_type<uchar4>(max(0, 0x04030201)) all
// read as byte 0 when multiplied (uint(v.z) * 7 gave 7, not 21; the MacBookPro11,5 session's narrow-vector fuzzing, VEC
// seed 213, where it was an index into a private array). Such calls (min, max, clamp, abs, popcount, clz, ctz, and
// reverse_bits, rotate, extract_bits and insert_bits: (uchar)reverse_bits(60u), 0 in fact, made a later signed divide
// wrong in 54 of 256 threads, mslfuzz2 plain seed 849) are folded here, and so is every instruction that then has only
// constant operands, so the back end gets the finished constants. INTEL_CONSTANT_CALL_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMConstICmp(int, LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstSelect(LLVMValueRef, LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstSub(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstAdd(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstMul(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstAnd(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstOr(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstXor(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstShl(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstLShr(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstAShr(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstTrunc(LLVMValueRef, LLVMTypeRef);
LLVMValueRef LLVMConstBitCast(LLVMValueRef, LLVMTypeRef);
LLVMValueRef LLVMConstExtractElement(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstInsertElement(LLVMValueRef, LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMConstVector(LLVMValueRef *, unsigned);
LLVMValueRef LLVMGetElementAsConstant(LLVMValueRef, unsigned);
LLVMValueRef LLVMIsAConstantInt(LLVMValueRef);
unsigned long long LLVMConstIntGetZExtValue(LLVMValueRef);
int LLVMGetICmpPredicate(LLVMValueRef);
}

// The constant lanes of an integer scalar or vector, or false if they can't all be read. Only a ConstantDataVector can
// be read lane by lane: a vector argument or instruction, or a constant vector with an undef lane, isn't one (reading it
// crashed the compiler on VEC=1 seed 734), and zeroinitializer is a ConstantAggregateZero.
static bool constantLanes(LLVMValueRef v, std::vector<LLVMValueRef> &out) {
    out.clear();
    unsigned n = lanes(LLVMTypeOf(v));
    if (!n) { if (!LLVMIsAConstantInt(v)) return false; out.push_back(v); return true; }
    if (LLVMIsAConstantAggregateZero(v)) {
        LLVMTypeRef element = LLVMGetElementType(LLVMTypeOf(v));
        if (LLVMGetTypeKind(element) != kTypeKindInteger) return false;
        out.assign(n, LLVMConstNull(element));
        return true;
    }
    if (!LLVMIsAConstantDataSequential(v)) return false;
    for (unsigned k = 0; k < n; k++) {
        LLVMValueRef e = LLVMGetElementAsConstant(v, k);
        if (!e || !LLVMIsAConstantInt(e)) return false;
        out.push_back(e);
    }
    return true;
}

// popcount / clz / ctz of a constant, lane by lane; nullptr if a lane isn't a plain integer of 64 bits or fewer.
static LLVMValueRef foldBitCount(LLVMValueRef x, int which) {
    std::vector<LLVMValueRef> in;
    if (!constantLanes(x, in)) return nullptr;
    std::vector<LLVMValueRef> out;
    for (LLVMValueRef e : in) {
        LLVMTypeRef type = LLVMTypeOf(e);
        unsigned bits = LLVMGetIntTypeWidth(type);
        if (bits > 64) return nullptr;
        unsigned long long v = LLVMConstIntGetZExtValue(e), r = 0;
        if (which == 0) { for (unsigned k = 0; k < bits; k++) r += (v >> k) & 1; }
        else if (which == 1) { r = bits; for (int k = (int)bits - 1; k >= 0; k--) if ((v >> k) & 1) { r = bits - 1 - k; break; } }
        else { r = bits; for (unsigned k = 0; k < bits; k++) if ((v >> k) & 1) { r = k; break; } }
        out.push_back(LLVMConstInt(type, r, false));
    }
    return lanes(LLVMTypeOf(x)) ? LLVMConstVector(out.data(), (unsigned)out.size()) : out[0];
}

// A shift amount that is in range in every lane (LLVM folds larger ones to undef, the GPU masks them).
// A bitcast between integer scalars and vectors of constants, folded to its lanes. LLVMConstBitCast leaves an integer
// cast to a vector as a constant expression (bitcast (<1 x i32> <i32 194> to <2 x i16>)), which can't be read lane by
// lane, so `as_type<short2>(min(194u, 253u))` stayed unfolded after i36 folded the min. nullptr if a lane isn't a whole
// number of bytes.
static LLVMValueRef foldBitCastConstant(LLVMValueRef a, LLVMTypeRef type) {
    std::vector<LLVMValueRef> in;
    if (!constantLanes(a, in) || in.empty()) return nullptr;
    unsigned from = LLVMGetIntTypeWidth(LLVMTypeOf(in[0]));
    LLVMTypeRef element = lanes(type) ? LLVMGetElementType(type) : type;
    if (LLVMGetTypeKind(element) != kTypeKindInteger) return nullptr;
    unsigned to = LLVMGetIntTypeWidth(element), count = lanes(type) ? lanes(type) : 1;
    if (from % 8 || to % 8 || from > 64 || to > 64 || from * in.size() != to * count) return nullptr;
    std::vector<uint8_t> bytes;  // little-endian, lane 0 first
    for (LLVMValueRef e : in) {
        uint64_t v = LLVMConstIntGetZExtValue(e);
        for (unsigned k = 0; k < from / 8; k++) bytes.push_back((uint8_t)(v >> (8 * k)));
    }
    std::vector<LLVMValueRef> out;
    for (unsigned lane = 0; lane < count; lane++) {
        uint64_t v = 0;
        for (unsigned k = 0; k < to / 8; k++) v |= (uint64_t)bytes[lane * (to / 8) + k] << (8 * k);
        out.push_back(LLVMConstInt(element, v, false));
    }
    return lanes(type) ? LLVMConstVector(out.data(), count) : out[0];
}

static bool shiftInRange(LLVMValueRef amount) {
    std::vector<LLVMValueRef> in;
    if (!constantLanes(amount, in)) return false;
    for (LLVMValueRef e : in) if (LLVMConstIntGetZExtValue(e) >= LLVMGetIntTypeWidth(LLVMTypeOf(e))) return false;
    return true;
}

// reverse_bits / rotate / extract_bits / insert_bits of constants, lane by lane (scalar offset and bit-count operands apply
// to every lane); nullptr where a lane isn't a plain integer of 64 bits or fewer, or a bit field reaches past the lane
// (undefined in MSL: left to the back end).
static LLVMValueRef foldBitField(int which, bool sign, LLVMValueRef *args, unsigned count) {  // 0 reverse, 1 rotate, 2 extract, 3 insert
    std::vector<std::vector<LLVMValueRef>> in(count);
    unsigned n = 0;
    for (unsigned k = 0; k < count; k++) {
        if (!constantLanes(args[k], in[k])) return nullptr;
        if (in[k].size() > n) n = (unsigned)in[k].size();
    }
    std::vector<LLVMValueRef> out;
    for (unsigned i = 0; i < n; i++) {
        auto lane = [&](unsigned k) { return in[k].size() == 1 ? in[k][0] : in[k][i]; };
        LLVMTypeRef type = LLVMTypeOf(lane(0));
        unsigned w = LLVMGetIntTypeWidth(type);
        if (w > 64) return nullptr;
        unsigned long long mask = w == 64 ? ~0ull : (1ull << w) - 1, v = LLVMConstIntGetZExtValue(lane(0)) & mask, r = 0;
        if (which == 0) {
            for (unsigned k = 0; k < w; k++) if ((v >> k) & 1) r |= 1ull << (w - 1 - k);
        } else if (which == 1) {
            unsigned s = (unsigned)(LLVMConstIntGetZExtValue(lane(1)) % w);
            r = s ? ((v << s) | (v >> (w - s))) & mask : v;
        } else {
            unsigned long long base = v, offset = LLVMConstIntGetZExtValue(lane(which == 2 ? 1 : 2)),
                               bits = LLVMConstIntGetZExtValue(lane(which == 2 ? 2 : 3));
            if (offset + bits > w) return nullptr;
            unsigned long long field = bits == 64 ? ~0ull : (1ull << bits) - 1;
            if (which == 2) {
                r = bits ? (base >> offset) & field : 0;
                if (sign && bits && bits < w && ((r >> (bits - 1)) & 1)) r |= ~field & mask;
            } else {
                unsigned long long insert = LLVMConstIntGetZExtValue(lane(1)) & mask, m = (field << offset) & mask;
                r = bits ? ((base & ~m) | ((insert << offset) & m)) & mask : base;
            }
        }
        out.push_back(LLVMConstInt(type, r, false));
    }
    return lanes(LLVMTypeOf(args[0])) ? LLVMConstVector(out.data(), (unsigned)out.size()) : out[0];
}

// The folded value of an instruction whose operands are all constants, or nullptr.
static LLVMValueRef foldInstruction(LLVMValueRef inst) {
    enum { kAdd = 8, kSub = 10, kMul = 12, kShl = 20, kLShr = 21, kAShr = 22, kAnd = 23, kOr = 24, kXor = 25, kTrunc = 30,
           kZExt = 31, kSExt = 32, kBitCast = 41, kICmp = 42, kSelect = 46, kExtract = 50, kInsert = 51 };
    int opcode = LLVMGetInstructionOpcode(inst);
    unsigned n = LLVMGetNumOperands(inst);
    if (opcode == 45 /* call */) return nullptr;
    for (unsigned k = 0; k < n; k++) if (!LLVMIsAConstant(LLVMGetOperand(inst, k))) return nullptr;
    LLVMValueRef a = n > 0 ? LLVMGetOperand(inst, 0) : nullptr, c = n > 1 ? LLVMGetOperand(inst, 1) : nullptr;
    LLVMTypeRef type = LLVMTypeOf(inst);
    LLVMTypeRef element = lanes(type) ? LLVMGetElementType(type) : type;
    switch (opcode) {
    case kAdd: case kSub: case kMul: case kAnd: case kOr: case kXor:
        if (LLVMGetTypeKind(element) != kTypeKindInteger) return nullptr;
        return opcode == kAdd ? LLVMConstAdd(a, c) : opcode == kSub ? LLVMConstSub(a, c) : opcode == kMul ? LLVMConstMul(a, c)
             : opcode == kAnd ? LLVMConstAnd(a, c) : opcode == kOr ? LLVMConstOr(a, c) : LLVMConstXor(a, c);
    case kShl: case kLShr: case kAShr:
        if (LLVMGetTypeKind(element) != kTypeKindInteger || !shiftInRange(c)) return nullptr;
        return opcode == kShl ? LLVMConstShl(a, c) : opcode == kLShr ? LLVMConstLShr(a, c) : LLVMConstAShr(a, c);
    case kTrunc: return LLVMConstTrunc(a, type);
    case kZExt: return LLVMConstZExt(a, type);
    case kSExt: return LLVMConstSExt(a, type);
    case kBitCast:
        if (LLVMGetTypeKind(element) != kTypeKindInteger) return nullptr;
        if (LLVMValueRef folded = foldBitCastConstant(a, type)) return folded;
        return LLVMConstBitCast(a, type);
    case kICmp: return LLVMConstICmp(LLVMGetICmpPredicate(inst), a, c);
    case kSelect: return LLVMConstSelect(a, c, LLVMGetOperand(inst, 2));
    case kExtract: return LLVMConstExtractElement(a, c);
    case kInsert: return LLVMConstInsertElement(a, c, LLVMGetOperand(inst, 2));
    default: return nullptr;
    }
}

// hadd / rhadd and the saturating add / subtract of scalar constants, exactly (bits <= 32), or nullptr
extern "C" long long LLVMConstIntGetSExtValue(LLVMValueRef);
static LLVMValueRef foldHalvingOrSaturating(int op, bool sign, LLVMValueRef x, LLVMValueRef y) {
    LLVMTypeRef type = LLVMTypeOf(x);
    if (lanes(type) || !LLVMIsAConstantInt(x) || !LLVMIsAConstantInt(y)) return nullptr;
    unsigned bits = LLVMGetIntTypeWidth(type);
    if (bits > 32) return nullptr;
    long long a = sign ? LLVMConstIntGetSExtValue(x) : (long long)LLVMConstIntGetZExtValue(x);
    long long b = sign ? LLVMConstIntGetSExtValue(y) : (long long)LLVMConstIntGetZExtValue(y);
    long long lo = sign ? -(1ll << (bits - 1)) : 0, hi = sign ? (1ll << (bits - 1)) - 1 : (1ll << bits) - 1, r;
    switch (op) {
    case 11: r = (a + b) >> 1; break;      // hadd: no overflow, rounded down (an arithmetic shift for signed)
    case 12: r = (a + b + 1) >> 1; break;  // rhadd
    case 13: r = std::min(std::max(a + b, lo), hi); break;  // add_sat
    default: r = std::min(std::max(a - b, lo), hi); break;  // sub_sat
    }
    return LLVMConstInt(type, (unsigned long long)r & ((1ull << bits) - 1), false);
}

static unsigned foldConstantCallsOnce(LLVMModuleRef module);
// Folds until nothing changes: a folded call can make another's operands constant (addsat(~1u, hadd(65536u, 36u)): the
// back end folded that addsat as a plain add once hadd's result was known, so extract_bits(x, 0, addsat(...) & 15) took
// 0 bits; mslfuzz2 VEC=1 seed 4630, i56; the stock compiler too).
static unsigned foldConstantCalls(LLVMModuleRef module) {
    if (disabled("INTEL_CONSTANT_CALL_FIX")) return 0;
    unsigned total = 0;
    for (int pass = 0; pass < 8; pass++) {
        unsigned n = foldConstantCallsOnce(module);
        total += n;
        if (!n) break;
    }
    return total;
}
static unsigned foldConstantCallsOnce(LLVMModuleRef module) {
    enum { kULT = 36, kSLT = 40, kUGT = 34, kSGT = 38 };
    std::vector<LLVMValueRef> work;
    unsigned folded = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        int op = !strncmp(name, "air.min.", 8) ? 0 : !strncmp(name, "air.max.", 8) ? 1 : !strncmp(name, "air.clamp.", 10) ? 2
               : !strncmp(name, "air.abs.", 8) ? 3 : !strncmp(name, "air.popcount.", 13) ? 4 : !strncmp(name, "air.clz.", 8) ? 5
               : !strncmp(name, "air.ctz.", 8) ? 6 : !strncmp(name, "air.reverse_bits.", 17) ? 7 : !strncmp(name, "air.rotate.", 11) ? 8
               : !strncmp(name, "air.extract_bits.", 17) ? 9 : !strncmp(name, "air.insert_bits.", 16) ? 10
               : !strncmp(name, "air.hadd.", 9) ? 11 : !strncmp(name, "air.rhadd.", 10) ? 12 : !strncmp(name, "air.add_sat.", 12) ? 13
               : !strncmp(name, "air.sub_sat.", 12) ? 14 : !strncmp(name, "air.min3.", 9) ? 15 : !strncmp(name, "air.max3.", 9) ? 16
               : !strncmp(name, "air.median3.", 12) ? 17 : -1;
        if (op < 0) continue;
        size_t at = op == 2 ? 10 : op == 4 ? 13 : op == 7 || op == 9 ? 17 : op == 8 ? 11 : op == 10 ? 16 : op == 11 ? 9 : op == 12 ? 10
                  : op == 13 || op == 14 || op == 17 ? 12 : op == 15 || op == 16 ? 9 : 8;
        char kind = name[at];  // u / s for min, max, clamp, abs and the bit fields; the type follows directly otherwise
        if ((op <= 3 || op >= 9) && ((kind != 'u' && kind != 's') || name[at + 1] != '.')) continue;
        bool sign = kind == 's';
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
        for (LLVMValueRef call : calls) {
            unsigned args = op == 10 ? 4 : op == 2 || op == 9 || op >= 15 ? 3 : op <= 1 || op == 8 || op >= 11 ? 2 : 1;
            // clz / ctz carry a second operand, the i1 "zero is undefined" flag (air.clz.i32(i32 x, i1 false)), which
            // the fold ignores: it gives the width for 0, which is what false asks for
            if ((op == 5 || op == 6) && LLVMIsACallInst(call) && LLVMGetNumOperands(call) == 3) args = 2;
            if (!LLVMIsACallInst(call) || LLVMGetNumOperands(call) != args + 1 || LLVMGetOperand(call, args) != f) continue;
            LLVMTypeRef type = LLVMTypeOf(call);
            LLVMTypeRef element = lanes(type) ? LLVMGetElementType(type) : type;
            if (LLVMGetTypeKind(element) != kTypeKindInteger) continue;
            // a bit field of 0 bits, whatever the other operands: extract_bits gives 0 and insert_bits its base (MSL), but
            // the back end's lowering shifts by the width, which LLVM folds as poison: w[(uint)((long)(1u |
            // extract_bits(v0, 0u, 0u)) >> s) & 3u] = 1u came out as w[1] in every thread (mslfuzz2 LONG=1 seed 2575, i59;
            // the stock compiler too)
            if (op == 9 || op == 10) {
                LLVMValueRef bits = LLVMGetOperand(call, args - 1);
                if (LLVMIsAConstant(bits) && LLVMIsNull(bits)) {
                    LLVMValueRef r = op == 9 ? LLVMConstNull(type) : LLVMGetOperand(call, 0);
                    for (LLVMUseRef u = LLVMGetFirstUse(call); u; u = LLVMGetNextUse(u)) work.push_back(LLVMGetUser(u));
                    LLVMReplaceAllUsesWith(call, r);
                    LLVMInstructionEraseFromParent(call);
                    folded++;
                    continue;
                }
            }
            bool constant = true;
            for (unsigned k = 0; k < args; k++) constant = constant && LLVMIsAConstant(LLVMGetOperand(call, k));
            if (!constant) continue;
            LLVMValueRef x = LLVMGetOperand(call, 0), r = nullptr;
            if (op <= 2 || op >= 15) {  // min, max, clamp; min3, max3, median3 (min3(240u, 239u, 177u) read through as_type
                                        // got every byte as byte 0, as in i36; mslfuzz2 VEC=1 seed 5854, i58)
                LLVMValueRef y = LLVMGetOperand(call, 1);
                auto mn = [&](LLVMValueRef p, LLVMValueRef q) { return LLVMConstSelect(LLVMConstICmp(sign ? kSLT : kULT, p, q), p, q); };
                auto mx = [&](LLVMValueRef p, LLVMValueRef q) { return LLVMConstSelect(LLVMConstICmp(sign ? kSGT : kUGT, p, q), p, q); };
                LLVMValueRef z = args == 3 ? LLVMGetOperand(call, 2) : nullptr;
                r = op == 0 ? mn(x, y) : op == 1 ? mx(x, y) : op == 2 ? mn(mx(x, y), z) : op == 15 ? mn(mn(x, y), z)
                  : op == 16 ? mx(mx(x, y), z) : mx(mn(x, y), mn(mx(x, y), z));
            } else if (op == 3) {
                r = sign ? LLVMConstSelect(LLVMConstICmp(kSLT, x, LLVMConstNull(type)), LLVMConstSub(LLVMConstNull(type), x), x) : x;
            } else if (op <= 6) {
                r = foldBitCount(x, op - 4);
            } else if (op >= 11) {
                r = foldHalvingOrSaturating(op, sign, x, LLVMGetOperand(call, 1));
            } else {
                LLVMValueRef operands[4];
                for (unsigned k = 0; k < args; k++) operands[k] = LLVMGetOperand(call, k);
                r = foldBitField(op - 7, sign, operands, args);
            }
            if (!r) continue;
            for (LLVMUseRef u = LLVMGetFirstUse(call); u; u = LLVMGetNextUse(u)) work.push_back(LLVMGetUser(u));
            LLVMReplaceAllUsesWith(call, r);
            LLVMInstructionEraseFromParent(call);
            folded++;
        }
    }
    std::set<LLVMValueRef> erased;  // an instruction can be queued once per folded operand
    while (!work.empty()) {  // instructions that may now have only constant operands
        LLVMValueRef inst = work.back();
        work.pop_back();
        if (erased.count(inst) || !LLVMIsAInstruction(inst)) continue;
        LLVMValueRef r = foldInstruction(inst);
        if (!r) continue;
        for (LLVMUseRef u = LLVMGetFirstUse(inst); u; u = LLVMGetNextUse(u)) work.push_back(LLVMGetUser(u));
        LLVMReplaceAllUsesWith(inst, r);
        LLVMInstructionEraseFromParent(inst);
        erased.insert(inst);
    }
    return folded;
}

// ---- saturating add / subtract of constants --------------------------------------------------------------------------
// The back end folds addsat with two constant operands as a plain add: addsat(95u, 4294967295u) came out 94 instead of
// 0xffffffff (mslfuzz2; with a variable operand it's right). Such calls (air.add_sat / air.sub_sat, unsigned or signed,
// 8 to 32 bits) are folded here, exactly. An add_sat with a zero operand, or a sub_sat of zero, is its other operand,
// and goes too, for any type: iCBE turns UADD_sat(0, x & 255) into something that reads another byte, so in
// `v + addsat(0u, (uint)c)` with a uchar c the sum got the wrong byte (110 of 256 threads; mslfuzz2 plain seed 812).
// INTEL_CONST_SAT_FIX=0 turns it off.
extern "C" {
long long LLVMConstIntGetSExtValue(LLVMValueRef);
}
static unsigned foldConstantSaturation(LLVMModuleRef module) {
    if (disabled("INTEL_CONST_SAT_FIX")) return 0;
    unsigned fixed = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        bool add = !strncmp(name, "air.add_sat.", 12), sub = !strncmp(name, "air.sub_sat.", 12);
        if ((!add && !sub) || (name[12] != 'u' && name[12] != 's') || name[13] != '.') continue;
        bool sign = name[12] == 's';
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
        for (LLVMValueRef call : calls) {
            if (!LLVMIsACallInst(call) || LLVMGetNumOperands(call) != 3 || LLVMGetOperand(call, 2) != f) continue;
            LLVMValueRef x = LLVMGetOperand(call, 0), y = LLVMGetOperand(call, 1);
            LLVMTypeRef type = LLVMTypeOf(call);
            bool zeroX = LLVMIsAConstant(x) && LLVMIsNull(x), zeroY = LLVMIsAConstant(y) && LLVMIsNull(y);
            if (zeroY || (add && zeroX)) {  // x + 0, 0 + y, x - 0
                LLVMReplaceAllUsesWith(call, zeroY ? x : y);
                LLVMInstructionEraseFromParent(call);
                fixed++;
                continue;
            }
            if (!LLVMIsAConstantInt(x) || !LLVMIsAConstantInt(y) || LLVMGetTypeKind(type) != kTypeKindInteger) continue;
            unsigned bits = LLVMGetIntTypeWidth(type);
            if (bits > 32) continue;
            long long r, lo, hi;
            if (sign) {
                long long a = LLVMConstIntGetSExtValue(x), b = LLVMConstIntGetSExtValue(y);
                r = add ? a + b : a - b; lo = -(1ll << (bits - 1)); hi = (1ll << (bits - 1)) - 1;
            } else {
                long long a = (long long)LLVMConstIntGetZExtValue(x), b = (long long)LLVMConstIntGetZExtValue(y);
                r = add ? a + b : a - b; lo = 0; hi = (1ll << bits) - 1;
            }
            r = r < lo ? lo : r > hi ? hi : r;
            LLVMReplaceAllUsesWith(call, LLVMConstInt(type, (unsigned long long)r, sign));
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    return fixed;
}

// The same fold happens when the operands become constant only in the plugin's own passes, after these rewrites: in a
// loop with a constant trip count, which the plugin unrolls, addsat(i, -i) has two constant operands in every copy of
// the body. The signed add_sat / sub_sat values then came out as plain sums, and an unsigned add_sat picking a private
// array element (p[addsat(i, -i) & 7]) made a value read in the same iteration take its next one: with
// v3 = (v5 ^ t) & 15 before v5 ^= p[...], v3 came from v5 after the update (231 of 256 threads; the as_type fragment
// fuzzing, VEC=1 seed 108, compute too). The 32-bit add_sat calls (unsigned and signed) and signed sub_sat calls left
// after the fold above, scalar or vector, are written out as an add or subtract, compares and selects, which LLVM folds
// exactly; unsigned sub_sat was right and stays. INTEL_LATE_SAT_FIX=0 turns it off. Test: i63.
static LLVMValueRef splat32(LLVMTypeRef type, uint32_t value) {  // value in an i32 or in every lane of an i32 vector
    LLVMValueRef v = LLVMConstInt(scalarOf(type), value, false);
    unsigned n = lanes(type);
    if (!n) return v;
    std::vector<LLVMValueRef> parts(n, v);
    return LLVMConstVector(parts.data(), n);
}
static unsigned expandSaturation(LLVMModuleRef module) {
    if (disabled("INTEL_LATE_SAT_FIX")) return 0;
    enum { kIntULT = 36, kIntSLT = 40 };
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        bool add = !strncmp(name, "air.add_sat.", 12), sub = !strncmp(name, "air.sub_sat.", 12);
        if ((!add && !sub) || (name[12] != 'u' && name[12] != 's') || name[13] != '.') continue;
        bool sign = name[12] == 's';
        if (sub && !sign) continue;
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
        for (LLVMValueRef call : calls) {
            if (!LLVMIsACallInst(call) || LLVMGetNumOperands(call) != 3 || LLVMGetOperand(call, 2) != f) continue;
            LLVMTypeRef type = LLVMTypeOf(call), scalar = scalarOf(type);
            if (LLVMGetTypeKind(scalar) != kTypeKindInteger || LLVMGetIntTypeWidth(scalar) != 32) continue;
            if (!b) b = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
            LLVMPositionBuilderBefore(b, call);
            LLVMValueRef x = LLVMGetOperand(call, 0), y = LLVMGetOperand(call, 1), r;
            if (!sign) {  // the sum, or all ones where it wrapped (came out below x)
                LLVMValueRef s = LLVMBuildAdd(b, x, y, "");
                r = LLVMBuildSelect(b, LLVMBuildICmp(b, kIntULT, s, x, ""), splat32(type, 0xffffffffu), s, "");
            } else {  // overflow: the result's sign differs from both operands' (add), or from x's where x and y differ (sub)
                LLVMValueRef s = add ? LLVMBuildAdd(b, x, y, "") : LLVMBuildSub(b, x, y, ""), zero = LLVMConstNull(type);
                LLVMValueRef both = LLVMBuildAnd(b, LLVMBuildXor(b, x, s, ""), LLVMBuildXor(b, add ? y : x, add ? s : y, ""), "");
                LLVMValueRef limit = LLVMBuildSelect(b, LLVMBuildICmp(b, kIntSLT, x, zero, ""), splat32(type, 0x80000000u),
                                                     splat32(type, 0x7fffffffu), "");
                r = LLVMBuildSelect(b, LLVMBuildICmp(b, kIntSLT, both, zero, ""), limit, s, "");
            }
            LLVMReplaceAllUsesWith(call, r);
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- cube gathers: a sampler that keeps seamless addressing -----------------------------------------------------------
// MetalOldCompat item 30 gives samplers whose min and mag filters are nearest the programmed (clamped) cube addressing,
// because integer cube textures with tiny faces sample as 0 with the seamless kind in vertex and fragment functions (and
// a texel read can't stand in there: in fragment functions read_texture_cube ignores the face). A nearest sample never
// spans a face edge, but a gather's 2x2 footprint does, so cube gathers through such a sampler came back clamped at face
// edges (WebGPU CTS textureGather sampled_3d_coords, nearest: 330 cases; also any cube shadow-map PCF done with gathers).
// A gather doesn't filter, and seamless cube addressing ignores the address modes, so cube gathers, color and depth (not
// compare gathers, whose sampler carries the compare function; depth_3d_coords: 60 cases),
// in vertex and fragment functions take a constexpr sampler with linear filtering instead of the app's: item 30 leaves
// that one seamless. INTEL_CUBE_GATHER_SAMPLER_FIX=0 turns it off.
extern "C" {
void LLVMAddNamedMetadataOperand(LLVMModuleRef, const char *, LLVMValueRef);
LLVMValueRef LLVMMDStringInContext(LLVMContextRef, const char *, unsigned);
LLVMValueRef LLVMGetNamedGlobal(LLVMModuleRef, const char *);
void LLVMSetInitializer(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMAddGlobalInAddressSpace(LLVMModuleRef, LLVMTypeRef, const char *, unsigned);
void LLVMSetGlobalConstant(LLVMValueRef, int);
void LLVMSetLinkage(LLVMValueRef, int);
LLVMValueRef LLVMConstBitCast(LLVMValueRef, LLVMTypeRef);
LLVMValueRef LLVMMDNodeInContext(LLVMContextRef, LLVMValueRef *, unsigned);
LLVMTypeRef LLVMInt64TypeInContext(LLVMContextRef);
void LLVMSetAlignment(LLVMValueRef, unsigned);
}
static unsigned linearCubeGathers(LLVMModuleRef module) {
    if (disabled("INTEL_CUBE_GATHER_SAMPLER_FIX") || runtimeNamesBound(module)) return 0;
    static const char kGlobal[] = "__air_sampler_state.cube_gather";
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMValueRef state = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (strncmp(name, "air.gather_texture_cube.", 24) && strncmp(name, "air.gather_texture_cube_array.", 30) &&
            strncmp(name, "air.gather_depth_cube.", 22) && strncmp(name, "air.gather_depth_cube_array.", 28))
            continue;
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
        for (LLVMValueRef call : calls) {
            int n = LLVMGetNumOperands(call);
            if (!LLVMIsACallInst(call) || n < 3 || LLVMGetOperand(call, n - 1) != f) continue;
            LLVMValueRef sampler = LLVMGetOperand(call, 1);
            if (LLVMIsAConstant(sampler) || kernelOnly(module, callerOf(call))) continue;  // constexpr already; kernels are right
            if (!state) {
                state = LLVMGetNamedGlobal(module, kGlobal);
                if (!state) {
                    LLVMTypeRef i64 = LLVMInt64TypeInContext(context);
                    state = LLVMAddGlobalInAddressSpace(module, i64, kGlobal, 2);
                    LLVMSetInitializer(state, LLVMConstInt(i64, 0x807bff0000080a49ull, false));  // filter::linear, the rest default
                    LLVMSetGlobalConstant(state, 1);
                    LLVMSetLinkage(state, 8 /* internal */);
                    LLVMSetAlignment(state, 8);
                    LLVMValueRef parts[2] = {LLVMMDStringInContext(context, "air.sampler_state", 17), state};
                    LLVMAddNamedMetadataOperand(module, "air.sampler_states", LLVMMDNodeInContext(context, parts, 2));
                }
            }
            LLVMSetOperand(call, 1, LLVMConstBitCast(state, LLVMTypeOf(sampler)));
            fixed++;
        }
    }
    return fixed;
}

// ---- constexpr samplers from newer front ends ----------------------------------------------------------------------
// The front end in Xcode 26 (metalfe-32023.850) writes a constexpr sampler as a [2 x i64] constant (!air.sampler_states),
// the second word 0 and bit 63 of the first clear; the runtime compiler that goes with the 3802 back end writes one i64,
// the same word with bit 63 set (checked for filters, mip filters, addressing, border colors, anisotropy, compare
// functions, LOD clamps). IGILInlineSamplerLowering reads the constant as an integer and dereferences null on the array,
// which kills MTLCompilerService: iMovie 10.4.4's viewer (Flexo's textureSamplingShader) never gets a pipeline and stays
// black, and so would any app's library built with that compiler that uses constexpr samplers. Such globals become the
// i64 the runtime compiler writes; their uses and the sampler-state metadata go to it.
// INTEL_SAMPLER_STATE_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMGetInitializer(LLVMValueRef);
void LLVMSetInitializer(LLVMValueRef, LLVMValueRef);
LLVMValueRef LLVMAddGlobalInAddressSpace(LLVMModuleRef, LLVMTypeRef, const char *, unsigned);
void LLVMSetGlobalConstant(LLVMValueRef, int);
int LLVMGetLinkage(LLVMValueRef);
void LLVMSetLinkage(LLVMValueRef, int);
void LLVMSetAlignment(LLVMValueRef, unsigned);
unsigned LLVMGetPointerAddressSpace(LLVMTypeRef);
LLVMValueRef LLVMIsAGlobalVariable(LLVMValueRef);
LLVMValueRef LLVMIsAConstantDataArray(LLVMValueRef);
LLVMValueRef LLVMGetElementAsConstant(LLVMValueRef, unsigned);
LLVMValueRef LLVMConstBitCast(LLVMValueRef, LLVMTypeRef);
void LLVMDeleteGlobal(LLVMValueRef);
void LLVMSetValueName(LLVMValueRef, const char *);
}
extern "C" void *valueAsMetadata(LLVMValueRef value) asm("__ZN4llvm15ValueAsMetadata3getEPNS_5ValueE");

static unsigned fixSamplerStateWords(LLVMModuleRef module) {
    const char *setting = getenv("INTEL_SAMPLER_STATE_FIX");
    if (setting && !strcmp(setting, "0")) return 0;
    enum { kArrayKind = 11 };  // LLVMTypeKind
    std::vector<LLVMValueRef> states(LLVMGetNamedMetadataNumOperands(module, "air.sampler_states"));
    if (states.empty()) return 0;
    LLVMGetNamedMetadataOperands(module, "air.sampler_states", states.data());
    LLVMTypeRef i64 = LLVMInt64TypeInContext(LLVMGetModuleContext(module));
    unsigned fixed = 0;
    for (LLVMValueRef state : states) {  // !{!"air.sampler_state", [2 x i64] addrspace(2)* @__air_sampler_state}
        std::vector<LLVMValueRef> parts = metadataOperands(state);
        void *node = metadataOf(state);
        if (parts.size() != 2 || !isString(parts[0], "air.sampler_state") || !node) continue;
        LLVMValueRef global = parts[1] ? LLVMIsAGlobalVariable(parts[1]) : nullptr;
        LLVMValueRef words = global ? LLVMGetInitializer(global) : nullptr;
        LLVMTypeRef type = words ? LLVMTypeOf(words) : nullptr;
        bool zero = words && LLVMIsAConstantAggregateZero(words);  // a state with every field 0 is a zeroinitializer
        if (!type || LLVMGetTypeKind(type) != kArrayKind || LLVMGetArrayLength(type) != 2 || LLVMGetElementType(type) != i64 ||
            !(zero || LLVMIsAConstantDataArray(words)))
            continue;
        uint64_t first = zero ? 0 : LLVMConstIntGetZExtValue(LLVMGetElementAsConstant(words, 0));
        uint64_t second = zero ? 0 : LLVMConstIntGetZExtValue(LLVMGetElementAsConstant(words, 1));
        if (second && logging()) fprintf(stderr, "[inteltex] sampler state: second word 0x%llx not representable, dropped\n", (unsigned long long)second);
        std::string name = LLVMGetValueName(global);
        LLVMValueRef word = LLVMAddGlobalInAddressSpace(module, i64, (name + ".word").c_str(), LLVMGetPointerAddressSpace(LLVMTypeOf(global)));
        LLVMSetInitializer(word, LLVMConstInt(i64, first | 1ull << 63, false));
        LLVMSetGlobalConstant(word, 1);
        LLVMSetLinkage(word, LLVMGetLinkage(global));
        LLVMSetAlignment(word, 8);
        mdNodeReplaceOperand(node, 1, valueAsMetadata(word));
        LLVMReplaceAllUsesWith(global, LLVMConstBitCast(word, LLVMTypeOf(global)));
        LLVMDeleteGlobal(global);
        LLVMSetValueName(word, name.c_str());
        fixed++;
    }
    return fixed;
}

// ---- explicit LODs in compute kernels ------------------------------------------------------------------------------
// Samplers in compute kernels on Haswell blend between mip levels only in the middle quarter of each step: with a linear
// mip filter, level n + f reads level n for f <= 0.375 and level n + 1 for f >= 0.625, and blends linearly in between
// (weight (f - 0.375) * 4). Vertex and fragment functions blend over the whole step, and the sampler state's
// TrilinearFilterQuality (0, full) changes nothing. So in compute kernels an explicit level with a fraction becomes
// n + 0.375 + f / 4, which gives weight f. A nearest mip filter still picks the same level (f < 0.5 stays below the
// middle), and whole levels are left alone (whether the min or mag filter applies depends on LOD > 0). Gradients in
// compute kernels blend the same way and are left as they are: their LOD would have to be computed in the shader.
// Haswell only: Ivy Bridge's samplers haven't been measured. Modules can reach the pass manager twice, so remapped calls
// are marked (!intel.level_remapped). INTEL_COMPUTE_TRILINEAR_FIX=0
// turns it off.
extern "C" {
LLVMValueRef LLVMBuildFSub(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
unsigned LLVMGetMDKindIDInContext(LLVMContextRef, const char *, unsigned);
LLVMValueRef LLVMGetMetadata(LLVMValueRef, unsigned);
void LLVMSetMetadata(LLVMValueRef, unsigned, LLVMValueRef);
}

static unsigned remapComputeLevels(LLVMModuleRef module) {
    const char *setting = getenv("INTEL_COMPUTE_TRILINEAR_FIX");
    if ((setting && !strcmp(setting, "0")) || ivyBridgePlugin || !LLVMGetNamedMetadataNumOperands(module, "air.kernel")) return 0;
    enum { kRealOEQ = 1, kRealOGT = 2 };  // LLVMRealPredicate
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context), f32 = LLVMFloatTypeInContext(context);
    static const char kMark[] = "intel.level_remapped";
    unsigned mark = LLVMGetMDKindIDInContext(context, kMark, sizeof kMark - 1);
    LLVMValueRef marker = LLVMMDNodeInContext(context, nullptr, 0);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (strncmp(name, "air.sample_", 11) || strstr(name, "_grad")) continue;
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
        for (LLVMValueRef call : calls) {
            int n = LLVMGetNumOperands(call);  // arguments (..., i1 level flag, float level or bias, i32), then the callee
            if (!LLVMIsACallInst(call) || n < 5 || LLVMGetOperand(call, n - 1) != f || LLVMGetMetadata(call, mark)) continue;
            LLVMValueRef flag = LLVMGetOperand(call, n - 4), level = LLVMGetOperand(call, n - 3);
            if (!LLVMIsAConstantInt(flag) || LLVMConstIntGetZExtValue(flag) != 1 || LLVMTypeOf(level) != f32) continue;
            LLVMValueRef mapped;
            if (LLVMIsAConstantFP(level)) {
                int lossy = 0;
                double l = LLVMConstRealGetDouble(level, &lossy), whole = floor(l);
                if (l == whole) continue;
                mapped = LLVMConstReal(f32, whole + 0.375 + (l - whole) * 0.25);
            } else {
                if (!b) b = LLVMCreateBuilderInContext(context);
                LLVMPositionBuilderBefore(b, call);
                LLVMValueRef truncated = LLVMBuildSIToFP(b, LLVMBuildFPToSI(b, level, i32, ""), f32, "");
                LLVMValueRef whole = LLVMBuildSelect(b, LLVMBuildFCmp(b, kRealOGT, truncated, level, ""),
                                                     LLVMBuildFSub(b, truncated, LLVMConstReal(f32, 1.0), ""), truncated, "");  // floor
                LLVMValueRef fraction = LLVMBuildFSub(b, level, whole, "");
                LLVMValueRef middle = LLVMBuildFAdd(b, LLVMBuildFAdd(b, whole, LLVMConstReal(f32, 0.375), ""),
                                                    LLVMBuildFMul(b, fraction, LLVMConstReal(f32, 0.25), ""), "");
                mapped = LLVMBuildSelect(b, LLVMBuildFCmp(b, kRealOEQ, fraction, LLVMConstReal(f32, 0.0), ""), level, middle, "");
            }
            LLVMSetOperand(call, n - 3, mapped);
            LLVMSetMetadata(call, mark, marker);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- threadgroup bools ---------------------------------------------------------------------------------------------
// LLVM shrinks a threadgroup bool to an i1 global, and the back end can't select loads and stores of i1 in threadgroup
// memory ("Cannot select" aborts MTLCompilerService; WebKit's WebGPU workgroupUniformLoad on bool, a10). Such globals
// become i8: loads compare with 0, stored values are zero-extended, and both are volatile, or the back end's GlobalOpt
// shrinks the global back to i1 (it only ever holds 0 or 1). INTEL_THREADGROUP_BOOL_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMGetFirstGlobal(LLVMModuleRef);
LLVMValueRef LLVMGetNextGlobal(LLVMValueRef);
LLVMValueRef LLVMIsAStoreInst(LLVMValueRef);
LLVMTypeRef LLVMInt8TypeInContext(LLVMContextRef);
void LLVMSetVolatile(LLVMValueRef, int);
}

static unsigned widenThreadgroupBools(LLVMModuleRef module) {
    const char *setting = getenv("INTEL_THREADGROUP_BOOL_FIX");
    if (setting && !strcmp(setting, "0")) return 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i1 = LLVMInt1TypeInContext(context), i8 = LLVMInt8TypeInContext(context);
    std::vector<LLVMValueRef> globals;
    for (LLVMValueRef g = LLVMGetFirstGlobal(module); g; g = LLVMGetNextGlobal(g))
        if (LLVMGetPointerAddressSpace(LLVMTypeOf(g)) == 3 && LLVMGetElementType(LLVMTypeOf(g)) == i1) globals.push_back(g);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef g : globals) {
        std::vector<LLVMValueRef> users;
        bool plain = true;  // only loads from it and stores to it
        for (LLVMUseRef u = LLVMGetFirstUse(g); u; u = LLVMGetNextUse(u)) {
            LLVMValueRef user = LLVMGetUser(u);
            if (LLVMIsALoadInst(user) || (LLVMIsAStoreInst(user) && LLVMGetOperand(user, 1) == g && LLVMGetOperand(user, 0) != g)) users.push_back(user);
            else plain = false;
        }
        if (!plain) continue;
        std::string name = LLVMGetValueName(g);
        LLVMValueRef wide = LLVMAddGlobalInAddressSpace(module, i8, (name + ".i8").c_str(), 3);
        LLVMValueRef init = LLVMGetInitializer(g);
        LLVMSetInitializer(wide, init && LLVMIsAConstantInt(init) ? LLVMConstInt(i8, LLVMConstIntGetZExtValue(init), false) : LLVMGetUndef(i8));
        LLVMSetLinkage(wide, LLVMGetLinkage(g));
        LLVMSetAlignment(wide, 1);
        if (!b) b = LLVMCreateBuilderInContext(context);
        for (LLVMValueRef user : users) {
            LLVMPositionBuilderBefore(b, user);
            if (LLVMIsALoadInst(user)) {
                // != 0 rather than a truncation, which the DAG combiner turns back into an i1 load
                LLVMValueRef load = LLVMBuildLoad(b, wide, "");
                LLVMSetVolatile(load, 1);
                LLVMValueRef value = LLVMBuildICmp(b, 33 /* LLVMIntNE */, load, LLVMConstInt(i8, 0, false), "");
                LLVMReplaceAllUsesWith(user, value);
            } else {
                LLVMSetVolatile(LLVMBuildStore(b, LLVMBuildZExt(b, LLVMGetOperand(user, 0), i8, ""), wide), 1);
            }
            LLVMInstructionEraseFromParent(user);
        }
        LLVMDeleteGlobal(g);
        LLVMSetValueName(wide, name.c_str());
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- over-aligned byte accesses to private memory ------------------------------------------------------------------
// A byte or halfword load from private (stack) memory with an alignment of 4 or more, as LLVM gives the first small field
// of a 16-byte-aligned struct in a dynamically indexed private array (`S w[2]; ... w[s].count`, EEVEE's G-buffer writer,
// c03), has no instruction pattern in the back end ("Cannot select: load ... anyext from i8", align 16), which aborts
// MTLCompilerService. Lowering the alignment doesn't last (the optimizer infers it again from the alloca), so such an
// access becomes one of its 32-bit word, which starts at the pointer: a load and a truncation, or a read-modify-write
// of the word for a store. They are volatile, or instruction selection narrows them back. INTEL_PRIVATE_ALIGN_FIX=0
// turns it off.
extern "C" {
unsigned LLVMGetAlignment(LLVMValueRef);
LLVMValueRef LLVMBuildBitCast(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char *);
LLVMValueRef LLVMBuildOr(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMValueRef LLVMBuildAnd(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char *);
LLVMTypeRef LLVMPointerType(LLVMTypeRef, unsigned);
}

static unsigned wordPrivateSubwords(LLVMModuleRef module) {
    const char *setting = getenv("INTEL_PRIVATE_ALIGN_FIX");
    if (setting && !strcmp(setting, "0")) return 0;
    enum { kIntegerKind = 8 };  // LLVMTypeKind
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context), i32Pointer = LLVMPointerType(i32, 0);
    std::vector<LLVMValueRef> accesses;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                bool load = LLVMIsALoadInst(inst), store = !load && LLVMIsAStoreInst(inst);
                if (!load && !store) continue;
                LLVMValueRef pointer = LLVMGetOperand(inst, load ? 0 : 1);
                LLVMTypeRef type = load ? LLVMTypeOf(inst) : LLVMTypeOf(LLVMGetOperand(inst, 0));
                if (LLVMGetPointerAddressSpace(LLVMTypeOf(pointer)) != 0 || LLVMGetTypeKind(type) != kIntegerKind || !subwordBits(type) ||
                    LLVMGetAlignment(inst) < 4)
                    continue;
                accesses.push_back(inst);
            }
    if (accesses.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(context);
    for (LLVMValueRef inst : accesses) {
        LLVMPositionBuilderBefore(b, inst);
        bool load = LLVMIsALoadInst(inst);
        LLVMValueRef pointer = LLVMGetOperand(inst, load ? 0 : 1);
        LLVMTypeRef type = load ? LLVMTypeOf(inst) : LLVMTypeOf(LLVMGetOperand(inst, 0));
        LLVMValueRef word = LLVMBuildBitCast(b, pointer, i32Pointer, "");
        LLVMValueRef old = LLVMBuildLoad(b, word, "");
        LLVMSetVolatile(old, 1);
        LLVMSetAlignment(old, 4);
        if (load) {
            LLVMReplaceAllUsesWith(inst, LLVMBuildTrunc(b, old, type, ""));
        } else {
            unsigned long long mask = subwordBits(type) == 8 ? 0xffu : 0xffffu;
            LLVMValueRef kept = LLVMBuildAnd(b, old, LLVMConstInt(i32, ~mask & 0xffffffffu, false), "");
            LLVMValueRef merged = LLVMBuildOr(b, kept, LLVMBuildZExt(b, LLVMGetOperand(inst, 0), i32, ""), "");
            LLVMValueRef put = LLVMBuildStore(b, merged, word);
            LLVMSetVolatile(put, 1);
            LLVMSetAlignment(put, 4);
        }
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)accesses.size();
}

// ---- float3 vertex and fragment inputs -------------------------------------------------------------------------------
// When a vertex function copies a component of a float3 vertex input straight to an output (`out.o = in.a.y`), the back
// end declares the input (DCL_INPUT i1.xyz) but drops its move into a register and writes the output from one nothing
// set (MOV o0.x, r1.x): 0 or garbage. Float2 and float4 inputs, and any arithmetic on the input, are right. ANGLE's
// vertex shaders do that copy for `out0 = in0.x` on a vec3 attribute (dEQP swizzles_vec3 *_vertex,
// conversions_vector_to_scalar vec3_to_float_vertex). In fragment functions, the z of a float3 input given straight to
// sample_compare as the reference value compares with the input's x instead; ANGLE passes sampler2DShadow coordinates
// as a vec3 varying that way (dEQP texture.sampler2dshadow_fragment, textureoffset.sampler2dshadow_fragment and their
// _bias cases). Each <3 x float> parameter of a vertex or fragment function goes through air.fast_fmax(a, a) first,
// which is exact (NaN stays NaN) and makes the back end read the input into a register. Only before the plugin binds
// air.* calls to its runtime library (see runtimeNamesBound). INTEL_VERTEX_FLOAT3_FIX=0 and INTEL_FRAGMENT_FLOAT3_FIX=0
// turn it off.
// Whether the plugin has already turned the module's air.* calls into the runtime library's air_* functions (a later
// pass-manager run on the same module): air.* calls added then are never resolved, and the back end crashes lowering them.
static bool runtimeNamesBound(LLVMModuleRef module) {
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        if (!strncmp(LLVMGetValueName(f), "air_", 4)) return true;
    return false;
}

static unsigned fixFloat3Inputs(LLVMModuleRef module) {
    if (runtimeNamesBound(module)) return 0;
    std::vector<LLVMValueRef> entryFunctions;
    for (const char *list : {"air.vertex", "air.fragment"}) {
        if (disabled(!strcmp(list, "air.vertex") ? "INTEL_VERTEX_FLOAT3_FIX" : "INTEL_FRAGMENT_FLOAT3_FIX")) continue;
        std::vector<LLVMValueRef> entries(LLVMGetNamedMetadataNumOperands(module, list));
        if (!entries.empty()) LLVMGetNamedMetadataOperands(module, list, entries.data());
        entryFunctions.insert(entryFunctions.end(), entries.begin(), entries.end());
    }
    if (entryFunctions.empty()) return 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef f32 = LLVMFloatTypeInContext(context), v3f32 = LLVMVectorType(f32, 3);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef node : entryFunctions) {
        std::vector<LLVMValueRef> parts = metadataOperands(node);
        LLVMValueRef function = parts.empty() ? nullptr : parts[0];
        if (!function || LLVMIsDeclaration(function) || !LLVMGetFirstBasicBlock(function)) continue;
        LLVMValueRef first = LLVMGetFirstInstruction(LLVMGetFirstBasicBlock(function));
        if (!first) continue;
        for (unsigned p = 0; p < LLVMCountParams(function); p++) {
            LLVMValueRef param = LLVMGetParam(function, p);
            if (LLVMTypeOf(param) != v3f32 || !LLVMGetFirstUse(param)) continue;
            std::vector<LLVMValueRef> users;
            bool done = false;
            for (LLVMUseRef u = LLVMGetFirstUse(param); u; u = LLVMGetNextUse(u)) {
                LLVMValueRef user = LLVMGetUser(u);
                const char *callee = LLVMIsACallInst(user) ? LLVMGetValueName(LLVMGetOperand(user, LLVMGetNumOperands(user) - 1)) : "";
                if ((!strcmp(callee, "air.fast_fmax.v3f32") || !strcmp(callee, "air_fast_fmax_v3f32")) &&
                    LLVMGetOperand(user, 0) == param && LLVMGetOperand(user, 1) == param)
                    done = true;  // this module's second pass
                else users.push_back(user);
            }
            if (done) continue;
            LLVMValueRef fmax = LLVMGetNamedFunction(module, "air.fast_fmax.v3f32");
            LLVMTypeRef params[2] = {v3f32, v3f32};
            if (!fmax) fmax = LLVMAddFunction(module, "air.fast_fmax.v3f32", LLVMFunctionType(v3f32, params, 2, 0));
            if (!b) b = LLVMCreateBuilderInContext(context);
            LLVMPositionBuilderBefore(b, first);
            LLVMValueRef args[2] = {param, param};
            LLVMValueRef read = LLVMBuildCall(b, fmax, args, 2, "");
            for (LLVMValueRef user : users)
                for (int i = 0; i < LLVMGetNumOperands(user); i++)
                    if (LLVMGetOperand(user, i) == param) LLVMSetOperand(user, i, read);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- get_num_samples ------------------------------------------------------------------------------------------------
// get_num_samples() (air.get_num_samples) returns 1 in a fragment function that takes a buffer argument, at any sample
// count; without one it's right. Every ANGLE fragment shader takes buffers, and ANGLE's alpha-to-coverage emulation (on
// for every non-Apple GPU) picks its dither pattern by sample count: with 1 it fell through to using alpha * 510 itself as
// the sample mask, so coverage jumped around instead of growing with alpha (dEQP
// multisample.fbo_*.proportionality_alpha_to_coverage). A render pipeline's sample count is fixed when its functions are
// compiled, and the module carries it (!air.state !{!"msaaLevel", i32 N}): the calls become that constant.
// INTEL_NUM_SAMPLES_FIX=0 turns it off.
static unsigned foldNumSamples(LLVMModuleRef module) {
    LLVMValueRef f = LLVMGetNamedFunction(module, "air.get_num_samples.i32");
    if (disabled("INTEL_NUM_SAMPLES_FIX") || !f || !LLVMGetFirstUse(f)) return 0;
    int samples = 0;
    std::vector<LLVMValueRef> states(LLVMGetNamedMetadataNumOperands(module, "air.state"));
    if (!states.empty()) LLVMGetNamedMetadataOperands(module, "air.state", states.data());
    for (LLVMValueRef state : states) {
        std::vector<LLVMValueRef> parts = metadataOperands(state);
        if (parts.size() == 2 && isString(parts[0], "msaaLevel") && LLVMIsAConstantInt(parts[1]))
            samples = (int)LLVMConstIntGetZExtValue(parts[1]);
    }
    if (samples < 1 || samples > 16) return 0;
    std::vector<LLVMValueRef> calls;
    for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u)) calls.push_back(LLVMGetUser(u));
    unsigned fixed = 0;
    for (LLVMValueRef call : calls) {
        if (!LLVMIsACallInst(call) || LLVMGetOperand(call, LLVMGetNumOperands(call) - 1) != f) continue;
        LLVMReplaceAllUsesWith(call, LLVMConstInt(LLVMTypeOf(call), samples, false));
        LLVMInstructionEraseFromParent(call);
        fixed++;
    }
    return fixed;
}

// ---- dynamically indexed private arrays ----------------------------------------------------------------------------
// A private array inside a struct (`struct { int v[3]; } a; ... a.v[i]`, the way ANGLE declares every GLSL array, as
// metal::array) that is indexed with a variable becomes an indexable register array (DCL_INDEXABLETEMP x0[N]) in vertex
// and fragment functions, and the back end addresses it two ways: stores at constant offsets go to raw scratch with byte
// addresses (element 2 of an int array lands in x0[0].z) while variable-index accesses use x0[i].x. Elements written one
// way and read the other come back 0 or stale (WebGL unary-minus-operator-in-dynamic-loop, dEQP shaderstruct
// array_member_dynamic_index, shaderindexing). Each load or store through a GEP into an alloca with one variable index over
// an array of at most 16 elements becomes accesses at every constant index plus selects (a load: one load per element and
// a select chain; a store: for each element, store select(i == k, value, old)), so only constant offsets remain. Out of
// range indices read the last element and store nothing. Only loads and stores of numbers and vectors of them: arrays of
// textures or samplers are left alone (the back end can't pick a handle with a select), and so are arrays that something
// other than loads and stores reaches (onlyDirectAccesses below). An array is rewritten whole or not at all: one
// variable-index access left as the front end wrote it next to rewritten ones is the mix this works around (mslfuzz2
// VEC=1 seed 1469, i44). INTEL_PRIVATE_ARRAY_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMBuildGEP(LLVMBuilderRef, LLVMValueRef, LLVMValueRef *, unsigned, const char *);
LLVMValueRef LLVMIsAGetElementPtrInst(LLVMValueRef);
LLVMTypeRef LLVMStructGetTypeAtIndex(LLVMTypeRef, unsigned);
}

static LLVMValueRef allocaBase(LLVMValueRef pointer) {  // the alloca a pointer is derived from by GEPs and bitcasts, or null
    for (int depth = 0; pointer && depth < 8; depth++) {
        if (LLVMIsAAllocaInst(pointer)) return pointer;
        if (LLVMIsAGetElementPtrInst(pointer) || LLVMIsABitCastInst(pointer)) pointer = LLVMGetOperand(pointer, 0);
        else return nullptr;
    }
    return nullptr;
}

// Whether a private array is only ever loaded and stored through GEPs and bitcasts of it (and named by llvm.* intrinsics:
// lifetime markers, memcpy, memset). Anything else -- a select or phi of pointers into it, a call, the pointer stored or
// converted -- keeps it in private memory, where the back end forwards a stale load of an element past a store to it
// (see splitPrivatePointerSelects); the selects below would turn every variable-index store into such loads and stores.
extern "C" {
int LLVMGetVolatile(LLVMValueRef);
LLVMValueRef LLVMIsASelectInst(LLVMValueRef);
}
static bool onlyDirectAccesses(LLVMValueRef pointer, int depth = 0) {
    if (depth > 8) return false;
    for (LLVMUseRef u = LLVMGetFirstUse(pointer); u; u = LLVMGetNextUse(u)) {
        LLVMValueRef user = LLVMGetUser(u);
        if (LLVMIsALoadInst(user)) continue;
        if (LLVMIsAStoreInst(user)) {
            if (LLVMGetOperand(user, 0) == pointer) return false;  // the address itself stored
            continue;
        }
        if ((LLVMIsAGetElementPtrInst(user) || LLVMIsABitCastInst(user)) && LLVMGetOperand(user, 0) == pointer) {
            if (!onlyDirectAccesses(user, depth + 1)) return false;
            continue;
        }
        if (LLVMIsACallInst(user)) {
            const char *name = LLVMGetValueName(LLVMGetCalledValue(user));
            if (name && !strncmp(name, "llvm.", 5)) continue;
        }
        return false;
    }
    return true;
}

// ---- private arrays of bytes and halfwords done on 32-bit words --------------------------------------------------
// A private uchar / ushort array (uchar pc[8]) is stored with truncating stores and read with extending loads, and after
// i07's and i35's rewrites the back end forwarded a stored 32-bit value to such a load without masking it, so a pc[i]
// read in a narrow min / max or division kept the bits above its byte (mslfuzz2 VEC=1 seed 1497, i47). An array of 8-
// or 16-bit integers that only GEPs into its elements reach, with only loads and stores of the element type behind
// them, becomes an array of i32: stores zero-extend, loads truncate. Runs before i07, which then rewrites the 32-bit
// array. INTEL_NARROW_PRIVATE_ARRAY_FIX=0 turns it off.
static unsigned widenNarrowPrivateArrays(LLVMModuleRef module) {
    if (disabled("INTEL_NARROW_PRIVATE_ARRAY_FIX") || runtimeNamesBound(module)) return 0;
    enum { kArrayKind = 11 };
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context);
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
        if (LLVMGetTypeKind(element) != kTypeKindInteger) continue;
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
        if (!b) b = LLVMCreateBuilderInContext(context);
        LLVMPositionBuilderBefore(b, alloca);
        LLVMValueRef wide = LLVMBuildAlloca(b, LLVMArrayType(i32, length), "");
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
                    LLVMBuildStore(b, LLVMBuildZExt(b, LLVMGetOperand(user, 0), i32, ""), slot);
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

static unsigned selectPrivateArrayIndices(LLVMModuleRef module) {
    const char *setting = getenv("INTEL_PRIVATE_ARRAY_FIX");
    if (setting && !strcmp(setting, "0")) return 0;
    std::map<LLVMValueRef, bool> direct;  // alloca -> onlyDirectAccesses
    enum { kArrayKind = 11, kStructKind = 10, kPointerKind = 12, kIntEQ = 32, kMaxElements = 16 };
    std::vector<LLVMValueRef> geps;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMIsAGetElementPtrInst(inst) && allocaBase(LLVMGetOperand(inst, 0))) geps.push_back(inst);
    // the GEPs with one variable index (not the first) into an array of 2..16 elements; dynamic = that operand
    auto arrayStep = [&](LLVMValueRef gep, int &dynamic) -> LLVMTypeRef {
        int n = LLVMGetNumOperands(gep);  // pointer, indices
        bool usable = true;
        dynamic = -1;
        for (int i = 1; i < n && usable; i++)
            if (!LLVMIsAConstantInt(LLVMGetOperand(gep, i))) usable = dynamic < 0, dynamic = i;
        if (!usable || dynamic < 2) return nullptr;  // exactly one variable index, and not the first (pointer-step) one
        // the type the variable index steps through: walk the pointee type with the indices before it
        LLVMTypeRef t = LLVMGetElementType(LLVMTypeOf(LLVMGetOperand(gep, 0)));
        for (int i = 2; i < dynamic && t; i++) {
            if (LLVMGetTypeKind(t) == kArrayKind) t = LLVMGetElementType(t);
            else if (LLVMGetTypeKind(t) == kStructKind) t = LLVMStructGetTypeAtIndex(t, (unsigned)LLVMConstIntGetZExtValue(LLVMGetOperand(gep, i)));
            else t = nullptr;
        }
        if (!t || LLVMGetTypeKind(t) != kArrayKind || LLVMGetArrayLength(t) < 2 || LLVMGetArrayLength(t) > kMaxElements) return nullptr;
        return t;
    };
    auto bitsOf = [](LLVMTypeRef type) -> unsigned {  // plain integer / floating-point scalars and vectors; 0 otherwise
        unsigned count = lanes(type) ? lanes(type) : 1;
        LLVMTypeRef e = lanes(type) ? LLVMGetElementType(type) : type;
        int kind = LLVMGetTypeKind(e);
        unsigned bits = kind == kTypeKindInteger ? LLVMGetIntTypeWidth(e) : kind == 1 ? 16 : kind == 2 ? 32 : kind == 3 ? 64 : 0;
        return bits * count;
    };
    auto plainValue = [&](LLVMTypeRef value) {  // plain data only: texture and sampler handles picked by a select break the back end (a05)
        int kind = LLVMGetTypeKind(scalarOf(value));
        return kind == kTypeKindInteger || kind == 1 /* half */ || kind == 2 /* float */ || kind == 3 /* double */;
    };
    LLVMBuilderRef b = nullptr;
    // A load or store through a bitcast of the element's address to a type of the same size (the front end stores
    // `p[i] = x` as <2 x i16> when x was a ushort2 view) becomes one of the element's own type plus a bitcast of the
    // value, so that the GEP below has only plain loads and stores (mslfuzz2 VEC=1 seed 1469).
    for (LLVMValueRef gep : geps) {
        int dynamic;
        LLVMTypeRef t = arrayStep(gep, dynamic);
        if (!t) continue;
        LLVMTypeRef element = LLVMGetElementType(t);
        unsigned elementBits = plainValue(element) ? bitsOf(element) : 0;
        if (!elementBits) continue;
        std::vector<LLVMValueRef> casts;
        for (LLVMUseRef u = LLVMGetFirstUse(gep); u; u = LLVMGetNextUse(u))
            if (LLVMIsABitCastInst(LLVMGetUser(u))) casts.push_back(LLVMGetUser(u));
        for (LLVMValueRef cast : casts) {
            std::vector<LLVMValueRef> accesses;
            bool same = true;
            for (LLVMUseRef u = LLVMGetFirstUse(cast); u && same; u = LLVMGetNextUse(u)) {
                LLVMValueRef user = LLVMGetUser(u);
                bool load = LLVMIsALoadInst(user), store = !load && LLVMIsAStoreInst(user) && LLVMGetOperand(user, 1) == cast;
                LLVMTypeRef value = load ? LLVMTypeOf(user) : store ? LLVMTypeOf(LLVMGetOperand(user, 0)) : nullptr;
                same = value && plainValue(value) && bitsOf(value) == elementBits;
                if (same) accesses.push_back(user);
            }
            if (!same || accesses.empty()) continue;
            if (!b) b = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
            for (LLVMValueRef access : accesses) {
                LLVMPositionBuilderBefore(b, access);
                if (LLVMIsALoadInst(access)) {
                    LLVMValueRef whole = LLVMBuildLoad(b, gep, "");
                    LLVMReplaceAllUsesWith(access, LLVMBuildBitCast(b, whole, LLVMTypeOf(access), ""));
                } else {
                    LLVMBuildStore(b, LLVMBuildBitCast(b, LLVMGetOperand(access, 0), element, ""), gep);
                }
                LLVMInstructionEraseFromParent(access);
            }
            if (!LLVMGetFirstUse(cast)) LLVMInstructionEraseFromParent(cast);
        }
    }
    // An array is rewritten whole or not at all: one variable-index access left as the front end wrote it next to
    // rewritten ones is exactly the mix of element slots and byte addresses this works around.
    auto rewritable = [&](LLVMValueRef gep, std::vector<LLVMValueRef> *out) {
        bool usable = true;
        for (LLVMUseRef u = LLVMGetFirstUse(gep); u && usable; u = LLVMGetNextUse(u)) {
            LLVMValueRef user = LLVMGetUser(u);
            bool load = LLVMIsALoadInst(user), store = !load && LLVMIsAStoreInst(user) && LLVMGetOperand(user, 1) == gep && LLVMGetOperand(user, 0) != gep;
            LLVMTypeRef value = load ? LLVMTypeOf(user) : store ? LLVMTypeOf(LLVMGetOperand(user, 0)) : nullptr;
            if (value && plainValue(value)) { if (out) out->push_back(user); }
            else usable = false;
        }
        return usable;
    };
    std::set<LLVMValueRef> partial;  // allocas with a variable-index access that can't be rewritten
    for (LLVMValueRef gep : geps) {
        int dynamic;
        if (!arrayStep(gep, dynamic)) continue;
        if (!rewritable(gep, nullptr)) partial.insert(allocaBase(LLVMGetOperand(gep, 0)));
    }
    unsigned fixed = 0;
    for (LLVMValueRef gep : geps) {
        int n = LLVMGetNumOperands(gep), dynamic;
        LLVMTypeRef t = arrayStep(gep, dynamic);
        if (!t) continue;
        LLVMValueRef base = allocaBase(LLVMGetOperand(gep, 0));
        if (partial.count(base)) continue;
        auto known = direct.find(base);
        if (known == direct.end()) known = direct.emplace(base, onlyDirectAccesses(base)).first;
        if (!known->second) continue;  // stays in memory: left as the front end wrote it
        unsigned length = LLVMGetArrayLength(t);
        std::vector<LLVMValueRef> users;
        bool usable = rewritable(gep, &users);
        if (!usable || users.empty()) continue;
        if (!b) b = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
        LLVMValueRef index = LLVMGetOperand(gep, dynamic);
        LLVMTypeRef indexType = LLVMTypeOf(index);
        for (LLVMValueRef user : users) {
            LLVMPositionBuilderBefore(b, user);
            std::vector<LLVMValueRef> indices(n - 1), slots(length);
            for (int i = 1; i < n; i++) indices[i - 1] = LLVMGetOperand(gep, i);
            for (unsigned k = 0; k < length; k++) {
                indices[dynamic - 1] = LLVMConstInt(indexType, k, false);
                slots[k] = LLVMBuildGEP(b, LLVMGetOperand(gep, 0), indices.data(), n - 1, "");
            }
            if (LLVMIsALoadInst(user)) {
                LLVMValueRef value = LLVMBuildLoad(b, slots[length - 1], "");
                for (int k = (int)length - 2; k >= 0; k--)
                    value = LLVMBuildSelect(b, LLVMBuildICmp(b, kIntEQ, index, LLVMConstInt(indexType, k, false), ""), LLVMBuildLoad(b, slots[k], ""), value, "");
                LLVMReplaceAllUsesWith(user, value);
            } else {
                LLVMValueRef value = LLVMGetOperand(user, 0);
                for (unsigned k = 0; k < length; k++) {
                    LLVMValueRef old = LLVMBuildLoad(b, slots[k], "");
                    LLVMBuildStore(b, LLVMBuildSelect(b, LLVMBuildICmp(b, kIntEQ, index, LLVMConstInt(indexType, k, false), ""), value, old, ""), slots[k]);
                }
            }
            LLVMInstructionEraseFromParent(user);
            fixed++;
        }
        if (!LLVMGetFirstUse(gep)) LLVMInstructionEraseFromParent(gep);
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- selects of pointers into one buffer -----------------------------------------------------------------------------
// `c ? in[i] : in[j]` comes out of the front end as a load through select(c, &in[i], &in[j]). The back end can't tell
// that both pointers name the same buffer, so it loads through a loop over the distinct surfaces in the SIMD group, and
// that loop takes flag register f0.1 without saving it: when the select sits in the then-branch of an if/else whose
// else-branch tests a condition the back end kept in f0.1, lanes that took the else came out as if the condition held
// (a switch whose case 0 broke out ran the default's code whenever a case-1 lane shared its SIMD8 group: differential
// fuzzing, mslfuzz2). A select whose arms are GEPs of the same pointer with indices of the same types becomes one GEP
// with the differing indices selected (a pointer itself counts as a GEP by 0): the same address, no surface loop. Device
// and constant pointers only (private ones are split by splitPrivatePointerSelects). INTEL_BUFFER_SELECT_FIX=0 turns it off.
static unsigned selectBufferIndices(LLVMModuleRef module) {
    if (disabled("INTEL_BUFFER_SELECT_FIX")) return 0;
    enum { kArrayKind = 11, kStructKind = 10, kPointerKind = 12, kVectorKind = 13 };
    std::vector<LLVMValueRef> selects;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMIsASelectInst(inst) && LLVMGetTypeKind(LLVMTypeOf(inst)) == kPointerKind) {
                    unsigned space = LLVMGetPointerAddressSpace(LLVMTypeOf(inst));
                    if (space == 1 || space == 2) selects.push_back(inst);
                }
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    auto parts = [](LLVMValueRef v, LLVMValueRef &base, std::vector<LLVMValueRef> &indices) {
        indices.clear();
        if (!LLVMIsAGetElementPtrInst(v)) { base = v; return; }
        base = LLVMGetOperand(v, 0);
        for (int i = 1; i < LLVMGetNumOperands(v); i++) indices.push_back(LLVMGetOperand(v, i));
    };
    for (LLVMValueRef sel : selects) {
        LLVMValueRef condition = LLVMGetOperand(sel, 0), baseA, baseB;
        std::vector<LLVMValueRef> a, b2;
        parts(LLVMGetOperand(sel, 1), baseA, a);
        parts(LLVMGetOperand(sel, 2), baseB, b2);
        if (baseA != baseB) continue;
        if (a.empty() && b2.size() == 1) a.push_back(LLVMConstNull(LLVMTypeOf(b2[0])));
        if (b2.empty() && a.size() == 1) b2.push_back(LLVMConstNull(LLVMTypeOf(a[0])));
        if (a.empty() || a.size() != b2.size()) continue;
        // indices may differ only where they step through a pointer, an array or a vector (struct field numbers are constants)
        bool usable = true;
        LLVMTypeRef t = LLVMTypeOf(baseA);
        for (size_t k = 0; k < a.size() && usable && t; k++) {
            if (LLVMTypeOf(a[k]) != LLVMTypeOf(b2[k])) usable = false;
            int kind = LLVMGetTypeKind(t);
            if (kind == kStructKind) {
                if (a[k] != b2[k]) usable = false;
                else t = LLVMStructGetTypeAtIndex(t, (unsigned)LLVMConstIntGetZExtValue(a[k]));
            } else if (kind == kPointerKind || kind == kArrayKind || kind == kVectorKind) t = LLVMGetElementType(t);
            else usable = false;
        }
        if (!usable || !t) continue;
        if (!b) b = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
        LLVMPositionBuilderBefore(b, sel);
        std::vector<LLVMValueRef> indices(a.size());
        for (size_t k = 0; k < a.size(); k++) indices[k] = a[k] == b2[k] ? a[k] : LLVMBuildSelect(b, condition, a[k], b2[k], "");
        LLVMValueRef gep = LLVMBuildGEP(b, baseA, indices.data(), (unsigned)indices.size(), "");
        if (LLVMTypeOf(gep) != LLVMTypeOf(sel)) {  // shouldn't happen: both arms had the select's type
            LLVMInstructionEraseFromParent(gep);
            continue;
        }
        LLVMReplaceAllUsesWith(sel, gep);
        LLVMInstructionEraseFromParent(sel);
        fixed++;
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- loads and stores through a select of private pointers ----------------------------------------------------------
// A pointer into a private array picked with a select (`thread uint *q = c ? &p[2] : &p[5]; *q += x;`) keeps the array in
// private memory, and there the back end forwards a load of an element past a store to that same element: in
// `p[5] = p[5] + a; p[5] = p[5] * 3u;` the second statement reads the value the first one loaded (stock compiler too).
// The variable-index rewrite above turns every store into such loads and stores, so with it random integer kernels with
// a pointer select came out wrong 43% of the time (differential fuzzing, mslfuzz). A load through such a select
// becomes a select of the two loads, a store two stores (each pointer gets the value or its own old contents), so no
// pointer into the array is selected any more and the back end keeps it in registers. Only selects whose arms both point
// into allocas and whose uses are all non-volatile loads and stores of numbers or vectors of them. Runs before the
// variable-index rewrite, which then also takes the arms. INTEL_PRIVATE_SELECT_FIX=0 turns it off.
static unsigned splitPrivatePointerSelects(LLVMModuleRef module) {
    const char *setting = getenv("INTEL_PRIVATE_SELECT_FIX");
    if (setting && !strcmp(setting, "0")) return 0;
    enum { kPointerKind = 12 };
    std::vector<LLVMValueRef> selects;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMIsASelectInst(inst) && LLVMGetTypeKind(LLVMTypeOf(inst)) == kPointerKind &&
                    allocaBase(LLVMGetOperand(inst, 1)) && allocaBase(LLVMGetOperand(inst, 2)))
                    selects.push_back(inst);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef sel : selects) {
        std::vector<LLVMValueRef> users;
        bool usable = true;
        for (LLVMUseRef u = LLVMGetFirstUse(sel); u && usable; u = LLVMGetNextUse(u)) {
            LLVMValueRef user = LLVMGetUser(u);
            bool load = LLVMIsALoadInst(user), store = !load && LLVMIsAStoreInst(user) && LLVMGetOperand(user, 1) == sel && LLVMGetOperand(user, 0) != sel;
            LLVMTypeRef value = load ? LLVMTypeOf(user) : store ? LLVMTypeOf(LLVMGetOperand(user, 0)) : nullptr;
            int kind = value ? LLVMGetTypeKind(scalarOf(value)) : -1;
            if (value && !LLVMGetVolatile(user) && (kind == kTypeKindInteger || kind == 1 /* half */ || kind == 2 /* float */ || kind == 3 /* double */))
                users.push_back(user);
            else
                usable = false;
        }
        if (!usable || users.empty()) continue;
        if (!b) b = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
        LLVMValueRef condition = LLVMGetOperand(sel, 0), first = LLVMGetOperand(sel, 1), second = LLVMGetOperand(sel, 2);
        for (LLVMValueRef user : users) {
            LLVMPositionBuilderBefore(b, user);
            if (LLVMIsALoadInst(user)) {
                LLVMValueRef a = LLVMBuildLoad(b, first, ""), c = LLVMBuildLoad(b, second, "");
                LLVMReplaceAllUsesWith(user, LLVMBuildSelect(b, condition, a, c, ""));
            } else {  // in order, so that two arms naming one element end with the stored value
                LLVMValueRef value = LLVMGetOperand(user, 0);
                LLVMBuildStore(b, LLVMBuildSelect(b, condition, value, LLVMBuildLoad(b, first, ""), ""), first);
                LLVMBuildStore(b, LLVMBuildSelect(b, condition, LLVMBuildLoad(b, second, ""), value, ""), second);
            }
            LLVMInstructionEraseFromParent(user);
            fixed++;
        }
        if (!LLVMGetFirstUse(sel)) LLVMInstructionEraseFromParent(sel);
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// ---- chains of short branches --------------------------------------------------------------------------------------
// The back end's register allocator (iCBE VirtualRegistersToRegisters -> CStructRegionTree::StructuralAnalysis) takes
// exponential time on functions made of chains of short conditional branches that all fall through to a shared block,
// the shape `if (a && b && c && d) ... else ...` compiles to when each test is a few compares: 4 such tests over vec4s
// take 2 s, 6 more than a minute, 8 more than ten minutes. Chrome's GPU watchdog kills the process meanwhile (WebGPU CTS
// shader,execution,robust_access_vertex, which validates each of up to 12 vertex attributes this way). Blocks that only
// compute (no memory access, no calls but pure air functions) are folded into their predecessor, the branch conditions
// combined with selects (`br a, B, E; B: br b, C, E` becomes `br (a ? b : false), C, E`), and if-then(-else) shapes
// with such arms become selects, until the chains are single blocks. Only blocks of at most INTEL_BRANCH_CHAIN_MOVE
// (default 16) instructions move, phis become selects only for numbers and vectors of them (never texture or sampler
// pointers, a05), and it only runs on functions with at least INTEL_BRANCH_CHAIN_MIN (default 12) conditional branches.
// INTEL_BRANCH_CHAIN_FIX=0 turns it off.
extern "C" {
LLVMValueRef LLVMGetBasicBlockTerminator(LLVMBasicBlockRef);
unsigned LLVMGetNumSuccessors(LLVMValueRef);
LLVMBasicBlockRef LLVMGetSuccessor(LLVMValueRef, unsigned);
int LLVMIsConditional(LLVMValueRef);
LLVMValueRef LLVMGetCondition(LLVMValueRef);
LLVMValueRef LLVMIsABranchInst(LLVMValueRef);
LLVMValueRef LLVMIsAPHINode(LLVMValueRef);
void LLVMInstructionRemoveFromParent(LLVMValueRef);
void LLVMInsertIntoBuilder(LLVMBuilderRef, LLVMValueRef);
LLVMValueRef LLVMBuildCondBr(LLVMBuilderRef, LLVMValueRef, LLVMBasicBlockRef, LLVMBasicBlockRef);
LLVMValueRef LLVMBuildBr(LLVMBuilderRef, LLVMBasicBlockRef);
LLVMValueRef LLVMBuildPhi(LLVMBuilderRef, LLVMTypeRef, const char *);
void LLVMAddIncoming(LLVMValueRef, LLVMValueRef *, LLVMBasicBlockRef *, unsigned);
unsigned LLVMCountIncoming(LLVMValueRef);
LLVMValueRef LLVMGetIncomingValue(LLVMValueRef, unsigned);
LLVMBasicBlockRef LLVMGetIncomingBlock(LLVMValueRef, unsigned);
void LLVMDeleteBasicBlock(LLVMBasicBlockRef);
void LLVMPositionBuilderAtEnd(LLVMBuilderRef, LLVMBasicBlockRef);
typedef struct LLVMOpaqueAttributeRef *LLVMAttributeRef;
unsigned LLVMGetEnumAttributeKindForName(const char *, size_t);
LLVMAttributeRef LLVMGetEnumAttributeAtIndex(LLVMValueRef, unsigned, unsigned);
LLVMAttributeRef LLVMGetCallSiteEnumAttribute(LLVMValueRef, unsigned, unsigned);
}

namespace flatten {
enum { kFunctionIndex = ~0u, kMaxSteps = 4096 };
static int maxMoved = 16;

static bool hasAttribute(LLVMValueRef call, LLVMValueRef callee, const char *name) {
    unsigned kind = LLVMGetEnumAttributeKindForName(name, strlen(name));
    return kind && (LLVMGetEnumAttributeAtIndex(callee, kFunctionIndex, kind) || LLVMGetCallSiteEnumAttribute(call, kFunctionIndex, kind));
}

// An instruction that can run on a path that didn't run it before: arithmetic, compares, selects, casts, vector and
// aggregate element moves, address arithmetic, and calls of air functions that read no memory and aren't SIMD-group
// operations. Not loads, stores, integer division (a zero divisor), phis or terminators.
static bool speculatable(LLVMValueRef inst) {
    int op = LLVMGetInstructionOpcode(inst);
    if ((op >= 8 && op <= 13) || op == 16 || op == 19 || (op >= 20 && op <= 25) || (op >= 29 && op <= 38) || op == 41 ||
        op == 42 || op == 43 || op == 46 || (op >= 50 && op <= 54))
        return true;  // add..fmul, fdiv, frem, shifts/logic, gep, casts but ptr<->int, bitcast, icmp, fcmp, select, vectors
    if (op != 45 || !LLVMIsACallInst(inst)) return false;
    LLVMValueRef callee = LLVMGetCalledValue(inst);
    const char *name = callee ? LLVMGetValueName(callee) : "";
    return !strncmp(name, "air.", 4) && LLVMIsDeclaration(callee) && !strstr(name, "simd") && !strstr(name, "quad") &&
           hasAttribute(inst, callee, "readnone") && !hasAttribute(inst, callee, "convergent");
}

// A block that can be folded into its predecessor: at most maxMoved speculatable instructions, a branch at the end.
static bool movable(LLVMBasicBlockRef bb) {
    LLVMValueRef term = LLVMGetBasicBlockTerminator(bb);
    if (!term || !LLVMIsABranchInst(term)) return false;
    int n = 0;
    for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst && inst != term; inst = LLVMGetNextInstruction(inst))
        if (++n > maxMoved || !speculatable(inst)) return false;
    return true;
}

// Whether the phis of `bb` that take different values from `a` and `b` can become selects: numbers and vectors of them.
static bool selectablePhis(LLVMBasicBlockRef bb, LLVMBasicBlockRef a, LLVMBasicBlockRef b) {
    for (LLVMValueRef phi = LLVMGetFirstInstruction(bb); phi && LLVMIsAPHINode(phi); phi = LLVMGetNextInstruction(phi)) {
        LLVMValueRef fromA = nullptr, fromB = nullptr;
        for (unsigned i = 0, n = LLVMCountIncoming(phi); i < n; i++) {
            if (LLVMGetIncomingBlock(phi, i) == a) fromA = LLVMGetIncomingValue(phi, i);
            if (LLVMGetIncomingBlock(phi, i) == b) fromB = LLVMGetIncomingValue(phi, i);
        }
        int kind = LLVMGetTypeKind(scalarOf(LLVMTypeOf(phi)));
        if (fromA && fromB && fromA != fromB && kind != kTypeKindInteger && kind != kTypeKindHalf && kind != kTypeKindFloat && kind != 3)
            return false;
    }
    return true;
}

static void moveBody(LLVMBuilderRef b, LLVMBasicBlockRef from, LLVMValueRef before) {  // all but the terminator
    LLVMValueRef term = LLVMGetBasicBlockTerminator(from);
    for (LLVMValueRef inst = LLVMGetFirstInstruction(from), next; inst && inst != term; inst = next) {
        next = LLVMGetNextInstruction(inst);
        LLVMInstructionRemoveFromParent(inst);
        LLVMPositionBuilderBefore(b, before);
        LLVMInsertIntoBuilder(b, inst);
    }
}

// Rewrites the phis of `bb` that have an entry from `from`: it becomes the entry from `to`, or, where `to` has one too,
// both become one entry from `to` with the value merge(phi, value from `to`, value from `from`). A switch that goes to
// `bb` from several cases gives its phis an entry per case, and those stay one per case: `from`'s switch, moved into
// `to`, still has them (mslfuzz2 VEC=1 seed 2642: switch cases 0 and 1 to the same block, and the merged phi with one
// entry failed the verifier, which aborted the compiler; i53).
template <typename Merge>
static void retargetPhis(LLVMBuilderRef b, LLVMBasicBlockRef bb, LLVMBasicBlockRef from, LLVMBasicBlockRef to, Merge merge) {
    std::vector<LLVMValueRef> phis;
    for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst && LLVMIsAPHINode(inst); inst = LLVMGetNextInstruction(inst)) phis.push_back(inst);
    for (LLVMValueRef phi : phis) {
        std::vector<LLVMValueRef> values;
        std::vector<LLVMBasicBlockRef> blocks;
        LLVMValueRef fromValue = nullptr, toValue = nullptr;
        unsigned n = LLVMCountIncoming(phi), fromEntries = 0;
        for (unsigned i = 0; i < n; i++) {
            LLVMBasicBlockRef in = LLVMGetIncomingBlock(phi, i);
            if (in == from) fromValue = LLVMGetIncomingValue(phi, i), fromEntries++;
            else if (in == to) toValue = LLVMGetIncomingValue(phi, i);
            else values.push_back(LLVMGetIncomingValue(phi, i)), blocks.push_back(in);
        }
        if (!fromValue) continue;  // nothing comes from `from`
        for (unsigned k = 0; k < (toValue ? 1 : fromEntries); k++) {
            values.push_back(toValue ? merge(phi, toValue, fromValue) : fromValue);
            blocks.push_back(to);
        }
        LLVMPositionBuilderBefore(b, phi);
        LLVMValueRef replacement = LLVMBuildPhi(b, LLVMTypeOf(phi), "");
        LLVMAddIncoming(replacement, values.data(), blocks.data(), (unsigned)values.size());
        LLVMReplaceAllUsesWith(phi, replacement);
        LLVMInstructionEraseFromParent(phi);
    }
}

static unsigned conditionalBranches(LLVMValueRef f) {
    unsigned n = 0;
    for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb)) {
        LLVMValueRef term = LLVMGetBasicBlockTerminator(bb);
        n += term && LLVMIsABranchInst(term) && LLVMIsConditional(term);
    }
    return n;
}

// One rewrite in `f`; false when there is nothing left to do.
static bool step(LLVMBuilderRef b, LLVMValueRef f, LLVMValueRef yes, LLVMValueRef no) {
    std::map<LLVMBasicBlockRef, std::vector<LLVMBasicBlockRef>> preds;
    for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
        if (LLVMValueRef term = LLVMGetBasicBlockTerminator(bb))
            for (unsigned i = 0, n = LLVMGetNumSuccessors(term); i < n; i++) preds[LLVMGetSuccessor(term, i)].push_back(bb);
    auto onlyFrom = [&](LLVMBasicBlockRef bb, LLVMBasicBlockRef p) { return preds[bb].size() == 1 && preds[bb][0] == p; };
    auto hasPhis = [](LLVMBasicBlockRef bb) { LLVMValueRef first = LLVMGetFirstInstruction(bb); return first && LLVMIsAPHINode(first); };
    for (LLVMBasicBlockRef p = LLVMGetFirstBasicBlock(f); p; p = LLVMGetNextBasicBlock(p)) {
        LLVMValueRef term = LLVMGetBasicBlockTerminator(p);
        if (!term || !LLVMIsABranchInst(term)) continue;
        if (!LLVMIsConditional(term)) {
            // p: br s, and p is s's only predecessor: s's instructions join p's
            LLVMBasicBlockRef s = LLVMGetSuccessor(term, 0);
            if (s == p || !onlyFrom(s, p)) continue;
            LLVMValueRef sTerm = LLVMGetBasicBlockTerminator(s);
            if (!sTerm) continue;
            while (hasPhis(s)) {  // one predecessor: each phi has the one entry
                LLVMValueRef phi = LLVMGetFirstInstruction(s);
                LLVMReplaceAllUsesWith(phi, LLVMGetIncomingValue(phi, 0));
                LLVMInstructionEraseFromParent(phi);
            }
            for (unsigned i = 0, n = LLVMGetNumSuccessors(sTerm); i < n; i++)
                retargetPhis(b, LLVMGetSuccessor(sTerm, i), s, p, [](LLVMValueRef, LLVMValueRef t, LLVMValueRef) { return t; });
            LLVMInstructionEraseFromParent(term);
            for (LLVMValueRef inst = LLVMGetFirstInstruction(s), next; inst; inst = next) {
                next = LLVMGetNextInstruction(inst);
                LLVMInstructionRemoveFromParent(inst);
                LLVMPositionBuilderAtEnd(b, p);
                LLVMInsertIntoBuilder(b, inst);
            }
            LLVMDeleteBasicBlock(s);
            return true;
        }
        LLVMValueRef c = LLVMGetCondition(term);
        LLVMBasicBlockRef t = LLVMGetSuccessor(term, 0), e = LLVMGetSuccessor(term, 1);
        if (t == e || t == p || e == p) continue;
        for (int side = 0; side < 2; side++) {
            // p: br c, s, other (s on the true side when side == 0), p is s's only predecessor, s only computes
            LLVMBasicBlockRef s = side ? e : t, other = side ? t : e;
            if (!onlyFrom(s, p) || hasPhis(s) || !movable(s)) continue;
            LLVMValueRef sTerm = LLVMGetBasicBlockTerminator(s);
            auto viaS = [&](LLVMValueRef sValue, LLVMValueRef pValue) {  // the value that depends on whether p went to s
                if (sValue == pValue) return sValue;
                LLVMPositionBuilderBefore(b, term);
                return side ? LLVMBuildSelect(b, c, pValue, sValue, "") : LLVMBuildSelect(b, c, sValue, pValue, "");
            };
            if (!LLVMIsConditional(sTerm)) {
                LLVMBasicBlockRef j = LLVMGetSuccessor(sTerm, 0);
                if (j == other) {
                    // triangle: p: br c, s, j; s: br j
                    if (!selectablePhis(j, p, s)) continue;
                    moveBody(b, s, term);
                    retargetPhis(b, j, s, p, [&](LLVMValueRef, LLVMValueRef pValue, LLVMValueRef sValue) { return viaS(sValue, pValue); });
                    LLVMPositionBuilderBefore(b, term);
                    LLVMBuildBr(b, j);
                    LLVMInstructionEraseFromParent(term);
                    LLVMDeleteBasicBlock(s);
                    return true;
                }
                // diamond: p: br c, t, e; t: br j; e: br j (both arms movable, j not p)
                LLVMValueRef oTerm = LLVMGetBasicBlockTerminator(other);
                if (side || j == p || !onlyFrom(other, p) || hasPhis(other) || !movable(other) || LLVMIsConditional(oTerm) ||
                    LLVMGetSuccessor(oTerm, 0) != j || !selectablePhis(j, t, e))
                    continue;
                moveBody(b, t, term);
                moveBody(b, e, term);
                retargetPhis(b, j, t, p, [](LLVMValueRef, LLVMValueRef, LLVMValueRef tValue) { return tValue; });
                retargetPhis(b, j, e, p, [&](LLVMValueRef, LLVMValueRef tValue, LLVMValueRef eValue) {
                    if (tValue == eValue) return tValue;
                    LLVMPositionBuilderBefore(b, term);
                    return LLVMBuildSelect(b, c, tValue, eValue, "");
                });
                LLVMPositionBuilderBefore(b, term);
                LLVMBuildBr(b, j);
                LLVMInstructionEraseFromParent(term);
                LLVMDeleteBasicBlock(t);
                LLVMDeleteBasicBlock(e);
                return true;
            }
            // shared destination: p: br c, s, other; s: br d, x, other (either order) -> p: br c', x, other
            LLVMValueRef d = LLVMGetCondition(sTerm);
            LLVMBasicBlockRef s0 = LLVMGetSuccessor(sTerm, 0), s1 = LLVMGetSuccessor(sTerm, 1);
            if ((s0 == other) == (s1 == other)) continue;
            bool otherOnTrue = s0 == other;  // in s
            LLVMBasicBlockRef x = otherOnTrue ? s1 : s0;
            if (x == p || x == s || !selectablePhis(other, p, s)) continue;
            moveBody(b, s, term);
            LLVMPositionBuilderBefore(b, term);
            // reach x iff (p goes to s) and (s goes to x)
            LLVMValueRef toX;
            if (!side) toX = otherOnTrue ? LLVMBuildSelect(b, c, d, yes, "") : LLVMBuildSelect(b, c, d, no, "");  // c && ...
            else toX = otherOnTrue ? LLVMBuildSelect(b, c, yes, d, "") : LLVMBuildSelect(b, c, no, d, "");       // !c && ...
            retargetPhis(b, other, s, p, [&](LLVMValueRef, LLVMValueRef pValue, LLVMValueRef sValue) { return viaS(sValue, pValue); });
            retargetPhis(b, x, s, p, [](LLVMValueRef, LLVMValueRef, LLVMValueRef sValue) { return sValue; });
            LLVMPositionBuilderBefore(b, term);
            // toX as computed is "goes to the 'other' side" when otherOnTrue (select(c, d, true) / select(c, true, d))
            if (otherOnTrue) LLVMBuildCondBr(b, toX, other, x);
            else LLVMBuildCondBr(b, toX, x, other);
            LLVMInstructionEraseFromParent(term);
            LLVMDeleteBasicBlock(s);
            return true;
        }
    }
    return false;
}
}  // namespace flatten

// ---- one buffer viewed as different types --------------------------------------------------------------------------
// WGSL lets a shader view the same buffer bytes as different types (bufferArrayView); Tint casts one byte pointer to
// each view's element type. The 3802 back end then reorders or forwards an access of one type past an access of the
// other to the same address, with or without the front end's alias metadata: in WebGPU CTS bufferArrayView
// mixed_types_aliasing, "load int, store vec2f there, load int" returned the first value (285 aliased cases, storage
// and workgroup buffers; every unaliased case passed, and with every access volatile all passed). Loads and stores
// reached (through GEPs and casts) from a cast of a device or threadgroup pointer whose root (the pointer under its
// GEPs and casts: views at different byte offsets share it) is cast to two or more element types in the same function
// are made volatile, which keeps them in order. The same goes for a root that a memcpy or memmove copies (an aggregate
// copy of the buffer, as Tint writes `output.a = *bufferView<array<i32, 32>>(&A, 0)`) and a cast views: the back end
// lowers the copy to loads and reuses an earlier load of a word past a store to it (bufferView mixed_types_aliasing
// with constant offsets: the store through the view never reached the copied-out array, 96 cases); such roots' casts
// count as punned, and their copies are made volatile too. A cast that only feeds such a copy (its i8 * operand) is
// no view: a buffer copied whole into a private variable and read from there (WebGPU CTS memory_layout read_layout,
// function and private address spaces) has no other access to keep in order, and a volatile copy into private memory
// lost the array's mat2x2<f16> values (the zero-initialization stores came after it). INTEL_TYPE_PUN_FIX=0 turns it
// off.
static bool sharedPointer(LLVMValueRef v) {
    LLVMTypeRef t = LLVMTypeOf(v);
    if (LLVMGetTypeKind(t) != kTypeKindPointer) return false;
    unsigned space = LLVMGetPointerAddressSpace(t);
    return space == 1 || space == 3;
}
static LLVMValueRef pointerRoot(LLVMValueRef p) {
    for (int depth = 0; depth < 16 && p && (LLVMIsAGetElementPtrInst(p) || LLVMIsABitCastInst(p)); depth++) p = LLVMGetOperand(p, 0);
    return p;
}
static bool copyCall(LLVMValueRef inst) {  // llvm.memcpy / llvm.memmove
    if (!LLVMIsACallInst(inst)) return false;
    const char *name = LLVMGetValueName(LLVMGetCalledValue(inst));
    return name && (!strncmp(name, "llvm.memcpy.", 12) || !strncmp(name, "llvm.memmove.", 13));
}
static bool onlyCopied(LLVMValueRef cast) {  // a cast that is nothing but a memcpy / memmove operand: not a view
    LLVMUseRef u = LLVMGetFirstUse(cast);
    if (!u) return false;
    for (; u; u = LLVMGetNextUse(u))
        if (!copyCall(LLVMGetUser(u))) return false;
    return true;
}
static unsigned volatilizePunnedAccesses(LLVMModuleRef module) {
    if (disabled("INTEL_TYPE_PUN_FIX")) return 0;
    unsigned marked = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (!LLVMGetFirstBasicBlock(f)) continue;
        // casts of one shared pointer to different element types
        std::map<LLVMValueRef, std::vector<LLVMValueRef>> castsOf;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMIsABitCastInst(inst) && sharedPointer(inst) && sharedPointer(LLVMGetOperand(inst, 0)) && !onlyCopied(inst))
                    castsOf[pointerRoot(LLVMGetOperand(inst, 0))].push_back(inst);
        // memcpy / memmove calls and the shared roots they copy to or from
        std::map<LLVMValueRef, std::vector<LLVMValueRef>> copiesOf;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (!LLVMIsACallInst(inst) || LLVMGetNumOperands(inst) < 6) continue;
                const char *name = LLVMGetValueName(LLVMGetCalledValue(inst));
                if (!name || (strncmp(name, "llvm.memcpy.", 12) && strncmp(name, "llvm.memmove.", 13))) continue;
                for (int k = 0; k < 2; k++)
                    if (sharedPointer(LLVMGetOperand(inst, k))) copiesOf[pointerRoot(LLVMGetOperand(inst, k))].push_back(inst);
            }
        std::vector<LLVMValueRef> punned, copies;
        for (auto &entry : castsOf) {
            bool differ = false;
            for (LLVMValueRef c : entry.second)
                differ = differ || LLVMGetElementType(LLVMTypeOf(c)) != LLVMGetElementType(LLVMTypeOf(entry.second[0]));
            auto copied = copiesOf.find(entry.first);
            if (copied != copiesOf.end()) copies.insert(copies.end(), copied->second.begin(), copied->second.end());
            if (differ || copied != copiesOf.end()) punned.insert(punned.end(), entry.second.begin(), entry.second.end());
        }
        if (punned.empty()) continue;
        LLVMValueRef yes = LLVMConstInt(LLVMInt1TypeInContext(LLVMGetModuleContext(module)), 1, false);
        for (LLVMValueRef call : copies) {  // llvm.memcpy(dest, src, length, align, isvolatile)
            if (LLVMGetOperand(call, 4) == yes) continue;
            LLVMSetOperand(call, 4, yes);
            marked++;
        }
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                bool load = LLVMIsALoadInst(inst), store = LLVMIsAStoreInst(inst);
                if (!load && !store) continue;
                bool reached = false;
                for (LLVMValueRef p = LLVMGetOperand(inst, load ? 0 : 1); p && !reached;
                     p = (LLVMIsAGetElementPtrInst(p) || LLVMIsABitCastInst(p)) ? LLVMGetOperand(p, 0) : nullptr)
                    reached = std::find(punned.begin(), punned.end(), p) != punned.end();
                if (!reached) continue;
                LLVMSetVolatile(inst, 1);
                marked++;
            }
    }
    return marked;
}

static unsigned flattenBranchChains(LLVMModuleRef module) {
    if (disabled("INTEL_BRANCH_CHAIN_FIX")) return 0;
    const char *setting = getenv("INTEL_BRANCH_CHAIN_MIN");
    unsigned minimum = setting ? (unsigned)atoi(setting) : 12, rewrites = 0;
    if (const char *move = getenv("INTEL_BRANCH_CHAIN_MOVE")) flatten::maxMoved = atoi(move);
    LLVMBuilderRef b = nullptr;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (!LLVMGetFirstBasicBlock(f) || flatten::conditionalBranches(f) < minimum) continue;
        if (!b) b = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
        LLVMTypeRef i1 = LLVMInt1TypeInContext(LLVMGetModuleContext(module));
        LLVMValueRef yes = LLVMConstInt(i1, 1, false), no = LLVMConstInt(i1, 0, false);
        for (int i = 0; i < flatten::kMaxSteps && flatten::step(b, f, yes, no); i++) rewrites++;
    }
    if (b) LLVMDisposeBuilder(b);
    return rewrites;
}

// ---- halfword vectors viewed as bytes in vertex and fragment functions --------------------------------------------
// as_type<uchar4>(ushort2) and as_type<char4>(short2), a bitcast <2 x i16> -> <4 x i8>, abort the compile of a vertex or
// fragment function (IGILTargetLowering::ReplaceNodeResults in libIGIL-Metal): the compiler service crashes and the
// pipeline fails with "Compiler encountered an internal error". The same cast in a compute function is right, and so are
// the other casts between words and vectors of bytes or halfwords (uint <-> uchar4 / ushort2, uchar4 -> ushort2,
// ushort <-> uchar2). Found by fuzzing fragment functions. In a module with a vertex or fragment function, each such
// bitcast becomes its bytes, put together lane by lane: byte 2k is halfword k truncated, byte 2k + 1 the halfword
// shifted right by 8 (in 32 bits). Runs after the other rewrites, which then see the module as before.
// INTEL_HALFWORD_BYTES_FIX=0 turns it off. Test: i62.
static unsigned splitHalfwordBytes(LLVMModuleRef module) {
    if (disabled("INTEL_HALFWORD_BYTES_FIX")) return 0;
    if (!LLVMGetNamedMetadataNumOperands(module, "air.vertex") && !LLVMGetNamedMetadataNumOperands(module, "air.fragment")) return 0;
    enum { kBitCast = 41 };
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i8 = LLVMIntTypeInContext(context, 8), i32 = LLVMInt32TypeInContext(context);
    std::vector<LLVMValueRef> found;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (LLVMGetInstructionOpcode(inst) != kBitCast) continue;
                LLVMTypeRef to = LLVMTypeOf(inst), from = LLVMTypeOf(LLVMGetOperand(inst, 0));
                if (subwordBits(to) == 8 && subwordBits(from) == 16 && lanes(from) && lanes(to) == 2 * lanes(from)) found.push_back(inst);
            }
    if (found.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(context);
    for (LLVMValueRef inst : found) {
        LLVMPositionBuilderBefore(b, inst);
        LLVMValueRef halves = LLVMGetOperand(inst, 0), bytes = LLVMGetUndef(LLVMTypeOf(inst));
        for (unsigned k = 0; k < lanes(LLVMTypeOf(inst)); k++) {
            LLVMValueRef half = LLVMBuildZExt(b, LLVMBuildExtractElement(b, halves, LLVMConstInt(i32, k / 2, false), ""), i32, "");
            if (k & 1) half = LLVMBuildLShr(b, half, LLVMConstInt(i32, 8, false), "");
            bytes = LLVMBuildInsertElement(b, bytes, LLVMBuildTrunc(b, half, i8, ""), LLVMConstInt(i32, k, false), "");
        }
        LLVMReplaceAllUsesWith(inst, bytes);
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)found.size();
}

// ---- compares of byte and halfword vectors in vertex and fragment functions ----------------------------------------
// In vertex and fragment functions the back end's type legalization of a compare between two <N x i8> (or <N x i16>)
// vectors depends on how each was made: any(uchar4(a, b, c, d) <= as_type<uchar4>(x)) crashed the compiler service
// (SelectionDAG::getZeroExtendInReg), any(as_type<char4>(x) > as_type<char4>(y)) came out wrong, and so did such compares
// of the bytes i62 builds (as_type fragment fuzzing seeds 2 and 15, and the shapes in between). The same compare on
// 32-bit lanes is right, where neither operand is a byte vector built with insertelement: zext of such a vector crashed
// the same way. Each icmp of an i8 / i16 vector is done on <N x i32>: the operands sign-extended for a signed predicate,
// zero-extended otherwise, with extendLanes (lane by lane for vectors put together with insertelement), and other
// operands from their packed word with shifts (signedValue as for i02, unsignedValue): sext of an as_type<char4> gave
// the wrong compare too, and zext of one crashed once a select used it. The result is the same <N x i1>. A per-lane select of byte vectors by such a compare
// crashed the same way even then (select(uchar4(...), uchar4(...), as_type<uchar4>(x) <= ...), seed 15): selects of
// i8 / i16 vectors with a vector condition are done on 32-bit lanes too and truncated back.
// INTEL_NARROW_VECTOR_COMPARE_FIX=0 turns it off.
// Test: i64.
// Arithmetic and bitwise operations on byte vectors crashed in the same legalization (as_type<uchar4>(x) ^
// as_type<uchar4>(y), as_type<char4>(x) | select(...): as_type fragment fuzzing seed 9), so add, sub, mul, shl, lshr,
// ashr, and, or and xor of i8 / i16 vectors are done on 32-bit lanes as well. Each such operation and select gets one
// <N x i32> value whose low bits are its lanes; the operations, selects and compares that use it take that value (masked
// or sign-extended where the high bits matter: the value lshr / ashr shifts, every shift amount, compares), and a trunc
// to the narrow vector serves the other uses. Phis
// of such vectors get a 32-bit phi beside them, so a vector carried around a loop isn't packed and unpacked each time.
// INTEL_NARROW_VECTOR_ARITH_FIX=0 leaves those operations alone. Test: i66.
// The zero-extended lanes of a packed vector of i8 / i16 (16 or 32 bits), from its word: (word >> bits * k) & mask.
static LLVMValueRef unsignedValue(LLVMBuilderRef b, LLVMTypeRef i32, LLVMValueRef x) {
    unsigned bits = subwordBits(LLVMTypeOf(x)), n = lanes(LLVMTypeOf(x));
    LLVMValueRef word = n && n <= 16 ? wordOf(b, i32, x) : nullptr;
    if (!word) return nullptr;
    LLVMTypeRef words = LLVMVectorType(i32, n);
    LLVMValueRef zero[16], right[16], mask[16];
    for (unsigned k = 0; k < n; k++)
        zero[k] = LLVMConstInt(i32, 0, false), right[k] = LLVMConstInt(i32, bits * k, false), mask[k] = LLVMConstInt(i32, (1u << bits) - 1, false);
    LLVMValueRef v = LLVMBuildShuffleVector(b, LLVMBuildInsertElement(b, LLVMGetUndef(words), word, LLVMConstInt(i32, 0, false), ""),
                                            LLVMGetUndef(words), LLVMConstVector(zero, n), "");
    return LLVMBuildAnd(b, LLVMBuildLShr(b, v, LLVMConstVector(right, n), ""), LLVMConstVector(mask, n), "");
}
static unsigned widenNarrowVectorCompares(LLVMModuleRef module) {
    bool compares = !disabled("INTEL_NARROW_VECTOR_COMPARE_FIX"), arithmetic = !disabled("INTEL_NARROW_VECTOR_ARITH_FIX");
    if (!compares && !arithmetic) return 0;
    if (!LLVMGetNamedMetadataNumOperands(module, "air.vertex") && !LLVMGetNamedMetadataNumOperands(module, "air.fragment")) return 0;
    enum { kAdd = 8, kSub = 10, kMul = 12, kShl = 20, kLShr = 21, kAShr = 22, kAnd = 23, kOr = 24, kXor = 25, kICmp = 42, kPHI = 44,
           kSelect = 46, kIntSGT = 38, kIntSLE = 41 };
    LLVMTypeRef i32 = LLVMInt32TypeInContext(LLVMGetModuleContext(module));
    std::vector<LLVMValueRef> found, narrow;  // compares; selects and operations done on 32-bit lanes
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int op = LLVMGetInstructionOpcode(inst);
                bool vector = lanes(LLVMTypeOf(inst)) && subwordBits(LLVMTypeOf(inst));
                if (op == kICmp && compares && lanes(LLVMTypeOf(LLVMGetOperand(inst, 0))) && subwordBits(LLVMTypeOf(LLVMGetOperand(inst, 0))))
                    found.push_back(inst);
                else if (op == kSelect && compares && vector && lanes(LLVMTypeOf(LLVMGetOperand(inst, 0))))
                    narrow.push_back(inst);
                else if (arithmetic && vector && (op == kAdd || op == kSub || op == kMul || (op >= kShl && op <= kXor) || op == kPHI))
                    narrow.push_back(inst);
            }
    if (found.empty() && narrow.empty()) return 0;
    std::set<LLVMValueRef> isNarrow(narrow.begin(), narrow.end());
    std::map<LLVMValueRef, LLVMValueRef> wideOf;  // one of `narrow`, or the trunc that replaced it: its 32-bit lanes
    std::function<LLVMValueRef(LLVMValueRef)> wideValue;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
    // v's lanes as <N x i32> before `at`: kind 0 with any high bits, 1 zero-extended, 2 sign-extended (renderLanes32 for
    // values that aren't one of `narrow`).
    auto operand = [&](LLVMValueRef v, LLVMValueRef at, int kind) -> LLVMValueRef {
        unsigned n = lanes(LLVMTypeOf(v)), bits = subwordBits(LLVMTypeOf(v));
        auto known = wideOf.find(v);
        LLVMValueRef w = known != wideOf.end() ? known->second : isNarrow.count(v) ? wideValue(v) : nullptr;
        LLVMPositionBuilderBefore(b, at);
        if (w && kind == 1) return LLVMBuildAnd(b, w, splat(LLVMConstInt(i32, (1u << bits) - 1, false), n), "");
        if (w && kind == 2) {
            LLVMValueRef s = splat(LLVMConstInt(i32, 32 - bits, false), n);
            return LLVMBuildAShr(b, LLVMBuildShl(b, w, s, ""), s, "");
        }
        if (w) return w;
        return renderLanes32(b, i32, v, kind == 2);
    };
    wideValue = [&](LLVMValueRef inst) -> LLVMValueRef {  // built before `inst`, from its operands' 32-bit lanes
        auto known = wideOf.find(inst);
        if (known != wideOf.end()) return known->second;
        int op = LLVMGetInstructionOpcode(inst);
        LLVMValueRef w;
        if (op == kPHI) {  // its incoming values are added below, once every operation has its 32-bit value
            LLVMPositionBuilderBefore(b, inst);
            return wideOf[inst] = LLVMBuildPhi(b, LLVMVectorType(i32, lanes(LLVMTypeOf(inst))), "");
        }
        if (op == kSelect) {
            LLVMValueRef x = operand(LLVMGetOperand(inst, 1), inst, 0), y = operand(LLVMGetOperand(inst, 2), inst, 0);
            LLVMPositionBuilderBefore(b, inst);
            w = LLVMBuildSelect(b, LLVMGetOperand(inst, 0), x, y, "");
        } else {  // the high bits matter for the value lshr / ashr shift and for every shift amount
            LLVMValueRef x = operand(LLVMGetOperand(inst, 0), inst, op == kLShr ? 1 : op == kAShr ? 2 : 0);
            LLVMValueRef y = operand(LLVMGetOperand(inst, 1), inst, op >= kShl && op <= kAShr ? 1 : 0);
            LLVMPositionBuilderBefore(b, inst);
            w = op == kAdd ? LLVMBuildAdd(b, x, y, "") : op == kSub ? LLVMBuildSub(b, x, y, "") : op == kMul ? LLVMBuildMul(b, x, y, "")
              : op == kShl ? LLVMBuildShl(b, x, y, "") : op == kLShr ? LLVMBuildLShr(b, x, y, "") : op == kAShr ? LLVMBuildAShr(b, x, y, "")
              : op == kAnd ? LLVMBuildAnd(b, x, y, "") : op == kOr ? LLVMBuildOr(b, x, y, "") : LLVMBuildXor(b, x, y, "");
        }
        wideOf[inst] = w;
        return w;
    };
    for (LLVMValueRef inst : narrow) wideValue(inst);
    for (LLVMValueRef inst : narrow) {  // phis: a loop-carried vector goes around the loop as 32-bit lanes
        if (LLVMGetInstructionOpcode(inst) != kPHI) continue;
        LLVMValueRef w = wideOf[inst];
        std::map<LLVMBasicBlockRef, LLVMValueRef> fromBlock;  // a switch with several cases to here: one value per block (i53)
        for (unsigned k = 0, n = LLVMCountIncoming(inst); k < n; k++) {
            LLVMBasicBlockRef from = LLVMGetIncomingBlock(inst, k);
            LLVMValueRef &value = fromBlock[from];
            if (!value) value = operand(LLVMGetIncomingValue(inst, k), LLVMGetBasicBlockTerminator(from), 0);
            LLVMAddIncoming(w, &value, &from, 1);
        }
    }
    for (LLVMValueRef inst : narrow) {  // the narrow vector for the other uses: stores, lane reads, casts, phis
        LLVMValueRef at = inst;
        while (LLVMIsAPHINode(at)) at = LLVMGetNextInstruction(at);  // (after the block's phis)
        LLVMPositionBuilderBefore(b, at);
        LLVMValueRef w = wideOf[inst], t = LLVMBuildTrunc(b, w, LLVMTypeOf(inst), "");
        LLVMReplaceAllUsesWith(inst, t);
        wideOf[t] = w;
    }
    for (LLVMValueRef inst : narrow) {
        wideOf.erase(inst);
        LLVMInstructionEraseFromParent(inst);
    }
    for (LLVMValueRef inst : found) {
        int predicate = LLVMGetICmpPredicate(inst);
        int kind = predicate >= kIntSGT && predicate <= kIntSLE ? 2 : 1;
        LLVMValueRef x = operand(LLVMGetOperand(inst, 0), inst, kind), y = operand(LLVMGetOperand(inst, 1), inst, kind);
        LLVMPositionBuilderBefore(b, inst);
        LLVMReplaceAllUsesWith(inst, LLVMBuildICmp(b, predicate, x, y, ""));
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)(found.size() + narrow.size());
}

// ---- compares of a 0/1 value with 1 in vertex and fragment functions --------------------------------------------------
// if (((x & 1u) & y) != 1u) { ... } in a fragment function took the branch by the wrong pixels: the front end makes it
// icmp eq (and (and x, 1), y), 1 with the targets swapped, and the back end, inverting it, turns the compare of a value
// that can only be 0 or 1 into the value itself, takes the `& 1` out of it as redundant for a 0/1 test, and then tests
// the whole register (IGIL: AND r, x, y; IF_CND.z r). Pixels where x & y has bits above bit 0 set went the wrong way.
// Compares with 0 of the same value are right, and so are selects on it. Found by fuzzing fragment functions (VEC=1
// seed 1248: x = insert_bits(...) & 1, y = mulhi(...); it began as a char2 & (char2(33, 56) & char2) expression that
// the front end folded to scalars). In a module with a vertex or fragment function, each icmp eq / ne of a value that
// can only be 0 or 1 (an and with such an operand, a shift right by all but one bit, zext of a bool, or, xor and select
// of such values) with 1 becomes icmp ne / eq with 0. INTEL_BIT_TEST_COMPARE_FIX=0 turns it off. Test: i68.
static bool zeroOrOne(LLVMValueRef v, int depth = 0) {
    if (LLVMIsAConstantInt(v)) return LLVMConstIntGetZExtValue(v) <= 1;
    if (depth > 8 || !LLVMIsAInstruction(v)) return false;
    enum { kLShr = 21, kAnd = 23, kOr = 24, kXor = 25, kZExt = 31, kSelect = 46 };
    switch (LLVMGetInstructionOpcode(v)) {
    case kAnd: return zeroOrOne(LLVMGetOperand(v, 0), depth + 1) || zeroOrOne(LLVMGetOperand(v, 1), depth + 1);
    case kOr: case kXor: return zeroOrOne(LLVMGetOperand(v, 0), depth + 1) && zeroOrOne(LLVMGetOperand(v, 1), depth + 1);
    case kSelect: return zeroOrOne(LLVMGetOperand(v, 1), depth + 1) && zeroOrOne(LLVMGetOperand(v, 2), depth + 1);
    case kZExt: return LLVMGetTypeKind(LLVMTypeOf(LLVMGetOperand(v, 0))) == kTypeKindInteger && LLVMGetIntTypeWidth(LLVMTypeOf(LLVMGetOperand(v, 0))) == 1;
    case kLShr: {
        LLVMValueRef amount = LLVMGetOperand(v, 1);
        return LLVMIsAConstantInt(amount) && LLVMConstIntGetZExtValue(amount) == LLVMGetIntTypeWidth(LLVMTypeOf(v)) - 1;
    }
    default: return false;
    }
}
static unsigned bitTestCompares(LLVMModuleRef module) {
    if (disabled("INTEL_BIT_TEST_COMPARE_FIX")) return 0;
    if (!LLVMGetNamedMetadataNumOperands(module, "air.vertex") && !LLVMGetNamedMetadataNumOperands(module, "air.fragment")) return 0;
    enum { kICmp = 42, kIntEQ = 32, kIntNE = 33 };
    std::vector<LLVMValueRef> found;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (LLVMGetInstructionOpcode(inst) != kICmp || LLVMGetTypeKind(LLVMTypeOf(LLVMGetOperand(inst, 0))) != kTypeKindInteger) continue;
                int predicate = LLVMGetICmpPredicate(inst);
                LLVMValueRef one = LLVMGetOperand(inst, 1);
                if ((predicate == kIntEQ || predicate == kIntNE) && LLVMIsAConstantInt(one) && LLVMConstIntGetZExtValue(one) == 1 &&
                    !LLVMIsAConstant(LLVMGetOperand(inst, 0)) && zeroOrOne(LLVMGetOperand(inst, 0)))
                    found.push_back(inst);
            }
    if (found.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
    for (LLVMValueRef inst : found) {
        LLVMPositionBuilderBefore(b, inst);
        LLVMValueRef v = LLVMGetOperand(inst, 0);
        LLVMReplaceAllUsesWith(inst, LLVMBuildICmp(b, LLVMGetICmpPredicate(inst) == kIntEQ ? kIntNE : kIntEQ, v, LLVMConstNull(LLVMTypeOf(v)), ""));
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)found.size();
}

// ---- 64-bit division and variable shifts in vertex and fragment functions ---------------------------------------------
// 64-bit udiv / sdiv / urem / srem, and shifts of an i64 by an amount that isn't a constant, crash the compiler service
// in a vertex or fragment function (((ulong)x << 32 | y) / (ulong)(x | 1u), (long)a / (long)(int)b, a >> (y & 63u)):
// the pipeline fails with "Compiler encountered an internal error". The same operations in a compute function are
// right, and so are 64-bit add, mul (i27), compares and shifts by a constant. Found by fuzzing fragment functions with
// 64-bit values, where every seed crashed. In a module with a vertex or fragment function, outside functions that only
// kernels call, each is done on the 32-bit halves of its operands (of each lane, for vectors): a shift by s & 63 as
// 32-bit shifts and a select on s & 32; a division as 64 shift-and-subtract steps in a loop (the shifted remainder kept
// in 65 bits, so divisors above 2^63 are right), giving the quotient and the remainder, for sdiv / srem on the
// magnitudes with the sign put back. Division by zero, undefined in MSL, gives all ones and the dividend.
// INTEL_RENDER_INT64_FIX=0 turns it off. Test: i67.
extern "C" {
LLVMBasicBlockRef LLVMAppendBasicBlockInContext(LLVMContextRef, LLVMValueRef, const char *);
void LLVMMoveBasicBlockAfter(LLVMBasicBlockRef, LLVMBasicBlockRef);
}
namespace int64 {
enum { kUDiv = 14, kSDiv = 15, kURem = 17, kSRem = 18, kShl = 20, kLShr = 21, kAShr = 22,
       kIntEQ = 32, kIntNE = 33, kIntUGT = 34, kIntUGE = 35, kIntULT = 36 };
struct Halves { LLVMValueRef lo, hi; };  // i32, or <N x i32> for <N x i64>

struct Builder {
    LLVMBuilderRef b;
    LLVMContextRef context;
    LLVMTypeRef i32, i64, type;  // type: i32 or <N x i32>
    unsigned n;
    LLVMValueRef c(unsigned v) { return splat(LLVMConstInt(i32, v, false), n); }
    LLVMValueRef shl(LLVMValueRef x, LLVMValueRef y) { return LLVMBuildShl(b, x, y, ""); }
    LLVMValueRef lshr(LLVMValueRef x, LLVMValueRef y) { return LLVMBuildLShr(b, x, y, ""); }
    LLVMValueRef ashr(LLVMValueRef x, LLVMValueRef y) { return LLVMBuildAShr(b, x, y, ""); }
    LLVMValueRef bitOr(LLVMValueRef x, LLVMValueRef y) { return LLVMBuildOr(b, x, y, ""); }
    LLVMValueRef bitXor(LLVMValueRef x, LLVMValueRef y) { return LLVMBuildXor(b, x, y, ""); }
    LLVMValueRef cmp(int predicate, LLVMValueRef x, LLVMValueRef y) { return LLVMBuildICmp(b, predicate, x, y, ""); }
    LLVMValueRef sel(LLVMValueRef c, LLVMValueRef x, LLVMValueRef y) { return LLVMBuildSelect(b, c, x, y, ""); }
    LLVMValueRef bit(LLVMValueRef condition) { return LLVMBuildZExt(b, condition, type, ""); }

    Halves split(LLVMValueRef v) {  // v: i64 or <N x i64>
        auto one = [&](LLVMValueRef s) -> Halves {
            return {LLVMBuildTrunc(b, s, i32, ""), LLVMBuildTrunc(b, LLVMBuildLShr(b, s, LLVMConstInt(i64, 32, false), ""), i32, "")};
        };
        if (!n) return one(v);
        Halves h = {LLVMGetUndef(type), LLVMGetUndef(type)};
        for (unsigned k = 0; k < n; k++) {
            LLVMValueRef index = LLVMConstInt(i32, k, false);
            Halves lane = one(LLVMBuildExtractElement(b, v, index, ""));
            h.lo = LLVMBuildInsertElement(b, h.lo, lane.lo, index, "");
            h.hi = LLVMBuildInsertElement(b, h.hi, lane.hi, index, "");
        }
        return h;
    }
    LLVMValueRef join(Halves h, LLVMTypeRef wide) {
        auto one = [&](LLVMValueRef lo, LLVMValueRef hi) {
            return LLVMBuildOr(b, LLVMBuildZExt(b, lo, i64, ""), LLVMBuildShl(b, LLVMBuildZExt(b, hi, i64, ""), LLVMConstInt(i64, 32, false), ""), "");
        };
        if (!n) return one(h.lo, h.hi);
        LLVMValueRef v = LLVMGetUndef(wide);
        for (unsigned k = 0; k < n; k++) {
            LLVMValueRef index = LLVMConstInt(i32, k, false);
            v = LLVMBuildInsertElement(b, v, one(LLVMBuildExtractElement(b, h.lo, index, ""), LLVMBuildExtractElement(b, h.hi, index, "")), index, "");
        }
        return v;
    }
    Halves add(Halves x, Halves y) {
        LLVMValueRef lo = LLVMBuildAdd(b, x.lo, y.lo, "");
        return {lo, LLVMBuildAdd(b, LLVMBuildAdd(b, x.hi, y.hi, ""), bit(cmp(kIntULT, lo, x.lo)), "")};
    }
    Halves negatedWhere(Halves x, LLVMValueRef mask) {  // mask: 0 or ~0 in each lane; ~x + 1 where it is ~0
        return add({bitXor(x.lo, mask), bitXor(x.hi, mask)}, {LLVMBuildAnd(b, mask, c(1), ""), c(0)});
    }
    Halves shifted(int op, Halves x, LLVMValueRef amount) {  // amount: the low half of the shift amount
        LLVMValueRef t = LLVMBuildAnd(b, amount, c(31), ""), back = LLVMBuildSub(b, c(31), t, "");
        LLVMValueRef far = cmp(kIntNE, LLVMBuildAnd(b, amount, c(32), ""), c(0));  // by 32..63
        if (op == kShl) {  // the bits moved up from lo: (lo >> 1) >> (31 - t), which is 0 for t = 0
            LLVMValueRef lo = shl(x.lo, t), hi = bitOr(shl(x.hi, t), lshr(lshr(x.lo, c(1)), back));
            return {sel(far, c(0), lo), sel(far, lo, hi)};
        }
        LLVMValueRef lo = bitOr(lshr(x.lo, t), shl(shl(x.hi, c(1)), back));
        LLVMValueRef hi = op == kAShr ? ashr(x.hi, t) : lshr(x.hi, t), fill = op == kAShr ? ashr(x.hi, c(31)) : c(0);
        return {sel(far, hi, lo), sel(far, fill, hi)};
    }
    // x / y and x % y by 64 shift-and-subtract steps, in a loop between the end of `bb` (left without a terminator)
    // and `tail`
    void divide(LLVMBasicBlockRef bb, LLVMBasicBlockRef tail, Halves x, Halves y, Halves &q, Halves &r) {
        LLVMBasicBlockRef loop = LLVMAppendBasicBlockInContext(context, LLVMGetBasicBlockParent(bb), "");
        LLVMMoveBasicBlockAfter(loop, bb);
        LLVMPositionBuilderAtEnd(b, bb);
        LLVMBuildBr(b, loop);
        LLVMPositionBuilderAtEnd(b, loop);
        LLVMValueRef step = LLVMBuildPhi(b, i32, ""), xl = LLVMBuildPhi(b, type, ""), xh = LLVMBuildPhi(b, type, "");
        LLVMValueRef rl = LLVMBuildPhi(b, type, ""), rh = LLVMBuildPhi(b, type, ""), ql = LLVMBuildPhi(b, type, ""), qh = LLVMBuildPhi(b, type, "");
        LLVMValueRef top = cmp(kIntNE, lshr(rh, c(31)), c(0));  // bit 64 of 2r + (next bit of x)
        LLVMValueRef sh = bitOr(shl(rh, c(1)), lshr(rl, c(31))), sl = bitOr(shl(rl, c(1)), lshr(xh, c(31)));
        LLVMValueRef fits = bitOr(top, bitOr(cmp(kIntUGT, sh, y.hi), LLVMBuildAnd(b, cmp(kIntEQ, sh, y.hi), cmp(kIntUGE, sl, y.lo), "")));
        LLVMValueRef dl = LLVMBuildSub(b, sl, y.lo, ""), dh = LLVMBuildSub(b, LLVMBuildSub(b, sh, y.hi, ""), bit(cmp(kIntULT, sl, y.lo)), "");
        LLVMValueRef rl2 = sel(fits, dl, sl), rh2 = sel(fits, dh, sh);
        LLVMValueRef ql2 = bitOr(shl(ql, c(1)), bit(fits)), qh2 = bitOr(shl(qh, c(1)), lshr(ql, c(31)));
        LLVMValueRef xl2 = shl(xl, c(1)), xh2 = bitOr(shl(xh, c(1)), lshr(xl, c(31)));
        LLVMValueRef next = LLVMBuildAdd(b, step, LLVMConstInt(i32, 1, false), "");
        LLVMBuildCondBr(b, LLVMBuildICmp(b, kIntEQ, next, LLVMConstInt(i32, 64, false), ""), tail, loop);
        LLVMBasicBlockRef from[2] = {bb, loop};
        auto incoming = [&](LLVMValueRef phi, LLVMValueRef first, LLVMValueRef again) {
            LLVMValueRef values[2] = {first, again};
            LLVMAddIncoming(phi, values, from, 2);
        };
        incoming(step, LLVMConstInt(i32, 0, false), next);
        incoming(xl, x.lo, xl2), incoming(xh, x.hi, xh2);
        incoming(rl, c(0), rl2), incoming(rh, c(0), rh2), incoming(ql, c(0), ql2), incoming(qh, c(0), qh2);
        q = {ql2, qh2}, r = {rl2, rh2};
    }
};

// Moves `inst` and everything after it in its block into a new block right after it (the successors' phis follow);
// the block is left without a terminator.
static LLVMBasicBlockRef splitAt(LLVMBuilderRef b, LLVMContextRef context, LLVMValueRef inst) {
    LLVMBasicBlockRef bb = LLVMGetInstructionParent(inst);
    LLVMBasicBlockRef tail = LLVMAppendBasicBlockInContext(context, LLVMGetBasicBlockParent(bb), "");
    LLVMMoveBasicBlockAfter(tail, bb);
    for (LLVMValueRef v = inst, next; v; v = next) {
        next = LLVMGetNextInstruction(v);
        LLVMInstructionRemoveFromParent(v);
        LLVMPositionBuilderAtEnd(b, tail);
        LLVMInsertIntoBuilder(b, v);
    }
    LLVMValueRef term = LLVMGetBasicBlockTerminator(tail);
    for (unsigned i = 0, n = term ? LLVMGetNumSuccessors(term) : 0; i < n; i++)
        flatten::retargetPhis(b, LLVMGetSuccessor(term, i), bb, tail, [](LLVMValueRef, LLVMValueRef to, LLVMValueRef) { return to; });
    return tail;
}
}  // namespace int64

static unsigned expandRenderInt64(LLVMModuleRef module) {
    using namespace int64;
    if (disabled("INTEL_RENDER_INT64_FIX")) return 0;
    if (!LLVMGetNamedMetadataNumOperands(module, "air.vertex") && !LLVMGetNamedMetadataNumOperands(module, "air.fragment")) return 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    std::vector<LLVMValueRef> found;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (!LLVMGetFirstBasicBlock(f) || kernelOnly(module, f)) continue;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                int op = LLVMGetInstructionOpcode(inst);
                LLVMTypeRef scalar = scalarOf(LLVMTypeOf(inst));
                if (LLVMGetTypeKind(scalar) != kTypeKindInteger || LLVMGetIntTypeWidth(scalar) != 64) continue;
                if (op == kUDiv || op == kSDiv || op == kURem || op == kSRem ||
                    (op >= kShl && op <= kAShr && !LLVMIsAConstant(LLVMGetOperand(inst, 1))))
                    found.push_back(inst);
            }
    }
    if (found.empty()) return 0;
    Builder g;
    g.b = LLVMCreateBuilderInContext(context), g.context = context;
    g.i32 = LLVMInt32TypeInContext(context), g.i64 = LLVMInt64TypeInContext(context);
    for (LLVMValueRef inst : found) {
        int op = LLVMGetInstructionOpcode(inst);
        LLVMTypeRef wide = LLVMTypeOf(inst);
        g.n = lanes(wide), g.type = shaped(g.i32, g.n);
        LLVMPositionBuilderBefore(g.b, inst);
        Halves x = g.split(LLVMGetOperand(inst, 0)), y = g.split(LLVMGetOperand(inst, 1)), result;
        if (op >= kShl && op <= kAShr) {
            result = g.shifted(op, x, y.lo);
        } else {
            bool sign = op == kSDiv || op == kSRem;
            LLVMValueRef sx = sign ? g.ashr(x.hi, g.c(31)) : nullptr, sy = sign ? g.ashr(y.hi, g.c(31)) : nullptr;
            if (sign) x = g.negatedWhere(x, sx), y = g.negatedWhere(y, sy);
            LLVMBasicBlockRef bb = LLVMGetInstructionParent(inst), tail = splitAt(g.b, context, inst);
            Halves q, r;
            g.divide(bb, tail, x, y, q, r);
            LLVMPositionBuilderBefore(g.b, inst);
            result = op == kUDiv ? q : op == kURem ? r : op == kSDiv ? g.negatedWhere(q, g.bitXor(sx, sy)) : g.negatedWhere(r, sx);
        }
        LLVMReplaceAllUsesWith(inst, g.join(result, wide));
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(g.b);
    return (unsigned)found.size();
}

// ---- SIMD16 pixel kernels with a clobbered value ---------------------------------------------------------------------
// The plugin has the GL driver's back end, iCBE, turn each fragment function into EU code: a SIMD8 and a SIMD16 kernel,
// the hardware dispatching SIMD16 for full pixel groups. Under the SIMD16 kernel's higher register pressure, iCBE's
// register allocator can give a compare whose result is only used through the flag (cmp.nz.f0.0 gN, x, 0 before a
// predicated sel) a register that still holds a live value; the compare overwrites it and the value's later read gets
// 0/-1. dEQP's uniformbuffers multi_nested_struct instance_array_mixed (ANGLE): the SIMD16 kernel builds a bool in g6
// (mov 0; (+f0.0) mov 1), a cmp.nz then takes g6 as its destination, and the last check reads g6: wrong in every SIMD16
// dispatch (236 of 256 pixels), right in SIMD8 ones; one comparison fewer, and the pressure and the bug were gone.
// So iCBE's CompilePixelShaderOpenGL is wrapped: after a compile, gen7eu::findCompareClobber looks for that in the SIMD16
// kernel (a flag-writing instruction overwriting a value nothing has read yet, read again afterwards; optimized code
// leaves no such dead stores), and if it's there the shader is compiled again with SIMD level 1, SIMD8 only (iCBE's
// kernel program then builds no SIMD16 kernel). INTEL_SIMD16_CLOBBER_FIX=0 turns it off; INTEL_SIMD8_PIXEL=1 asks for
// SIMD8 only for every fragment function (testing). Haswell's iCBE only (the Ivy Bridge plugin's is not looked at).
// The C export: (compiler, platform index, ?, OPTIMIZER_LEVEL, SIMD_LEVEL, input state, ?, AIR::SCompilerOutputPixelShader
// **, PLATFORM_STR *); it fills the caller's output block, which holds the SIMD8/16/32 kernel pointers at 0x47fb and their
// sizes (uint32) at 0x4813.
typedef long (*CompilePixelShaderFn)(void *, int, void *, int, int, void *, void *, void *, void *);
static CompilePixelShaderFn originalCompilePixelShader;
static const char *const kICBEPaths[] = {
    "/Library/GPUBundles/AppleIntelHD5000GraphicsGLDriver.bundle/Contents/MacOS/iCBE.dylib",  // the plugin's order
    "/System/Library/Extensions/AppleIntelHD5000GraphicsGLDriver.bundle/Contents/MacOS/iCBE.dylib",
};
// INTELTEX_DUMP_KERNELS=<dir> (debugging): each pixel shader compile's SIMD8 and SIMD16 kernels as
// ps-<pid>-<n>[-clobbered]-simd8/16.bin, their first constant register as ps-<pid>-<n>.info and the IGIL text they came
// from as ps-<pid>-<n>.igil.
static void dumpPixelKernels(void *output, const char *tag) {
    const char *dir = getenv("INTELTEX_DUMP_KERNELS");
    const uint8_t *block = output ? *(uint8_t **)output : nullptr;
    if (!dir || !block) return;
    static std::atomic<int> serial;
    int n = serial++;
    char path[1024];
    for (int k = 0; k < 2; k++) {
        const uint8_t *kernel = nullptr;
        uint32_t size = 0;
        memcpy(&kernel, block + 0x47fb + 8 * k, sizeof kernel);
        memcpy(&size, block + 0x4813 + 4 * k, sizeof size);
        if (!kernel || !size || size > (1u << 20)) continue;
        snprintf(path, sizeof path, "%s/ps-%d-%04d%s-simd%d.bin", dir, getpid(), n, tag, k ? 16 : 8);
        if (FILE *f = fopen(path, "wb")) { fwrite(kernel, 1, size, f); fclose(f); }
    }
    uint32_t start8 = 0, start16 = 0;  // the kernels' first constant/setup register (3DSTATE_PS dispatch GRF start)
    memcpy(&start8, block + 0x481f, 4);
    memcpy(&start16, block + 0x4823, 4);
    snprintf(path, sizeof path, "%s/ps-%d-%04d%s.info", dir, getpid(), n, tag);
    if (FILE *f = fopen(path, "w")) { fprintf(f, "start8 %u start16 %u\n", start8, start16); fclose(f); }
    snprintf(path, sizeof path, "%s/ps-%d-%04d%s.igil", dir, getpid(), n, tag);
    if (!lastIGILForDump.empty())
        if (FILE *f = fopen(path, "w")) { fputs(lastIGILForDump.c_str(), f); fclose(f); }
}

static long hookedCompilePixelShader(void *compiler, int platform, void *a3, int optimizer, int simd, void *input, void *a7,
                                     void *output, void *platformInfo) {
    if (getenv("INTEL_SIMD8_PIXEL") && !disabled("INTEL_SIMD8_PIXEL")) simd = 1;
    long result = originalCompilePixelShader(compiler, platform, a3, optimizer, simd, input, a7, output, platformInfo);
    if (!result || simd == 1 || !output || disabled("INTEL_SIMD16_CLOBBER_FIX")) return dumpPixelKernels(output, ""), result;
    const uint8_t *block = *(uint8_t **)output, *kernel16 = nullptr;
    uint32_t size16 = 0;
    if (!block) return result;
    memcpy(&kernel16, block + 0x4803, sizeof kernel16);
    memcpy(&size16, block + 0x4817, sizeof size16);
    if (!kernel16 || !size16 || size16 > (1u << 20)) return result;
    gen7eu::Clobber c;
    int found = gen7eu::findCompareClobber(kernel16, size16, &c);
    if (found < 0) {
        if (logging()) fprintf(stderr, "[inteltex] SIMD16 pixel kernel (%u bytes): %s\n", size16, found == -1 ? "no clobber" : "not followed");
        dumpPixelKernels(output, "");
        return result;
    }
    if (logging()) fprintf(stderr, "[inteltex] SIMD16 pixel kernel: #%d overwrites #%d's value, which #%d reads: SIMD8 only\n",
                           c.clobber, c.writer, c.reader);
    dumpPixelKernels(output, "-clobbered");
    long again = originalCompilePixelShader(compiler, platform, a3, optimizer, 1, input, a7, output, platformInfo);
    if (again) return dumpPixelKernels(output, ""), again;
    return originalCompilePixelShader(compiler, platform, a3, optimizer, simd, input, a7, output, platformInfo);  // as before
}
static void installICBEHook() {
    static bool done;
    if (done || ivyBridgePlugin) return;
    done = true;
    void *h = nullptr;
    for (const char *path : kICBEPaths) if ((h = dlopen(path, RTLD_NOLOAD | RTLD_LAZY))) break;
    for (const char *path : kICBEPaths) if (!h && (h = dlopen(path, RTLD_LAZY))) break;  // the plugin loads it on demand
    unsigned char *entry = h ? (unsigned char *)dlsym(h, "CompilePixelShaderOpenGL") : nullptr;
    if (entry) originalCompilePixelShader = (CompilePixelShaderFn)hookFunction(entry, (void *)hookedCompilePixelShader);
    if (logging()) fprintf(stderr, "[inteltex] iCBE CompilePixelShaderOpenGL %s\n", originalCompilePixelShader ? "hooked" : "NOT hooked");
}

// ---- loops that never exit -------------------------------------------------------------------------------------------
// A block whose only instruction branches back to itself is a loop that can never exit or do anything; LLVM leaves one
// where a loop can't advance for the function constants it was specialized with (MPS's reduce_multiple_passes_axes_*
// kernels, entered when a stride is 0). The IGIL back end compiles most of them, but nested in MPSGraph's outer-axis
// reductions (reductionMaximum / softMax over axis 0) its compile never finishes (USC::CompileComputeShaderOpenCL_Gen7
// spins), the stock compiler too, and the app waits forever. A thread that reached such a loop would hang the GPU, so
// it returns instead: nothing a finishing thread does changes. INTEL_INFINITE_LOOP_FIX=0 leaves them.
extern "C" {
LLVMValueRef LLVMBuildRetVoid(LLVMBuilderRef);
LLVMValueRef LLVMBuildRet(LLVMBuilderRef, LLVMValueRef);
LLVMTypeRef LLVMGetReturnType(LLVMTypeRef);
}
enum { kOpcodeBr = 2, kTypeKindVoid = 0 };
static unsigned returnFromEndlessLoops(LLVMModuleRef module) {
    if (disabled("INTEL_INFINITE_LOOP_FIX")) return 0;
    unsigned n = 0;
    LLVMBuilderRef builder = nullptr;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (LLVMIsDeclaration(f)) continue;
        LLVMTypeRef result = LLVMGetReturnType(LLVMGetElementType(LLVMTypeOf(f)));
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb)) {
            LLVMValueRef branch = LLVMGetBasicBlockTerminator(bb);
            if (!branch || LLVMGetFirstInstruction(bb) != branch || LLVMGetInstructionOpcode(branch) != kOpcodeBr || LLVMIsConditional(branch) ||
                LLVMGetNumSuccessors(branch) != 1 || LLVMGetSuccessor(branch, 0) != bb)
                continue;
            if (!builder) builder = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
            LLVMPositionBuilderBefore(builder, branch);
            if (LLVMGetTypeKind(result) == kTypeKindVoid) LLVMBuildRetVoid(builder);
            else LLVMBuildRet(builder, LLVMGetUndef(result));
            LLVMInstructionEraseFromParent(branch);
            n++;
        }
    }
    if (builder) LLVMDisposeBuilder(builder);
    return n;
}

static int hookedRun(void *self, LLVMModuleRef module) {
    pthread_mutex_lock(&installLock);
    installIntoPlugin(false);  // test process: the plugin was dlopened after we were inserted
    installICBEHook();
    bool ready = textFixInstalled && resolveIGIL();
    pthread_mutex_unlock(&installLock);
    if (module && getenv("INTELTEX_DUMP_INPUT")) {  // debugging: every module as it reaches the pass manager
        static int serial;
        char path[1024];
        snprintf(path, sizeof path, "%s/input-%d-%d.ll", getenv("INTELTEX_DUMP_INPUT"), getpid(), serial++);  // services run in parallel
        if (FILE *f = fopen(path, "w")) { char *text = LLVMPrintModuleToString(module); fputs(text, f); LLVMDisposeMessage(text); fclose(f); }
    }
    if (module) {
        unsigned n = dropMaxWorkGroupSize(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u air.max_work_group_size attribute(s) dropped\n", n);
        n = returnFromEndlessLoops(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u loop(s) that never exit made returns\n", n);
        n = dropArrayStructInfo(module);
        if (n && logging()) fprintf(stderr, "[inteltex] struct info dropped from %u array-of-struct argument(s)\n", n);
        n = fixEscapedHandleLoads(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u texture/sampler load(s) through escaped pointers re-indexed into the argument\n", n);
        n = fixVertexSignedSubwords(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u signed i8/i16 conversion(s) in a vertex function done on the 32-bit word\n", n);
        n = dropSampleCompareBias(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u depth comparison(s) with an LOD bias: bias dropped\n", n);
        n = lowerIntegerGradients(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u integer gradient sample(s) done at the level the gradients select\n", n);
        n = widenNarrowDivisions(module);  // before signedDivisionNegations, which then sees the 32-bit divides
        if (n && logging()) fprintf(stderr, "[inteltex] %u 8/16-bit division(s) done on 32-bit lanes\n", n);
        n = signedDivisionNegations(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u signed division(s) of a negated value done on the value\n", n);
        n = selectWideDivisionLanes(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u vector lane(s) picked by a 64-bit quotient done with selects\n", n);
        n = signedPowerOfTwoDivisions(module);  // after the two division rewrites above
        if (n && logging()) fprintf(stderr, "[inteltex] %u signed division(s) by a power of two done with shifts\n", n);
        n = foldConstantCalls(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u integer function call(s) of constants folded\n", n);
        n = widenNarrowMinMax(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u 8/16-bit min / max / clamp call(s) done on 32-bit lanes\n", n);
        n = foldConstantSaturation(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u addsat / subsat of constants folded\n", n);
        n = expandSaturation(module);  // after the fold: what's left may still become constant in the plugin's passes
        if (n && logging()) fprintf(stderr, "[inteltex] %u 32-bit addsat / signed subsat written out as add, compares and selects\n", n);
        n = exactMadSat(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u madsat / mulhi / madhi call(s) done with 32-bit operations\n", n);
        n = exact64BitMultiplies(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u 64-bit multiply / mulhi / madhi call(s) built from 32-bit limbs\n", n);
        n = linearCubeGathers(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u cube gather(s) given a linear constexpr sampler (seamless at face edges)\n", n);
        n = greenGathers(module);  // before foldIntegerSampleOffsets, which then fixes the offsets of both gathers
        if (n && logging()) fprintf(stderr, "[inteltex] %u green gather(s) checked against a red one, sampled where the two agree\n", n);
        n = foldIntegerSampleOffsets(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u integer texture sample(s): texel offset moved into the coordinates\n", n);
        n = fixSamplerStateWords(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u constexpr sampler(s) in the [2 x i64] form rewritten as i64\n", n);
        n = remapComputeLevels(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u explicit level(s) in a compute kernel remapped for the sampler's mip blend\n", n);
        n = widenThreadgroupBools(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u threadgroup bool(s) widened to i8\n", n);
        n = wordPrivateSubwords(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u aligned byte/halfword access(es) to private memory done on the 32-bit word\n", n);
        n = fixFloat3Inputs(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u float3 vertex/fragment input(s) read through fmax\n", n);
        n = foldNumSamples(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u get_num_samples() call(s) replaced by the pipeline's sample count\n", n);
        n = splitPrivatePointerSelects(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u load(s)/store(s) through a select of private pointers split per pointer\n", n);
        n = widenNarrowPrivateArrays(module);  // before selectPrivateArrayIndices, which then rewrites the i32 arrays
        if (n && logging()) fprintf(stderr, "[inteltex] %u private array(s) of bytes / halfwords done on 32-bit words\n", n);
        n = selectPrivateArrayIndices(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u variable-index private array access(es) done at constant indices\n", n);
        n = volatilizePunnedAccesses(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u access(es) to a buffer viewed as different types made volatile\n", n);
        unsigned flattened = flattenBranchChains(module);
        if (flattened && logging()) fprintf(stderr, "[inteltex] %u short branch(es) folded into selects\n", flattened);
        n = selectBufferIndices(module);  // after flattenBranchChains, whose selects can pick pointers
        if (n && logging()) fprintf(stderr, "[inteltex] %u select(s) of pointers into one buffer turned into a selected index\n", n);
        n = bitTestCompares(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u compare(s) of a 0/1 value with 1 in a vertex/fragment module done as a compare with 0\n", n);
        n = expandRenderInt64(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u 64-bit division(s) / variable shift(s) in a vertex/fragment function done on 32-bit halves\n", n);
        n = widenNarrowVectorCompares(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u compare(s), select(s) and operation(s) on byte / halfword vectors in a vertex/fragment module done on 32-bit lanes\n", n);
        n = splitHalfwordBytes(module);  // last: the rewrites above see the module as before
        if (n && logging()) fprintf(stderr, "[inteltex] %u bitcast(s) of halfwords to bytes in a vertex/fragment module done lane by lane\n", n);
        if (getenv("INTELTEX_DUMP_REWRITTEN")) {  // debugging: every module after these rewrites
            static int serial;
            char path[1024];
            snprintf(path, sizeof path, "%s/rewritten-%d-%d.ll", getenv("INTELTEX_DUMP_REWRITTEN"), getpid(), serial++);
            if (FILE *f = fopen(path, "w")) { char *text = LLVMPrintModuleToString(module); fputs(text, f); LLVMDisposeMessage(text); fclose(f); }
        }
    }
    if (module && ready) {
        unsigned n = lowerTextureAtomics(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u texture atomic call(s) lowered\n", n);
        for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
            const char *name = LLVMGetValueName(f);
            if (!strstr(name, "air.atomic_") || !strstr(name, "_texture_") || !LLVMGetFirstUse(f)) continue;
            char *type = LLVMPrintTypeToString(LLVMTypeOf(f));
            fprintf(stderr, "[inteltex] not lowered: %s %s\n", name, type);  // the compile fails
            LLVMDisposeMessage(type);
        }
        if (n && getenv("INTELTEX_DUMP")) {  // debugging: the lowered module
            static int serial;
            char path[1024];
            snprintf(path, sizeof path, "%s/lowered-%d.ll", getenv("INTELTEX_DUMP"), serial++);
            if (FILE *f = fopen(path, "w")) { char *text = LLVMPrintModuleToString(module); fputs(text, f); LLVMDisposeMessage(text); fclose(f); }
        }
    }
    int result = passManagerRun(self, module);
    if (unsigned n = uniformMisses.exchange(0); n && logging())
        fprintf(stderr, "[inteltex] uniformity analysis: %u dependency read(s) of an instruction it had not reached\n", n);
    return result;
}

__attribute__((constructor)) static void installFromConstructor() {
    if (const char *log = getenv("INTELTEX_LOG"); log && log[0] == '/') freopen(log, "a", stderr);
    installIntoPlugin(true);
}

#ifdef INTELTEX_INTERPOSE  // test build for DYLD_INSERT_LIBRARIES
__attribute__((used, section("__DATA,__interpose"))) static struct { void *replacement, *original; } interposers[] = {
    {(void *)hookedRun, (void *)passManagerRun},
};
#endif
