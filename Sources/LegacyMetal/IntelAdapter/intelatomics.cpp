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
// small private arrays done at constant indices (the back end addresses such arrays two incompatible ways).
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
#include <map>
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

// Inline hook: entry -> replacement; returns a trampoline that runs the relocated prologue and continues.
static void *hookFunction(unsigned char *entry, void *replacement) {
    if (memcmp(entry, kPrologue, sizeof kPrologue)) return nullptr;
    unsigned char *stub = (unsigned char *)mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (stub == MAP_FAILED) return nullptr;
    static const unsigned char jump[] = {0xff, 0xe0};  // jmp rax
    unsigned char *p = emit(stub, entry, sizeof kPrologue);
    p = emitMovRax(p, entry + sizeof kPrologue);
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

// The back-end hooks, once libIGIL-Metal is loaded (the plugin loads it on demand).
static bool installIntoBackEnd(void *igil) {
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

// Texel offsets on integer textures: into the coordinates.
static unsigned foldIntegerSampleOffsets(LLVMModuleRef module) {
    if (disabled("INTEL_INTEGER_OFFSET_FIX")) return 0;
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
        {"air.sample_texture_2d_grad.", "texture_2d", 2, 2, 6, 1},              // tex, sampler, coord, dPdx, dPdy, i1, offset, i32
        {"air.sample_texture_2d_array_grad.", "texture_2d_array", 2, 2, 7, 1},  // ..., coord, i32 layer, dPdx, dPdy, i1, offset, i32
        {"air.sample_texture_3d_grad.", "texture_3d", 3, 2, 6, 1},
    };
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (!integerResult(name, strlen(name))) continue;
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
        if (!type || LLVMGetTypeKind(type) != kArrayKind || LLVMGetArrayLength(type) != 2 || LLVMGetElementType(type) != i64 ||
            !LLVMIsAConstantDataArray(words))
            continue;
        uint64_t first = LLVMConstIntGetZExtValue(LLVMGetElementAsConstant(words, 0));
        uint64_t second = LLVMConstIntGetZExtValue(LLVMGetElementAsConstant(words, 1));
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
// textures or samplers are left alone (the back end can't pick a handle with a select). INTEL_PRIVATE_ARRAY_FIX=0 turns
// it off.
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

static unsigned selectPrivateArrayIndices(LLVMModuleRef module) {
    const char *setting = getenv("INTEL_PRIVATE_ARRAY_FIX");
    if (setting && !strcmp(setting, "0")) return 0;
    enum { kArrayKind = 11, kStructKind = 10, kPointerKind = 12, kIntEQ = 32, kMaxElements = 16 };
    std::vector<LLVMValueRef> geps;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMIsAGetElementPtrInst(inst) && allocaBase(LLVMGetOperand(inst, 0))) geps.push_back(inst);
    LLVMBuilderRef b = nullptr;
    unsigned fixed = 0;
    for (LLVMValueRef gep : geps) {
        int n = LLVMGetNumOperands(gep);  // pointer, indices
        int dynamic = -1;
        bool usable = true;
        for (int i = 1; i < n && usable; i++)
            if (!LLVMIsAConstantInt(LLVMGetOperand(gep, i))) usable = dynamic < 0, dynamic = i;
        if (!usable || dynamic < 2) continue;  // exactly one variable index, and not the first (pointer-step) one
        // the type the variable index steps through: walk the pointee type with the indices before it
        LLVMTypeRef t = LLVMGetElementType(LLVMTypeOf(LLVMGetOperand(gep, 0)));
        for (int i = 2; i < dynamic && t; i++) {
            if (LLVMGetTypeKind(t) == kArrayKind) t = LLVMGetElementType(t);
            else if (LLVMGetTypeKind(t) == kStructKind) t = LLVMStructGetTypeAtIndex(t, (unsigned)LLVMConstIntGetZExtValue(LLVMGetOperand(gep, i)));
            else t = nullptr;
        }
        if (!t || LLVMGetTypeKind(t) != kArrayKind || LLVMGetArrayLength(t) < 2 || LLVMGetArrayLength(t) > kMaxElements) continue;
        unsigned length = LLVMGetArrayLength(t);
        std::vector<LLVMValueRef> users;
        for (LLVMUseRef u = LLVMGetFirstUse(gep); u && usable; u = LLVMGetNextUse(u)) {
            LLVMValueRef user = LLVMGetUser(u);
            bool load = LLVMIsALoadInst(user), store = !load && LLVMIsAStoreInst(user) && LLVMGetOperand(user, 1) == gep && LLVMGetOperand(user, 0) != gep;
            // plain data only: texture and sampler handles picked by a select break the back end (a05)
            LLVMTypeRef value = load ? LLVMTypeOf(user) : store ? LLVMTypeOf(LLVMGetOperand(user, 0)) : nullptr;
            int kind = value ? LLVMGetTypeKind(scalarOf(value)) : -1;
            if (value && (kind == kTypeKindInteger || kind == 1 /* half */ || kind == 2 /* float */ || kind == 3 /* double */)) users.push_back(user);
            else usable = false;
        }
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
// both become one entry from `to` with the value merge(phi, value from `to`, value from `from`).
template <typename Merge>
static void retargetPhis(LLVMBuilderRef b, LLVMBasicBlockRef bb, LLVMBasicBlockRef from, LLVMBasicBlockRef to, Merge merge) {
    std::vector<LLVMValueRef> phis;
    for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst && LLVMIsAPHINode(inst); inst = LLVMGetNextInstruction(inst)) phis.push_back(inst);
    for (LLVMValueRef phi : phis) {
        std::vector<LLVMValueRef> values;
        std::vector<LLVMBasicBlockRef> blocks;
        LLVMValueRef fromValue = nullptr, toValue = nullptr;
        unsigned n = LLVMCountIncoming(phi);
        for (unsigned i = 0; i < n; i++) {
            LLVMBasicBlockRef in = LLVMGetIncomingBlock(phi, i);
            if (in == from) fromValue = LLVMGetIncomingValue(phi, i);
            else if (in == to) toValue = LLVMGetIncomingValue(phi, i);
            else values.push_back(LLVMGetIncomingValue(phi, i)), blocks.push_back(in);
        }
        if (!fromValue) continue;  // nothing comes from `from`
        values.push_back(toValue ? merge(phi, toValue, fromValue) : fromValue);
        blocks.push_back(to);
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
// are made volatile, which keeps them in order. INTEL_TYPE_PUN_FIX=0 turns it off.
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
static unsigned volatilizePunnedAccesses(LLVMModuleRef module) {
    if (disabled("INTEL_TYPE_PUN_FIX")) return 0;
    unsigned marked = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        if (!LLVMGetFirstBasicBlock(f)) continue;
        // casts of one shared pointer to different element types
        std::map<LLVMValueRef, std::vector<LLVMValueRef>> castsOf;
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMIsABitCastInst(inst) && sharedPointer(inst) && sharedPointer(LLVMGetOperand(inst, 0)))
                    castsOf[pointerRoot(LLVMGetOperand(inst, 0))].push_back(inst);
        std::vector<LLVMValueRef> punned;
        for (auto &entry : castsOf) {
            bool differ = false;
            for (LLVMValueRef c : entry.second)
                differ = differ || LLVMGetElementType(LLVMTypeOf(c)) != LLVMGetElementType(LLVMTypeOf(entry.second[0]));
            if (differ) punned.insert(punned.end(), entry.second.begin(), entry.second.end());
        }
        if (punned.empty()) continue;
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
        n = selectPrivateArrayIndices(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u variable-index private array access(es) done at constant indices\n", n);
        n = volatilizePunnedAccesses(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u access(es) to a buffer viewed as different types made volatile\n", n);
        unsigned flattened = flattenBranchChains(module);
        if (flattened && logging()) fprintf(stderr, "[inteltex] %u short branch(es) folded into selects\n", flattened);
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
    return passManagerRun(self, module);
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
