// texatomic.dylib: MSL texture atomics (Metal 3.1) for the 12.5 AMD shader compiler (AMDShared + libAMDIL902 +
// ATIRadeonX4000SCLib) that OCLP installs for GCN GPUs on macOS 14+.
//
// libAMDIL902 doesn't know the air.atomic_*_explicit_texture_* intrinsics and silently drops the calls, but the GCN
// hardware and the shader compiler support typed-image atomics. Two steps:
//   1. Before ILPluginHelper::compileShader: retarget each texture-atomic call whose result is unused to the texture
//      write intrinsic with the same arguments (texture, coords, [array,] value, i32, i32) and replace its memory-order
//      operand (always 0, the write's lod operand) with a tag 0x7A7000xx naming the atomic operation. The backend then
//      emits the texture's descriptor, coordinates and value followed by `uav_store_mip_ext_direct... lodreg`.
//   2. Before SCCompileShader: disassemble the IL tokens, turn every store whose lod register was loaded with a tag
//      into `uav_<op>_ext_direct_view(typed)...` (the same operands minus mem0 and the lod), reassemble.
// LLVM 5.0.2 internals (Twine, Use, Value layouts) are pinned to the stock libAMDIL902 by its SHA-256.
//
// Second job, Southern Islands GPUs only (GCN1, SC family 110): after SCCompileShader, insert the wait states SC leaves
// out between a scalar write of a buffer descriptor and the s_buffer_load reading it (sihazard.c). Without them, loads
// through Metal argument buffers can read a half-written descriptor and return 0. Also set GLC (bypass the vector L1)
// on loads from memory the same shader writes: SI can return a stale value for a load right after a store to the same
// address (Blender EEVEE's scratch-memory G-buffer writer -> black blocks behind glass). AMD_SI_HAZARD_FIX=0 turns
// both off, AMD_SI_L1_FIX=0 only the L1 bypass.
//
// Installed: AMDShared.bundle/Contents/MacOS/AMDTextureAtomics.dylib, loaded by a weak load command in AMDShared.
// Test use (in-process compiling): DYLD_INSERT_LIBRARIES=Tests/tools/localcc.dylib:build/texatomic.dylib <app>
//   TEXATOMIC_LOG=1   log what is rewritten
#include "sihazard.h"
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- hooked functions -------------------------------------------------------------------------------------------
// A static member: (Module&, std::string& il, char*&, uint64&, char*&, uint64&, std::string&).
extern bool compileShader(void *module, void *il, void *a, void *b, void *c, void *d, void *e)
    asm("__ZN4llvm12amdMtlPlugin14ILPluginHelper13compileShaderERNS_6ModuleERNSt3__112basic_stringIcNS4_11char_traitsIcEENS4_9allocatorIcEEEERPcRySD_SE_SB_");
typedef void (*SCPrintFn)(void *userData, char *unused, char *format, va_list args);
extern int SCCompileShader(void *sc, void *src, void *out);
extern int SCDumpILShader(void *userData, const void *tokens, uint32_t sizeBytes, SCPrintFn print);
extern int ilXltTextToBinary(const char *text, void **binary, unsigned *dwords);
extern int SCGetInstructionSet(int family, int revision, int deviceID);
extern void *operatorNewArray(unsigned long) asm("__Znam");  // AMDShared frees the machine code with delete[]
extern void operatorDeleteArray(void *) asm("__ZdaPv");

static bool logging(void) { return getenv("TEXATOMIC_LOG") != NULL; }

// ---- pinned LLVM 5 API inside libAMDIL902 -----------------------------------------------------------------------
// Stock 12.5 libAMDIL902, and the same file patched by libAMDIL902/make_parser_fix.py (metadata parser fixes 1-3, then
// also the GEP Select insertion-point fix 4), which leave symbols and data layouts unchanged. Identified independently
// of the code signature (Dortania's release signing, PatcherSupportPkg's ad-hoc copies and local re-signing all
// differ): the LC_UUID plus the SHA-256 of the __TEXT segment's file bytes after the load commands, which covers the
// code, the constants and the header padding the patches use (tools/textpin.py computes the same values).
static const unsigned char kProviderUUID[16] = {
    0xd5, 0xcf, 0x00, 0x07, 0x89, 0x35, 0x31, 0x93, 0xb3, 0xf1, 0xd0, 0xb3, 0xdd, 0x0d, 0xcc, 0x91};
static const unsigned char kProviderTextHashes[3][32] = {{
    0xe4, 0x38, 0x93, 0xcb, 0x0b, 0x79, 0xed, 0x81, 0x99, 0xad, 0x29, 0x80, 0x13, 0xb2, 0xe1, 0xcc,
    0xc3, 0x7c, 0xa5, 0x51, 0x03, 0x46, 0x90, 0x06, 0x40, 0x6c, 0xbb, 0xb1, 0xa2, 0x76, 0x9c, 0x49}, {
    0xd4, 0x3d, 0x71, 0x3d, 0x4d, 0x19, 0xc9, 0xec, 0x2a, 0xeb, 0x7b, 0x08, 0xb0, 0x39, 0x12, 0xdd,
    0x27, 0xec, 0xc7, 0x99, 0x89, 0xbe, 0x38, 0xad, 0xa7, 0x8a, 0xaf, 0x0f, 0x72, 0x07, 0x3a, 0x4e}, {
    0x7b, 0x1b, 0x92, 0xe8, 0x36, 0xfe, 0x7d, 0x30, 0x5b, 0x30, 0x55, 0x0d, 0x17, 0x9f, 0x01, 0x62,
    0xdc, 0x60, 0x45, 0x93, 0x5f, 0x0d, 0x68, 0xd4, 0x1b, 0x58, 0xeb, 0x53, 0xfc, 0x2d, 0xb7, 0x81}};  // stock, patches 1-3, patches 1-4

// True if `bytes` is one of the pinned libAMDIL902 builds.
static bool isPinnedProvider(const char *bytes, size_t length) {
    if (length < sizeof(struct mach_header_64)) return false;
    const struct mach_header_64 *header = (const struct mach_header_64 *)bytes;
    if (header->magic != MH_MAGIC_64 || sizeof *header + header->sizeofcmds > length) return false;
    const unsigned char *uuid = NULL;
    uint64_t textEnd = 0;
    const char *p = bytes + sizeof *header;
    for (uint32_t i = 0; i < header->ncmds; i++, p += ((const struct load_command *)p)->cmdsize) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_UUID) uuid = ((const struct uuid_command *)lc)->uuid;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_TEXT))
            textEnd = ((const struct segment_command_64 *)lc)->fileoff + ((const struct segment_command_64 *)lc)->filesize;
    }
    size_t start = sizeof *header + header->sizeofcmds;
    if (!uuid || memcmp(uuid, kProviderUUID, 16) || textEnd <= start || textEnd > length) return false;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes + start, (CC_LONG)(textEnd - start), hash);
    for (int k = 0; k < 3; k++)
        if (!memcmp(hash, kProviderTextHashes[k], sizeof hash)) return true;
    return false;
}

typedef struct { const char *data; size_t size; } StringRef;
// ArrayRef<T> by value: a 16-byte aggregate, so it goes in two registers only if both are free (otherwise on the stack).
typedef struct { void **data; size_t size; } ArrayRef;
typedef struct { const void *lhs, *rhs; unsigned char lhsKind, rhsKind; } Twine;  // LLVM 5: 8-byte children
enum { kTwineEmpty = 1, kTwineCString = 3 };

static struct {
    bool valid;
    void *(*getFunction)(void *module, const char *name, size_t size);
    void *(*getOrInsertFunction)(void *module, const char *name, size_t size, void *functionType);
    void *(*functionTypeGet)(void *result, void **params, size_t count, bool varArg);
    void *(*constantIntGet)(void *type, uint64_t value, bool isSigned);
    void *(*getInt32Ty)(void *context);
    void *(*getVoidTy)(void *context);
    void *(*getContext)(void *value);
    void *(*getUser)(void *use);
    void (*replaceUsesOfWith)(void *user, void *from, void *to);
    // For atomics whose result is used: a volatile load placeholder that carries the result in the IL.
    void *(*pointerTypeGet)(void *element, unsigned addressSpace);
    void *(*intToPtr)(void *constant, void *type, bool onlyIfReduced);
    void *(*getInt64Ty)(void *context);
    void *(*userNew)(size_t size, unsigned operands);
    void (*loadInst)(void *self, void *type, void *pointer, const void *name, bool isVolatile, void *insertBefore);
    void (*insertAfter)(void *self, void *position);
    void (*replaceAllUsesWith)(void *self, void *with);
    // Creating calls and the helper instructions for atomic load/store/compare-exchange.
    void (*instruction)(void *self, void *type, unsigned opcode, void *operands, unsigned count, void *insertBefore);
    void (*callInit)(void *self, void *functionType, void *callee, ArrayRef args, ArrayRef bundles, const void *name);
    void (*eraseFromParent)(void *self);
    void (*extractElement)(void *self, void *vector, void *index, const void *name, void *insertBefore);
    void (*insertElement)(void *self, void *vector, void *element, void *index, const void *name, void *insertBefore);
    void (*storeInst)(void *self, void *value, void *pointer, void *insertBefore);
    void *(*cmpCreate)(unsigned opcode, unsigned predicate, void *lhs, void *rhs, const void *name, void *insertBefore);
    void *(*splat)(unsigned count, void *element);
    // ushort coordinates (the .i16 variants): zero-extended to the 32-bit forms.
    void *(*castCreate)(unsigned opcode, void *value, void *type, const void *name, void *insertBefore);
    void *(*vectorTypeGet)(void *element, unsigned count);
    void *(*getInt16Ty)(void *context);
    void (*moduleDump)(void *module);  // llvm::Module::dump() (stderr), for TEXATOMIC_DUMP_MODULE
    void (*parseOptions)(int argc, const char *const *argv, const char *overview);  // LLVMParseCommandLineOptions
    // Escaped argument-table pointers (fixEscapedHandleLoads); optional, that fix only.
    bool (*hasByValAttr)(void *argument);
    StringRef (*structName)(void *structType);
    void (*buildLazyArguments)(void *function);
} api;

static void *resolveIn(const char *bytes, size_t length, const struct symtab_command *table, uint64_t textAddress,
                       void *base, const char *name) {
    const struct nlist_64 *symbols = (const struct nlist_64 *)(bytes + table->symoff);
    for (uint32_t i = 0; i < table->nsyms; i++) {
        const struct nlist_64 *s = &symbols[i];
        if ((s->n_type & N_STAB) || (s->n_type & N_TYPE) != N_SECT || s->n_un.n_strx >= table->strsize) continue;
        if (!strcmp(bytes + table->stroff + s->n_un.n_strx, name)) return (char *)base + (s->n_value - textAddress);
    }
    return NULL;
}

static bool resolveAPI(void) {
    static int state;  // 0 = not tried, 1 = ok, -1 = unavailable
    if (state) return state > 0;
    state = -1;
    Dl_info info;
    if (!dladdr((void *)compileShader, &info) || !info.dli_fname) return false;
    FILE *f = fopen(info.dli_fname, "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long length = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *bytes = malloc(length);
    bool read = fread(bytes, 1, length, f) == (size_t)length;
    fclose(f);
    if (!read || !isPinnedProvider(bytes, (size_t)length)) {
        if (logging()) fprintf(stderr, "[texatomic] %s is not the pinned libAMDIL902, disabled\n", info.dli_fname);
        free(bytes);
        return false;
    }
    const struct mach_header_64 *header = (const struct mach_header_64 *)bytes;
    const struct symtab_command *table = NULL;
    uint64_t textAddress = 0;
    const char *p = bytes + sizeof *header;
    for (uint32_t i = 0; i < header->ncmds; i++, p += ((const struct load_command *)p)->cmdsize) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SYMTAB) table = (const struct symtab_command *)lc;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_TEXT))
            textAddress = ((const struct segment_command_64 *)lc)->vmaddr;
    }
    if (table && textAddress) {
#define RESOLVE(field, symbol) api.field = resolveIn(bytes, length, table, textAddress, info.dli_fbase, symbol)
        RESOLVE(getFunction, "__ZNK4llvm6Module11getFunctionENS_9StringRefE");
        RESOLVE(getOrInsertFunction, "__ZN4llvm6Module19getOrInsertFunctionENS_9StringRefEPNS_12FunctionTypeE");
        RESOLVE(functionTypeGet, "__ZN4llvm12FunctionType3getEPNS_4TypeENS_8ArrayRefIS2_EEb");
        RESOLVE(constantIntGet, "__ZN4llvm11ConstantInt3getEPNS_4TypeEyb");
        RESOLVE(getInt32Ty, "__ZN4llvm4Type10getInt32TyERNS_11LLVMContextE");
        RESOLVE(getVoidTy, "__ZN4llvm4Type9getVoidTyERNS_11LLVMContextE");
        RESOLVE(getContext, "__ZNK4llvm5Value10getContextEv");
        RESOLVE(getUser, "__ZNK4llvm3Use7getUserEv");
        RESOLVE(replaceUsesOfWith, "__ZN4llvm4User17replaceUsesOfWithEPNS_5ValueES2_");
        RESOLVE(pointerTypeGet, "__ZN4llvm11PointerType3getEPNS_4TypeEj");
        RESOLVE(intToPtr, "__ZN4llvm12ConstantExpr11getIntToPtrEPNS_8ConstantEPNS_4TypeEb");
        RESOLVE(getInt64Ty, "__ZN4llvm4Type10getInt64TyERNS_11LLVMContextE");
        RESOLVE(userNew, "__ZN4llvm4UsernwEmj");
        RESOLVE(loadInst, "__ZN4llvm8LoadInstC1EPNS_4TypeEPNS_5ValueERKNS_5TwineEbPNS_11InstructionE");
        RESOLVE(insertAfter, "__ZN4llvm11Instruction11insertAfterEPS0_");
        RESOLVE(replaceAllUsesWith, "__ZN4llvm5Value18replaceAllUsesWithEPS0_");
        RESOLVE(instruction, "__ZN4llvm11InstructionC2EPNS_4TypeEjPNS_3UseEjPS0_");
        RESOLVE(callInit, "__ZN4llvm8CallInst4initEPNS_12FunctionTypeEPNS_5ValueENS_8ArrayRefIS4_EENS5_INS_17OperandBundleDefTIS4_EEEERKNS_5TwineE");
        RESOLVE(eraseFromParent, "__ZN4llvm11Instruction15eraseFromParentEv");
        RESOLVE(extractElement, "__ZN4llvm18ExtractElementInstC1EPNS_5ValueES2_RKNS_5TwineEPNS_11InstructionE");
        RESOLVE(insertElement, "__ZN4llvm17InsertElementInstC1EPNS_5ValueES2_S2_RKNS_5TwineEPNS_11InstructionE");
        RESOLVE(storeInst, "__ZN4llvm9StoreInstC1EPNS_5ValueES2_PNS_11InstructionE");
        RESOLVE(cmpCreate, "__ZN4llvm7CmpInst6CreateENS_11Instruction8OtherOpsENS0_9PredicateEPNS_5ValueES5_RKNS_5TwineEPS1_");
        RESOLVE(splat, "__ZN4llvm14ConstantVector8getSplatEjPNS_8ConstantE");
        RESOLVE(castCreate, "__ZN4llvm8CastInst6CreateENS_11Instruction7CastOpsEPNS_5ValueEPNS_4TypeERKNS_5TwineEPS1_");
        RESOLVE(vectorTypeGet, "__ZN4llvm10VectorType3getEPNS_4TypeEj");
        RESOLVE(getInt16Ty, "__ZN4llvm4Type10getInt16TyERNS_11LLVMContextE");
        RESOLVE(moduleDump, "__ZNK4llvm6Module4dumpEv");
        RESOLVE(parseOptions, "_LLVMParseCommandLineOptions");
        RESOLVE(hasByValAttr, "__ZNK4llvm8Argument12hasByValAttrEv");
        RESOLVE(structName, "__ZNK4llvm10StructType7getNameEv");
        RESOLVE(buildLazyArguments, "__ZNK4llvm8Function18BuildLazyArgumentsEv");
#undef RESOLVE
        api.valid = api.getFunction && api.getOrInsertFunction && api.functionTypeGet && api.constantIntGet &&
                    api.getInt32Ty && api.getVoidTy && api.getContext && api.getUser && api.replaceUsesOfWith &&
                    api.pointerTypeGet && api.intToPtr && api.getInt64Ty && api.userNew && api.loadInst &&
                    api.insertAfter && api.replaceAllUsesWith && api.instruction && api.callInit && api.eraseFromParent &&
                    api.extractElement && api.insertElement && api.storeInst && api.cmpCreate && api.splat &&
                    api.castCreate && api.vectorTypeGet && api.getInt16Ty;
    }
    free(bytes);
    state = api.valid ? 1 : -1;
    return api.valid;
}

// LLVM 5 Value: Type *VTy @0, Use *UseList @8, u8 SubclassID @16, u32 NumUserOperands:28 | flags @20.
// Use: Value *Val @0, Use *Next @8, Prev @16 (24 bytes). Fixed operands are co-allocated in front of the User.
// Instruction is 56 bytes; CallInst adds AttributeList Attrs @56 and FunctionType *FTy @64.
// FunctionType: ContainedTys @16, [0] = return type. GlobalValue::ValueType @24.
enum { kUseSize = 24, kOpcodeZExt = 37, kOpcodeCall = 54, kOpcodeICmp = 51, kPredicateEQ = 32 };
static void *typeOf(void *value) { return *(void **)value; }
static void *firstUse(void *value) { return *(void **)((char *)value + 8); }
static void *nextUse(void *use) { return *(void **)((char *)use + 8); }
static unsigned char subclassID(void *value) { return *(unsigned char *)((char *)value + 16); }
static uint32_t operandBits(void *user) { return *(uint32_t *)((char *)user + 20); }
static unsigned numOperands(void *user) { return operandBits(user) & 0x0FFFFFFF; }
static bool hungOffUses(void *user) { return operandBits(user) & (1u << 30); }
static void *operand(void *user, unsigned i) { return *(void **)((char *)user - (numOperands(user) - i) * kUseSize); }
static void *returnType(void *functionType) { return (*(void ***)((char *)functionType + 16))[0]; }
static const Twine kNoName = {NULL, NULL, kTwineEmpty, kTwineEmpty};

// ---- step 1: AIR -------------------------------------------------------------------------------------------------
// Operation codes carried in the tag; 9 = compare-exchange (value.x = desired, value.y = expected).
enum { kOpAdd = 1, kOpSub, kOpMin, kOpMax, kOpAnd, kOpOr, kOpXor, kOpExchange, kOpCompareExchange };
static const struct { const char *air; unsigned code; } kOps[] = {
    {"fetch_add", kOpAdd}, {"fetch_sub", kOpSub}, {"fetch_min", kOpMin}, {"fetch_max", kOpMax},
    {"fetch_and", kOpAnd}, {"fetch_or", kOpOr},   {"fetch_xor", kOpXor}, {"exchange", kOpExchange},
};
static const char *const kDims[] = {"1d", "1d_array", "2d", "2d_array", "3d", "buffer_1d"};
// Texture buffers have no lod operand (write: texture, coord, value, access); their tag goes in value.w instead,
// which R32 formats ignore.
static bool isBuffer(const char *dim) { return !strncmp(dim, "buffer", 6); }
// Tag (the write's lod operand): 0x7A70 | id (bits 8-15, 0 = result unused) | op (bits 0-6) | signed (bit 7).
// An atomic whose result is used gets id >= 1 and a volatile load from 0x7A710000_000000<id> placed right after it,
// which takes over the result's uses; the IL pass turns the load into a copy of the atomic's return register.
enum { kTagBase = 0x7A700000, kTagSigned = 0x80, kMaxResults = 255 };
static const uint64_t kResultAddressBase = 0x7A71000000000000ULL;

typedef struct {
    void *module, *context, *i32, *zero;
    void *narrow[3], *wide[3];  // i16, <2 x i16>, <3 x i16> and their 32-bit forms
    unsigned char functionID;  // SubclassID of a Function
    unsigned results, lowered;
} Lowering;

static void *calls(void *function, void **out, unsigned max) {
    unsigned n = 0;
    for (void *use = firstUse(function); use && n < max; use = nextUse(use)) out[n++] = api.getUser(use);
    if (n < max) out[n] = NULL;
    return out;
}

// A well-formed call of `function`: callee last, fixed (co-allocated) operands, the expected operand count.
static bool isCall(void *call, void *function, unsigned operands) {
    return !hungOffUses(call) && numOperands(call) == operands && operand(call, operands - 1) == function;
}

static void *tagFor(Lowering *L, unsigned op, bool isSigned, unsigned id) {
    return api.constantIntGet(L->i32, kTagBase | (id << 8) | op | (isSigned ? kTagSigned : 0), false);
}

// air.write_texture_<dim>.<sign>.v4i32 with the given parameter types, or NULL if a different declaration exists.
static void *writeFunction(Lowering *L, const char *dim, char sign, void **params, unsigned count, void **typeOut) {
    char name[96];
    snprintf(name, sizeof name, "air.write_texture_%s.%c.v4i32", dim, sign);
    void *type = api.functionTypeGet(api.getVoidTy(L->context), params, count, false);
    void *write = api.getOrInsertFunction(L->module, name, strlen(name), type);
    if (!write || subclassID(write) != L->functionID) return NULL;  // a bitcast: existing declaration of another type
    if (typeOut) *typeOut = type;
    return write;
}

static void *createCall(void *function, void *functionType, void **args, unsigned count, void *insertBefore) {
    unsigned operands = count + 1;
    char *call = api.userNew(128, operands);  // sizeof(CallInst) is 72 in LLVM 5
    api.instruction(call, returnType(functionType), kOpcodeCall, call - operands * kUseSize, operands, insertBefore);
    memset(call + 56, 0, 128 - 56);  // CallInst::Attrs (empty AttributeList) and FTy before init
    api.callInit(call, functionType, function, (ArrayRef){args, count}, (ArrayRef){NULL, 0}, &kNoName);
    return call;
}

// A ushort coordinate or layer as the 32-bit value the texture write takes.
static void *widen(Lowering *L, void *value, void *before) {
    for (int k = 0; k < 3; k++)
        if (typeOf(value) == L->narrow[k]) return api.castCreate(kOpcodeZExt, value, L->wide[k], &kNoName, before);
    return value;
}

// Tagged write (texture, coords, [array,] value, tag, scope) in front of `before`.
static bool createTaggedWrite(Lowering *L, const char *dim, char sign, void **head, unsigned headCount, void *value,
                              void *tag, void *scope, void *before) {
    void *args[8], *params[8], *type;
    unsigned n = 0;
    for (unsigned k = 0; k < headCount; k++) args[n++] = k ? widen(L, head[k], before) : head[k];
    if (isBuffer(dim)) {
        if (tag != L->zero) {
            void *tagged = api.userNew(96, 3);
            api.insertElement(tagged, value, tag, api.constantIntGet(L->i32, 3, false), &kNoName, before);
            value = tagged;
        }
        args[n++] = value;
        args[n++] = scope;
    } else {
        args[n++] = value;
        args[n++] = tag;
        args[n++] = scope;
    }
    for (unsigned k = 0; k < n; k++) params[k] = typeOf(args[k]);
    void *write = writeFunction(L, dim, sign, params, n, &type);
    if (!write) return false;
    createCall(write, type, args, n, before);
    return true;
}

// Volatile load from the result address of `id`; inserted after `after`.
static void *createResultLoad(Lowering *L, void *vectorType, unsigned id, void *after) {
    void *pointerType = api.pointerTypeGet(vectorType, 1);
    void *address = api.intToPtr(api.constantIntGet(api.getInt64Ty(L->context), kResultAddressBase | id, false), pointerType, false);
    void *load = api.userNew(96, 1);  // sizeof(LoadInst) is 56 in LLVM 5; extra room is harmless
    api.loadInst(load, vectorType, address, &kNoName, true, NULL);
    api.insertAfter(load, after);
    return load;
}

// fetch_<op> / exchange: retarget the call itself to a tagged texture write (same operands, void).
// Operands: texture, coords, [array,] value, memory order, scope, callee.
static void lowerFetchViaNewWrite(Lowering *L, void *atomic, unsigned op, const char *dim, char sign);
static bool lowerFetchCall(Lowering *L, void *call, unsigned op, const char *dim, char sign, bool isArray);

static void lowerFetch(Lowering *L, void *atomic, unsigned op, const char *dim, char sign, bool isArray, bool narrow) {
    if (isBuffer(dim)) { lowerFetchViaNewWrite(L, atomic, op, dim, sign); return; }
    void *list[256];
    calls(atomic, list, 256);
    if (narrow) {  // ushort coordinates: a new write with widened ones
        for (unsigned i = 0; i < 256 && list[i]; i++)
            if (isCall(list[i], atomic, isArray ? 7 : 6)) lowerFetchCall(L, list[i], op, dim, sign, isArray);
        return;
    }
    void *atomicType = *(void **)((char *)atomic + 24);
    for (unsigned i = 0; i < 256 && list[i]; i++) {
        void *call = list[i];
        unsigned n = isArray ? 7 : 6;
        if (!isCall(call, atomic, n) || operand(call, n - 3) != L->zero) continue;
        bool clash = false;  // the order operand is found by value; no other operand may be the same constant
        for (unsigned k = 0; k < n - 3; k++) clash |= operand(call, k) == L->zero;
        if (clash) { lowerFetchCall(L, call, op, dim, sign, isArray); continue; }
        if (firstUse(call) && L->results == kMaxResults) continue;
        void *params[8];
        for (unsigned k = 0; k < n - 1; k++) params[k] = typeOf(operand(call, k));
        void *writeType;
        void *write = writeFunction(L, dim, sign, params, n - 1, &writeType);
        // The call keeps the atomic's <4 x i32> type and FunctionType; a texture write must be void or instruction
        // selection fails. Retype it: Value::VTy and CallInst::FTy (located by value).
        void **fty = NULL;
        for (int k = 7; k < 10 && !fty; k++)
            if (((void **)call)[k] == atomicType) fty = &((void **)call)[k];
        if (!write || !fty) continue;
        unsigned id = 0;
        if (firstUse(call)) {
            id = ++L->results;
            api.replaceAllUsesWith(call, createResultLoad(L, typeOf(call), id, call));
        }
        api.replaceUsesOfWith(call, L->zero, tagFor(L, op, sign == 's', id));
        api.replaceUsesOfWith(call, atomic, write);
        *fty = writeType;
        *(void **)call = api.getVoidTy(L->context);
        L->lowered++;
    }
}

// fetch_<op>/exchange(texture, coord, [array,] value, order, scope): a new tagged write in front (texture buffers:
// value.w = tag; other dimensions: the tag as the write's lod).
static bool lowerFetchCall(Lowering *L, void *call, unsigned op, const char *dim, char sign, bool isArray) {
    if (L->results == kMaxResults) return false;
    unsigned v = isArray ? 3 : 2, id = firstUse(call) ? L->results + 1 : 0;
    void *head[3] = {operand(call, 0), operand(call, 1), isArray ? operand(call, 2) : NULL};
    if (!createTaggedWrite(L, dim, sign, head, isArray ? 3 : 2, operand(call, v), tagFor(L, op, sign == 's', id), operand(call, v + 2), call))
        return false;
    if (id) {
        L->results = id;
        api.replaceAllUsesWith(call, createResultLoad(L, typeOf(call), id, call));
    }
    api.eraseFromParent(call);
    L->lowered++;
    return true;
}

static void lowerFetchViaNewWrite(Lowering *L, void *atomic, unsigned op, const char *dim, char sign) {
    void *list[256];
    calls(atomic, list, 256);
    for (unsigned i = 0; i < 256 && list[i]; i++)
        if (isCall(list[i], atomic, 6)) lowerFetchCall(L, list[i], op, dim, sign, false);
}

// atomic_store(texture, value, coords, [array,] order, scope): a plain texture write; a 32-bit texel store is atomic.
static void lowerStore(Lowering *L, void *atomic, const char *dim, char sign, bool isArray) {
    void *list[256];
    calls(atomic, list, 256);
    for (unsigned i = 0; i < 256 && list[i]; i++) {
        void *call = list[i];
        unsigned n = isArray ? 7 : 6;
        if (!isCall(call, atomic, n)) continue;
        void *head[3] = {operand(call, 0), operand(call, 2), isArray ? operand(call, 3) : NULL};
        if (!createTaggedWrite(L, dim, sign, head, isArray ? 3 : 2, operand(call, 1), L->zero, operand(call, n - 2), call))
            continue;
        api.eraseFromParent(call);
        L->lowered++;
    }
}

// atomic_load(texture, coords, [array,] order, scope) -> <4 x i32>: an atomic or with 0 that returns the old value.
static void lowerLoad(Lowering *L, void *atomic, const char *dim, char sign, bool isArray) {
    void *list[256];
    calls(atomic, list, 256);
    for (unsigned i = 0; i < 256 && list[i]; i++) {
        void *call = list[i];
        unsigned n = isArray ? 6 : 5;
        if (!isCall(call, atomic, n)) continue;
        if (!firstUse(call)) { api.eraseFromParent(call); L->lowered++; continue; }
        if (L->results == kMaxResults) continue;
        unsigned id = L->results + 1;
        void *head[3] = {operand(call, 0), operand(call, 1), isArray ? operand(call, 2) : NULL};
        void *zeros = api.splat(4, L->zero);
        if (!createTaggedWrite(L, dim, sign, head, isArray ? 3 : 2, zeros, tagFor(L, kOpOr, false, id), operand(call, n - 2), call))
            continue;
        L->results = id;
        api.replaceAllUsesWith(call, createResultLoad(L, typeOf(call), id, call));
        api.eraseFromParent(call);
        L->lowered++;
    }
}

// atomic_compare_exchange_weak(texture, coords, [array,] <4 x i32>* expected, desired, success, failure, scope) -> i1.
// The tagged write carries <desired.x, expected.x, ..>; the old value comes back through a result load, then
// success = old.x == expected.x and *expected = old (unchanged on success, the current value on failure).
static void lowerCompareExchange(Lowering *L, void *atomic, const char *dim, char sign, bool isArray) {
    void *list[256];
    calls(atomic, list, 256);
    for (unsigned i = 0; i < 256 && list[i]; i++) {
        void *call = list[i];
        unsigned n = isArray ? 9 : 8, e = isArray ? 3 : 2;
        if (!isCall(call, atomic, n) || L->results == kMaxResults) continue;
        void *expectedPointer = operand(call, e), *desired = operand(call, e + 1);
        void *vectorType = typeOf(desired);
        void *expected = api.userNew(96, 1);
        api.loadInst(expected, vectorType, expectedPointer, &kNoName, false, call);
        void *expectedX = api.userNew(96, 2);
        api.extractElement(expectedX, expected, L->zero, &kNoName, call);
        void *packed = api.userNew(96, 3);
        api.insertElement(packed, desired, expectedX, api.constantIntGet(L->i32, 1, false), &kNoName, call);
        unsigned id = L->results + 1;
        void *head[3] = {operand(call, 0), operand(call, 1), isArray ? operand(call, 2) : NULL};
        if (!createTaggedWrite(L, dim, sign, head, isArray ? 3 : 2, packed, tagFor(L, kOpCompareExchange, false, id),
                               operand(call, n - 2), call))
            continue;  // leaves dead helper instructions, removed by the backend's own cleanup
        L->results = id;
        void *old = createResultLoad(L, vectorType, id, call);
        void *oldX = api.userNew(96, 2);
        api.extractElement(oldX, old, L->zero, &kNoName, NULL);
        api.insertAfter(oldX, old);
        void *success = api.cmpCreate(kOpcodeICmp, kPredicateEQ, oldX, expectedX, &kNoName, NULL);
        api.insertAfter(success, oldX);
        void *store = api.userNew(96, 2);
        api.storeInst(store, old, expectedPointer, NULL);
        api.insertAfter(store, success);
        api.replaceAllUsesWith(call, success);
        api.eraseFromParent(call);
        L->lowered++;
    }
}

static unsigned lowerTextureAtomics(void *module) {
    Lowering L = {.module = module};
    for (size_t d = 0; d < sizeof kDims / sizeof kDims[0]; d++)
    for (int s = 0; s < 4; s++) {
        const char *dim = kDims[d];
        char sign = s & 1 ? 's' : 'u', name[128];
        bool isArray = strstr(dim, "_array") != NULL, narrow = s >= 2;  // narrow: ushort coordinates (.i16)
        for (int kind = 0; kind < (int)(sizeof kOps / sizeof kOps[0]) + 3; kind++) {
            const char *air = kind < (int)(sizeof kOps / sizeof kOps[0]) ? kOps[kind].air
                            : (const char *[]){"store", "load", "compare_exchange_weak"}[kind - sizeof kOps / sizeof kOps[0]];
            snprintf(name, sizeof name, "air.atomic_%s_explicit_texture_%s%s.%c.v4i32", air, dim, narrow ? ".i16" : "", sign);
            void *atomic = api.getFunction(module, name, strlen(name));
            if (!atomic || !firstUse(atomic)) continue;
            if (!L.context) {
                L.context = api.getContext(atomic);
                L.i32 = api.getInt32Ty(L.context);
                L.zero = api.constantIntGet(L.i32, 0, false);
                L.functionID = subclassID(atomic);
                L.narrow[0] = api.getInt16Ty(L.context);
                L.wide[0] = L.i32;
                for (int k = 1; k < 3; k++) {
                    L.narrow[k] = api.vectorTypeGet(L.narrow[0], k + 1);
                    L.wide[k] = api.vectorTypeGet(L.i32, k + 1);
                }
            }
            unsigned before = L.lowered;
            if (kind < (int)(sizeof kOps / sizeof kOps[0])) lowerFetch(&L, atomic, kOps[kind].code, dim, sign, isArray, narrow);
            else if (!strcmp(air, "store")) lowerStore(&L, atomic, dim, sign, isArray);
            else if (!strcmp(air, "load")) lowerLoad(&L, atomic, dim, sign, isArray);
            else lowerCompareExchange(&L, atomic, dim, sign, isArray);
            if (logging()) fprintf(stderr, "[texatomic] %s: %u call(s) lowered%s\n", name, L.lowered - before,
                                   firstUse(atomic) ? ", some left (unsupported shape)" : "");
        }
    }
    return L.lowered;
}

// ---- step 1b: AIR, texture/sampler loads through escaped pointers --------------------------------------------------
// MSL texture and sampler array arguments are byval arrays of handles in AIR. libAMDIL902 places them in the
// argument table (user data API slots 6/7, global memory) and lowers a handle load from a GEP of such an argument to
// a global load, but a handle load through any other private pointer to a scratch load. When the address of an
// element is stored to memory and loaded back, the backend loses the connection: ANGLE keeps `thread texture2d *`
// and `thread sampler *` pairs in an array of structs and indexes it at runtime (WebGL sampler arrays sampled in a
// loop), so `*env[i].texture` reads scratch at the argument table's global address, gets garbage, and the sample
// returns 0 or, through a garbage descriptor, hangs the GPU (WebGL conformance glsl/bugs/sampler-array-using-
// loop-index). Fix: every handle load whose pointer doesn't lead back to an argument or an alloca becomes
//   v = load p;  v = select(p == &a[k], load &a[k], v)  for each element k of each byval handle array a of that type
// in the same function, so the element loads take the argument-table path; the original load stays as the fallback
// for pointers into private memory. AMD_HANDLE_FIX=0 turns it off.
// LLVM 5 list layouts in the pinned library (Function::args, BasicBlock::insertInto, Function::eraseFromParent):
// Module::FunctionList sentinel @0x18; Function: Parent @0x28, list node @0x38, BasicBlocks sentinel @0x48,
// Arguments @0x58, NumArgs @0x60 (Argument = 40 bytes; lazily built while SubclassData bit 0 @0x12 is set);
// BasicBlock: node @0x18, InstList sentinel @0x28, Parent @0x38; Instruction: node @0x18, Parent @0x28.
// ilist nodes: Prev @0, Next @8. GetElementPtrInst: SourceElementType @0x38, ResultElementType @0x40.
enum { kModuleFunctions = 0x18, kFunctionParent = 0x28, kFunctionNode = 0x38, kFunctionBlocks = 0x48,
       kFunctionArgs = 0x58, kFunctionNumArgs = 0x60, kArgumentSize = 40, kBlockNode = 0x18, kBlockInstructions = 0x28,
       kBlockParent = 0x38, kInstructionNode = 0x18, kInstructionParent = 0x28 };
enum { kTypeStruct = 13, kTypeArray = 14, kTypePointer = 15 };  // Type::TypeID @8
enum { kValueArgument = 0, kValueInstruction = 24 };  // SubclassID; an instruction's is kValueInstruction + opcode
enum { kOpcodeAlloca = 29, kOpcodeLoad = 30, kOpcodeGEP = 32, kOpcodeBitCast = 47, kOpcodeSelect = 55 };
enum { kMaxHandleArrays = 8, kMaxHandleElements = 32, kMaxHandleLoads = 256, kMaxUsers = 64 };

static void *nextNode(void *node) { return *(void **)((char *)node + 8); }
static unsigned typeID(void *type) { return *(unsigned char *)((char *)type + 8); }
static void *elementType(void *type) { return (*(void ***)((char *)type + 16))[0]; }  // pointee / array element
static uint64_t arrayLength(void *type) { return *(uint64_t *)((char *)type + 32); }
static bool isInstruction(void *value, unsigned opcode) { return subclassID(value) == kValueInstruction + opcode; }

// Texture or sampler handle: a pointer to %struct._texture_*, %struct._depth_* or %struct._sampler_t.
static bool isHandleType(void *type) {
    if (typeID(type) != kTypePointer || typeID(elementType(type)) != kTypeStruct) return false;
    StringRef name = api.structName(elementType(type));
    return name.data && ((name.size > 15 && !strncmp(name.data, "struct._texture", 15)) ||
                         (name.size > 13 && !strncmp(name.data, "struct._depth", 13)) ||
                         (name.size >= 15 && !strncmp(name.data, "struct._sampler", 15)));
}

// Plain store of `value` into the operand slot `i` of a newly created user (the slot's Val is still null):
// Use::set + Value::addUse (Use: Val @0, Next @8, Prev @16 with 2 tag bits; Value::UseList @8).
static void setNewOperand(void *user, unsigned i, void *value) {
    char *use = (char *)user - (numOperands(user) - i) * kUseSize;
    void **list = (void **)((char *)value + 8);
    *(void **)use = value;
    void *next = *list;
    *(void **)(use + 8) = next;
    if (next) {
        uintptr_t *prev = (uintptr_t *)((char *)next + 16);
        *prev = (uintptr_t)(use + 8) | (*prev & 3);
    }
    uintptr_t *prev = (uintptr_t *)(use + 16);
    *prev = (uintptr_t)list | (*prev & 3);
    *list = use;
}

static void *createInstruction(void *type, unsigned opcode, void **operands, unsigned count, size_t size) {
    char *inst = api.userNew(size, count);
    api.instruction(inst, type, opcode, inst - count * kUseSize, count, NULL);
    for (unsigned i = 0; i < count; i++) setNewOperand(inst, i, operands[i]);
    return inst;
}

// The base a pointer is computed from: through GEPs and bitcasts, and through selects whose arms agree.
// Returns true if every path ends at an argument, an alloca or a constant/global (the backend knows where those point).
static bool knownBase(void *pointer, int depth) {
    for (int steps = 0; steps < 64; steps++) {
        unsigned char id = subclassID(pointer);
        if (id < kValueInstruction) return true;  // Argument, global, constant
        if (isInstruction(pointer, kOpcodeAlloca)) return true;
        if (isInstruction(pointer, kOpcodeGEP) || isInstruction(pointer, kOpcodeBitCast)) {
            if (hungOffUses(pointer) || numOperands(pointer) < 1) return false;
            pointer = operand(pointer, 0);
            continue;
        }
        if (isInstruction(pointer, kOpcodeSelect) && depth < 4 && !hungOffUses(pointer) && numOperands(pointer) == 3)
            return knownBase(operand(pointer, 1), depth + 1) && knownBase(operand(pointer, 2), depth + 1);
        return false;  // a pointer loaded from memory, a phi, a call result, ...
    }
    return false;
}

typedef struct { void *argument, *arrayType, *handleType; unsigned length; } HandleArray;

static unsigned fixFunctionHandleLoads(void *function, void *i64) {
    if (*(unsigned char *)((char *)function + 0x12) & 1) api.buildLazyArguments(function);
    char *args = *(char **)((char *)function + kFunctionArgs);
    size_t numArgs = *(size_t *)((char *)function + kFunctionNumArgs);
    HandleArray arrays[kMaxHandleArrays];
    unsigned numArrays = 0;
    for (size_t i = 0; i < numArgs && numArrays < kMaxHandleArrays; i++) {
        void *arg = args + i * kArgumentSize, *type = typeOf(arg);
        if (subclassID(arg) != kValueArgument || typeID(type) != kTypePointer) continue;
        void *array = elementType(type);
        if (typeID(array) != kTypeArray || !isHandleType(elementType(array)) || !api.hasByValAttr(arg)) continue;
        uint64_t length = arrayLength(array);
        if (length < 1 || length > kMaxHandleElements) continue;
        arrays[numArrays++] = (HandleArray){arg, array, elementType(array), (unsigned)length};
    }
    if (!numArrays) return 0;
    // Collect first, rewrite after: the rewrite inserts instructions into the lists being walked.
    void *loads[kMaxHandleLoads];
    unsigned numLoads = 0;
    char *blocks = (char *)function + kFunctionBlocks;
    for (char *bn = nextNode(blocks); bn != blocks; bn = nextNode(bn)) {
        char *block = bn - kBlockNode, *insts = block + kBlockInstructions;
        if (*(void **)(block + kBlockParent) != function) return 0;  // layout mismatch: leave the module alone
        for (char *in = nextNode(insts); in != insts; in = nextNode(in)) {
            char *inst = in - kInstructionNode;
            if (*(void **)(inst + kInstructionParent) != block) return 0;
            if (!isInstruction(inst, kOpcodeLoad) || hungOffUses(inst) || numOperands(inst) != 1) continue;
            bool matches = false;
            for (unsigned a = 0; a < numArrays; a++) matches |= typeOf(inst) == arrays[a].handleType;
            if (matches && !knownBase(operand(inst, 0), 0) && numLoads < kMaxHandleLoads) loads[numLoads++] = inst;
        }
    }
    unsigned fixed = 0;
    for (unsigned l = 0; l < numLoads; l++) {
        void *load = loads[l], *pointer = operand(load, 0), *handle = typeOf(load);
        void *pointerType = api.pointerTypeGet(handle, 0);
        if (typeOf(pointer) != pointerType) continue;  // only private (address space 0) pointers to the handle
        void *users[kMaxUsers];
        unsigned numUsers = 0;
        bool tooMany = false;
        for (void *use = firstUse(load); use; use = nextUse(use)) {
            if (numUsers == kMaxUsers) { tooMany = true; break; }
            void *user = api.getUser(use);
            bool seen = false;
            for (unsigned u = 0; u < numUsers; u++) seen |= users[u] == user;
            if (!seen) users[numUsers++] = user;
        }
        if (tooMany || !numUsers) continue;
        void *position = load, *value = load, *zero = api.constantIntGet(i64, 0, false);
        for (unsigned a = 0; a < numArrays; a++) {
            if (arrays[a].handleType != handle) continue;
            for (unsigned k = 0; k < arrays[a].length; k++) {
                void *gepOperands[3] = {arrays[a].argument, zero, api.constantIntGet(i64, k, false)};
                char *element = createInstruction(pointerType, kOpcodeGEP, gepOperands, 3, 128);
                *(void **)(element + 0x38) = arrays[a].arrayType;  // SourceElementType
                *(void **)(element + 0x40) = handle;               // ResultElementType
                api.insertAfter(element, position);
                void *same = api.cmpCreate(kOpcodeICmp, kPredicateEQ, pointer, element, &kNoName, NULL);
                api.insertAfter(same, element);
                void *direct = api.userNew(96, 1);
                api.loadInst(direct, handle, element, &kNoName, false, NULL);
                api.insertAfter(direct, same);
                void *selectOperands[3] = {same, direct, value};
                value = createInstruction(handle, kOpcodeSelect, selectOperands, 3, 96);
                api.insertAfter(value, direct);
                position = value;
            }
        }
        for (unsigned u = 0; u < numUsers; u++) api.replaceUsesOfWith(users[u], load, value);
        fixed++;
    }
    return fixed;
}

static unsigned fixEscapedHandleLoads(void *module) {
    const char *setting = getenv("AMD_HANDLE_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.hasByValAttr || !api.structName || !api.buildLazyArguments) return 0;
    char *functions = (char *)module + kModuleFunctions;
    void *i64 = NULL;
    unsigned fixed = 0;
    for (char *fn = nextNode(functions); fn != functions; fn = nextNode(fn)) {
        char *function = fn - kFunctionNode;
        if (*(void **)(function + kFunctionParent) != module) return fixed;  // layout mismatch
        char *blocks = function + kFunctionBlocks;
        if (nextNode(blocks) == blocks) continue;  // a declaration
        if (!i64) i64 = api.getInt64Ty(api.getContext(function));
        unsigned n = fixFunctionHandleLoads(function, i64);
        if (n && logging()) fprintf(stderr, "[texatomic] %u texture/sampler load(s) through escaped pointers routed to the argument table\n", n);
        fixed += n;
    }
    return fixed;
}

static bool hookedCompileShader(void *module, void *il, void *a, void *b, void *c, void *d, void *e) {
    if (module && resolveAPI()) {
        static bool optionsParsed;  // TEXATOMIC_LLVM_ARGS="-print-after-all ...": libAMDIL902's LLVM options (diagnostics)
        const char *llvmArgs = getenv("TEXATOMIC_LLVM_ARGS");
        if (llvmArgs && api.parseOptions && !optionsParsed) {
            optionsParsed = true;
            const char *argv[16] = {"libAMDIL902"};
            int argc = 1;
            char *copy = strdup(llvmArgs);
            for (char *save, *t = strtok_r(copy, " ", &save); t && argc < 16; t = strtok_r(NULL, " ", &save)) argv[argc++] = t;
            api.parseOptions(argc, argv, "");
        }
        if (getenv("TEXATOMIC_DUMP_MODULE") && api.moduleDump) api.moduleDump(module);  // the AIR libAMDIL902 receives
        fixEscapedHandleLoads(module);
        unsigned n = lowerTextureAtomics(module);
        if (logging()) fprintf(stderr, "[texatomic] compileShader: %u texture atomic call(s) lowered\n", n);
    } else if (logging()) {
        fprintf(stderr, "[texatomic] compileShader: LLVM API unavailable\n");
    }
    return compileShader(module, il, a, b, c, d, e);
}

// ---- step 2: IL --------------------------------------------------------------------------------------------------
enum { kSrcTokens = 0x108, kSrcSize = 0x110 };  // _SC_SRCSHADER fields (AMDShared dumpILWithData)

typedef struct { char *buf; size_t len, cap; } Text;

static void append(Text *t, const char *s, size_t n) {
    if (t->len + n + 1 > t->cap) {
        t->cap = (t->len + n + 1) * 2;
        t->buf = realloc(t->buf, t->cap);
    }
    memcpy(t->buf + t->len, s, n);
    t->len += n;
    t->buf[t->len] = 0;
}

static void appendFormatted(void *userData, char *unused, char *format, va_list args) {
    char small[512];
    va_list copy;
    va_copy(copy, args);
    int n = vsnprintf(small, sizeof small, format, copy);
    va_end(copy);
    if (n < 0) return;
    if ((size_t)n < sizeof small) { append(userData, small, n); return; }
    char *big = malloc(n + 1);
    vsnprintf(big, n + 1, format, args);
    append(userData, big, n);
    free(big);
}

// IL opcode stem for a tag's operation; exchange exists only in the returning (uav_read_) form.
static const char *ilOpName(unsigned tag) {
    bool isSigned = tag & kTagSigned;
    switch (tag & 0x7F) {
        case 1: return "add";
        case 2: return "sub";
        case 3: return isSigned ? "min" : "umin";
        case 4: return isSigned ? "max" : "umax";
        case 5: return "and";
        case 6: return "or";
        case 7: return "xor";
        case 8: return "xchg";
        case 9: return "cmp_xchg";
    }
    return NULL;
}

enum { kResultRegister = 7900 };  // r7900 + id holds the old value of returning atomic <id>; r7900 is a scratch dst

// The constant last written to component `comp` of register `reg` before line `before`: a mov_lit, possibly reached
// through plain register copies (mov rD.mask, rS.swizzle).
static bool findLiteral(char **lines, int before, const char *reg, char comp, uint32_t *value) {
    for (int depth = 0; depth < 8; depth++) {
        size_t regLen = strlen(reg);
        int index = comp == 'x' ? 0 : comp == 'y' ? 1 : comp == 'z' ? 2 : 3, i;
        const char *l = NULL, *dst = NULL;
        for (i = before - 1; i >= 0; i--) {
            l = lines[i];
            while (*l == ' ') l++;
            const char *space = strchr(l, ' ');
            if (!space) continue;
            dst = space + 1;
            if (strncmp(dst, reg, regLen) || (dst[regLen] != '.' && dst[regLen] != ',' && dst[regLen] != ' ')) continue;
            if (dst[regLen] == '.' && dst[regLen + 1 + index] != comp) continue;  // writes other components only
            break;
        }
        if (i < 0) return false;
        const char *src = strchr(dst, ',');
        if (!src) return false;
        if (!strncmp(l, "mov_lit ", 8)) {
            for (int k = 0; src && k < index; k++) src = strchr(src + 1, ',');
            if (!src) return false;
            *value = (uint32_t)strtoul(src + 1, NULL, 0);
            return true;
        }
        if (strncmp(l, "mov ", 4)) return false;  // computed, not a constant
        // mov rD.mask, rS[.swizzle]: follow component `comp` to its source component.
        char source[32], swizzle[8] = "xyzw";
        if (sscanf(src + 1, " %31[^.\n ].%4s", source, swizzle) < 1) return false;
        size_t sl = strlen(swizzle);
        comp = swizzle[index < (int)sl ? index : (int)sl - 1];
        static char follow[32];
        snprintf(follow, sizeof follow, "%s", source);
        reg = follow;
        before = i;
    }
    return false;
}

// Rewrites tagged stores into atomics and result placeholder loads into copies of the atomic's return register.
// Returns the number of atomics rewritten, or -1 if any tag or placeholder was left (the shader must then not run:
// a leftover placeholder loads from a bogus address).
static int rewriteIL(const char *in, Text *out) {
    char *copy = strdup(in);
    int lineCount = 0, cap = 1024, rewritten = 0, failed = 0;
    unsigned pendingLoad = 0;  // id whose placeholder address was just loaded, waiting for its raw load
    int pendingSince = 0;
    char **lines = malloc(cap * sizeof *lines);
    for (char *save, *l = strtok_r(copy, "\n", &save); l; l = strtok_r(NULL, "\n", &save)) {
        if (lineCount == cap) lines = realloc(lines, (cap *= 2) * sizeof *lines);
        lines[lineCount++] = l;
    }
    for (int i = 0; i < lineCount; i++) {
        const char *l = lines[i];
        char dim[32], fmt[32], coords[64], value[64], reg[32], desc[64], line[320];
        char comp;
        uint32_t lo, hi;
        if (sscanf(l, " uav_store_mip_ext_direct_type(%31[^)])_fmt(%31[^)]) mem0, %63[^,], %63[^,], %31[^.].%c, %63s",
                   dim, fmt, coords, value, reg, &comp, desc) == 7) {
            uint32_t tag;
            if (findLiteral(lines, i, reg, comp, &tag) && (tag & 0xFFFF0000) == kTagBase) {
                const char *op = ilOpName(tag & 0xFF);
                unsigned id = (tag >> 8) & 0xFF;
                if (!op) { failed++; continue; }
                int n;
                if (!strcmp(op, "cmp_xchg")) {  // value.x = new value, value.y = compare value
                    char base[64];
                    snprintf(base, sizeof base, "%.*s", (int)strcspn(value, "."), value);
                    n = snprintf(line, sizeof line, "uav_read_cmp_xchg_ext_direct_view(typed)_type(%s)_fmt(%s) r%u, %s, %s.x, %s.y, %s\n",
                                 dim, fmt, kResultRegister + id, coords, base, base, desc);
                } else if (id || !strcmp(op, "xchg"))  // returning form; an unused exchange result goes to the scratch dst
                    n = snprintf(line, sizeof line, "uav_read_%s_ext_direct_view(typed)_type(%s)_fmt(%s) r%u, %s, %s, %s\n",
                                 op, dim, fmt, kResultRegister + id, coords, value, desc);
                else
                    n = snprintf(line, sizeof line, "uav_%s_ext_direct_view(typed)_type(%s)_fmt(%s) %s, %s, %s\n",
                                 op, dim, fmt, coords, value, desc);
                append(out, line, n);
                rewritten++;
                continue;
            }
        }
        if (sscanf(l, " uav_store_mask_ext_direct_type(%31[^)])_fmt(%31[^)]) mem0, %63[^,], %63[^,], %63s",
                   dim, fmt, coords, value, desc) == 5 && !strcmp(dim, "buffer")) {
            uint32_t tag;
            char base[64];
            snprintf(base, sizeof base, "%.*s", (int)strcspn(value, "."), value);
            if (findLiteral(lines, i, base, 'w', &tag) && (tag & 0xFFFF0000) == kTagBase) {
                const char *op = ilOpName(tag & 0xFF);
                unsigned id = (tag >> 8) & 0xFF;
                if (!op) { failed++; continue; }
                int n;
                if (!strcmp(op, "cmp_xchg"))
                    n = snprintf(line, sizeof line, "uav_read_cmp_xchg_ext_direct_view(typed)_type(%s)_fmt(%s) r%u, %s, %s.x, %s.y, %s\n",
                                 dim, fmt, kResultRegister + id, coords, base, base, desc);
                else if (id || !strcmp(op, "xchg"))
                    n = snprintf(line, sizeof line, "uav_read_%s_ext_direct_view(typed)_type(%s)_fmt(%s) r%u, %s, %s, %s\n",
                                 op, dim, fmt, kResultRegister + id, coords, value, desc);
                else
                    n = snprintf(line, sizeof line, "uav_%s_ext_direct_view(typed)_type(%s)_fmt(%s) %s, %s, %s\n",
                                 op, dim, fmt, coords, value, desc);
                append(out, line, n);
                rewritten++;
                continue;
            }
        }
        // Placeholder address: mov_lit rN.xy__, <id>, 0x7A710000, ...
        if (sscanf(l, " mov_lit %31[^,], %x, %x", reg, &lo, &hi) == 3 && hi == (uint32_t)(kResultAddressBase >> 32) && lo &&
            lo <= kMaxResults) {
            if (pendingLoad) failed++;
            pendingLoad = lo;
            pendingSince = i;
        }
        // ...followed by the raw load whose destination is the atomic's result.
        if (pendingLoad && sscanf(l, " uav_raw_load_ext_direct_access(%*[^)]) %31[^,],", reg) == 1) {
            int n = snprintf(line, sizeof line, "mov %s, r%u.xxxx\n", reg, kResultRegister + pendingLoad);
            append(out, line, n);
            pendingLoad = 0;
            continue;
        }
        if (pendingLoad && i - pendingSince > 64) { failed++; pendingLoad = 0; }
        append(out, l, strlen(l));
        append(out, "\n", 1);
    }
    if (pendingLoad) failed++;
    free(lines);
    free(copy);
    return failed ? -1 : rewritten;
}

// ---- Southern Islands wait states ----------------------------------------------------------------------------------
// The GPU family AMDShared creates its SC instance for (AMDMTLCompilerPluginSCBase constructor).
static int scFamily;

static int hookedSCGetInstructionSet(int family, int revision, int deviceID) {
    scFamily = family;
    return SCGetInstructionSet(family, revision, deviceID);
}

// _SC_SI_HWSHADER_COMMON (AMDBronzeMTLCompilerPluginSC::compile*Shader, setupRelocationInfo): the caller's {code, size}
// pair that SC fills (the field then holds the code pointer), and the relocation count. Relocations point into the
// code; shaders that have any (none of the tested ones do) are left alone rather than guessing their offset units.
enum { kHwIsa = 0x1710, kHwIsaSize = 0x171c, kHwRelocCount = 0x1854, kFamilySI = 110 };

static void fixSIHazards(void *out, void **pair) {
    if (scFamily != kFamilySI || !pair || !pair[0] || pair[0] != *(void **)((char *)out + kHwIsa)) return;
    const char *setting = getenv("AMD_SI_HAZARD_FIX");
    if (setting && !strcmp(setting, "0")) return;
    uint32_t bytes = *(uint32_t *)&pair[1], newBytes = 0, relocCount = *(uint32_t *)((char *)out + kHwRelocCount);
    unsigned inserted = 0;
    const char *unsupported = relocCount ? "relocations" : NULL, *l1Unsupported = NULL;
    // In place (no size change): loads from memory this shader also writes bypass the vector L1 (stale reads).
    const char *l1Setting = getenv("AMD_SI_L1_FIX");
    unsigned glc = relocCount || (l1Setting && !strcmp(l1Setting, "0")) ? 0 : siBypassL1ForWrittenResources(pair[0], bytes, &l1Unsupported);
    if (logging() && (glc || l1Unsupported)) fprintf(stderr, "[texatomic] SI: %u load(s) bypass L1%s%s\n", glc,
                                                     l1Unsupported ? ", L1 pass skipped: " : "", l1Unsupported ? l1Unsupported : "");
    uint32_t *fixed = relocCount ? NULL : siFixBufferLoadHazards(pair[0], bytes, &newBytes, &inserted, &unsupported);
    if (unsupported && logging()) fprintf(stderr, "[texatomic] SI: left unchanged (%s)\n", unsupported);
    if (!fixed) return;
    void *code = operatorNewArray(newBytes);
    memcpy(code, fixed, newBytes);
    free(fixed);
    operatorDeleteArray(pair[0]);
    pair[0] = code;
    *(uint32_t *)&pair[1] = newBytes;
    *(void **)((char *)out + kHwIsa) = code;
    *(uint32_t *)((char *)out + kHwIsaSize) = newBytes;
    if (logging()) fprintf(stderr, "[texatomic] SI: %u s_nop inserted (%u -> %u bytes)\n", inserted, bytes, newBytes);
}

// User data API slot 8 is the shader's constant data segment (program-scope `constant` variables: Tint/Dawn's
// `volatile constexpr constant uint tint_volatile_zero`, read by Chrome's Skia Graphite shaders). libAMDIL902 also
// adds it, wrongly, when it materializes the address of a threadgroup variable as a value (e.g. stored in thread
// memory: Blender's `threadgroup float (&array)[N]` class members): `i64add rX, <slot 8>, <LDS offset>`, while direct
// accesses use the bare offset. Loads through such a pointer miss the variable (out-of-range LDS reads return 0;
// Blender EEVEE's depth of field lost its slight-focus layer). Fix: in compute shaders that declare LDS, drop the base
// from exactly those adds (`mov rX, <LDS offset>`). The read itself and its other uses stay: constant-data loads build
// their buffer descriptor from the unchanged base and add their offset to the load address.
// (Earlier versions zeroed the slot-8 read itself: everywhere, which broke Chrome's text, tabs and icons, and then in
// LDS compute shaders, which still broke the constant reads of such shaders.) Not handled: a pointer to a
// program-scope constant formed in an LDS compute shader (its base + offset add looks the same). Returns the count.
static const char kThreadgroupBaseSlot[] = "dcl_user_data_api_slot(8) r8197.xy__\n";

// The register an IL line writes, if it writes one ("mov r12.xy__, ..." -> 12); -1 for lines without a destination
// (control flow, stores, descriptor setup).
static int writtenRegister(const char *line) {
    static const char *const kNoDest[] = {"if_", "else", "endif", "whileloop", "endloop", "break", "continue", "ret",
                                          "set_descriptor", "uav_raw_store", "uav_store", "uav_byte_store", "uav_short_store",
                                          "lds_store", "dcl_", "fence", "switch", "case", "default", "endswitch", "discard"};
    while (*line == ' ' || *line == '\t') line++;
    for (size_t i = 0; i < sizeof kNoDest / sizeof *kNoDest; i++) if (!strncmp(line, kNoDest[i], strlen(kNoDest[i]))) return -1;
    const char *space = strchr(line, ' ');
    unsigned reg;
    return space && sscanf(space + 1, "r%u", &reg) == 1 ? (int)reg : -1;
}

static int dropThreadgroupBase(const char *in, Text *out) {
    int n = 0, base = -1;  // base: the register holding the slot-8 value, while it holds it
    bool afterSlot8 = false;
    char *copy = strdup(in);
    for (char *save, *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        unsigned reg, x, a, b;
        char rewritten[96];
        const char *emit = line;
        const char *text = line + strspn(line, " \t");
        if (!strcmp(text, "dcl_user_data_api_slot(8) r8197.xy__")) {
            afterSlot8 = true;
        } else if (afterSlot8 && sscanf(text, "mov r%u.xy__, r8197.xyyy", &reg) == 1) {
            base = (int)reg;
            afterSlot8 = false;
        } else {
            afterSlot8 = false;
            if (base >= 0 && sscanf(text, "i64add r%u.xy__, r%u.xyyy, r%u.xyyy", &x, &a, &b) == 3 && ((int)a == base) != ((int)b == base)) {
                snprintf(rewritten, sizeof rewritten, "%.*smov r%u.xy__, r%u.xyyy", (int)(text - line), line, x, (int)a == base ? b : a);
                emit = rewritten;
                n++;
                if ((int)x == base) base = -1;
            } else if (base >= 0 && writtenRegister(text) == base) {
                base = -1;  // overwritten: no longer the slot-8 value
            }
        }
        append(out, emit, strlen(emit));
        append(out, "\n", 1);
    }
    free(copy);
    return n;
}

static int hookedSCCompileShader(void *sc, void *src, void *out) {
    void **tokens = (void **)((char *)src + kSrcTokens);
    uint32_t *size = (uint32_t *)((char *)src + kSrcSize);
    Text il = {0};
    SCDumpILShader(&il, *tokens, *size, appendFormatted);
    const char *ldsSetting = getenv("AMD_LDS_BASE_FIX");
    bool atomics = il.buf && (strstr(il.buf, "0x7A70") || strstr(il.buf, "0x7A71"));
    bool ldsBase = scFamily == kFamilySI && il.buf && !strncmp(il.buf, "il_cs", 5) && strstr(il.buf, "dcl_lds_id(") &&
                   strstr(il.buf, kThreadgroupBaseSlot) && !(ldsSetting && !strcmp(ldsSetting, "0"));
    if (atomics || ldsBase) {
        Text edited = {0}, based = {0};
        int n = atomics ? rewriteIL(il.buf, &edited) : 0;
        int k = ldsBase && (!atomics || n > 0) ? dropThreadgroupBase(atomics ? edited.buf : il.buf, &based) : 0;
        const char *text = k > 0 ? based.buf : atomics && n > 0 ? edited.buf : NULL;
        void *binary = NULL;
        unsigned dwords = 0;
        int ok = text ? ilXltTextToBinary(text, &binary, &dwords) : 0;
        if (logging()) {
            if (atomics) fprintf(stderr, "[texatomic] IL: %d texture atomic(s) rewritten\n", n);
            if (k) fprintf(stderr, "[texatomic] IL: %d threadgroup address(es): data-segment base (API slot 8) dropped\n", k);
            if (text) fprintf(stderr, "[texatomic] IL: assembled %s\n", ok == 1 ? "ok" : "FAILED");
            if (getenv("TEXATOMIC_DUMP")) fprintf(stderr, "%s\n", text ? text : "");
        }
        free(edited.buf);
        free(based.buf);
        free(il.buf);
        if (atomics && ok != 1) return 1;  // fail the pipeline rather than run tagged placeholders
        if (ok == 1) {
            *tokens = binary;
            *size = dwords * 4;
        }
    } else {
        free(il.buf);
    }
    void **pair = *(void ***)((char *)out + kHwIsa);
    int r = SCCompileShader(sc, src, out);
    if (r == 0) fixSIHazards(out, pair);
    return r;
}

// ---- installation ---------------------------------------------------------------------------------------------------
// System-wide, this library is a weak dependency of AMDShared (the compiler plugin MTLCompilerService dlopens). dyld has
// bound AMDShared's imports before our initializer runs, so redirect the imported pointers there (found by value in
// AMDShared's data segments). In a test process, DYLD_INSERT_LIBRARIES + the __interpose table below do the same.
#include <mach-o/dyld.h>
#include <mach/mach.h>

static unsigned redirectImports(const struct mach_header_64 *header, intptr_t slide) {
    struct { void *original, *replacement; } targets[] = {
        {(void *)compileShader, (void *)hookedCompileShader},
        {(void *)SCCompileShader, (void *)hookedSCCompileShader},
        {(void *)SCGetInstructionSet, (void *)hookedSCGetInstructionSet},
    };
    unsigned patched = 0;
    const char *p = (const char *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, p += ((const struct load_command *)p)->cmdsize) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)p;
        if (seg->cmd != LC_SEGMENT_64 || strncmp(seg->segname, "__DATA", 6)) continue;
        void **start = (void **)(seg->vmaddr + slide), **end = (void **)(seg->vmaddr + slide + seg->vmsize);
        for (void **slot = start; slot < end; slot++)
            for (size_t t = 0; t < sizeof targets / sizeof targets[0]; t++) {
                if (*slot != targets[t].original) continue;
                vm_protect(mach_task_self(), (vm_address_t)slot & ~(vm_address_t)(vm_page_size - 1), vm_page_size, false,
                           VM_PROT_READ | VM_PROT_WRITE);
                *slot = targets[t].replacement;
                patched++;
            }
    }
    return patched;
}

__attribute__((constructor)) static void installIntoAMDShared(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0;
        if (len < 9 || strcmp(name + len - 9, "AMDShared")) continue;
        unsigned n = redirectImports((const struct mach_header_64 *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
        if (logging()) fprintf(stderr, "[texatomic] %s: %u import(s) redirected\n", name, n);
    }
}

#ifdef TEXATOMIC_INTERPOSE  // test build for DYLD_INSERT_LIBRARIES (see build.sh)
__attribute__((used, section("__DATA,__interpose"))) static struct { void *replacement, *original; } interposers[] = {
    {(void *)hookedCompileShader, (void *)compileShader},
    {(void *)hookedSCCompileShader, (void *)SCCompileShader},
    {(void *)hookedSCGetInstructionSet, (void *)SCGetInstructionSet},
};
#endif
