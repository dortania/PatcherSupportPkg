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
// Installed: AppleIntelHD5000GraphicsMTLDriver.bundle/Contents/MacOS/IntelTextureAtomics.dylib, a weak dependency of
// libMTLIntelCompilerPlugin.dylib. Test use: DYLD_INSERT_LIBRARIES=Tests/tools/localcc.dylib:build/intelatomics-test.dylib
//   INTELTEX_LOG=1        log what is rewritten
//   INTELTEX_DUMP=<dir>   write each lowered module and the IGIL text before the fix
//   INTELTEX_DUMP_INPUT=<dir>  write every module as it reaches the pass manager
// Also (compiler compatibility, not texture atomics): air.max_work_group_size dropped (the back end aborts on it), and
// air.struct_type_info dropped from array-of-struct buffer arguments (the argument-buffer emulation asserts on them).
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <sys/mman.h>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

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

extern "C" void intelatomicsFixIGIL(std::string *text) {
    std::string &s = *text;
    if (getenv("INTELTEX_DUMP")) {  // debugging: the IGIL text as the back end produced it
        static int serial;
        char path[1024];
        snprintf(path, sizeof path, "%s/igil-%d.txt", getenv("INTELTEX_DUMP"), serial++);
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
static void installIntoPlugin(bool redirectImport) {
    static bool done;
    if (done) return;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0, suffix = strlen(kPluginSuffix);
        if (len < suffix || strcmp(name + len - suffix, kPluginSuffix)) continue;
        done = true;
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

static int hookedRun(void *self, LLVMModuleRef module) {
    pthread_mutex_lock(&installLock);
    installIntoPlugin(false);  // test process: the plugin was dlopened after we were inserted
    bool ready = textFixInstalled && resolveIGIL();
    pthread_mutex_unlock(&installLock);
    if (module && getenv("INTELTEX_DUMP_INPUT")) {  // debugging: every module as it reaches the pass manager
        static int serial;
        char path[1024];
        snprintf(path, sizeof path, "%s/input-%d.ll", getenv("INTELTEX_DUMP_INPUT"), serial++);
        if (FILE *f = fopen(path, "w")) { char *text = LLVMPrintModuleToString(module); fputs(text, f); LLVMDisposeMessage(text); fclose(f); }
    }
    if (module) {
        unsigned n = dropMaxWorkGroupSize(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u air.max_work_group_size attribute(s) dropped\n", n);
        n = dropArrayStructInfo(module);
        if (n && logging()) fprintf(stderr, "[inteltex] struct info dropped from %u array-of-struct argument(s)\n", n);
        n = fixEscapedHandleLoads(module);
        if (n && logging()) fprintf(stderr, "[inteltex] %u texture/sampler load(s) through escaped pointers re-indexed into the argument\n", n);
        if (n && getenv("INTELTEX_DUMP_HANDLES")) {  // debugging: the module after that rewrite
            static int serial;
            char path[1024];
            snprintf(path, sizeof path, "%s/handles-%d.ll", getenv("INTELTEX_DUMP_HANDLES"), serial++);
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

__attribute__((constructor)) static void installFromConstructor() { installIntoPlugin(true); }

#ifdef INTELTEX_INTERPOSE  // test build for DYLD_INSERT_LIBRARIES
__attribute__((used, section("__DATA,__interpose"))) static struct { void *replacement, *original; } interposers[] = {
    {(void *)hookedRun, (void *)passManagerRun},
};
#endif
