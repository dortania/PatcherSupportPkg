// IntelTextureAtomics.dylib: fixes for OCLP's 3802 Intel Metal compiler (libMTLIntelCompilerPlugin + libIGIL-Metal) on
// Haswell and Ivy Bridge, fed by the macOS 14 front end. Each fix rewrites the module before the back end runs, hooks a
// back-end function, or corrects the IGIL text the back end produces. FIXES.md section 4 lists them, each with the switch
// that turns it off and its test.
//
// Loaded as a weak dependency of libMTLIntelCompilerPlugin.dylib from AppleIntelHD5000GraphicsMTLDriver.bundle (Haswell,
// 12.5 payload) and AppleIntelHD4000GraphicsMTLDriver.bundle (Ivy Bridge, 11.7.10 payloads: an older plugin build whose
// entry points have other names). Tests load it from build/ (Tests/verify.sh, Tests/fuzz/gpu.sh BUILD=1).
//   INTELTEX_LOG=1 | <file>        log each rewrite (to a file, e.g. from MTLCompilerService through __XPC_INTELTEX_LOG)
//   INTELTEX_DUMP=<dir>            the lowered modules, and the IGIL text before and after its fixes
//   INTELTEX_DUMP_INPUT=<dir>      every module as it reaches the pass manager
//   INTELTEX_DUMP_REWRITTEN=<dir>  every module after the rewrites
//   INTELTEX_DUMP_KERNELS=<dir>    each pixel shader's SIMD8 and SIMD16 kernels
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
#include "LLVM38.h"

extern "C" int passManagerRun(void *self, LLVMModuleRef module) asm("__ZN4llvm6legacy11PassManager3runERNS_6ModuleE");

static bool logging() { return getenv("INTELTEX_LOG") != nullptr; }
// One line per fix that changed something: "[inteltex] <format with the count>".
static void logCount(const char *format, unsigned count) {
    char message[512];
    snprintf(message, sizeof message, format, count);
    fprintf(stderr, "[inteltex] %s\n", message);
}
// A fix is on unless its switch is set to 0.
static bool disabled(const char *setting) {
    const char *value = getenv(setting);
    return value && !strcmp(value, "0");
}
// Debugging: writes `text` to <the directory $setting names>/<name>-[<pid>-]<serial><extension>, numbered per name.
static std::map<std::string, int> *dumpSerials;  // per dump name; allocated once, never destroyed
static void dumpText(const char *setting, const char *name, bool withProcessId, const char *extension, const std::string &text) {
    const char *directory = getenv(setting);
    if (!directory) return;
    if (!dumpSerials) dumpSerials = new std::map<std::string, int>;
    int serial = (*dumpSerials)[name]++;
    char path[1024];
    if (withProcessId) snprintf(path, sizeof path, "%s/%s-%d-%d%s", directory, name, getpid(), serial, extension);
    else snprintf(path, sizeof path, "%s/%s-%d%s", directory, name, serial, extension);
    if (FILE *f = fopen(path, "w")) { fwrite(text.data(), 1, text.size(), f); fclose(f); }
}
static void dumpModule(const char *setting, const char *name, bool withProcessId, LLVMModuleRef module) {
    if (!getenv(setting)) return;
    char *text = LLVMPrintModuleToString(module);
    dumpText(setting, name, withProcessId, ".ll", text);
    LLVMDisposeMessage(text);
}

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
// MSL texture atomics (Metal 3.1): the plugin's built-in library has no air.atomic_*_explicit_texture_* functions, but the
// back end has image atomics. Three steps turn one into the other:
//   1. here: air.atomic_<op>_explicit_texture_<dim> becomes llvm.igil.atom.<op>i32.image, tagged with the texture's binding;
//   2. hookedLowerImageAtomic puts the tag where the image operand goes (the back end finds that only in the entry block);
//   3. the IGIL text fix replaces the tag with the u<N> declared for that binding.
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
static long metadataInt(LLVMValueRef value) {
    return value && LLVMIsAConstantInt(value) ? (long)LLVMConstIntGetZExtValue(value) : -1;
}
// The integer `skip` operands after the first `key` among a node's operands, or -1.
static long fieldAfter(const std::vector<LLVMValueRef> &fields, const char *key, unsigned skip = 1) {
    for (size_t k = 0; k + skip < fields.size(); k++)
        if (isString(fields[k], key)) return metadataInt(fields[k + skip]);
    return -1;
}
// The position of the first `key` among a node's operands that has an operand after it, or -1.
static long indexOfKeyWithValue(const std::vector<LLVMValueRef> &fields, const char *key) {
    for (size_t k = 0; k + 1 < fields.size(); k++)
        if (isString(fields[k], key)) return (long)k;
    return -1;
}

extern "C" void mdNodeReplaceOperand(void *node, unsigned index, void *replacement) asm("__ZN4llvm6MDNode18replaceOperandWithEjPNS_8MetadataE");
static bool replaceOperandWithNode(LLVMContextRef context, LLVMValueRef node, unsigned index, std::vector<LLVMValueRef> &operands) {
    void *target = metadataOf(node);
    void *replacement = metadataOf(LLVMMDNodeInContext(context, operands.data(), (unsigned)operands.size()));
    if (!target || !replacement) return false;
    mdNodeReplaceOperand(target, index, replacement);
    return true;
}

// An entry point's node in the module's !air.kernel, !air.fragment or !air.vertex list: !{function, !outputs, !inputs, ...}.
struct EntryPoint {
    const char *list;
    LLVMValueRef node;
    std::vector<LLVMValueRef> operands;
    LLVMValueRef function() const { return operands.empty() ? nullptr : operands[0]; }
};
// Visits every entry point. Each node is read just before its visit, so a visit may rewrite the nodes it has seen.
template <typename Visit> static void forEachEntryPoint(LLVMModuleRef module, Visit visit) {
    for (const char *list : {"air.kernel", "air.fragment", "air.vertex"}) {
        std::vector<LLVMValueRef> nodes(LLVMGetNamedMetadataNumOperands(module, list));
        if (nodes.empty()) continue;
        LLVMGetNamedMetadataOperands(module, list, nodes.data());
        for (LLVMValueRef node : nodes) visit(EntryPoint{list, node, metadataOperands(node)});
    }
}
// Replaces each argument description of every entry point (in its output and input lists) that `rewrite` returns
// operands for. Returns how many it replaced.
template <typename Rewrite> static unsigned rewriteEachArgument(LLVMModuleRef module, Rewrite rewrite) {
    unsigned replaced = 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    forEachEntryPoint(module, [&](const EntryPoint &entry) {
        for (unsigned list = 1; list < entry.operands.size(); list++) {
            std::vector<LLVMValueRef> descriptions = metadataOperands(entry.operands[list]);
            for (unsigned d = 0; d < descriptions.size(); d++) {
                std::vector<LLVMValueRef> replacement = rewrite(entry.function(), metadataOperands(descriptions[d]));
                if (!replacement.empty() && replaceOperandWithNode(context, entry.operands[list], d, replacement)) replaced++;
            }
        }
    });
    return replaced;
}
// The binding of texture parameter `param` of `function`, from !air.kernel / !air.fragment / !air.vertex:
// !{fn, !outputs, !{..., !{i32 param, !"air.texture", !"air.location_index", i32 binding, i32 count, ...}, ...}}
static int textureBinding(LLVMModuleRef module, LLVMValueRef function, unsigned param) {
    int binding = -1;
    forEachEntryPoint(module, [&](const EntryPoint &entry) {
        if (binding >= 0 || entry.operands.size() < 3 || entry.function() != function) return;
        for (LLVMValueRef description : metadataOperands(entry.operands[2])) {
            std::vector<LLVMValueRef> fields = metadataOperands(description);
            if (fields.size() < 5 || metadataInt(fields[0]) != (long)param || !isString(fields[1], "air.texture")) continue;
            for (size_t k = 2; k + 1 < fields.size(); k++)
                if (isString(fields[k], "air.location_index") && LLVMIsAConstantInt(fields[k + 1])) {
                    binding = (int)LLVMConstIntGetZExtValue(fields[k + 1]);
                    return;
                }
        }
    });
    return binding;
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
// Text helpers for the IGIL fixes.
static std::vector<std::string> splitLines(const std::string &text) {
    std::vector<std::string> lines;
    for (size_t pos = 0; pos <= text.size();) {
        size_t eol = text.find('\n', pos);
        if (eol == std::string::npos) eol = text.size();
        lines.push_back(text.substr(pos, eol - pos));
        pos = eol + 1;
    }
    return lines;
}
static std::string joinLines(const std::vector<std::string> &lines) {
    std::string text;
    for (size_t i = 0; i < lines.size(); i++) {
        text += lines[i];
        if (i + 1 < lines.size()) text += '\n';
    }
    return text;
}
// Sets the highest temporary register the IGIL text declares: DCL_TEMPS r0..r<last>.
static void declareTemporariesUpTo(std::string &text, unsigned long last) {
    size_t numberAt = text.find("\tDCL_TEMPS r0..r") + 16, numberEnd = text.find_first_not_of("0123456789", numberAt);
    text.replace(numberAt, numberEnd - numberAt, std::to_string(last));
}
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
// In a long fragment function iCBE gets the immediate lanes of a MOV_SWZ that mixes immediates and per-pixel values
// right in only one pixel of eight (i11). FMAX(FMIN(p, -inf), c) is c for any per-pixel p, so those lanes are computed
// per pixel; exact for normal floats and zero, other bit patterns are left alone.
static bool exactThroughFmax(const std::string &immediate) {  // "0x3F800000": a normal float or a zero
    if (immediate.compare(0, 2, "0x") || immediate.size() < 3 || immediate.size() > 10 ||
        immediate.find_first_not_of("0123456789abcdefABCDEF", 2) != std::string::npos)
        return false;
    uint32_t bits = (uint32_t)strtoul(immediate.c_str() + 2, nullptr, 16), exponent = (bits >> 23) & 0xff;
    return (bits & 0x7fffffff) == 0 || (exponent != 0 && exponent != 0xff);
}
static unsigned perPixelSwizzleImmediates(std::string &s) {
    if (disabled("INTEL_SWIZZLE_IMMEDIATE_FIX") || s.find("MOV_SWZ") == std::string::npos) return 0;
    size_t temps = s.find("DCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned long next = strtoul(s.c_str() + temps + 15, nullptr, 10) + 1;
    std::vector<std::string> lines = splitLines(s);
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
    std::string result = joinLines(out);
    size_t t = result.find("DCL_TEMPS r0..r");
    result.replace(t, result.find(';', t) - t, "DCL_TEMPS r0..r" + std::to_string(next - 1));
    s = result;
    return fixed;
}

// ---- vertex IDs in indirect draws ---------------------------------------------------------------------------------
// In indexed indirect draws VERTEXID leaves out the base vertex unless the shader's system-value constants (c0) also
// list BASE_VERTEX_ID, so vertex shaders that read VERTEXID get it declared (i13). On Ivy Bridge, direct draws after an
// indirect one also need MetalOldCompat item 48.
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
// MSL's dfdx / dfdy are fine, but iCBE evaluates the IGIL writer's GRADIENT_X / GRADIENT_Y coarse, one difference per
// 2x2 quad. They become GRADIENT_X_FINE / GRADIENT_Y_FINE (i15).
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
// For SAMPLE_LC the IGIL writer builds coordinates and LOD in the destination register but names the coordinate register
// as the operand, whose w iCBE reads as the LOD and nothing wrote (i24, i78). The operand becomes the destination
// register. Not cube arrays: their w is the array index and the back end finds the LOD elsewhere (a09).
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
                auto endsWith = [&](const char *tail) { size_t k = strlen(tail); return eol >= pos + k && !s.compare(eol - k, k, tail); };
                bool shape = endsWith(", 2D;") || endsWith(", 2D_ARRAY;") || endsWith(", CUBE;");
                if (shape && !s.compare(previous[0], strlen(coords), coords) && !s.compare(previous[1], strlen(lod), lod)) {
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

// ---- cube-array comparisons at a level ----------------------------------------------------------------------------------
// iCBE takes a cube array's SAMPLE_LC level from rC.w, the array index, so layer n compared at level n (i79). The
// projective SAMPLE_PLC takes the level as an operand but divides coordinates and reference by rC.w, so they are first
// multiplied by max(index, 2^-8); the reference can come back one ulp off (FIXES.md, known limitations).
static unsigned cubeArrayCompareLevels(std::string &s) {
    if (disabled("INTEL_CUBE_ARRAY_LEVEL_FIX") || s.find(", CUBEARRAY;") == std::string::npos) return 0;
    size_t decl = s.find("\tDCL_TEMPS r0..r");
    unsigned last = 0;
    int declLen = 0;
    if (decl == std::string::npos || sscanf(s.c_str() + decl, "\tDCL_TEMPS r0..r%u;%n", &last, &declLen) != 1 || !declLen) return 0;
    unsigned a = last + 1, b = last + 2, n = 0;
    size_t previous = std::string::npos;
    for (size_t pos = 0; pos < s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        unsigned d, c, d2;
        int at = 0;
        if (eol > pos && previous != std::string::npos && eol - pos >= 12 &&
            sscanf(s.c_str() + pos, "\tSAMPLE_LC r%u, r%u(%n", &d, &c, &at) == 2 && at &&
            !s.compare(eol - 12, 12, ", CUBEARRAY;") && sscanf(s.c_str() + previous, "\tMOV r%u.w, ", &d2) == 1 && d2 == d) {
            // "(OFFSETS), tT, sS, REF, CUBEARRAY;" after "rC("
            std::string tail = s.substr(pos + at, eol - (pos + at));
            size_t close = tail.find("), ");
            size_t refEnd = tail.rfind(", CUBEARRAY;");
            size_t refStart = refEnd == std::string::npos ? std::string::npos : tail.rfind(", ", refEnd - 1);
            if (close != std::string::npos && refStart != std::string::npos && refStart > close) {
                std::string offsets = tail.substr(0, close), resources = tail.substr(close + 3, refStart - (close + 3));
                std::string ref = tail.substr(refStart + 2, refEnd - (refStart + 2));
                auto r = [](unsigned k) { return "r" + std::to_string(k); };
                std::string rest = "\tFMAX " + r(a) + ".w, " + r(c) + ".wwww, 0x3B800000;\n\tFMUL " + r(a) + ".xyz, " + r(c) + ".xyzx, " + r(a) +
                                   ".wwww;\n\tFMUL " + r(b) + ".x, " + ref + ", " + r(a) + ".w;\n\tSAMPLE_PLC " + r(d) + ", " + r(a) + "(" + offsets +
                                   "), " + resources + ", " + r(d) + ".w, " + r(b) + ".x, CUBEARRAY;";
                s.replace(pos, eol - pos, rest);
                eol = s.find('\n', pos + rest.size() - 1);
                if (eol == std::string::npos) eol = s.size();
                n++;
            }
        }
        previous = eol > pos ? pos : std::string::npos;
        pos = eol + 1;
    }
    if (n) {
        char newDecl[64];
        snprintf(newDecl, sizeof newDecl, "\tDCL_TEMPS r0..r%u;", b);
        s.replace(decl, declLen, newDecl);
    }
    return n;
}

// ---- a narrow mask after a narrower one --------------------------------------------------------------------------------
// iCBE takes AND rC, rB, 0xFFFF after AND rB, rA, 255 for a 16-bit zero-extension of rA and drops the 255 (i29). The
// second AND changes nothing, so it becomes a MOV.
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
// iCBE keeps STOI / BTOI results in 16- / 8-bit registers and extends them where they are read; merged (MOV_CND) with a
// 32-bit value they were read back zero-extended (i45, i57). They become SHL / SAR pairs, which iCBE computes on 32 bits.
static unsigned signExtensions(std::string &s) {
    if (disabled("INTEL_SIGN_EXTEND_FIX") || (s.find("\tSTOI ") == std::string::npos && s.find("\tBTOI ") == std::string::npos)) return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    std::vector<std::string> lines = splitLines(s);
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
    std::string out = joinLines(lines);
    declareTemporariesUpTo(out, last);
    s = out;
    return n;
}

// ---- signed compares of a sum with zero, in the IGIL text ---------------------------------------------------------
// In pixel and vertex shaders iCBE folds (x + C) < 0 into x < -C as if the add couldn't wrap, likewise > 0 (i65). Such
// compares become tests of the sum's sign bit and, for > 0 and <= 0, of the sum being 0.
static unsigned signTestsOfSums(std::string &s) {
    if (disabled("INTEL_SUM_SIGN_TEST_FIX") || (s.find("\tPIXELSHADER") == std::string::npos && s.find("\tVERTEXSHADER") == std::string::npos))
        return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    std::vector<std::string> lines = splitLines(s);
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
    std::string out = joinLines(lines);
    declareTemporariesUpTo(out, last);
    s = out;
    return n;
}

// ---- negations feeding a signed divide, in the IGIL text ------------------------------------------------------------
// iCBE folds a negation (IADD r, 0, -x) into the IDIV that reads it as a source modifier and drops it (i26), also when it
// reaches the divide through copies, merges or folded operations (i60, i61). So in a shader with an IDIV every such
// negation becomes XOR -1 and IADD 1.
static unsigned negatedDivideOperands(std::string &s) {
    if (disabled("INTEL_SIGNED_DIV_NEG_FIX") || s.find("\tIDIV ") == std::string::npos) return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    std::vector<std::string> lines = splitLines(s);
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
    std::string out = joinLines(lines);
    declareTemporariesUpTo(out, last);
    s = out;
    return n;
}

// ---- loop-carried copies before a loop's exit ------------------------------------------------------------------------
// iCBE propagates a copy taken at the top of a loop body (MOV rOld, rNext) past the next iteration's MOV rNext before
// BREAK_CND, so after the loop rOld held the value of an iteration that never ran (i41). Copies whose register isn't
// read outside the loop move after the BREAK_CND.
static unsigned loopExitCopies(std::string &s) {
    if (disabled("INTEL_LOOP_EXIT_COPY_FIX") || s.find("\tBREAK_CND") == std::string::npos) return 0;
    std::vector<std::string> lines = splitLines(s);
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
// iCBE gives SHR / SAR of a value it knows is narrow (a constant below 65536, an AND with such a mask) a narrow result
// register, and merging it with a wider copy of the variable dropped the high bits (i40, i54). Such shifts run with
// bit 31 set and XOR it away after, so every register is 32 bits wide; narrow ANDs read through phi copies, min / max,
// signed operations or a 32-bit saturating add are widened the same way (i46, i48, i52, i55).
static unsigned narrowShifts(std::string &s) {
    if (disabled("INTEL_NARROW_SHIFT_FIX") ||
        (s.find("\tSHR ") == std::string::npos && s.find("\tSAR ") == std::string::npos && s.find("\tAND ") == std::string::npos))
        return 0;
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    std::vector<std::string> lines = splitLines(s);
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
    // registers read by an operation that takes a narrow source as signed (i46) or by a 32-bit saturating add (i48); the
    // narrow saturating opcodes (UBADD / USADD / BADD / SADD) are left alone
    auto saturating = [](const std::string &l) {
        return (!l.compare(0, 6, "\tUADD ") || !l.compare(0, 6, "\tIADD ") || !l.compare(0, 6, "\tUSUB ") || !l.compare(0, 6, "\tISUB ")) &&
               l.find("_sat.") != std::string::npos;
    };
    // single-definition MOV / MOV_SWZ copies are followed lane by lane to the register that computed the value (i52)
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
    std::string out = joinLines(lines);
    declareTemporariesUpTo(out, last);
    s = out;
    return n;
}

// ---- narrow negations ----------------------------------------------------------------------------------------------
// iCBE folds BADD rD, 0, -rX and the BTOI after it into -(sext x) instead of sext(-x), wrong for x = 0x80 (i37). The
// negation becomes XOR 0xFF (0xFFFF for SADD) and an add of 1 of the same width; a 32-bit IADD would lose the BTOI.
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
    declareTemporariesUpTo(out, last);
    s = out;
    return n;
}

// ---- narrow unsigned divides ---------------------------------------------------------------------------------------
// iCBE drops the AND 0xFF / 0xFFFF that zero-extends a UBDIV / USDIV operand but divides the whole register, so upper
// bits left in a lane were divided too (i30). Each becomes a 32-bit UDIV of copies masked to the lane's width.
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
    declareTemporariesUpTo(out, last);
    s = out;
    return n;
}

// ---- a narrow mask reached through copies ----------------------------------------------------------------------------
// redundantNarrowMasks' iCBE fold, with the narrower AND reaching the 16-bit one through MOVs (i32) or through an OR,
// XOR or IADD whose other operand iCBE folds to 0 (i76). The register is set from a wider value on another path, so
// the AND stays and is done on 32 bits instead, as in narrowShifts: (x | bit 31) & (mask | bit 31), XOR bit 31 (i43).
static unsigned narrowMasksThroughCopies(std::string &s) {
    if (disabled("INTEL_NARROW_MASK_FIX")) return 0;
    const bool throughOr = !disabled("INTEL_MASK_OR_FIX");
    size_t temps = s.find("\tDCL_TEMPS r0..r");
    if (temps == std::string::npos) return 0;
    unsigned last = (unsigned)strtoul(s.c_str() + temps + 16, nullptr, 10);
    std::vector<std::string> lines = splitLines(s);
    // every definition of rN.x: a MOV from rM.x (source M), an AND with an immediate (mask), or anything else; an OR /
    // XOR / IADD of registers counts as a copy of each register operand
    struct Def { int source; unsigned long mask; };
    std::map<unsigned, std::vector<Def>> defs;
    for (const std::string &l : lines) {
        unsigned d, src, src2;
        char imm[32], op[8];
        int at = 0;
        if (throughOr && sscanf(l.c_str(), "\t%7[A-Z] r%u.x, r%u.x, %n", op, &d, &src, &at) == 3 && at &&
            (!strcmp(op, "OR") || !strcmp(op, "XOR") || !strcmp(op, "IADD"))) {
            defs[d].push_back({(int)src, 0});
            if (sscanf(l.c_str() + at, "r%u.x;", &src2) == 1) defs[d].push_back({(int)src2, 0});
            continue;
        }
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
    std::string out = joinLines(lines);
    declareTemporariesUpTo(out, last);
    s = out;
    return n;
}

// ---- integer divides in a branch of a pixel shader: SIMD8 only -------------------------------------------------------
// In a SIMD16 pixel kernel iCBE can read stale values it moved into a branch with an integer divide (i77; the IR, the
// IGIL text and the SIMD8 kernel are right; Gen7 splits each divide in two there). Pixel shaders with a divide in an IF,
// a LOOP or anywhere with subroutines are compiled SIMD8 only, as INTEL_SIMD8_PIXEL=1 does for all.
static thread_local bool pixelDivideInBranch;
static bool divideInBranch(const std::string &s) {
    if (s.find("PIXELSHADER") == std::string::npos || disabled("INTEL_PIXEL_DIVIDE_SIMD8_FIX")) return false;
    bool calls = s.find("\tCALL") != std::string::npos;
    int depth = 0;
    for (size_t pos = 0; pos < s.size();) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        const char *l = s.c_str() + pos;
        if (!strncmp(l, "\tIF_", 4) || !strncmp(l, "\tLOOP;", 6)) depth++;
        else if ((!strncmp(l, "\tENDIF;", 7) || !strncmp(l, "\tENDLOOP;", 9)) && depth > 0) depth--;
        else if ((!strncmp(l, "\tUDIV ", 6) || !strncmp(l, "\tIDIV ", 6) || !strncmp(l, "\tUBDIV ", 7) || !strncmp(l, "\tUSDIV ", 7)) &&
                 (depth > 0 || calls))
            return true;
        pos = eol + 1;
    }
    return false;
}

static thread_local std::string lastIGILForDump;  // INTELTEX_DUMP_KERNELS: the IGIL text iCBE compiles next on this thread
// ---- image atomics -------------------------------------------------------------------------------------------------
// IMM_ATOMIC_<OP> dst, rI, rC, ...  where rC = MOV_SWZ rC, x, y, z, rT.c and MOV rT.c, <kImageTag | binding>
//   ->  MOV rC.w, 0;  IMM_ATOMIC_<OP> dst, uM, rC, ...   (uM: the DCL_UAVTYPED with LOCATION_INDEX binding, 0)
// An atomic whose texture can't be found gets "unresolved_image", which fails the compile rather than address the
// wrong texture.
static std::vector<int> uavOfEachBinding(const std::vector<std::string> &lines) {
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
    return uavOfBinding;
}
// The UAV of the texture step 1 tagged into the w lane of the atomic's coordinates, or -1.
static int taggedImageUAV(const std::vector<std::string> &lines, size_t atomicLine, const std::string &coordinates,
                          const std::vector<int> &uavOfBinding) {
    std::string swizzleOpcode, tagOpcode;
    std::vector<std::string> swizzle, tag;
    if (coordinates.empty() || definition(lines, atomicLine, coordinates, swizzleOpcode, swizzle) < 0 ||
        swizzleOpcode != "MOV_SWZ" || swizzle.size() != 5) return -1;
    std::string tagRegister = operandRegister(swizzle[4]);
    if (tagRegister.empty() || definition(lines, atomicLine, tagRegister, tagOpcode, tag) < 0 || tagOpcode != "MOV" ||
        tag.size() != 2) return -1;
    unsigned long long value = strtoull(tag[1].c_str(), nullptr, 0);
    if ((value & kImageTagMask) != kImageTag || (value & kBindingMask) >= uavOfBinding.size()) return -1;
    return uavOfBinding[value & kBindingMask];
}
static void bindImageAtomics(std::string &s) {
    if (s.find("IMM_ATOMIC_") == std::string::npos) return;
    std::vector<std::string> lines = splitLines(s);
    std::vector<int> uavOfBinding = uavOfEachBinding(lines);
    unsigned fixed = 0, failed = 0;
    std::vector<std::string> out;
    for (size_t i = 0; i < lines.size(); i++) {
        std::string opcode;
        std::vector<std::string> ops = instructionOperands(lines[i], &opcode);
        if (opcode.compare(0, 11, "IMM_ATOMIC_") || ops.size() < 4) {
            out.push_back(lines[i]);
            continue;
        }
        std::string coords = operandRegister(ops[2]);
        int u = taggedImageUAV(lines, i, coords, uavOfBinding);
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
    s = joinLines(out);
    if (logging() || failed) fprintf(stderr, "[inteltex] IGIL: %u image atomic operand(s) resolved, %u unresolved\n", fixed, failed);
}

struct IGILTextFix {
    unsigned (*apply)(std::string &igil);
    const char *logFormat;  // with %u for the count
};
static const IGILTextFix kIGILTextFixes[] = {
    {fineGradients, "%u derivative(s) made fine"},
    {narrowMasksThroughCopies, "%u AND 0xFFFF / 0xFF over a narrower AND done on 32 bits"},
    {narrowUnsignedDivides, "%u UBDIV / USDIV done as UDIV of masked copies"},
    {redundantNarrowMasks, "%u AND 0xFFFF after a narrower AND made a MOV"},
    {narrowNegations, "%u BADD / SADD negation(s) done as XOR and add"},
    {narrowShifts, "%u SHR / SAR of a narrow value done on 32 bits"},
    {loopExitCopies, "%u loop-carried copies moved after the loop's BREAK_CND"},
    {negatedDivideOperands, "%u negation(s) in a shader with an IDIV done as XOR and add"},
    {signTestsOfSums, "%u signed compare(s) of a sum with zero done on its sign bit"},
    {signExtensions, "%u STOI / BTOI done as shift pairs"},
    {sampleLodOperands, "%u explicit-LOD sample(s) given the register holding the LOD"},
    {cubeArrayCompareLevels, "%u cube-array comparison(s) at a level made projective"},
};

extern "C" void intelatomicsFixIGIL(std::string *text) {
    if (getenv("INTELTEX_DUMP_KERNELS")) lastIGILForDump = *text;
    std::string &s = *text;
    dumpText("INTELTEX_DUMP", "igil", false, ".txt", s);
    if (s.find("PIXELSHADER") != std::string::npos) {
        unsigned n = perPixelSwizzleImmediates(s);
        if (n && logging()) fprintf(stderr, "[inteltex] %u MOV_SWZ with immediate and per-pixel lanes: immediate lanes computed per pixel\n", n);
        if (n) dumpText("INTELTEX_DUMP", "igil-fixed", false, ".txt", s);
    }
    if (declareBaseVertex(s) && logging()) fprintf(stderr, "[inteltex] vertex shader reads VERTEXID: BASE_VERTEX_ID declared\n");
    for (const IGILTextFix &fix : kIGILTextFixes)
        if (unsigned n = fix.apply(s); n && logging()) logCount(fix.logFormat, n);
    pixelDivideInBranch = divideInBranch(s);
    if (pixelDivideInBranch && logging()) fprintf(stderr, "[inteltex] pixel shader with an integer divide in a branch: SIMD8 only\n");
    dumpText("INTELTEX_DUMP", "igil-after", false, ".txt", s);
    bindImageAtomics(s);
}

// ---- installation --------------------------------------------------------------------------------------------------
static const char *const kPluginSuffix = "libMTLIntelCompilerPlugin.dylib";
static const unsigned char kPrologue[12] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x41, 0x55, 0x41, 0x54};
// The Ivy Bridge plugin's compileComputeFunctionIGILtoBinary saves fewer registers: push rbp; mov rbp, rsp; push r14;
// push rbx; sub rsp, 0xa0. 14 bytes are the whole instructions that cover the 12-byte jump (none RIP-relative).
static const unsigned char kPrologueIVBCompute[14] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x56, 0x53, 0x48, 0x81, 0xec, 0xa0, 0x00, 0x00, 0x00};
// compile*FunctionIGILtoBinary(this, std::string &igil, ...): the IGIL text is the second argument (rsi).
static const char *const kIGILEntryPoints[] = {
    "_ZN16MTLIntelCompiler33compileVertexFunctionIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEERPN3AIR13Serialization25SSerializedCompilerOutputINS8_27SCompilerOutputVertexShaderEEEjP21MTLIntelCompilerInputS7_",
    "_ZN16MTLIntelCompiler34compileComputeFunctionIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEEP22MTLIntelCSDeviceBinaryRPN3AIR13Serialization25SSerializedCompilerOutputINSA_28SCompilerOutputComputeShaderEEEjS7_",
    "_ZN16MTLIntelCompiler35compileFragmentFunctionIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEERPN3AIR13Serialization25SSerializedCompilerOutputINS8_26SCompilerOutputPixelShaderEEEjS7_",
    "_ZN16MTLIntelCompiler40compileTessellationFunctionsIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEERPN3AIR13Serialization25SSerializedCompilerOutputINS8_25SCompilerOutputHullShaderEEERPNSA_INS8_27SCompilerOutputDomainShaderEEEjS7_",
};
// The same entry points in OCLP's 11.7.10 / 11.7.10-22 Ivy Bridge plugin, an older build of the compiler whose outputs
// are MTLIntel*DeviceBinary structs instead of SSerializedCompilerOutput: other mangled names, the same IGIL argument.
// INTEL_IVB_TEXT_FIX=0 leaves them unhooked (the IGIL text fixes off on Ivy Bridge, as before).
static const char *const kIGILEntryPointsIVB[] = {
    "_ZN16MTLIntelCompiler33compileVertexFunctionIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEEP22MTLIntelVSDeviceBinaryjP21MTLIntelCompilerInputS7_",
    "_ZN16MTLIntelCompiler34compileComputeFunctionIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEEP22MTLIntelCSDeviceBinaryjS7_",
    "_ZN16MTLIntelCompiler35compileFragmentFunctionIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEEP22MTLIntelPSDeviceBinaryjS7_",
    "_ZN16MTLIntelCompiler40compileTessellationFunctionsIGILtoBinaryERNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEER32MTLIntelTessellationDeviceBinaryjS7_",
};

static int hookedRun(void *self, LLVMModuleRef module);
static unsigned char *emit(unsigned char *p, const void *bytes, size_t n) { memcpy(p, bytes, n); return p + n; }
static unsigned char *emitMovRax(unsigned char *p, const void *value) {
    *p++ = 0x48; *p++ = 0xb8;
    memcpy(p, &value, 8);
    return p + 8;
}

// ---- LowerImageAtomic (libIGIL-Metal) ------------------------------------------------------------------------------
using llvm38::SDValue;
static SDValue (*originalLowerImageAtomic)(const void *self, unsigned id, SDValue op, void *dag);
static uint64_t (*constantValue)(const void *self, const SDValue &value, void *dag, bool &flag);
static const unsigned short kISDConstant = 0xa;
using llvm38::EVT;
struct SDLoc { void *debugLoc; unsigned order; };
extern "C" SDValue dagGetConstant(void *dag, uint64_t value, const SDLoc &dl, EVT vt, bool isTarget, bool isOpaque)
    asm("__ZN4llvm12SelectionDAG11getConstantEyRKNS_5SDLocENS_3EVTEbb");
extern "C" char *dagUpdateNodeOperands(void *dag, char *node, const SDValue *ops, size_t count)
    asm("__ZN4llvm12SelectionDAG18UpdateNodeOperandsEPNS_6SDNodeENS_8ArrayRefINS_7SDValueEEE");

// Operand 2 of an image atomic's node is the image, operand 3 the tag (a spare operand).
static bool isTag(const void *self, SDValue value, void *dag) {
    bool flag = true;
    return llvm38::sdOpcode(value.node) == kISDConstant && (constantValue(self, value, dag, flag) & kImageTagMask) == kImageTag;
}
static SDValue hookedLowerImageAtomic(const void *self, unsigned id, SDValue op, void *dag) {
    using namespace llvm38;
    char *operands = sdOperandList(op.node);
    unsigned count = sdOperandCount(op.node);
    SDValue image = sdOperandAt(operands, 2), tag = sdOperandAt(operands, 3);
    if (count > 16) return originalLowerImageAtomic(self, id, op, dag);
    if (isTag(self, image, dag)) return op;  // done already (the legalizer revisits updated nodes)
    if (!isTag(self, tag, dag)) return originalLowerImageAtomic(self, id, op, dag);
    // The image operand becomes the tag constant (valid in every block); the IGIL text fix puts the UAV in its place.
    SDLoc dl = {nullptr, sdIROrder(op.node)};
    EVT vt = sdValueType(tag);
    SDValue ops[16];
    for (unsigned k = 0; k < count; k++) ops[k] = sdOperandAt(operands, k);
    ops[2] = tag;
    ops[3] = ops[4] = dagGetConstant(dag, 0, dl, vt, false, false);
    ops[count - 1] = sdOperandAt(operands, 4);  // the value, back from the second spare operand
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


// Entry stub: save the argument registers, intelatomicsFixIGIL(rsi), restore, run the relocated prologue (12 bytes, or
// 14 for the Ivy Bridge compute entry), continue after it. The function's other arguments, including stack ones, are untouched.
static bool hookIGILEntry(unsigned char *entry) {
    size_t length = !memcmp(entry, kPrologue, sizeof kPrologue)                     ? sizeof kPrologue
                    : !memcmp(entry, kPrologueIVBCompute, sizeof kPrologueIVBCompute) ? sizeof kPrologueIVBCompute
                                                                                      : 0;
    if (!length) return false;
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
    p = emit(p, entry, length);
    p = emitMovRax(p, entry + length);
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

// Installs into the loaded plugin once: import redirect (unless interposed already) and the IGIL entry hooks.
static pthread_mutex_t installLock = PTHREAD_MUTEX_INITIALIZER;
static bool textFixInstalled;
static bool ivyBridgePlugin;  // OCLP's 11.7.10 AppleIntelHD4000GraphicsMTLDriver plugin
static void installIntoPlugin(bool redirectImport) {
    static bool done;
    if (done) return;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0, suffix = strlen(kPluginSuffix);
        if (len < suffix || strcmp(name + len - suffix, kPluginSuffix)) continue;
        done = true;
        void *h = dlopen(name, RTLD_NOLOAD | RTLD_LAZY);
        // Told apart by its own entry point, not only by the bundle in its path: test runs load the plugin by leaf name
        // from a temporary folder.
        ivyBridgePlugin = strstr(name, "AppleIntelHD4000GraphicsMTLDriver") || (h && dlsym(h, kIGILEntryPointsIVB[1]));
        unsigned imports = redirectImport ? redirectImportedPointer((const mach_header_64 *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), (void *)passManagerRun, (void *)hookedRun) : 0;
        const char *const *symbols = ivyBridgePlugin ? kIGILEntryPointsIVB : kIGILEntryPoints;
        size_t count = ivyBridgePlugin ? sizeof kIGILEntryPointsIVB / sizeof *kIGILEntryPointsIVB : sizeof kIGILEntryPoints / sizeof *kIGILEntryPoints;
        if (ivyBridgePlugin && disabled("INTEL_IVB_TEXT_FIX")) count = 0;
        unsigned hooks = 0;
        for (size_t s = 0; s < count; s++) {
            unsigned char *entry = h ? (unsigned char *)dlsym(h, symbols[s]) : nullptr;
            if (entry && hookIGILEntry(entry)) hooks++;
        }
        textFixInstalled = count && hooks == count;
        if (logging()) fprintf(stderr, "[inteltex] %s: %u import(s) redirected, %u IGIL entry point(s) hooked\n", name, imports, hooks);
    }
}

// ---- IGILUniformAnalysis::getDependency (libIGIL-Metal) ---------------------------------------------------------------
// getDependency(V) reads past the end of the uniformity map's buckets for an instruction with no entry yet (calculate_dep
// asks two levels down, for ashr (add (shl x, c), y), c): garbage, or a compiler-service crash when the map ends at a
// page (i49; the stock compiler too). Such an instruction counts as varying (4); the worklist recomputes its users once
// it gets an entry.
static const unsigned char kGetDependencyPrologue[13] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x53, 0x48, 0x83, 0xec, 0x18};
static unsigned (*originalGetDependency)(void *self, const void *value);
static bool (*uniformHasDependency)(void *self, const void *value);
static std::atomic<unsigned> uniformMisses;
static unsigned hookedGetDependency(void *self, const void *value) {
    if (llvm38::valueId(value) >= llvm38::kFirstInstruction && !uniformHasDependency(self, value)) return uniformMisses++, 4;
    return originalGetDependency(self, value);
}

// ---- IGILHelperFunctions::isValueUsed (Ivy Bridge libIGIL-Metal) ------------------------------------------------------
// IGILair_ldst_handling's isValueUsed walk calls Use::getUser five times per step and allocates a std::set node per user:
// Core Animation's uber shader took 26 s to compile, and WindowServer waited on it for up to a minute at the first boot
// after an install (i74; the stock compiler too). This is the same walk with the same answers: one getUser per use, a
// flat pointer set, an explicit stack. Only the Ivy Bridge build (checked by hash), only for an empty set, which is all
// its callers pass. INTEL_VALUE_USED_CHECK=1 runs the original too and reports any difference.
static const uint64_t kIsValueUsedHashIVB = 0xe6c9c39bb2e6d97dULL;
static const size_t kIsValueUsedSizeIVB = 594;
static bool (*originalIsValueUsed)(void *visited, const char *target, const char *root, const char *begin, const char *end);
extern "C" const char *useGetUser(const char *use) asm("__ZNK4llvm3Use7getUserEv");
struct NameRef { const char *data; size_t length; };
extern "C" NameRef valueGetName(const char *value) asm("__ZNK4llvm5Value7getNameEv");
static std::atomic<unsigned long> valueUsedMismatches, valueUsedCalls, valueUsedSteps, valueUsedRootKinds[256];
namespace valueused {
using namespace llvm38;
// Open addressing on pointers; returns false if already present. Kept per thread and emptied after each walk by
// clearing only the slots it filled (a compile calls the walk thousands of times).
struct PointerSet {
    std::vector<uintptr_t> slots = std::vector<uintptr_t>(1024);
    std::vector<size_t> filled;
    bool insert(uintptr_t p) {
        if (2 * (filled.size() + 1) > slots.size()) grow();
        size_t mask = slots.size() - 1, i = (p >> 4) * 0x9e3779b97f4a7c15ULL >> 20 & mask;
        for (;; i = (i + 1) & mask) {
            if (slots[i] == p) return false;
            if (!slots[i]) return slots[i] = p, filled.push_back(i), true;
        }
    }
    void grow() {
        std::vector<uintptr_t> old(slots.size() * 2);
        old.swap(slots);
        filled.clear();
        for (uintptr_t p : old) if (p) insert(p);
    }
    void clear() {
        for (size_t i : filled) slots[i] = 0;
        filled.clear();
    }
};
static bool namePrefix(const char *function, const char *prefix, size_t n) {
    NameRef name = valueGetName(function);
    return name.length >= n && !memcmp(name.data, prefix, n);
}
struct Frame { const char *value, *next, *end; };
struct Walker { std::vector<Frame> stack; PointerSet visited; };
static bool walk(const char *target, const char *root, const char *begin, const char *end) {
    static thread_local Walker walker;
    struct Reset { Walker &w; ~Reset() { w.stack.clear(); w.visited.clear(); } } reset{walker};
    std::vector<Frame> &stack = walker.stack;
    PointerSet &visited = walker.visited;
    stack.push_back({root, begin, end});
    while (!stack.empty()) {
        Frame &f = stack.back();
        if (f.next == f.end) { stack.pop_back(); continue; }
        const char *use = f.next, *value = f.value;
        f.next = nextUse(use);
        const char *user = useGetUser(use);
        if (!visited.insert((uintptr_t)user)) continue;
        if (logging()) valueUsedSteps++;
        unsigned char kind = valueId(user);
        if (user == target) {
            if (kind == kLoadInstruction || kind == kStoreInstruction) { if (lastOperand(user) == value) return true; continue; }
            return true;
        }
        if (kind == kGEPInstruction) {
            if (operand(user, 0) == value) stack.push_back({user, firstUse(user), nullptr});
            continue;
        }
        if (kind == kLoadInstruction || kind == kStoreInstruction) continue;
        if (kind == kCallInstruction) {
            const char *callee = lastOperand(user);
            if (!callee || valueId(callee) != kFunctionValue || !namePrefix(callee, "llvm.", 5)) continue;  // Function::isIntrinsic
            if (namePrefix(callee, "llvm.igil.ld", 12) || namePrefix(callee, "llvm.igil.st", 12)) continue;
        }
        stack.push_back({user, firstUse(user), nullptr});
    }
    return false;
}
}  // namespace valueused
static void reportValueUsed() {
    fprintf(stderr, "[inteltex] isValueUsed: %lu walks, %lu users visited; roots by value id:", valueUsedCalls.load(), valueUsedSteps.load());
    for (int i = 0; i < 256; i++) if (valueUsedRootKinds[i]) fprintf(stderr, " %d:%lu", i, valueUsedRootKinds[i].load());
    fprintf(stderr, "\n");
}
static bool hookedIsValueUsed(void *visited, const char *target, const char *root, const char *begin, const char *end) {
    if (((const size_t *)visited)[2]) return originalIsValueUsed(visited, target, root, begin, end);  // std::set size
    bool result = valueused::walk(target, root, begin, end);
    if (logging()) {
        static std::once_flag once;
        std::call_once(once, [] { atexit(reportValueUsed); });
        valueUsedCalls++;
        valueUsedRootKinds[llvm38::valueId(root)]++;
    }
    static const bool check = getenv("INTEL_VALUE_USED_CHECK") && !disabled("INTEL_VALUE_USED_CHECK");
    if (check && result != originalIsValueUsed(visited, target, root, begin, end)) {
        valueUsedMismatches++;
        fprintf(stderr, "[inteltex] isValueUsed MISMATCH: fast %d (target %p root %p)\n", result, target, root);
    }
    return result;
}
static uint64_t fnv1a(const unsigned char *p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    while (n--) h = (h ^ *p++) * 0x100000001b3ULL;
    return h;
}

// The back-end hooks, once libIGIL-Metal is loaded (the plugin loads it on demand).
static bool installIntoBackEnd(void *igil) {
    unsigned char *valueUsed = (unsigned char *)dlsym(igil, "_ZN19IGILHelperFunctions11isValueUsedERNSt3__13setIPN4llvm5ValueENS0_4lessIS4_EENS0_9allocatorIS4_EEEEPKS3_SC_NS3_17use_iterator_implIKNS2_3UseEEESG_");
    if (valueUsed && fnv1a(valueUsed, kIsValueUsedSizeIVB) == kIsValueUsedHashIVB && !disabled("INTEL_VALUE_USED_FIX"))
        originalIsValueUsed = (bool (*)(void *, const char *, const char *, const char *, const char *))hookFunction(valueUsed, (void *)hookedIsValueUsed);
    if (logging()) fprintf(stderr, "[inteltex] libIGIL-Metal: isValueUsed %s\n", originalIsValueUsed ? "hooked" : "NOT hooked");
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
// IGILParseMetadata aborts the compiler service on the air.max_work_group_size that
// [[max_total_threads_per_threadgroup(N)]] adds (every Firefox WebGPU device on the Intel GPU was lost). The value is
// only a hint and the parser skips empty attribute nodes, so it becomes !{}.
static unsigned dropMaxWorkGroupSize(LLVMModuleRef module) {
    unsigned dropped = 0;
    void *empty = nullptr;
    forEachEntryPoint(module, [&](const EntryPoint &entry) {
        if (strcmp(entry.list, "air.kernel")) return;
        for (unsigned i = 1; i < entry.operands.size(); i++) {
            std::vector<LLVMValueRef> attribute = metadataOperands(entry.operands[i]);
            if (attribute.empty() || !isString(attribute[0], "air.max_work_group_size")) continue;
            void *node = metadataOf(entry.node);
            if (!empty) empty = metadataOf(LLVMMDNodeInContext(LLVMGetModuleContext(module), nullptr, 0));
            if (!node || !empty) continue;
            mdNodeReplaceOperand(node, i, empty);
            dropped++;
        }
    });
    return dropped;
}

// The plugin's MetadataParser::parseArgument asserts that an argument with air.struct_type_info points to a struct,
// which aborts MTLCompilerService for `device T (&)[N]` arguments (naga writes them; i01). For plain-data structs the
// info is reflection only, so it is dropped from such arguments.
// Struct info that describes plain data only: scalar, vector or plain-struct members; no buffers, textures or samplers.
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

static bool isPointerToArray(LLVMValueRef value) {
    enum { kPointerKind = 12, kArrayKind = 11 };  // LLVMTypeKind
    LLVMTypeRef type = LLVMTypeOf(value);
    return LLVMGetTypeKind(type) == kPointerKind && LLVMGetTypeKind(LLVMGetElementType(type)) == kArrayKind;
}
static unsigned dropArrayStructInfo(LLVMModuleRef module) {
    return rewriteEachArgument(module, [](LLVMValueRef function, const std::vector<LLVMValueRef> &description) {
        std::vector<LLVMValueRef> withoutStructInfo;
        long param = description.empty() ? -1 : metadataInt(description[0]);
        long info = indexOfKeyWithValue(description, "air.struct_type_info");
        if (!function || param < 0 || info < 0 || (unsigned long)param >= LLVMCountParams(function)) return withoutStructInfo;
        if (!isPointerToArray(LLVMGetParam(function, (unsigned)param))) return withoutStructInfo;
        if (!plainStructInfo(description[info + 1], 0)) return withoutStructInfo;  // resources inside (indirect arguments)
        for (long j = 0; j < (long)description.size(); j++)
            if (j != info && j != info + 1) withoutStructInfo.push_back(description[j]);
        return withoutStructInfo;
    });
}

// ---- argument-buffer references in the 12.x plugin's emulation --------------------------------------------------------
// The 12.x plugin's argument-buffer emulation writes each hidden buffer's number into the operand after
// "air.location_index". For a reference member the macOS 14 front end puts "air.buffer_size" there first, so the number
// lands in the size and the kernel uses a buffer the driver never binds (Safari's WebGPU compute on Haswell). (i83, s86)
enum EmulatedReferenceOperand { kArgNo, kKind, kSizeKey, kSlot, kLocationKey, kMemberId, kFirstOtherOperand };
static bool hasEmulationSlotInSizeField(const std::vector<LLVMValueRef> &description) {
    return description.size() >= kFirstOtherOperand && isString(description[kKind], "air.buffer") &&
           isString(description[kSizeKey], "air.buffer_size") && metadataInt(description[kSlot]) >= 0 &&
           isString(description[kLocationKey], "air.location_index") && metadataInt(description[kMemberId]) >= 0 &&
           isString(description.back(), "air.emulation_argument");
}
static unsigned moveEmulatedReferenceSlotsToLocation(LLVMModuleRef module) {
    if (disabled("INTEL_EMULATED_REFERENCE_FIX")) return 0;
    return rewriteEachArgument(module, [](LLVMValueRef, const std::vector<LLVMValueRef> &description) {
        std::vector<LLVMValueRef> pointerMemberForm;
        if (!hasEmulationSlotInSizeField(description)) return pointerMemberForm;
        pointerMemberForm = {description[kArgNo], description[kKind], description[kLocationKey], description[kSlot]};
        pointerMemberForm.insert(pointerMemberForm.end(), description.begin() + kFirstOtherOperand, description.end());
        return pointerMemberForm;
    });
}

// ---- argument buffers on Ivy Bridge ---------------------------------------------------------------------------------
// OCLP's 11.7.10 Ivy Bridge plugin doesn't emulate argument buffers and its driver has no argument-buffer runtime: a
// pointer member was read as an offset into the argument buffer itself, and vertex and fragment functions failed to
// build (i85, s61; WebKit's ANGLE puts every WebGL 2 uniform block in one). Each pointer member becomes a hidden buffer
// parameter __ivbab_<argument buffer index>_<id> at a free buffer index counted down from 30 (vertex functions keep
// 0-16 for vertex buffers), which MetalOldCompat item 47 binds; texture and sampler members, which crashed the compiler service, likewise become hidden texture and sampler
// parameters counted down from 30 and 15 (s86, MetalOldCompat item 79). Constants stay in the argument buffer.
// (LLVMGetAttributeCountAtIndex dereferences an empty attribute set in this LLVM, so the attributes go over whole)
extern "C" void functionCopyAttributesFrom(void *function, const void *source) asm("__ZN4llvm8Function18copyAttributesFromEPKNS_11GlobalValueE");
extern "C" void basicBlockInsertInto(void *block, void *function, void *before) asm("__ZN4llvm10BasicBlock10insertIntoEPNS_8FunctionEPS0_");
extern "C" void *valueAsMetadataGet(void *value) asm("__ZN4llvm15ValueAsMetadata3getEPNS_5ValueE");

enum { kAbIntegerKind = 8, kAbStructKind = 10, kAbArrayKind = 11, kAbPointerKind = 12 };  // LLVMTypeKind

enum { kSlotBuffer, kSlotTexture, kSlotSampler, kSlotKinds };
struct ArgumentBufferSlot {  // one pointer or handle of an argument buffer, reached by GEP(argument buffer, 0, path...)
    unsigned kind, bufferIndex, id, hidden;
    std::vector<unsigned> path;
    LLVMValueRef kindNode;  // the member's !{n, !"air.buffer", !"air.location_index", id, count, ...}
    LLVMValueRef param = nullptr;
    LLVMTypeRef type = nullptr;  // the pointer or handle type at the path: the hidden parameter's type
};


// The members of a struct_type_info node: [!"air.struct_type_info", !nested,] offset, size, count, type name, name,
// !"air.indirect_argument", !kind-or-i32 each. The i32 of a nested member (a metal::array) is its first id.
struct StructInfoMember { long count; LLVMValueRef nested, kind; long firstId, offset; };
static bool structInfoMembers(LLVMValueRef info, std::vector<StructInfoMember> &out) {
    std::vector<LLVMValueRef> ops = metadataOperands(info);
    for (size_t i = 0; i < ops.size();) {
        LLVMValueRef nested = nullptr;
        if (isString(ops[i], "air.struct_type_info")) {
            if (i + 1 >= ops.size() || !LLVMIsAMDNode(ops[i + 1])) return false;
            nested = ops[i + 1];
            i += 2;
        }
        if (i + 7 > ops.size() || !isString(ops[i + 5], "air.indirect_argument")) return false;
        bool node = LLVMIsAMDNode(ops[i + 6]);
        out.push_back({metadataInt(ops[i + 2]), nested, node ? ops[i + 6] : nullptr, node ? -1 : metadataInt(ops[i + 6]), metadataInt(ops[i])});
        i += 7;
    }
    return !out.empty();
}
static bool isBufferKind(LLVMValueRef kind, long &id) {
    std::vector<LLVMValueRef> f = metadataOperands(kind);
    if (f.size() < 2 || !isString(f[1], "air.buffer")) return false;
    id = fieldAfter(f, "air.location_index");
    return id >= 0;
}
// A texture or sampler member: kSlotTexture / kSlotSampler, its id, and the path to its handle in its element (a
// metal::texture2d / metal::sampler struct around one pointer: {0}; the pointer itself: {}). -1 if it isn't one.
static int handleSlotKind(LLVMValueRef kind, LLVMTypeRef element, long &id, std::vector<unsigned> &inner, LLVMTypeRef &pointer) {
    std::vector<LLVMValueRef> f = metadataOperands(kind);
    if (f.size() < 2) return -1;
    int slot = isString(f[1], "air.texture") ? kSlotTexture : isString(f[1], "air.sampler") ? kSlotSampler : -1;
    if (slot < 0 || fieldAfter(f, "air.location_index", 2) > 1 || disabled("INTEL_IVB_ARGUMENT_BUFFER_TEXTURES")) return -1;
    id = fieldAfter(f, "air.location_index");
    inner.clear();
    if (LLVMGetTypeKind(element) == kAbStructKind && LLVMCountStructElementTypes(element) == 1) {
        element = LLVMStructGetTypeAtIndex(element, 0);
        inner.push_back(0);
    }
    pointer = element;
    return id >= 0 && LLVMGetTypeKind(element) == kAbPointerKind ? slot : -1;
}

// A struct element that is only padding: [n x i8].
static bool bytePadding(LLVMTypeRef type) {
    return LLVMGetTypeKind(type) == kAbArrayKind && LLVMGetTypeKind(LLVMGetElementType(type)) == kAbIntegerKind &&
           LLVMGetIntTypeWidth(LLVMGetElementType(type)) == 8;
}

// The pointer slots of one argument buffer: pointer members (path {e}) and metal::array members of pointers ({e, 0, j}),
// e being the member's element of the struct type. A struct with a reference member (WebKit's WebGPU writes
// `device array<T, 1> &x [[id(0)]]; uint length [[id(1)]];`) is a packed struct with explicit padding instead, whose
// members are matched to elements by byte offset (i82). False for a layout this pass doesn't follow.
static bool argumentBufferSlots(LLVMValueRef info, LLVMTypeRef structType, unsigned bufferIndex, std::vector<ArgumentBufferSlot> &out,
                                LLVMTargetDataRef td) {
    std::vector<StructInfoMember> members;
    if (!structInfoMembers(info, members) || LLVMGetTypeKind(structType) != kAbStructKind) return false;
    unsigned elements = LLVMCountStructElementTypes(structType);
    std::vector<unsigned> elementOf(members.size());
    if (elements == members.size()) {
        for (unsigned m = 0; m < members.size(); m++) elementOf[m] = m;
    } else {
        if (!td || elements < members.size() || disabled("INTEL_IVB_PADDED_ARGUMENT_BUFFER_FIX")) return false;
        unsigned m = 0;
        for (unsigned e = 0; e < elements; e++) {
            unsigned long long offset = LLVMOffsetOfElement(td, structType, e);
            if (m < members.size() && members[m].offset >= 0 && offset == (unsigned long long)members[m].offset) elementOf[m++] = e;
            else if (!bytePadding(LLVMStructGetTypeAtIndex(structType, e))) return false;  // an element no member describes
        }
        if (m != members.size()) return false;
    }
    for (unsigned m = 0; m < members.size(); m++) {
        unsigned e = elementOf[m];
        LLVMTypeRef element = LLVMStructGetTypeAtIndex(structType, e);
        long id = -1;
        if (members[m].kind && isBufferKind(members[m].kind, id)) {
            if (LLVMGetTypeKind(element) != kAbPointerKind) return false;
            out.push_back({kSlotBuffer, bufferIndex, (unsigned)id, 0, {e}, members[m].kind});
            out.back().type = element;
            continue;
        }
        std::vector<unsigned> inner;
        LLVMTypeRef pointer = nullptr;
        int handle = members[m].kind ? handleSlotKind(members[m].kind, element, id, inner, pointer) : -1;
        if (handle >= 0) {
            std::vector<unsigned> path = {e};
            path.insert(path.end(), inner.begin(), inner.end());
            out.push_back({(unsigned)handle, bufferIndex, (unsigned)id, 0, path, members[m].kind});
            out.back().type = pointer;
            continue;
        }
        if (!members[m].nested) continue;
        std::vector<StructInfoMember> nested;
        if (!structInfoMembers(members[m].nested, nested) || nested.size() != 1 || !nested[0].kind || !isBufferKind(nested[0].kind, id))
            continue;  // a nested struct of something else
        if (LLVMGetTypeKind(element) != kAbStructKind || LLVMCountStructElementTypes(element) != 1) return false;
        LLVMTypeRef array = LLVMStructGetTypeAtIndex(element, 0);
        if (LLVMGetTypeKind(array) != kAbArrayKind || LLVMGetTypeKind(LLVMGetElementType(array)) != kAbPointerKind ||
            nested[0].count != (long)LLVMGetArrayLength(array))
            return false;
        // the __elems member's id counts from the array's own first id (!"air.indirect_argument", i32 3 for
        // array<constant B *, 3> b [[id(3)]]), which an argument buffer with two arrays needs
        long first = members[m].firstId > 0 ? members[m].firstId : 0;
        for (unsigned j = 0; j < LLVMGetArrayLength(array); j++) {
            out.push_back({kSlotBuffer, bufferIndex, (unsigned)(first + id) + j, 0, {e, 0, j}, nested[0].kind});
            out.back().type = LLVMGetElementType(array);
        }
    }
    return true;
}

// The slot a load reads its pointer through: GEP(param, 0, path...) with constant indices. *wrapper: the GEP is to the
// metal::texture2d / metal::sampler struct around a handle (path... without its last 0), which WebKit's copies of such a
// member load as an i64 through a bitcast (`texture2d<float> t = ab.t;`).
static ArgumentBufferSlot *slotOf(LLVMValueRef gep, LLVMValueRef param, unsigned bufferIndex, std::vector<ArgumentBufferSlot> &slots,
                                  bool *wrapper) {
    if (!gep || !LLVMIsAGetElementPtrInst(gep) || LLVMGetOperand(gep, 0) != param) return nullptr;
    int n = LLVMGetNumOperands(gep);
    if (n < 3) return nullptr;
    std::vector<unsigned> path;
    for (int i = 1; i < n; i++) {
        LLVMValueRef index = LLVMGetOperand(gep, i);
        if (!LLVMIsAConstantInt(index)) return nullptr;
        if (i > 1) path.push_back((unsigned)LLVMConstIntGetZExtValue(index));
        else if (LLVMConstIntGetZExtValue(index)) return nullptr;
    }
    *wrapper = false;
    for (ArgumentBufferSlot &s : slots)
        if (s.bufferIndex == bufferIndex && s.path == path) return &s;
    path.push_back(0);
    for (ArgumentBufferSlot &s : slots)
        if (s.bufferIndex == bufferIndex && s.kind != kSlotBuffer && s.path == path) return *wrapper = true, &s;
    return nullptr;
}
enum { kOpIntToPtr = 40 };  // LLVMOpcode
// A load the rewrite can replace: of the pointer itself, or of a 64-bit integer through a bitcast.
static bool slotLoad(LLVMValueRef load, LLVMValueRef from) {
    if (!LLVMIsALoadInst(load) || LLVMGetOperand(load, 0) != from) return false;
    LLVMTypeRef t = LLVMTypeOf(load);
    return LLVMGetTypeKind(t) == kAbPointerKind || (LLVMGetTypeKind(t) == kAbIntegerKind && LLVMGetIntTypeWidth(t) == 64);
}

// ---- program-scope constants in vertex and fragment functions on Ivy Bridge -----------------------------------------
// The 11.7.10 plugin puts a vertex or fragment function's program-scope constants in an inline constant buffer that its
// driver doesn't bind, so their loads read the app's buffer 0, or 0 (i73; compute kernels are right). Loads at a
// constant address read the initializer instead, and loads of a small array at a run-time index a select over its
// elements.
// Element `index` of a constant aggregate, or null.
static LLVMValueRef constantElement(LLVMValueRef c, unsigned index) {
    LLVMTypeRef type = LLVMTypeOf(c);
    int kind = LLVMGetTypeKind(type);
    if (kind == kAbArrayKind && index >= LLVMGetArrayLength(type)) return nullptr;
    if (kind == kAbStructKind && index >= LLVMCountStructElementTypes(type)) return nullptr;
    if (kind != kAbArrayKind && kind != kAbStructKind) return nullptr;
    if (LLVMIsAConstantAggregateZero(c))
        return LLVMConstNull(kind == kAbArrayKind ? LLVMGetElementType(type) : LLVMStructGetTypeAtIndex(type, index));
    if (LLVMIsAConstantDataSequential(c)) return LLVMGetElementAsConstant(c, index);
    if (LLVMIsAConstantArray(c) || LLVMIsAConstantStruct(c)) return LLVMGetOperand(c, index);
    return nullptr;
}
static bool scalarOrVector(LLVMTypeRef type) {
    int kind = LLVMGetTypeKind(type);
    return kind == 1 || kind == 2 || kind == 3 || kind == 8 || kind == 13;  // half, float, double, integer, vector
}

static unsigned ivbInlineConstants(LLVMModuleRef module) {
    if (disabled("INTEL_IVB_INLINE_CONSTANT_FIX")) return 0;
    if (!LLVMGetNamedMetadataNumOperands(module, "air.vertex") && !LLVMGetNamedMetadataNumOperands(module, "air.fragment")) return 0;
    enum { kGEP = 29 };  // LLVMOpcode
    unsigned replaced = 0;
    LLVMBuilderRef builder = nullptr;
    for (LLVMValueRef global = LLVMGetFirstGlobal(module); global; global = LLVMGetNextGlobal(global)) {
        LLVMValueRef init = LLVMGetInitializer(global);
        if (!init || LLVMIsDeclaration(global) || LLVMGetPointerAddressSpace(LLVMTypeOf(global)) != 2) continue;
        std::vector<LLVMValueRef> users;
        for (LLVMUseRef u = LLVMGetFirstUse(global); u; u = LLVMGetNextUse(u)) users.push_back(LLVMGetUser(u));
        for (LLVMValueRef user : users) {
            // the element a constant path leads to, from the variable itself (path empty) or a constant GEP of it
            std::vector<LLVMValueRef> loads, path;
            LLVMValueRef dynamic = nullptr;  // a run-time last index
            if (LLVMIsALoadInst(user)) {
                loads.push_back(user);
            } else if ((LLVMIsAConstantExpr(user) && LLVMGetConstOpcode(user) == kGEP) || LLVMIsAGetElementPtrInst(user)) {
                int n = LLVMGetNumOperands(user);
                if (n < 3 || LLVMGetOperand(user, 0) != global || !LLVMIsAConstantInt(LLVMGetOperand(user, 1)) ||
                    LLVMConstIntGetZExtValue(LLVMGetOperand(user, 1)) != 0)
                    continue;
                bool ok = true;
                for (int i = 2; i < n; i++) {
                    LLVMValueRef index = LLVMGetOperand(user, i);
                    if (LLVMIsAConstantInt(index)) path.push_back(index);
                    else if (i == n - 1 && LLVMIsAGetElementPtrInst(user)) dynamic = index;
                    else ok = false;
                }
                if (!ok) continue;
                for (LLVMUseRef u = LLVMGetFirstUse(user); u; u = LLVMGetNextUse(u))
                    if (LLVMIsALoadInst(LLVMGetUser(u)) && LLVMGetOperand(LLVMGetUser(u), 0) == user) loads.push_back(LLVMGetUser(u));
            }
            if (loads.empty()) continue;
            LLVMValueRef value = init;
            for (LLVMValueRef index : path)
                if (value) value = constantElement(value, (unsigned)LLVMConstIntGetZExtValue(index));
            if (!value) continue;
            std::vector<LLVMValueRef> elements;  // for a run-time index: the array's elements
            if (dynamic) {
                LLVMTypeRef type = LLVMTypeOf(value);
                if (LLVMGetTypeKind(type) != kAbArrayKind || LLVMGetArrayLength(type) > 64 || !LLVMGetArrayLength(type) ||
                    !scalarOrVector(LLVMGetElementType(type)))
                    continue;
                for (unsigned k = 0; k < LLVMGetArrayLength(type); k++) elements.push_back(constantElement(value, k));
                if (std::find(elements.begin(), elements.end(), nullptr) != elements.end()) continue;
            } else if (!scalarOrVector(LLVMTypeOf(value)))
                continue;
            for (LLVMValueRef load : loads) {
                LLVMValueRef result = value;
                if (dynamic) {
                    if (!builder) builder = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
                    LLVMPositionBuilderBefore(builder, load);
                    result = elements.back();
                    for (size_t k = elements.size() - 1; k-- > 0;) {
                        LLVMValueRef is = LLVMBuildICmp(builder, 32 /* LLVMIntEQ */, dynamic, LLVMConstInt(LLVMTypeOf(dynamic), k, 0), "");
                        result = LLVMBuildSelect(builder, is, elements[k], result, "");
                    }
                }
                if (LLVMTypeOf(result) != LLVMTypeOf(load)) continue;
                LLVMReplaceAllUsesWith(load, result);
                LLVMInstructionEraseFromParent(load);
                replaced++;
            }
            if (LLVMIsAGetElementPtrInst(user) && !LLVMGetFirstUse(user)) LLVMInstructionEraseFromParent(user);
        }
    }
    if (builder) LLVMDisposeBuilder(builder);
    return replaced;
}

// ANGLE's entry functions hand the argument buffer to the translated main (an internal function), so the pointer loads
// are in a callee when the module gets here: every function such an entry calls, transitively, is inlined first
// (alwaysinline and LLVM's always-inliner), which the back end would have done anyway.
static bool passesArgumentBufferToCall(LLVMValueRef function, LLVMValueRef inputs) {
    for (LLVMValueRef description : metadataOperands(inputs)) {
        std::vector<LLVMValueRef> fields = metadataOperands(description);
        long param = fields.size() > 1 && isString(fields[1], "air.indirect_buffer") ? metadataInt(fields[0]) : -1;
        if (param < 0 || (unsigned)param >= LLVMCountParams(function)) continue;
        for (LLVMUseRef use = LLVMGetFirstUse(LLVMGetParam(function, (unsigned)param)); use; use = LLVMGetNextUse(use))
            if (LLVMIsACallInst(LLVMGetUser(use))) return true;
    }
    return false;
}
static bool inlineArgumentBufferCallees(LLVMModuleRef module) {
    LLVMContextRef context = LLVMGetModuleContext(module);
    std::vector<LLVMValueRef> work;
    forEachEntryPoint(module, [&](const EntryPoint &entry) {
        LLVMValueRef function = entry.function();
        if (entry.operands.size() < 3 || !function || !LLVMIsAFunction(function) || LLVMIsDeclaration(function)) return;
        if (passesArgumentBufferToCall(function, entry.operands[2])) work.push_back(function);
    });
    std::set<LLVMValueRef> marked;
    unsigned alwaysInline = LLVMGetEnumAttributeKindForName("alwaysinline", 12);
    unsigned noInline = LLVMGetEnumAttributeKindForName("noinline", 8);
    while (!work.empty()) {
        LLVMValueRef f = work.back();
        work.pop_back();
        for (LLVMBasicBlockRef block = LLVMGetFirstBasicBlock(f); block; block = LLVMGetNextBasicBlock(block))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(block); inst; inst = LLVMGetNextInstruction(inst)) {
                LLVMValueRef callee = LLVMIsACallInst(inst) ? LLVMGetCalledValue(inst) : nullptr;
                if (!callee || !LLVMIsAFunction(callee) || LLVMIsDeclaration(callee) || marked.count(callee)) continue;
                marked.insert(callee);
                if (noInline) LLVMRemoveEnumAttributeAtIndex(callee, ~0u, noInline);
                LLVMAddAttributeAtIndex(callee, ~0u, LLVMCreateEnumAttribute(context, alwaysInline, 0));
                work.push_back(callee);
            }
    }
    if (marked.empty() || !alwaysInline) return false;
    LLVMPassManagerRef passes = LLVMCreatePassManager();
    LLVMAddAlwaysInlinerPass(passes);
    LLVMRunPassManager(passes, module);
    LLVMDisposePassManager(passes);
    if (logging()) fprintf(stderr, "[inteltex] %zu function(s) an argument buffer is passed to inlined\n", marked.size());
    return true;
}

static unsigned ivbArgumentBuffers(LLVMModuleRef module) {
    if (disabled("INTEL_IVB_ARGUMENT_BUFFER_FIX")) return 0;
    inlineArgumentBufferCallees(module);
    unsigned rewritten = 0;
    const char *dataLayout = LLVMGetDataLayoutStr(module);
    LLVMTargetDataRef layout = dataLayout ? LLVMCreateTargetData(dataLayout) : nullptr;  // for packed structs, see argumentBufferSlots
    struct DisposeLayout { LLVMTargetDataRef t; ~DisposeLayout() { if (t) LLVMDisposeTargetData(t); } } disposeLayout{layout};
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context);
    forEachEntryPoint(module, [&](const EntryPoint &entry) {
        const std::vector<LLVMValueRef> &parts = entry.operands;
        const char *list = entry.list;
        if (parts.size() < 3 || !parts[0] || LLVMIsDeclaration(parts[0])) return;
        LLVMValueRef function = parts[0];
        unsigned params = LLVMCountParams(function);
        std::vector<LLVMValueRef> args = metadataOperands(parts[2]);
        // buffer, texture and sampler indices the function already uses, and its argument buffers in index order
        std::set<unsigned> used[kSlotKinds];
        std::map<unsigned, std::pair<unsigned, LLVMValueRef>> buffers;  // index -> (param, struct_type_info)
        bool ok = true;
        for (LLVMValueRef arg : args) {
            std::vector<LLVMValueRef> f = metadataOperands(arg);
            if (f.size() < 2) continue;
            bool plain = isString(f[1], "air.buffer"), indirect = isString(f[1], "air.indirect_buffer");
            int handle = isString(f[1], "air.texture") ? kSlotTexture : isString(f[1], "air.sampler") ? kSlotSampler : -1;
            if (!plain && !indirect && handle < 0) continue;
            long index = fieldAfter(f, "air.location_index"), count = fieldAfter(f, "air.location_index", 2), param = metadataInt(f[0]);
            if (index < 0 || param < 0 || (unsigned)param >= params) { ok = false; break; }
            for (long k = 0; k < (count > 0 ? count : 1); k++) used[handle < 0 ? kSlotBuffer : handle].insert((unsigned)(index + k));
            if (handle >= 0) continue;
            if (!indirect) continue;
            long info = -1;
            for (size_t k = 0; k + 1 < f.size(); k++)
                if (isString(f[k], "air.struct_type_info")) info = (long)k + 1;
            if (info < 0) { ok = false; break; }
            buffers[(unsigned)index] = {(unsigned)param, f[info]};
        }
        if (!ok || buffers.empty()) return;
        std::vector<ArgumentBufferSlot> slots;
        for (auto &b : buffers) {
            LLVMTypeRef type = LLVMTypeOf(LLVMGetParam(function, b.second.first));
            if (LLVMGetTypeKind(type) != kAbPointerKind ||
                !argumentBufferSlots(b.second.second, LLVMGetElementType(type), b.first, slots, layout)) { ok = false; break; }
        }
        if (!ok || slots.empty()) return;
        std::sort(slots.begin(), slots.end(), [](const ArgumentBufferSlot &a, const ArgumentBufferSlot &b) {
            return a.bufferIndex != b.bufferIndex ? a.bufferIndex < b.bufferIndex : a.id < b.id;
        });
        // counted down per kind, in order of argument buffer index and id (as MetalOldCompat does)
        int next[kSlotKinds] = {30, 30, 15};
        int lowest[kSlotKinds] = {!strcmp(list, "air.vertex") ? 17 : 0, 0, 0};
        for (ArgumentBufferSlot &s : slots) {
            int &n = next[s.kind];
            while (n >= lowest[s.kind] && used[s.kind].count((unsigned)n)) n--;
            if (n < lowest[s.kind]) { ok = false; break; }
            s.hidden = (unsigned)n--;
        }
        if (!ok) {
            if (logging()) fprintf(stderr, "[inteltex] %s: %zu argument-buffer pointers/handles, not enough free indices\n",
                                   LLVMGetValueName(function), slots.size());
            return;
        }
        // the pointer loads: load(GEP(argument buffer, 0, member[, element])), or through a bitcast of it
        struct SlotLoad { LLVMValueRef first, cast; ArgumentBufferSlot *second; };
        std::vector<SlotLoad> loads;
        for (auto &b : buffers) {
            LLVMValueRef param = LLVMGetParam(function, b.second.first);
            for (LLVMUseRef u = LLVMGetFirstUse(param); u; u = LLVMGetNextUse(u)) {
                LLVMValueRef gep = LLVMGetUser(u);
                bool wrapper = false;
                ArgumentBufferSlot *slot = slotOf(gep, param, b.first, slots, &wrapper);
                if (!slot && LLVMIsABitCastInst(gep) && LLVMGetOperand(gep, 0) == param) {
                    // the first member, at offset 0, read through a cast of the argument buffer itself (WebKit's
                    // `i8 constant *` for a bind group with dynamic offsets): element 0, or the handle in its wrapper
                    for (ArgumentBufferSlot &s : slots)
                        if (s.bufferIndex == b.first && (s.path == std::vector<unsigned>{0} ||
                                                         (s.kind != kSlotBuffer && s.path == std::vector<unsigned>{0, 0})))
                            slot = &s;
                    if (slot)
                        for (LLVMUseRef w = LLVMGetFirstUse(gep); w; w = LLVMGetNextUse(w))
                            if (slotLoad(LLVMGetUser(w), gep)) loads.push_back({LLVMGetUser(w), gep, slot});
                    continue;
                }
                if (!slot) continue;
                for (LLVMUseRef v = LLVMGetFirstUse(gep); v; v = LLVMGetNextUse(v)) {
                    LLVMValueRef user = LLVMGetUser(v);
                    if (!wrapper && slotLoad(user, gep)) loads.push_back({user, nullptr, slot});
                    else if (LLVMIsABitCastInst(user) && LLVMGetOperand(user, 0) == gep)
                        for (LLVMUseRef w = LLVMGetFirstUse(user); w; w = LLVMGetNextUse(w))
                            if (slotLoad(LLVMGetUser(w), user)) loads.push_back({LLVMGetUser(w), user, slot});
                }
            }
        }
        if (loads.empty()) return;
        std::vector<ArgumentBufferSlot *> hidden;  // slots that get a parameter, in parameter order
        for (auto &l : loads)
            if (std::find(hidden.begin(), hidden.end(), l.second) == hidden.end()) hidden.push_back(l.second);
        // the new function: the old parameters, then one per loaded slot; the body moves over
        LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(function));
        std::vector<LLVMTypeRef> types(LLVMCountParamTypes(type));
        LLVMGetParamTypes(type, types.data());
        for (ArgumentBufferSlot *s : hidden)
            for (auto &l : loads)
                if (l.second == s) { types.push_back(s->type ? s->type : LLVMTypeOf(l.first)); break; }
        std::string name = LLVMGetValueName(function);
        LLVMSetValueName(function, (name + ".ivbab").c_str());
        LLVMValueRef rewrittenFn = LLVMAddFunction(module, name.c_str(),
            LLVMFunctionType(LLVMGetReturnType(type), types.data(), (unsigned)types.size(), LLVMIsFunctionVarArg(type)));
        LLVMSetLinkage(rewrittenFn, LLVMGetLinkage(function));
        functionCopyAttributesFrom(rewrittenFn, function);  // the attribute set by position: the old parameters keep theirs
        for (unsigned p = 0; p < params; p++) {
            LLVMSetValueName(LLVMGetParam(rewrittenFn, p), LLVMGetValueName(LLVMGetParam(function, p)));
            LLVMReplaceAllUsesWith(LLVMGetParam(function, p), LLVMGetParam(rewrittenFn, p));
        }
        while (LLVMBasicBlockRef block = LLVMGetFirstBasicBlock(function)) {
            LLVMRemoveBasicBlockFromParent(block);
            basicBlockInsertInto(block, rewrittenFn, nullptr);
        }
        std::vector<LLVMValueRef> newArgs = args;
        for (size_t h = 0; h < hidden.size(); h++) {
            ArgumentBufferSlot *s = hidden[h];
            s->param = LLVMGetParam(rewrittenFn, params + (unsigned)h);
            char hiddenName[48];
            snprintf(hiddenName, sizeof hiddenName, "__ivbab_%u_%u", s->bufferIndex, s->id);
            LLVMSetValueName(s->param, hiddenName);
            std::vector<LLVMValueRef> f = metadataOperands(s->kindNode);
            f[0] = LLVMConstInt(i32, params + h, 0);
            for (size_t k = 0; k + 1 < f.size(); k++) {
                if (isString(f[k], "air.location_index") && k + 2 < f.size()) {
                    f[k + 1] = LLVMConstInt(i32, s->hidden, 0);
                    f[k + 2] = LLVMConstInt(i32, 1, 0);
                }
                if (isString(f[k], "air.arg_name")) f[k + 1] = LLVMMDStringInContext(context, hiddenName, (unsigned)strlen(hiddenName));
            }
            newArgs.push_back(LLVMMDNodeInContext(context, f.data(), (unsigned)f.size()));
        }
        LLVMBuilderRef builder = LLVMCreateBuilderInContext(context);
        for (auto &l : loads) {
            LLVMValueRef gep = l.cast ? LLVMGetOperand(l.cast, 0) : LLVMGetOperand(l.first, 0), param = l.second->param;
            LLVMTypeRef loaded = LLVMTypeOf(l.first);
            if (loaded == LLVMTypeOf(param)) {
                LLVMReplaceAllUsesWith(l.first, param);
            } else if (LLVMGetTypeKind(loaded) == kAbIntegerKind) {  // an i64 copy: its inttoptr to the handle type is the parameter
                std::vector<LLVMValueRef> handles;
                for (LLVMUseRef w = LLVMGetFirstUse(l.first); w; w = LLVMGetNextUse(w))
                    if (LLVMGetInstructionOpcode(LLVMGetUser(w)) == kOpIntToPtr && LLVMTypeOf(LLVMGetUser(w)) == LLVMTypeOf(param))
                        handles.push_back(LLVMGetUser(w));
                for (LLVMValueRef h : handles) {
                    LLVMReplaceAllUsesWith(h, param);
                    LLVMInstructionEraseFromParent(h);
                }
                if (LLVMGetFirstUse(l.first)) {
                    LLVMPositionBuilderBefore(builder, l.first);
                    LLVMReplaceAllUsesWith(l.first, LLVMBuildPtrToInt(builder, param, loaded, ""));
                }
            } else {
                LLVMPositionBuilderBefore(builder, l.first);
                LLVMReplaceAllUsesWith(l.first, LLVMBuildBitCast(builder, param, loaded, ""));
            }
            LLVMInstructionEraseFromParent(l.first);
            if (l.cast && !LLVMGetFirstUse(l.cast)) LLVMInstructionEraseFromParent(l.cast);
            if (LLVMIsAGetElementPtrInst(gep) && !LLVMGetFirstUse(gep)) LLVMInstructionEraseFromParent(gep);  // not the argument buffer itself
        }
        LLVMDisposeBuilder(builder);
        void *node = metadataOf(entry.node), *argList = metadataOf(LLVMMDNodeInContext(context, newArgs.data(), (unsigned)newArgs.size()));
        if (node && argList) {
            mdNodeReplaceOperand(node, 0, valueAsMetadataGet(rewrittenFn));
            mdNodeReplaceOperand(node, 2, argList);
        }
        if (!LLVMGetFirstUse(function)) LLVMDeleteFunction(function);
        rewritten++;
        if (logging()) {
            fprintf(stderr, "[inteltex] %s: %zu argument-buffer pointer/handle load(s) read hidden argument(s)", name.c_str(), loads.size());
            for (ArgumentBufferSlot *s : hidden) fprintf(stderr, " %u.%u->%c%u", s->bufferIndex, s->id, "bts"[s->kind], s->hidden);
            fprintf(stderr, "\n");
        }
    });
    return rewritten;
}


// ---- argument-buffer member offsets in vertex and fragment functions on Ivy Bridge ----------------------------------
// In vertex and fragment functions the 11.7.10 back end lays argument buffers out with 4-byte pointers where the C
// layout (compute kernels, MetalOldCompat item 47's encoder) has 8, so members after a pointer were read early (i84).
// Each member access addresses the member at its byte offset in the data layout instead (an i8 GEP), which the back
// end doesn't lay out again.
static unsigned ivbArgumentBufferOffsets(LLVMModuleRef module) {
    if (disabled("INTEL_IVB_ARGUMENT_BUFFER_OFFSETS")) return 0;
    const char *dataLayout = LLVMGetDataLayoutStr(module);
    LLVMTargetDataRef layout = dataLayout ? LLVMCreateTargetData(dataLayout) : nullptr;
    if (!layout) return 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i8 = LLVMInt8TypeInContext(context), i64 = LLVMInt64TypeInContext(context);
    LLVMBuilderRef builder = LLVMCreateBuilderInContext(context);
    unsigned rewritten = 0;
    for (const char *list : {"air.vertex", "air.fragment"}) {
        std::vector<LLVMValueRef> entries(LLVMGetNamedMetadataNumOperands(module, list));
        if (entries.empty()) continue;
        LLVMGetNamedMetadataOperands(module, list, entries.data());
        for (LLVMValueRef entry : entries) {
            std::vector<LLVMValueRef> parts = metadataOperands(entry);
            if (parts.size() < 3 || !parts[0] || LLVMIsDeclaration(parts[0])) continue;
            LLVMValueRef function = parts[0];
            for (LLVMValueRef arg : metadataOperands(parts[2])) {
                std::vector<LLVMValueRef> f = metadataOperands(arg);
                long index = f.empty() ? -1 : metadataInt(f[0]);
                if (f.size() < 2 || !isString(f[1], "air.indirect_buffer") || index < 0 || (unsigned)index >= LLVMCountParams(function)) continue;
                LLVMValueRef param = LLVMGetParam(function, (unsigned)index);
                LLVMTypeRef pointer = LLVMTypeOf(param);
                if (LLVMGetTypeKind(pointer) != kAbPointerKind || LLVMGetTypeKind(LLVMGetElementType(pointer)) != kAbStructKind) continue;
                LLVMTypeRef structType = LLVMGetElementType(pointer);
                unsigned space = LLVMGetPointerAddressSpace(pointer);
                std::vector<LLVMValueRef> geps;  // GEP(param, 0, constant element, ...)
                for (LLVMUseRef u = LLVMGetFirstUse(param); u; u = LLVMGetNextUse(u)) {
                    LLVMValueRef gep = LLVMGetUser(u);
                    if (!LLVMIsAGetElementPtrInst(gep) || LLVMGetOperand(gep, 0) != param || LLVMGetNumOperands(gep) < 3) continue;
                    LLVMValueRef first = LLVMGetOperand(gep, 1), element = LLVMGetOperand(gep, 2);
                    if (!LLVMIsAConstantInt(first) || LLVMConstIntGetZExtValue(first) || !LLVMIsAConstantInt(element)) continue;
                    if (LLVMConstIntGetZExtValue(element) >= LLVMCountStructElementTypes(structType)) continue;
                    geps.push_back(gep);
                }
                for (LLVMValueRef gep : geps) {
                    unsigned e = (unsigned)LLVMConstIntGetZExtValue(LLVMGetOperand(gep, 2));
                    LLVMTypeRef member = LLVMStructGetTypeAtIndex(structType, e);
                    LLVMPositionBuilderBefore(builder, gep);
                    LLVMValueRef offset = LLVMConstInt(i64, LLVMOffsetOfElement(layout, structType, e), 0);
                    LLVMValueRef bytes = LLVMBuildInBoundsGEP(builder, LLVMBuildBitCast(builder, param, LLVMPointerType(i8, space), ""), &offset, 1, "");
                    LLVMValueRef at = LLVMBuildBitCast(builder, bytes, LLVMPointerType(member, space), "");
                    int n = LLVMGetNumOperands(gep);
                    if (n > 3) {  // further indices into the member: GEP(member, 0, ...)
                        std::vector<LLVMValueRef> rest = {LLVMConstInt(LLVMTypeOf(LLVMGetOperand(gep, 1)), 0, 0)};
                        for (int i = 3; i < n; i++) rest.push_back(LLVMGetOperand(gep, i));
                        at = LLVMBuildInBoundsGEP(builder, at, rest.data(), (unsigned)rest.size(), "");
                    }
                    if (LLVMTypeOf(at) != LLVMTypeOf(gep)) at = LLVMBuildBitCast(builder, at, LLVMTypeOf(gep), "");
                    LLVMReplaceAllUsesWith(gep, at);
                    LLVMInstructionEraseFromParent(gep);
                    rewritten++;
                }
            }
        }
    }
    LLVMDisposeBuilder(builder);
    LLVMDisposeTargetData(layout);
    return rewritten;
}

// ---- texture/sampler loads through escaped pointers -----------------------------------------------------------------
// IGILTextureTypeEncode follows a texture or sampler array argument's binding through constant-index GEPs, loads and
// stores; a handle loaded through a pointer that was stored to memory and loaded back at a run-time index (ANGLE's
// sampler arrays in loops) crashed the compiler service (a05). Such a load becomes `load &a[idx]`, idx a select over the
// candidate addresses: only integers are selected, never a handle (the pass gives each value one binding).
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
    if (disabled("INTEL_HANDLE_FIX")) return 0;
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
// In vertex functions (SIMD4x2) the back end reads the sign-extended top lane of a constant-buffer word that isn't the
// first in its 16 bytes from the first word instead: char4(x).w, short2(x).y, unpack_snorm*(x).w / .y (i02). ANGLE's
// vertex shaders unpack their Y flip that way, so every WebGL draw collapsed. Such extensions and unpacks become
// shl + ashr on the packed word (the unpacks then convert, scale and clamp as MSL defines them).
enum { kTypeKindHalf = 1, kTypeKindFloat = 2, kTypeKindInteger = 8, kTypeKindVector = 13, kOpcodeSExt = 32,
       kOpcodeSIToFP = 36, kRealOLT = 4 };

static unsigned lanes(LLVMTypeRef type) { return LLVMGetTypeKind(type) == kTypeKindVector ? LLVMGetVectorSize(type) : 0; }


// Extends a narrow integer (vector) value to i32 lanes for the widening rewrites below. A vector put together from
// constants with insertelement, or through bitwise operations with a constant operand, is extended lane by lane with
// the constants folded here: the back end sign-extends such constant lanes even in a zext (i35, i51).
// INTEL_NARROW_CONSTANT_LANES_FIX=0 extends the whole vector instead.
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
    if (disabled("INTEL_SIGNED_SUBWORD_FIX") || !LLVMGetNamedMetadataNumOperands(module, "air.vertex")) return 0;
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
// The back end can't select a depth comparison with an LOD bias ("Cannot select" aborts MTLCompilerService, taking the
// page's WebGL context) and can't compute an LOD to make it explicit (i03). The bias is dropped: shadow maps with one
// level, the usual kind, are unaffected.

static unsigned dropSampleCompareBias(LLVMModuleRef module) {
    if (disabled("INTEL_COMPARE_BIAS_FIX")) return 0;
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
// Integer textures are only sampled with nearest filtering, where the LOD only picks the level. Three back-end bugs:
// - a gradient sample in a compute kernel crashes it (LowerReadImage_Int): it becomes an explicit-level sample (i08);
// - it ignores the texel offset of integer samples and gathers (a08, i04): the offset goes into the coordinates, in
//   texels of the level read, the level computed in the shader where the GPU would pick it;
// - in compute kernels it adds a gather's offset to the normalized coordinate as is, on any format (i19): those gathers
//   get the same rewrite at level 0.
// The computed level is a nearest mip filter's: log2 of the longer gradient in level-0 texels (+ bias), rounded and
// clamped. A sampler that doesn't mipmap reads level 0 regardless (then the offset is in the wrong level's texels).

static bool runtimeNamesBound(LLVMModuleRef module);
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
// Haswell's and Ivy Bridge's gather4 return red for the green component of R32G32 formats, a hardware erratum (Mesa uses
// a separate surface state for gathers; this driver has none), and the shader can't tell R32G32 from other formats
// (i50, i72). A 2D green gather is also done as a red one, and where the two agree in all four texels the green values
// come from four level-0 samples at the footprint's texel centers, in gather order. Cube gathers keep the erratum.
static unsigned greenGathers(LLVMModuleRef module) {
    if (disabled("INTEL_GATHER_GREEN_FIX") || runtimeNamesBound(module)) return 0;
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
// The back end's madsat (air.mad_sat) misses the carry out of the add (madsat(a, 3u, b) wrapped), and its mul_hi /
// mad_hi are wrong with a constant operand or signed (i21). Both are built from 32-bit operations instead; signed madsat
// saturates by sign when the 64-bit sum's high word disagrees with the low word's sign. 32-bit elements only.
// The high word of a 32 x 32-bit product from 16-bit halves (every partial product fits in 32 bits): unsigned, then
// corrected for signed operands (hi_s = hi_u - (a < 0 ? b : 0) - (b < 0 ? a : 0)).
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
// The back end's narrow divides (USDIV and the like) expect operands extended the way the operation's signedness says,
// but constants and lanes built from them arrive sign-extended (i31). udiv / urem / sdiv / srem on i8 and i16 are done
// on 32-bit lanes. In vertex and fragment functions as_type vector operands went wrong when extended as a whole (a
// crash, or the unsigned remainder): there they and the operands of the narrow min / max / clamp below are widened with
// renderLanes32 (i70; INTEL_NARROW_VECTOR_OPERAND_FIX=0 turns that part off).
static LLVMValueRef unsignedValue(LLVMBuilderRef b, LLVMTypeRef i32, LLVMValueRef x);
// The lanes of an i8 / i16 vector as <N x i32>, zero- or sign-extended, for vertex and fragment functions, where the
// back end's legalization of a narrow vector depends on how it was made: insertelement or constant lanes one by one
// (extendLanes); an as_type or a load from its word with shifts; a trunc from its 32-bit lanes; anything else lane by
// lane (extending the whole vector crashed for as_type<ushort3>(half3), i69).
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
// iCBE turns a signed divide by a constant +-2^k into an arithmetic shift, which rounds toward minus infinity: -7 / 4
// came out -2 (i28). Such divides become (x + ((x >> (w - 1)) >>> (w - k))) >> k, negated for -2^k, lane by lane for
// constant vectors.
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
// The back end's 64-bit multiply gets the high word of its 32-bit partial products wrong when a factor is constant (see
// buildMulHi), so a * b and mulhi of 64-bit values came out wrong (i27). Multiplies of two widened 32-bit values (every
// buffer index) stay; the others are built from 32-bit limbs with exact high words, mulhi / madhi .i64 then corrected
// for signed factors.
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
// A vector lane picked with an index computed from a 64-bit quotient read the index before the expanded division loop
// wrote it (i33), and an index from a 64-bit shift of a constant crashes the DAG legalizer. Such extractelement /
// insertelement indices become selects. It runs again after the integer-function fold, which can make such a shift's
// base constant (i59).
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
// min, max and clamp on 8- and 16-bit integers compare a lane the back end zero-extended against a constant it
// sign-extended: min(uchar2 a, uchar2(130, 183)) returned a (i22). They're done on 32-bit lanes.
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
// iCBE folds a negation (0 - v) into the integer divide that uses it as a source modifier and drops it: (-v) % d came
// out as v % d (i26). Such a divide is done on v and negated: select(v == INT_MIN, r, 0 - r), since 0 - INT_MIN is
// INT_MIN again; a remainder by 0 - d is a remainder by d.
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
// iCBE folds integer functions of constants (max(0, 0x04030201), popcount(0xF0u), reverse_bits, extract_bits, ...)
// itself, and what it builds from the folded value can be wrong (i36, i39, i58). They are folded here, with every
// instruction left with only constant operands, so the back end gets the finished constants.

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

// A bitcast between integer scalars and vectors of constants, folded to its lanes: LLVMConstBitCast leaves an integer
// cast to a vector as a constant expression, which can't be read lane by lane (i42). nullptr if a lane isn't a whole
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

// A shift amount that is in range in every lane (LLVM folds larger ones to undef, the GPU masks them).
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
// The back end folds addsat / subsat of two constants as a plain add (addsat(95u, 4294967295u) came out 94), and iCBE
// turns UADD_sat(0, x & 255) into a read of another byte (i38). Such calls are folded here exactly, and an add_sat with
// a zero operand or a sub_sat of zero becomes its other operand.
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

static LLVMValueRef splat32(LLVMTypeRef type, uint32_t value) {  // value in an i32 or in every lane of an i32 vector
    LLVMValueRef v = LLVMConstInt(scalarOf(type), value, false);
    unsigned n = lanes(type);
    if (!n) return v;
    std::vector<LLVMValueRef> parts(n, v);
    return LLVMConstVector(parts.data(), n);
}
// The same fold happens when the operands become constant only in the plugin's own passes (an unrolled loop's
// addsat(i, -i)): signed results came out as plain sums, and an unsigned one picking a private array element made a
// value read in the same iteration take its next one (i56, i63). The 32-bit add_sat and signed sub_sat calls left after
// the fold above are written out as an add or subtract, compares and selects; unsigned sub_sat was right and stays.
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
// MetalOldCompat item 30 gives nearest-filter samplers clamped cube addressing (integer cube textures with tiny faces
// sample as 0 with seamless addressing), but a gather's 2x2 footprint spans face edges and came back clamped there
// (i20). A gather doesn't filter and seamless addressing ignores the address modes, so cube gathers (color and depth,
// not compare) in vertex and fragment functions take a constexpr linear sampler instead, which item 30 leaves seamless.
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
// Xcode 26's front end (metalfe-32023.850) writes a constexpr sampler as a [2 x i64] constant (the second word 0, bit
// 63 of the first clear); the runtime compiler that goes with the 3802 back end writes one i64, the same word with bit
// 63 set. IGILInlineSamplerLowering dereferences null on the array and kills MTLCompilerService (iMovie's viewer stays
// black; i05). Such globals become that i64; their uses and the sampler-state metadata go to it.
extern "C" void *valueAsMetadata(LLVMValueRef value) asm("__ZN4llvm15ValueAsMetadata3getEPNS_5ValueE");

static unsigned fixSamplerStateWords(LLVMModuleRef module) {
    if (disabled("INTEL_SAMPLER_STATE_FIX")) return 0;
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
// Samplers in compute kernels on Haswell and Ivy Bridge blend between mip levels only in the middle quarter of each
// step (level n + f reads n for f <= 0.375, n + 1 for f >= 0.625); vertex and fragment functions blend over the whole
// step (s19). An explicit level with a fraction becomes n + 0.375 + f / 4, which gives weight f; whole levels and
// gradients are left alone. Modules can reach the pass manager twice, so remapped calls are marked
// (!intel.level_remapped).

static unsigned remapComputeLevels(LLVMModuleRef module) {
    if (disabled("INTEL_COMPUTE_TRILINEAR_FIX") || !LLVMGetNamedMetadataNumOperands(module, "air.kernel")) return 0;
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
// LLVM shrinks a threadgroup bool to an i1 global, and the back end can't select i1 loads and stores in threadgroup
// memory ("Cannot select" aborts MTLCompilerService; a10). Such globals become i8, accessed volatile, or the back
// end's GlobalOpt shrinks them back to i1.

static unsigned widenThreadgroupBools(LLVMModuleRef module) {
    if (disabled("INTEL_THREADGROUP_BOOL_FIX")) return 0;
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

// ---- threadgroup atomics that only ever hold constants -------------------------------------------------------------
// The back end turns relaxed threadgroup atomics into plain loads and stores before its GlobalOpt, which then shrinks an
// atomic only ever stored constants to an i1 it can't store ("Cannot select ... Constant:i1", i86). A volatile read of it
// at the start of each function that stores to it keeps GlobalOpt off it; the atomics themselves stay.

enum { kThreadgroupAddressSpace = 3, kMaxConstantExprDepth = 8 };
static LLVMValueRef threadgroupGlobalUnder(LLVMValueRef pointer) {  // the global a constant GEP / bitcast chain starts at
    for (int depth = 0; pointer && depth < kMaxConstantExprDepth; depth++) {
        if (LLVMIsAGlobalVariable(pointer))
            return LLVMGetPointerAddressSpace(LLVMTypeOf(pointer)) == kThreadgroupAddressSpace ? pointer : nullptr;
        if (!LLVMIsAConstantExpr(pointer) || LLVMGetNumOperands(pointer) < 1) return nullptr;
        pointer = LLVMGetOperand(pointer, 0);
    }
    return nullptr;
}
static bool isThreadgroupAtomicStore(LLVMValueRef inst) {
    static const char kAtomicStorePrefix[] = "air.atomic.local.store.";
    LLVMValueRef callee = LLVMIsACallInst(inst) ? LLVMGetCalledValue(inst) : nullptr;
    const char *name = callee ? LLVMGetValueName(callee) : nullptr;
    return name && !strncmp(name, kAtomicStorePrefix, sizeof kAtomicStorePrefix - 1);
}
struct ThreadgroupAtomicStore { LLVMValueRef global, function, pointer; };
static unsigned pinConstantThreadgroupAtomics(LLVMModuleRef module) {
    if (disabled("INTEL_THREADGROUP_ATOMIC_FIX")) return 0;
    std::map<LLVMValueRef, bool> storesOnlyConstants;
    std::vector<ThreadgroupAtomicStore> stores;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (!isThreadgroupAtomicStore(inst)) continue;
                LLVMValueRef pointer = LLVMGetOperand(inst, 0), global = threadgroupGlobalUnder(pointer);
                if (!global || !LLVMIsAConstantExpr(pointer)) continue;
                bool constant = LLVMIsAConstantInt(LLVMGetOperand(inst, 1)) != nullptr;
                auto known = storesOnlyConstants.find(global);
                storesOnlyConstants[global] = (known == storesOnlyConstants.end() || known->second) && constant;
                stores.push_back({global, f, pointer});
            }
    LLVMBuilderRef b = nullptr;
    std::set<std::pair<LLVMValueRef, LLVMValueRef>> pinned;  // (function, global)
    for (const ThreadgroupAtomicStore &store : stores) {
        if (!storesOnlyConstants[store.global] || !pinned.insert({store.function, store.global}).second) continue;
        LLVMValueRef first = LLVMGetFirstInstruction(LLVMGetFirstBasicBlock(store.function));
        if (!b) b = LLVMCreateBuilderInContext(LLVMGetModuleContext(module));
        LLVMPositionBuilderBefore(b, first);
        LLVMSetVolatile(LLVMBuildLoad(b, store.pointer, ""), 1);
    }
    if (b) LLVMDisposeBuilder(b);
    return (unsigned)pinned.size();
}

// ---- over-aligned byte accesses to private memory ------------------------------------------------------------------
// A byte or halfword load from private memory aligned to 4 or more (the first small field of a 16-byte-aligned struct
// in a dynamically indexed private array) has no instruction pattern in the back end and aborts MTLCompilerService
// (c03). Lowering the alignment doesn't last, so such an access becomes a volatile one of its 32-bit word (instruction
// selection narrows a plain one back).

static unsigned wordPrivateSubwords(LLVMModuleRef module) {
    if (disabled("INTEL_PRIVATE_ALIGN_FIX")) return 0;
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
// The back end drops the move of a float3 vertex input into a register when a component is copied straight to an
// output (`out.o = in.a.y` read 0 or garbage; i06), and in fragment functions a float3 input's z given straight to
// sample_compare as the reference compares with its x (i09); ANGLE writes both. Each <3 x float> parameter of a vertex
// or fragment function goes through air.fast_fmax(a, a) first, exact even for NaN, which makes the back end load it.
// Only before the plugin binds air.* calls to its runtime library (runtimeNamesBound).
// Whether the plugin has already turned the module's air.* calls into the runtime library's air_* functions (a later
// pass-manager run on the same module): air.* calls added then are never resolved and crash the back end.
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
// get_num_samples() returns 1 in a fragment function that takes a buffer argument, at any sample count, which broke
// ANGLE's alpha-to-coverage emulation (i10). A render pipeline's sample count is fixed at compile time and the module
// carries it (!air.state !{!"msaaLevel", i32 N}): the calls become that constant.
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
// In vertex and fragment functions the back end addresses a dynamically indexed private array two ways (constant-offset
// stores by byte address in raw scratch, variable-index accesses as x0[i].x), so elements written one way and read the
// other came back 0 or stale (i07, i34). Variable-index loads and stores into an array of at most 16 numbers or vectors
// become accesses at every constant index plus selects (out of range: the last element read, nothing stored), for the
// whole array or none of it, since one access left as it was is the mix this works around (i44).

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
// After the private-array rewrites the back end forwarded a stored 32-bit value to a narrow load of a uchar / ushort
// private array without masking it (i47). Arrays of 8- or 16-bit integers reached only through element GEPs, loads and
// stores become arrays of i32 (stores zero-extend, loads truncate), before i07's rewrite. Not on Ivy Bridge, whose
// 11.7.10 compiler gets i47 right as it is and wrong with the words.
static unsigned widenNarrowPrivateArrays(LLVMModuleRef module) {
    if (disabled("INTEL_NARROW_PRIVATE_ARRAY_FIX") || ivyBridgePlugin || runtimeNamesBound(module)) return 0;
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
    if (disabled("INTEL_PRIVATE_ARRAY_FIX")) return 0;
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
// For a load through select(c, &in[i], &in[j]) the back end loops over the distinct surfaces in the SIMD group, and
// that loop takes flag register f0.1 without saving it, so an enclosing else-branch's condition kept there flipped
// (i23). A select of two GEPs of the same pointer becomes one GEP with the differing indices selected: the same
// address, no surface loop. Device and constant pointers only (private ones: splitPrivatePointerSelects).
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
// A pointer into a private array picked with a select keeps the array in private memory, where the back end forwards a
// load of an element past a store to it (i17; the stock compiler too), and the variable-index rewrite makes many such
// loads and stores. A load through such a select becomes a select of the two loads, a store two stores (each pointer
// gets the value or its old contents), so the array can stay in registers. Runs before the variable-index rewrite.
static unsigned splitPrivatePointerSelects(LLVMModuleRef module) {
    if (disabled("INTEL_PRIVATE_SELECT_FIX")) return 0;
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
// iCBE's register allocator (CStructRegionTree::StructuralAnalysis) takes exponential time on chains of short
// conditional branches that fall through to a shared block, as `if (a && b && c && d)` compiles: 8 such tests take over
// ten minutes, and Chrome's GPU watchdog kills the process (i12). Pure computing blocks are folded into their
// predecessor with the conditions combined by selects, and if-then(-else) shapes become selects. Tunables:
// INTEL_BRANCH_CHAIN_MOVE (most instructions a moved block may have, default 16), INTEL_BRANCH_CHAIN_MIN (conditional
// branches before it runs, default 12). Phis become selects only for numbers and vectors, never handles (a05).

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
// both become one entry from `to` with the value merge(phi, value from `to`, value from `from`). A switch from several
// cases keeps one entry per case: `from`'s switch, moved into `to`, still has them (i53).
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
// The 3802 back end reorders or forwards an access of one type past an access of another type to the same address, as
// WGSL's buffer views (Tint casts one byte pointer to each view's type) and aggregate copies of such a buffer do (i16,
// i18). Accesses through a device or threadgroup root cast to two or more element types in one function, or both
// copied and viewed, are made volatile, which keeps them in order. A cast that only feeds a copy into private memory
// is no view: a volatile copy there lost values.
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

// ---- reloads after a store through another pointer -----------------------------------------------------------------
// Within a block the back end gives a load of p the value of an earlier load of p when a store through another pointer
// of the same address space comes between them, even after a store to p: "x = *p; *p = x + 1; *q = y; return *p"
// returns the old x (i87). Such a reload is made volatile, which the back end reads from memory.

static LLVMValueRef withoutBitcasts(LLVMValueRef pointer) {
    while (pointer && LLVMIsABitCastInst(pointer)) pointer = LLVMGetOperand(pointer, 0);
    return pointer;
}
static bool sameAddress(LLVMValueRef a, LLVMValueRef b) {  // one pointer, or equal GEPs of one pointer
    a = withoutBitcasts(a);
    b = withoutBitcasts(b);
    if (a == b) return true;
    if (!LLVMIsAGetElementPtrInst(a) || !LLVMIsAGetElementPtrInst(b) || LLVMGetNumOperands(a) != LLVMGetNumOperands(b)) return false;
    for (int i = 1; i < LLVMGetNumOperands(a); i++)
        if (LLVMGetOperand(a, i) != LLVMGetOperand(b, i)) return false;
    return sameAddress(LLVMGetOperand(a, 0), LLVMGetOperand(b, 0));
}
static unsigned addressSpaceOf(LLVMValueRef pointer) { return LLVMGetPointerAddressSpace(LLVMTypeOf(pointer)); }

struct StoredPointer {
    LLVMValueRef pointer;
    bool storedThroughAnotherSince;
};
static void noteStore(std::vector<StoredPointer> &stored, LLVMValueRef pointer) {
    for (StoredPointer &earlier : stored)
        if (addressSpaceOf(earlier.pointer) == addressSpaceOf(pointer) && !sameAddress(earlier.pointer, pointer))
            earlier.storedThroughAnotherSince = true;
    stored.erase(std::remove_if(stored.begin(), stored.end(),
                                [pointer](const StoredPointer &earlier) { return sameAddress(earlier.pointer, pointer); }),
                 stored.end());
    stored.push_back({pointer, false});
}
static bool reloadsAfterAnotherStore(const std::vector<StoredPointer> &stored, LLVMValueRef pointer) {
    return std::any_of(stored.begin(), stored.end(), [pointer](const StoredPointer &earlier) {
        return earlier.storedThroughAnotherSince && sameAddress(earlier.pointer, pointer);
    });
}
static unsigned volatileReloadsAfterOtherStores(LLVMModuleRef module) {
    if (disabled("INTEL_STALE_RELOAD_FIX")) return 0;
    unsigned marked = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb)) {
            std::vector<StoredPointer> stored;  // device / threadgroup pointers stored to in this block
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (LLVMIsAStoreInst(inst) && sharedPointer(LLVMGetOperand(inst, 1))) {
                    noteStore(stored, LLVMGetOperand(inst, 1));
                } else if (LLVMIsALoadInst(inst) && !LLVMGetVolatile(inst) && sharedPointer(LLVMGetOperand(inst, 0)) &&
                           reloadsAfterAnotherStore(stored, LLVMGetOperand(inst, 0))) {
                    LLVMSetVolatile(inst, 1);
                    marked++;
                }
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
// as_type<uchar4>(ushort2) and as_type<char4>(short2) abort the compile of a vertex or fragment function in
// IGILTargetLowering::ReplaceNodeResults (i62; compute functions are right). In such modules each of these bitcasts
// becomes its bytes, put together lane by lane from shifted halfwords. Runs after the other rewrites.
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

// ---- byte vectors viewed as halfwords on Ivy Bridge -----------------------------------------------------------------
// Ivy Bridge's iCBE reads a half of as_type<short2>(uchar4) / as_type<ushort2>(char4) (BPACK, then SUNPACK) wrong when
// a byte lane is a known 0 (i75; the stock compiler too). Such bitcasts become their halfwords put together with
// shifts, only where a byte lane is a known 0: elsewhere BPACK is right and the shifts could trip the narrow-shift
// handling instead. Runs after the other rewrites.
static bool knownZeroByteLane(LLVMValueRef v, int depth = 0) {
    enum { kAnd = 23, kInsertElement = 51 };
    if (depth > 8) return false;
    if (LLVMIsAConstantAggregateZero(v)) return true;
    bool data = LLVMIsAConstantDataSequential(v) != nullptr;
    if (data || LLVMIsAConstantVector(v)) {
        for (unsigned k = 0; k < lanes(LLVMTypeOf(v)); k++) {
            LLVMValueRef e = data ? LLVMGetElementAsConstant(v, k) : LLVMGetOperand(v, k);
            if (e && LLVMIsAConstantInt(e) && LLVMConstIntGetZExtValue(e) == 0) return true;
        }
        return false;
    }
    if (!LLVMIsAInstruction(v)) return false;
    int opcode = LLVMGetInstructionOpcode(v);
    if (opcode == kInsertElement) {
        LLVMValueRef x = LLVMGetOperand(v, 1);
        if (LLVMIsAConstantInt(x) && LLVMConstIntGetZExtValue(x) == 0) return true;
        return knownZeroByteLane(LLVMGetOperand(v, 0), depth + 1);
    }
    if (opcode == kAnd) return knownZeroByteLane(LLVMGetOperand(v, 0), depth + 1) || knownZeroByteLane(LLVMGetOperand(v, 1), depth + 1);
    return false;
}
static unsigned packByteHalfwords(LLVMModuleRef module) {
    if (disabled("INTEL_BYTE_HALFWORDS_FIX") || !ivyBridgePlugin) return 0;
    enum { kBitCast = 41 };
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i16 = LLVMIntTypeInContext(context, 16), i32 = LLVMInt32TypeInContext(context);
    std::vector<LLVMValueRef> found;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                if (LLVMGetInstructionOpcode(inst) != kBitCast) continue;
                LLVMTypeRef to = LLVMTypeOf(inst), from = LLVMTypeOf(LLVMGetOperand(inst, 0));
                if (subwordBits(from) == 8 && subwordBits(to) == 16 && lanes(to) && lanes(from) == 2 * lanes(to) &&
                    knownZeroByteLane(LLVMGetOperand(inst, 0)))
                    found.push_back(inst);
            }
    if (found.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(context);
    for (LLVMValueRef inst : found) {
        LLVMPositionBuilderBefore(b, inst);
        LLVMValueRef bytes = LLVMGetOperand(inst, 0), halves = LLVMGetUndef(LLVMTypeOf(inst));
        for (unsigned k = 0; k < lanes(LLVMTypeOf(inst)); k++) {
            LLVMValueRef low = LLVMBuildZExt(b, LLVMBuildExtractElement(b, bytes, LLVMConstInt(i32, 2 * k, false), ""), i32, "");
            LLVMValueRef high = LLVMBuildZExt(b, LLVMBuildExtractElement(b, bytes, LLVMConstInt(i32, 2 * k + 1, false), ""), i32, "");
            LLVMValueRef half = LLVMBuildOr(b, low, LLVMBuildShl(b, high, LLVMConstInt(i32, 8, false), ""), "");
            halves = LLVMBuildInsertElement(b, halves, LLVMBuildTrunc(b, half, i16, ""), LLVMConstInt(i32, k, false), "");
        }
        LLVMReplaceAllUsesWith(inst, halves);
        LLVMInstructionEraseFromParent(inst);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)found.size();
}

// ---- compares of byte and halfword vectors in vertex and fragment functions ----------------------------------------
// In vertex and fragment functions the back end's legalization of i8 / i16 vectors depends on how each was made:
// compares of byte vectors crashed the compiler service (SelectionDAG::getZeroExtendInReg) or came out wrong, and so
// did per-lane selects by them (i64); arithmetic and bitwise operations crashed the same way (i66). Such compares,
// selects and operations are done on <N x i32> lanes (extendLanes for vectors put together with insertelement, the
// packed word with shifts otherwise), and phis of such vectors get a 32-bit phi beside them.
// INTEL_NARROW_VECTOR_ARITH_FIX=0 leaves the arithmetic alone.
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
// Inverting icmp eq (and (and x, 1), y), 1, the back end turns the compare of a 0/1 value into the value itself, drops
// the `& 1` and tests the whole register, so pixels where x & y had higher bits set took the wrong branch (i68). In
// such modules each icmp eq / ne of a value that can only be 0 or 1 with 1 becomes icmp ne / eq with 0.
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
// 64-bit division and remainder, and i64 shifts by a non-constant amount, crash the compiler service in vertex and
// fragment functions (i67; compute functions are right). In such modules, outside functions only kernels call, each is
// done on 32-bit halves: shifts as 32-bit shifts and a select on s & 32, division as 64 shift-and-subtract steps (a
// 65-bit remainder, so divisors above 2^63 are right). Division by zero gives all ones and the dividend.
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
// Under a SIMD16 pixel kernel's register pressure, iCBE's allocator can give a compare whose result is only used
// through the flag a register that still holds a live value, which the compare then overwrites (i14; SIMD8 kernels
// are right). iCBE's CompilePixelShaderOpenGL is wrapped: when gen7eu::findCompareClobber finds that in the SIMD16
// kernel, the shader is compiled again SIMD8 only. INTEL_SIMD8_PIXEL=1 asks for SIMD8 only for every fragment function
// (testing). The clobber check reads Haswell's iCBE output only; Ivy Bridge's is wrapped for the SIMD level only (i77).
// The C export: (compiler, platform index, ?, OPTIMIZER_LEVEL, SIMD_LEVEL, input state, ?,
// AIR::SCompilerOutputPixelShader **, PLATFORM_STR *); it fills the caller's output block, which holds the SIMD8/16/32
// kernel pointers at 0x47fb and their sizes (uint32) at 0x4813.
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
    if (pixelDivideInBranch) simd = 1;  // set by intelatomicsFixIGIL for the IGIL text this compiles
    pixelDivideInBranch = false;
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
// Ivy Bridge's iCBE (the HD 4000 GL driver's) exports the same CompilePixelShaderOpenGL, its fourth and fifth arguments
// the OPTIMIZER_LEVEL and SIMD_LEVEL it hands to USC::CompilePixelShaderOpenGL. Only the SIMD level is changed there: the
// output block isn't read, its layout is unverified on that build.
static CompilePixelShaderFn originalCompilePixelShaderIVB;
static long hookedCompilePixelShaderIVB(void *compiler, int platform, void *a3, int optimizer, int simd, void *input, void *a7,
                                        void *output, void *platformInfo) {
    if (getenv("INTEL_SIMD8_PIXEL") && !disabled("INTEL_SIMD8_PIXEL")) simd = 1;
    if (pixelDivideInBranch) simd = 1;  // set by intelatomicsFixIGIL for the IGIL text this compiles
    pixelDivideInBranch = false;
    return originalCompilePixelShaderIVB(compiler, platform, a3, optimizer, simd, input, a7, output, platformInfo);
}
static void installICBEHook() {
    static bool done;
    if (done) return;
    if (ivyBridgePlugin) {
        done = true;
        const char *path = "/System/Library/Extensions/AppleIntelHD4000GraphicsGLDriver.bundle/Contents/MacOS/iCBE.dylib";
        void *h = dlopen(path, RTLD_NOLOAD | RTLD_LAZY);
        if (!h) h = dlopen(path, RTLD_LAZY);
        unsigned char *entry = h ? (unsigned char *)dlsym(h, "CompilePixelShaderOpenGL") : nullptr;
        if (entry) originalCompilePixelShaderIVB = (CompilePixelShaderFn)hookFunction(entry, (void *)hookedCompilePixelShaderIVB);
        if (logging()) fprintf(stderr, "[inteltex] Ivy Bridge iCBE CompilePixelShaderOpenGL %s\n", originalCompilePixelShaderIVB ? "hooked" : "NOT hooked");
        return;
    }
    done = true;
    void *h = nullptr;
    for (const char *path : kICBEPaths) if ((h = dlopen(path, RTLD_NOLOAD | RTLD_LAZY))) break;
    for (const char *path : kICBEPaths) if (!h && (h = dlopen(path, RTLD_LAZY))) break;  // the plugin loads it on demand
    unsigned char *entry = h ? (unsigned char *)dlsym(h, "CompilePixelShaderOpenGL") : nullptr;
    if (entry) originalCompilePixelShader = (CompilePixelShaderFn)hookFunction(entry, (void *)hookedCompilePixelShader);
    if (logging()) fprintf(stderr, "[inteltex] iCBE CompilePixelShaderOpenGL %s\n", originalCompilePixelShader ? "hooked" : "NOT hooked");
}

// ---- loops that never exit -------------------------------------------------------------------------------------------
// LLVM leaves a block that only branches back to itself where a specialized loop can't advance (MPS reductions with a
// zero stride), and nested in MPSGraph's outer-axis reductions the back end's compile of it never finishes (i71; the
// stock compiler too). A thread reaching such a loop would hang the GPU, so it returns instead.
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

// ---- Kepler's three: half constants, gradient compares, struct copies ------------------------------------------------
// Three tests written for the Kepler adapter (n05, n12, n13) fail on Intel too, Ivy Bridge and Haswell alike, with the
// stock compiler as well; the same three rewrites as GeForceAIRCompat (NVIDIAAdapter/nvair.cpp) fix them here.

// Half vectors spelled as bitcasts in constants, bitcast (<1 x i32> <i32 bits> to <2 x half>) (WGSL `const` f16
// matrices), made IGILTargetLowering::processGlobalData recurse until the compiler crashed (n13). In global
// initializers each such bitcast becomes the plain half vector it stands for.
static double halfBitsValue(unsigned h) {
    int sign = (h >> 15) & 1, exponent = (h >> 10) & 31;
    unsigned mantissa = h & 1023;
    double v;
    if (exponent == 0) v = std::ldexp((double)mantissa, -24);
    else if (exponent == 31) v = mantissa ? NAN : INFINITY;
    else v = std::ldexp((double)(mantissa | 1024), exponent - 25);
    return sign ? -v : v;
}
static bool constantIntBytes(LLVMValueRef c, std::vector<uint8_t> &bytes) {  // low element first
    auto add = [&](LLVMValueRef v) {
        if (!v || !LLVMIsAConstantInt(v)) return false;
        unsigned width = LLVMGetIntTypeWidth(LLVMTypeOf(v));
        if (width % 8 || width > 64) return false;
        unsigned long long x = LLVMConstIntGetZExtValue(v);
        for (unsigned k = 0; k < width / 8; k++) bytes.push_back((uint8_t)(x >> (8 * k)));
        return true;
    };
    LLVMTypeRef t = LLVMTypeOf(c);
    if (LLVMGetTypeKind(t) == kTypeKindInteger) return add(c);
    if (LLVMGetTypeKind(t) != kTypeKindVector) return false;
    for (unsigned i = 0; i < LLVMGetVectorSize(t); i++)
        if (!add(LLVMIsAConstantDataVector(c) ? LLVMGetElementAsConstant(c, i) : LLVMIsAConstantVector(c) ? LLVMGetOperand(c, i) : nullptr))
            return false;
    return true;
}
static LLVMValueRef foldHalfBitcasts(LLVMContextRef context, LLVMValueRef c, bool &changed, int depth = 0) {
    enum { kOpBitCast = 41 };
    if (!c || depth > 16) return c;
    LLVMTypeRef t = LLVMTypeOf(c), half = LLVMHalfTypeInContext(context);
    if (LLVMIsAConstantExpr(c) && LLVMGetConstOpcode(c) == kOpBitCast && LLVMGetTypeKind(t) == kTypeKindVector && LLVMGetElementType(t) == half) {
        std::vector<uint8_t> bytes;
        unsigned n = LLVMGetVectorSize(t);
        if (!constantIntBytes(LLVMGetOperand(c, 0), bytes) || bytes.size() != 2 * n) return c;
        std::vector<LLVMValueRef> halves;
        for (unsigned i = 0; i < n; i++) halves.push_back(LLVMConstReal(half, halfBitsValue(bytes[2 * i] | bytes[2 * i + 1] << 8)));
        changed = true;
        return LLVMConstVector(halves.data(), n);
    }
    bool isStruct = LLVMIsAConstantStruct(c), isArray = LLVMIsAConstantArray(c), isVector = LLVMIsAConstantVector(c);
    if (!isStruct && !isArray && !isVector) return c;
    unsigned n = (unsigned)LLVMGetNumOperands(c);
    std::vector<LLVMValueRef> elements(n);
    bool inner = false;
    for (unsigned i = 0; i < n; i++) elements[i] = foldHalfBitcasts(context, LLVMGetOperand(c, i), inner, depth + 1);
    if (!inner) return c;
    changed = true;
    if (isArray) return LLVMConstArray(LLVMGetElementType(t), elements.data(), n);
    if (isVector) return LLVMConstVector(elements.data(), n);
    return LLVMGetStructName(t) ? LLVMConstNamedStruct(t, elements.data(), n)
                                : LLVMConstStructInContext(context, elements.data(), n, LLVMIsPackedStruct(t));
}
static unsigned foldHalfVectorBitcasts(LLVMModuleRef module) {
    if (disabled("INTEL_HALF_CONSTANT_FIX")) return 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    unsigned fixed = 0;
    for (LLVMValueRef v = LLVMGetFirstGlobal(module); v; v = LLVMGetNextGlobal(v)) {
        LLVMValueRef init = LLVMIsDeclaration(v) ? nullptr : LLVMGetInitializer(v);
        if (!init) continue;
        bool changed = false;
        LLVMValueRef folded = foldHalfBitcasts(context, init, changed);
        if (changed) LLVMSetInitializer(v, folded), fixed++;
    }
    return fixed;
}

// Instruction selection gives up on depth comparisons with gradients (sample_compare with gradient2d and its 2D-array,
// cube and cube-array forms) in kernels and fragment functions (n05, i78; ANGLE avoids them, MetalOldCompat item 11).
// Each becomes the level form of the same comparison, which the plugin compiles (i24), at the level the gradients
// select with a nearest mip filter: 2D levels as for integer textures (selectedLevel), cube levels from the derivatives
// of the major axis's face coordinates, as GeForceAIRCompat's gradient samples. The 3802 runtime compiler's forms only.
// The level a cube gradient selects (nearest mip filter), an i32: 0.5 * log2(max over dPdx, dPdy of |d(face s, t)|^2 *
// size^2) + 0.5, clamped; a zero major axis gives NaN, which clampedLevel makes 0.
static LLVMValueRef cubeSelectedLevel(LLVMBuilderRef b, LLVMModuleRef module, LLVMValueRef texture, const char *type, LLVMValueRef coord,
                                      LLVMValueRef dPdx, LLVMValueRef dPdy) {
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context), f32 = LLVMFloatTypeInContext(context);
    auto lane = [&](LLVMValueRef v, unsigned k) { return LLVMBuildExtractElement(b, v, LLVMConstInt(i32, k, false), ""); };
    auto absolute = [&](LLVMValueRef x) {
        return LLVMBuildSelect(b, LLVMBuildFCmp(b, 4 /* OLT */, x, LLVMConstReal(f32, 0.0), ""), LLVMBuildFSub(b, LLVMConstReal(f32, 0.0), x, ""), x, "");
    };
    LLVMValueRef x = lane(coord, 0), y = lane(coord, 1), z = lane(coord, 2), ax = absolute(x), ay = absolute(y), az = absolute(z);
    LLVMValueRef isX = LLVMBuildAnd(b, LLVMBuildFCmp(b, 3 /* OGE */, ax, ay, ""), LLVMBuildFCmp(b, 3 /* OGE */, ax, az, ""), "");
    LLVMValueRef yOverZ = LLVMBuildFCmp(b, 3 /* OGE */, ay, az, "");
    auto pick = [&](LLVMValueRef px, LLVMValueRef py, LLVMValueRef pz) {  // the major axis's component, then the two others
        return LLVMBuildSelect(b, isX, px, LLVMBuildSelect(b, yOverZ, py, pz, ""), "");
    };
    LLVMValueRef ma = pick(x, y, z), b1 = LLVMBuildSelect(b, isX, y, x, ""), b2 = pick(z, z, y);
    LLVMValueRef twoMa2 = LLVMBuildFMul(b, LLVMConstReal(f32, 2.0), LLVMBuildFMul(b, ma, ma, ""), "");
    LLVMValueRef size = textureSize(b, module, texture, type, 0, LLVMConstInt(i32, 0, false)), rho[2];
    for (int k = 0; k < 2; k++) {
        LLVMValueRef g = k ? dPdy : dPdx, gx = lane(g, 0), gy = lane(g, 1), gz = lane(g, 2);
        LLVMValueRef dma = pick(gx, gy, gz), db1 = LLVMBuildSelect(b, isX, gy, gx, ""), db2 = pick(gz, gz, gy);
        LLVMValueRef ds = LLVMBuildFDiv(b, LLVMBuildFSub(b, LLVMBuildFMul(b, db1, ma, ""), LLVMBuildFMul(b, b1, dma, ""), ""), twoMa2, "");
        LLVMValueRef dt = LLVMBuildFDiv(b, LLVMBuildFSub(b, LLVMBuildFMul(b, db2, ma, ""), LLVMBuildFMul(b, b2, dma, ""), ""), twoMa2, "");
        LLVMValueRef ss = LLVMBuildFMul(b, ds, size, ""), tt = LLVMBuildFMul(b, dt, size, "");
        rho[k] = LLVMBuildFAdd(b, LLVMBuildFMul(b, ss, ss, ""), LLVMBuildFMul(b, tt, tt, ""), "");
    }
    LLVMValueRef longer = LLVMBuildSelect(b, LLVMBuildFCmp(b, 2 /* OGT */, rho[0], rho[1], ""), rho[0], rho[1], "");
    LLVMValueRef log = LLVMBuildCall(b, declared(module, "air.fast_log2.f32", f32, f32), &longer, 1, "");
    return clampedLevel(b, module, texture, type, LLVMBuildFAdd(b, LLVMBuildFMul(b, log, LLVMConstReal(f32, 0.5), ""), LLVMConstReal(f32, 0.5), ""));
}
static unsigned fixGradientCompares(LLVMModuleRef module) {
    if (disabled("INTEL_COMPARE_GRADIENT_FIX")) return 0;
    enum { kPointerKind = 12 };
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef f32 = LLVMFloatTypeInContext(context), i1 = LLVMInt1TypeInContext(context), i32 = LLVMInt32TypeInContext(context);
    LLVMTypeRef v2 = LLVMVectorType(f32, 2), v3 = LLVMVectorType(f32, 3), v2i = LLVMVectorType(i32, 2);
    // gradient form: (texture, sampler, i32, coord, [i32 layer,] float reference, dPdx, dPdy, [i1 has offset, int2 offset,] i32)
    // level form:    (texture, sampler, i32, coord, [i32 layer,] float reference, [i1 has offset, int2 offset,] i1 1, float 0, i32)
    static const struct { const char *grad, *level, *type; bool cube, array; } kForms[] = {
        {"air.sample_compare_depth_2d_grad.f32", "air.sample_compare_depth_2d.f32", "depth_2d", false, false},
        {"air.sample_compare_depth_2d_array_grad.f32", "air.sample_compare_depth_2d_array.f32", "depth_2d_array", false, true},
        {"air.sample_compare_depth_cube_grad.f32", "air.sample_compare_depth_cube.f32", "depth_cube", true, false},
        {"air.sample_compare_depth_cube_array_grad.f32", "air.sample_compare_depth_cube_array.f32", "depth_cube_array", true, true},
    };
    unsigned fixed = 0;
    LLVMBuilderRef b = nullptr;
    for (const auto &form : kForms) {
        LLVMValueRef f = LLVMGetNamedFunction(module, form.grad);
        if (!f || !LLVMIsDeclaration(f) || !LLVMGetFirstUse(f)) continue;
        LLVMTypeRef type = LLVMGetElementType(LLVMTypeOf(f)), params[12];
        unsigned count = LLVMCountParamTypes(type), r = form.array ? 5 : 4;
        if (count != (form.cube ? r + 4 : r + 6) || count > 12 || LLVMGetReturnType(type) != f32) continue;
        LLVMGetParamTypes(type, params);
        LLVMTypeRef coord = form.cube ? v3 : v2;
        if (LLVMGetTypeKind(params[0]) != kPointerKind || LLVMGetTypeKind(params[1]) != kPointerKind || params[2] != i32 || params[3] != coord ||
            (form.array && params[4] != i32) || params[r] != f32 || params[r + 1] != coord || params[r + 2] != coord)
            continue;
        if (!form.cube && (params[r + 3] != i1 || params[r + 4] != v2i || params[r + 5] != i32)) continue;
        if (form.cube && params[r + 3] != i32) continue;
        LLVMTypeRef levelParams[12];
        unsigned n = 0;
        for (unsigned k = 0; k <= r; k++) levelParams[n++] = params[k];
        if (!form.cube) levelParams[n++] = i1, levelParams[n++] = v2i;
        levelParams[n++] = i1, levelParams[n++] = f32, levelParams[n++] = i32;
        LLVMValueRef levelForm = LLVMGetNamedFunction(module, form.level);
        if (!levelForm) levelForm = LLVMAddFunction(module, form.level, LLVMFunctionType(f32, levelParams, n, 0));
        else if (LLVMCountParamTypes(LLVMGetElementType(LLVMTypeOf(levelForm))) != n) continue;
        std::vector<LLVMValueRef> calls;
        for (LLVMUseRef u = LLVMGetFirstUse(f); u; u = LLVMGetNextUse(u))
            if (LLVMValueRef call = LLVMIsACallInst(LLVMGetUser(u)))
                if (LLVMGetCalledValue(call) == f) calls.push_back(call);
        for (LLVMValueRef call : calls) {
            if (!b) b = LLVMCreateBuilderInContext(context);
            LLVMPositionBuilderBefore(b, call);
            LLVMValueRef args[12];
            unsigned a = 0;
            for (unsigned k = 0; k <= r; k++) args[a++] = LLVMGetOperand(call, k);
            if (!form.cube) args[a++] = LLVMGetOperand(call, r + 3), args[a++] = LLVMGetOperand(call, r + 4);
            LLVMValueRef texture = LLVMGetOperand(call, 0), dPdx = LLVMGetOperand(call, r + 1), dPdy = LLVMGetOperand(call, r + 2);
            LLVMValueRef level = form.cube ? cubeSelectedLevel(b, module, texture, form.type, LLVMGetOperand(call, 3), dPdx, dPdy)
                                           : selectedLevel(b, module, texture, form.type, 2, dPdx, dPdy, nullptr);
            args[a++] = LLVMConstInt(i1, 1, 0), args[a++] = LLVMBuildSIToFP(b, level, f32, ""), args[a++] = LLVMGetOperand(call, count - 1);
            LLVMReplaceAllUsesWith(call, LLVMBuildCall(b, levelForm, args, a, ""));
            LLVMInstructionEraseFromParent(call);
            fixed++;
        }
    }
    if (b) LLVMDisposeBuilder(b);
    return fixed;
}

// Struct copies (llvm.memcpy of a constant length): the back end moves a copy's loads above an earlier store that may
// alias its source, the stock compiler too, although the alias scopes say they may alias (n12). Each word-aligned copy
// of whole words up to 1 KiB becomes 32-bit loads and stores, volatile on the device and threadgroup side (the HD 4000
// still reordered plain ones, i80; a volatile copy into private memory loses values, i16). Runs after
// volatilizePunnedAccesses, which would otherwise take the new i32 views for punning.
static unsigned expandConstantCopies(LLVMModuleRef module) {
    if (disabled("INTEL_COPY_EXPAND_FIX")) return 0;
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context);
    std::vector<LLVMValueRef> copies;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(f); bb; bb = LLVMGetNextBasicBlock(bb))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst; inst = LLVMGetNextInstruction(inst)) {
                LLVMValueRef callee = LLVMIsACallInst(inst) ? LLVMGetCalledValue(inst) : nullptr;
                if (!callee || strncmp(LLVMGetValueName(callee), "llvm.memcpy.", 12) || LLVMGetNumArgOperands(inst) != 5) continue;
                LLVMValueRef length = LLVMGetOperand(inst, 2), align = LLVMGetOperand(inst, 3), isVolatile = LLVMGetOperand(inst, 4);
                if (!LLVMIsAConstantInt(length) || !LLVMIsAConstantInt(align) || !LLVMIsAConstantInt(isVolatile)) continue;
                unsigned long long bytes = LLVMConstIntGetZExtValue(length);
                if (bytes < 4 || bytes > 1024 || bytes % 4 || LLVMConstIntGetZExtValue(align) < 4 || LLVMConstIntGetZExtValue(isVolatile)) continue;
                copies.push_back(inst);
            }
    if (copies.empty()) return 0;
    LLVMBuilderRef b = LLVMCreateBuilderInContext(context);
    for (LLVMValueRef copy : copies) {
        LLVMPositionBuilderBefore(b, copy);
        LLVMValueRef dst = LLVMGetOperand(copy, 0), src = LLVMGetOperand(copy, 1);
        dst = LLVMBuildBitCast(b, dst, LLVMPointerType(i32, LLVMGetPointerAddressSpace(LLVMTypeOf(dst))), "");
        src = LLVMBuildBitCast(b, src, LLVMPointerType(i32, LLVMGetPointerAddressSpace(LLVMTypeOf(src))), "");
        unsigned words = (unsigned)(LLVMConstIntGetZExtValue(LLVMGetOperand(copy, 2)) / 4);
        for (unsigned k = 0; k < words; k++) {
            LLVMValueRef index = LLVMConstInt(i32, k, 0);
            LLVMValueRef word = LLVMBuildLoad(b, LLVMBuildGEP(b, src, &index, 1, ""), "");
            LLVMSetAlignment(word, 4);
            LLVMValueRef store = LLVMBuildStore(b, word, LLVMBuildGEP(b, dst, &index, 1, ""));
            LLVMSetAlignment(store, 4);
            unsigned from = LLVMGetPointerAddressSpace(LLVMTypeOf(src)), to = LLVMGetPointerAddressSpace(LLVMTypeOf(dst));
            if (from == 1 || from == 3) LLVMSetVolatile(word, 1);  // device and threadgroup memory: see above
            if (to == 1 || to == 3) LLVMSetVolatile(store, 1);
        }
        LLVMInstructionEraseFromParent(copy);
    }
    LLVMDisposeBuilder(b);
    return (unsigned)copies.size();
}

// ---- inline asm ---------------------------------------------------------------------------------------------------
// ANGLE writes __asm__("") into every loop it translates; IGILInstructionCleanup asks every call for its callee's name
// and dereferences null for inline asm, crashing the compiler service (i81; Electron windows with Skia's blur shadows
// stayed blank). Metal has no inline asm to run, and the front end's loop passes are done by now: the call is dropped.
static unsigned dropInlineAsm(LLVMModuleRef module) {
    return disabled("INTEL_INLINE_ASM_FIX") ? 0 : dropUnusedInlineAsmCalls(module);
}

enum PluginScope { kEveryPlugin, kIvyBridgeOnly, kHaswellOnly };
enum Condition { kAlways, kOnlyIfPreviousChanged };
struct ModuleFix {
    unsigned (*apply)(LLVMModuleRef module);
    const char *logFormat;  // with %u for the count
    PluginScope scope = kEveryPlugin;
    Condition condition = kAlways;
};
// In this order: some rewrites prepare the module for later ones.
static const ModuleFix kModuleFixes[] = {
    {ivbInlineConstants, "%u load(s) of program-scope constants read their values", kIvyBridgeOnly},
    {ivbArgumentBuffers, "%u function(s): argument-buffer pointers made hidden buffers", kIvyBridgeOnly},
    {ivbArgumentBufferOffsets, "%u argument-buffer member access(es) in vertex/fragment functions done at byte offsets", kIvyBridgeOnly},
    {dropInlineAsm, "%u inline asm call(s) dropped"},
    {dropMaxWorkGroupSize, "%u air.max_work_group_size attribute(s) dropped"},
    {returnFromEndlessLoops, "%u loop(s) that never exit made returns"},
    {dropArrayStructInfo, "struct info dropped from %u array-of-struct argument(s)"},
    {moveEmulatedReferenceSlotsToLocation, "%u argument-buffer reference(s) given the hidden buffer the driver binds", kHaswellOnly},
    {fixEscapedHandleLoads, "%u texture/sampler load(s) through escaped pointers re-indexed into the argument"},
    {fixVertexSignedSubwords, "%u signed i8/i16 conversion(s) in a vertex function done on the 32-bit word"},
    {fixGradientCompares, "%u depth comparison(s) with gradients done at level 0"},
    {foldHalfVectorBitcasts, "%u constant(s) with half vectors spelled as bitcasts rewritten"},
    {dropSampleCompareBias, "%u depth comparison(s) with an LOD bias: bias dropped"},
    {lowerIntegerGradients, "%u integer gradient sample(s) done at the level the gradients select"},
    {widenNarrowDivisions, "%u 8/16-bit division(s) done on 32-bit lanes"},  // before signedDivisionNegations, which then sees the 32-bit divides
    {signedDivisionNegations, "%u signed division(s) of a negated value done on the value"},
    {selectWideDivisionLanes, "%u vector lane(s) picked by a 64-bit quotient done with selects"},
    {signedPowerOfTwoDivisions, "%u signed division(s) by a power of two done with shifts"},  // after the two division rewrites above
    {foldConstantCalls, "%u integer function call(s) of constants folded"},
    {selectWideDivisionLanes, "%u vector lane(s) picked by a 64-bit shift of a folded constant done with selects", kEveryPlugin, kOnlyIfPreviousChanged},  // the fold can leave a shift of a constant as an index (i59)
    {widenNarrowMinMax, "%u 8/16-bit min / max / clamp call(s) done on 32-bit lanes"},
    {foldConstantSaturation, "%u addsat / subsat of constants folded"},
    {expandSaturation, "%u 32-bit addsat / signed subsat written out as add, compares and selects"},  // after the fold: what's left may still become constant in the plugin's passes
    {exactMadSat, "%u madsat / mulhi / madhi call(s) done with 32-bit operations"},
    {exact64BitMultiplies, "%u 64-bit multiply / mulhi / madhi call(s) built from 32-bit limbs"},
    {linearCubeGathers, "%u cube gather(s) given a linear constexpr sampler (seamless at face edges)"},
    {greenGathers, "%u green gather(s) checked against a red one, sampled where the two agree"},  // before foldIntegerSampleOffsets, which then fixes the offsets of both gathers
    {foldIntegerSampleOffsets, "%u integer texture sample(s): texel offset moved into the coordinates"},
    {fixSamplerStateWords, "%u constexpr sampler(s) in the [2 x i64] form rewritten as i64"},
    {remapComputeLevels, "%u explicit level(s) in a compute kernel remapped for the sampler's mip blend"},
    {widenThreadgroupBools, "%u threadgroup bool(s) widened to i8"},
    {pinConstantThreadgroupAtomics, "%u threadgroup atomic(s) holding only constants read once, volatile"},
    {wordPrivateSubwords, "%u aligned byte/halfword access(es) to private memory done on the 32-bit word"},
    {fixFloat3Inputs, "%u float3 vertex/fragment input(s) read through fmax"},
    {foldNumSamples, "%u get_num_samples() call(s) replaced by the pipeline's sample count"},
    {splitPrivatePointerSelects, "%u load(s)/store(s) through a select of private pointers split per pointer"},
    {widenNarrowPrivateArrays, "%u private array(s) of bytes / halfwords done on 32-bit words"},  // before selectPrivateArrayIndices, which then rewrites the i32 arrays
    {selectPrivateArrayIndices, "%u variable-index private array access(es) done at constant indices"},
    {volatilizePunnedAccesses, "%u access(es) to a buffer viewed as different types made volatile"},
    {expandConstantCopies, "%u constant-length copie(s) done as 32-bit loads and stores"},  // after volatilizePunnedAccesses (see there)
    {flattenBranchChains, "%u short branch(es) folded into selects"},
    {selectBufferIndices, "%u select(s) of pointers into one buffer turned into a selected index"},  // after flattenBranchChains, whose selects can pick pointers
    {volatileReloadsAfterOtherStores, "%u reload(s) after a store through another pointer made volatile"},  // after the rewrites that add loads and stores
    {bitTestCompares, "%u compare(s) of a 0/1 value with 1 in a vertex/fragment module done as a compare with 0"},
    {expandRenderInt64, "%u 64-bit division(s) / variable shift(s) in a vertex/fragment function done on 32-bit halves"},
    {widenNarrowVectorCompares, "%u compare(s), select(s) and operation(s) on byte / halfword vectors in a vertex/fragment module done on 32-bit lanes"},
    {splitHalfwordBytes, "%u bitcast(s) of halfwords to bytes in a vertex/fragment module done lane by lane"},  // after the rewrites above, which see the module as before
    {packByteHalfwords, "%u bitcast(s) of bytes to halfwords put together lane by lane (Ivy Bridge)"},
};

static bool appliesToThisPlugin(PluginScope scope) {
    return scope == kEveryPlugin || (scope == kIvyBridgeOnly) == ivyBridgePlugin;
}
static void applyModuleFixes(LLVMModuleRef module) {
    unsigned previousChanges = 0;
    for (const ModuleFix &fix : kModuleFixes) {
        bool runs = appliesToThisPlugin(fix.scope) && (fix.condition == kAlways || previousChanges);
        unsigned changes = runs ? fix.apply(module) : 0;
        if (changes && logging()) logCount(fix.logFormat, changes);
        previousChanges = changes;
    }
}
static void lowerTextureAtomicCalls(LLVMModuleRef module) {
    unsigned n = lowerTextureAtomics(module);
    if (n && logging()) fprintf(stderr, "[inteltex] %u texture atomic call(s) lowered\n", n);
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f)) {
        const char *name = LLVMGetValueName(f);
        if (!strstr(name, "air.atomic_") || !strstr(name, "_texture_") || !LLVMGetFirstUse(f)) continue;
        char *type = LLVMPrintTypeToString(LLVMTypeOf(f));
        fprintf(stderr, "[inteltex] not lowered: %s %s\n", name, type);  // the compile fails
        LLVMDisposeMessage(type);
    }
    if (n) dumpModule("INTELTEX_DUMP", "lowered", false, module);
}
static bool installHooksOnce() {  // true once texture atomics can be lowered
    pthread_mutex_lock(&installLock);
    installIntoPlugin(false);  // test process: the plugin was dlopened after we were inserted
    installICBEHook();
    bool canLowerTextureAtomics = textFixInstalled && resolveIGIL();
    pthread_mutex_unlock(&installLock);
    return canLowerTextureAtomics;
}

static int hookedRun(void *self, LLVMModuleRef module) {
    bool canLowerTextureAtomics = installHooksOnce();
    if (module) {
        dumpModule("INTELTEX_DUMP_INPUT", "input", true, module);  // compiler services run in parallel: per process
        applyModuleFixes(module);
        dumpModule("INTELTEX_DUMP_REWRITTEN", "rewritten", true, module);
        if (canLowerTextureAtomics) lowerTextureAtomicCalls(module);
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
