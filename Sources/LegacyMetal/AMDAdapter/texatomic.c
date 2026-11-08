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
// Third job: keep compares false for NaN under fast math, as Apple's current compilers do (keepCompareNaNs; Blender
// EEVEE's volume lighting depends on it). AMD_NAN_FIX=0 turns it off.
//
// Fourth job: compute ldexp on half as float (ldexpHalfAsFloat): libAMDIL902 crashes on half3 and returns wrong values
// for the other widths. AMD_LDEXP_FIX=0 turns it off.
//
// Fifth job: make gather on integer textures read the right texels (shiftIntegerGatherCoords, normalizeFetch4).
// AMD_GATHER_FIX=0 turns it off.
//
// Sixth job: clamp cube array indices (clampCubeArrayIndices): GCN reads the wrong face for one below 0.
// AMD_CUBE_ARRAY_FIX=0 turns it off.
//
// Seventh job: load threadgroup bools as bytes (loadThreadgroupBoolsAsBytes): libAMDIL902 reads them as false.
// AMD_LDS_BOOL_FIX=0 turns it off.
//
// Eighth job, with the 12.5-24 Bronze driver only (Sequoia without MetalOld): read multisample textures without their
// FMASK (identityFmaskLookups). There the driver leaves the FMASK descriptor table (API slot 13) unset for render
// stages, so a fragment shader's texture2d_ms read loads its FMASK descriptor from GPU address 0 and the GPU resets;
// compute reads get a stale table and wrong samples. Both encoders expand compressed MSAA textures when they're bound
// (BronzeCompressionMgr_SubmitCondExpand), so the identity sample map is right. AMD_FMASK_FIX=0 turns it off,
// AMD_FMASK_FIX=1 turns it on with any driver.
//
// Ninth job: constexpr samplers from newer front ends (twoWordSamplerStates): libraries built for macOS 15 or later (AIR 2.7)
// store each one as a [2 x i64] constant, which libAMDIL902 can't read, so the sampler comes out as 0.
// AMD_SAMPLER_STATE_FIX=0 turns it off.
//
// Tenth job: unpack normalized integers exactly (exactUnpackNorm): libAMDIL902's unpack_snorm2x16_to_float is up to
// 6 ulp off, unpack_unorm2x16_to_float 2. AMD_UNPACK_FIX=0 turns it off.
//
// Eleventh job: private arrays written at variable indexes (privateArrayIndexedStores): SC's M0-relative register
// writes lose updates across branches and loop iterations; such arrays are accessed at constant indexes only.
// AMD_PRIVATE_STORE_FIX=0 turns it off.
//
// Twelfth job: unsigned saturating adds and subtracts as plain arithmetic (plainSaturatingAddSub): SC turns
// `usub_sat x, 0` into a float clamp. AMD_SATURATE_FIX=0 turns it off.
//
// Thirteenth job: rotates as shifts (rotatesAsShifts): SC folds a constant rotate by a multiple of 8 the wrong way.
// AMD_ROTATE_FIX=0 turns it off.
//
// Sixteenth job: 8- and 16-bit divisions, remainders, right shifts and comparisons done in 32 bits
// (narrowUnsignedConstants): libAMDIL902 neither clears nor extends the upper bits of narrow values. AMD_NARROW_CONSTANT_FIX=0
// turns it off.
//
// Fifteenth job: single-bit tests as bit-field extracts (singleBitTests): libAMDIL902 drops the `& 1` of `(x & 1) != 0`
// once the comparison is or'ed with another one. AMD_BIT_TEST_FIX=0 turns it off.
//
// Fourteenth job (AMD IL, before SC): loops whose last if/else ends both branches with break + continue get a single
// exit (singleLoopExits): SC loses track of which threads take the else branch. AMD_LOOP_EXIT_FIX=0 turns it off.
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
#include <unistd.h>

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
// also the GEP Select insertion-point fix 4), which leave symbols and data layouts unchanged. Tahoe's 12.5-GCN-25 copy
// is the stock file with OCLP's stub in initializeIABArgTypeSet; its patched builds keep the stub instead of fix 1.
// Identified independently of the code signature (Dortania's release signing, PatcherSupportPkg's ad-hoc copies and
// local re-signing all differ): the LC_UUID plus the SHA-256 of the __TEXT segment's file bytes after the load
// commands, which covers the code, the constants and the header padding the patches use (tools/textpin.py computes
// the same values).
static const unsigned char kProviderUUID[16] = {
    0xd5, 0xcf, 0x00, 0x07, 0x89, 0x35, 0x31, 0x93, 0xb3, 0xf1, 0xd0, 0xb3, 0xdd, 0x0d, 0xcc, 0x91};
static const unsigned char kProviderTextHashes[8][32] = {{
    0xe4, 0x38, 0x93, 0xcb, 0x0b, 0x79, 0xed, 0x81, 0x99, 0xad, 0x29, 0x80, 0x13, 0xb2, 0xe1, 0xcc,
    0xc3, 0x7c, 0xa5, 0x51, 0x03, 0x46, 0x90, 0x06, 0x40, 0x6c, 0xbb, 0xb1, 0xa2, 0x76, 0x9c, 0x49}, {
    0x2c, 0xd2, 0xc2, 0x33, 0x1e, 0x2a, 0x48, 0x2f, 0x7b, 0xb4, 0x37, 0x79, 0xe7, 0xd1, 0x27, 0x32,
    0xf4, 0xd9, 0x4e, 0xc7, 0x88, 0x3d, 0xf4, 0xf5, 0xf0, 0x03, 0x7f, 0x7a, 0xa7, 0xab, 0x74, 0x29}, {
    0x7b, 0x1b, 0x92, 0xe8, 0x36, 0xfe, 0x7d, 0x30, 0x5b, 0x30, 0x55, 0x0d, 0x17, 0x9f, 0x01, 0x62,
    0xdc, 0x60, 0x45, 0x93, 0x5f, 0x0d, 0x68, 0xd4, 0x1b, 0x58, 0xeb, 0x53, 0xfc, 0x2d, 0xb7, 0x81}, {
    0xf4, 0x7a, 0x81, 0x95, 0x13, 0x33, 0xee, 0x23, 0x7b, 0x4f, 0x17, 0x32, 0xb2, 0x5c, 0xd5, 0x77,
    0x99, 0x07, 0xfa, 0x14, 0xda, 0x8e, 0x5f, 0x37, 0xb4, 0x5b, 0x7a, 0x5f, 0x02, 0xf4, 0xb7, 0xc6}, {
    0x56, 0xdf, 0x17, 0x9a, 0x64, 0x0a, 0x63, 0x55, 0xd7, 0x6f, 0xd8, 0x90, 0x65, 0xb5, 0x7e, 0x5e,
    0x35, 0x19, 0xa7, 0x1e, 0x11, 0xd3, 0x46, 0x93, 0xf5, 0xdb, 0x32, 0x73, 0x5f, 0xfc, 0x36, 0x2a}, {
    0x6e, 0x3a, 0xb3, 0x42, 0x70, 0x61, 0x95, 0x3a, 0x2b, 0xd6, 0x8e, 0xa1, 0x4d, 0x80, 0x95, 0x35,
    0x02, 0x07, 0x52, 0xf4, 0x93, 0xa2, 0xdf, 0x70, 0xd1, 0xa8, 0x5c, 0x10, 0x5b, 0x71, 0x0e, 0x1f}, {
    0xef, 0xa0, 0x90, 0xd4, 0x88, 0x13, 0x8a, 0x7b, 0xb5, 0x96, 0xfd, 0xb0, 0xb6, 0xc2, 0xf2, 0x48,
    0xf3, 0x49, 0xd0, 0x88, 0x5d, 0x5f, 0x25, 0xfb, 0xca, 0xe1, 0x63, 0x25, 0xea, 0x37, 0x90, 0xd4}, {
    0xec, 0x14, 0x21, 0x45, 0xe0, 0xff, 0x7a, 0x63, 0x77, 0x8d, 0x13, 0x8a, 0x51, 0xcd, 0xe3, 0x2a,
    0x6a, 0x89, 0x03, 0x65, 0xb5, 0xd4, 0x9a, 0x5e, 0x54, 0x65, 0x69, 0xa7, 0xf3, 0x76, 0xec, 0x93}};
// 12.5: stock, patches 1-3 and 5, patches 1-4, patches 1-5. 12.5-GCN-25: stock, patches 2-3 and 5, patches 2-4, patches 2-5.

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
    for (size_t k = 0; k < sizeof kProviderTextHashes / sizeof kProviderTextHashes[0]; k++)
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
    void (*addFnAttr)(void *function, const char *kind, size_t kindSize, const char *value, size_t valueSize);
    void (*eraseFunction)(void *function);  // optional, ldexpHalfAsFloat only
    void *(*getFloatTy)(void *context);     // ldexpHalfAsFloat and shiftIntegerGatherCoords
    void *(*binaryCreate)(unsigned opcode, void *lhs, void *rhs, const void *name, void *insertBefore);  // shiftIntegerGatherCoords
    void *(*constantFP)(void *type, double value);  // same
    void *(*getInt1Ty)(void *context);  // loadThreadgroupBoolsAsBytes
    void *(*getInt8Ty)(void *context);  // same
    // twoWordSamplerStates
    void *(*getNamedMetadata)(void *module, const Twine *name);
    unsigned (*namedMDNumOperands)(void *namedMD);
    void *(*namedMDGetOperand)(void *namedMD, unsigned i);
    void (*setInitializer)(void *global, void *constant);
    // privateArrayIndexedStores
    void *(*gepCreate)(void *sourceType, void *pointer, ArrayRef indices, const Twine *name, void *insertBefore);
    void (*selectInit)(void *self, void *condition, void *ifTrue, void *ifFalse, const Twine *name, void *insertBefore);
    // cubeIntegerGathers
    void *(*extractValueCreate)(void *aggregate, ArrayRef indices, const Twine *name, void *insertBefore);
    void *(*undefGet)(void *type);  // bitcastLaneExtracts
    // floatAtomicsAsInteger
    void *(*splitBasicBlock)(void *block, void *instructionNode, const Twine *name);
    void (*branchInit)(void *self, void *destination, void *insertBefore);
    void (*condBranchInit)(void *self, void *ifTrue, void *ifFalse, void *condition, void *insertBefore);
    void (*allocaInit)(void *self, void *type, unsigned addressSpace, const Twine *name, void *insertBefore);
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
        RESOLVE(addFnAttr, "__ZN4llvm8Function9addFnAttrENS_9StringRefES1_");
        RESOLVE(eraseFunction, "__ZN4llvm8Function15eraseFromParentEv");
        RESOLVE(getFloatTy, "__ZN4llvm4Type10getFloatTyERNS_11LLVMContextE");
        RESOLVE(getInt1Ty, "__ZN4llvm4Type9getInt1TyERNS_11LLVMContextE");
        RESOLVE(getInt8Ty, "__ZN4llvm4Type9getInt8TyERNS_11LLVMContextE");
        RESOLVE(binaryCreate, "__ZN4llvm14BinaryOperator6CreateENS_11Instruction9BinaryOpsEPNS_5ValueES4_RKNS_5TwineEPS1_");
        RESOLVE(constantFP, "__ZN4llvm10ConstantFP3getEPNS_4TypeEd");
        RESOLVE(getNamedMetadata, "__ZNK4llvm6Module16getNamedMetadataERKNS_5TwineE");
        RESOLVE(namedMDNumOperands, "__ZNK4llvm11NamedMDNode14getNumOperandsEv");
        RESOLVE(namedMDGetOperand, "__ZNK4llvm11NamedMDNode10getOperandEj");
        RESOLVE(setInitializer, "__ZN4llvm14GlobalVariable14setInitializerEPNS_8ConstantE");
        RESOLVE(gepCreate, "__ZN4llvm17GetElementPtrInst6CreateEPNS_4TypeEPNS_5ValueENS_8ArrayRefIS4_EERKNS_5TwineEPNS_11InstructionE");
        RESOLVE(selectInit, "__ZN4llvm10SelectInstC2EPNS_5ValueES2_S2_RKNS_5TwineEPNS_11InstructionE");
        RESOLVE(undefGet, "__ZN4llvm10UndefValue3getEPNS_4TypeE");
        RESOLVE(splitBasicBlock, "__ZN4llvm10BasicBlock15splitBasicBlockENS_14ilist_iteratorINS_12ilist_detail12node_optionsINS_11InstructionELb0ELb0EvEELb0ELb0EEERKNS_5TwineE");
        RESOLVE(branchInit, "__ZN4llvm10BranchInstC2EPNS_10BasicBlockEPNS_11InstructionE");
        RESOLVE(condBranchInit, "__ZN4llvm10BranchInstC2EPNS_10BasicBlockES2_PNS_5ValueEPNS_11InstructionE");
        RESOLVE(allocaInit, "__ZN4llvm10AllocaInstC2EPNS_4TypeEjRKNS_5TwineEPNS_11InstructionE");
        RESOLVE(extractValueCreate, "__ZN4llvm16ExtractValueInst6CreateEPNS_5ValueENS_8ArrayRefIjEERKNS_5TwineEPNS_11InstructionE");
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
enum { kUseSize = 24, kOpcodeFSub = 14, kOpcodeFDiv = 19, kOpcodeZExt = 37, kOpcodeUIToFP = 41, kOpcodeFPTrunc = 43, kOpcodeFPExt = 44, kOpcodeCall = 54, kOpcodeICmp = 51, kPredicateEQ = 32, kPredicateNE = 33 };
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
enum { kModuleFunctions = 0x18, kFunctionValueType = 0x18, kFunctionParent = 0x28, kFunctionNode = 0x38, kFunctionBlocks = 0x48,
       kFunctionArgs = 0x58, kFunctionNumArgs = 0x60, kArgumentSize = 40, kBlockNode = 0x18, kBlockInstructions = 0x28,
       kBlockParent = 0x38, kInstructionNode = 0x18, kInstructionParent = 0x28 };
enum { kTypeStruct = 13, kTypeArray = 14, kTypePointer = 15 };  // Type::TypeID @8
enum { kValueArgument = 0, kValueFunction = 5, kValueGlobalVariable = 8, kValueInstruction = 24 };  // SubclassID; an instruction's is kValueInstruction + opcode
enum { kOpcodeAlloca = 29, kOpcodeLoad = 30, kOpcodeGEP = 32, kOpcodeBitCast = 47, kOpcodeSelect = 55 };
enum { kMaxHandleArrays = 8, kMaxHandleElements = 32, kMaxHandleLoads = 256, kMaxUsers = 64 };

static void *nextNode(void *node) { return *(void **)((char *)node + 8); }
static void *prevNode(void *node) { return *(void **)node; }  // ilist_node_base: Prev @0, Next @8
static unsigned typeID(void *type) { return *(unsigned char *)((char *)type + 8); }
static void *elementType(void *type) { return (*(void ***)((char *)type + 16))[0]; }  // pointee / array element
static uint64_t arrayLength(void *type) { return *(uint64_t *)((char *)type + 32); }
static bool isInstruction(void *value, unsigned opcode) { return subclassID(value) == kValueInstruction + opcode; }
static bool isVolatileLoad(void *load) { return *(uint16_t *)((char *)load + 0x12) & 1; }  // LoadInst: SubclassData bit 0

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

// Metal compiles with fast math by default, which marks every function "no-nans-fp-math"="true". LLVM 5's instruction
// selection takes that as NoNaNsFPMath and treats compares as NaN-free, e.g. it branches on `x <= t` for `if (x > t)`,
// so a NaN takes the other branch. Apple's current compilers keep compares false for NaN, and shaders rely on that:
// Blender EEVEE's safe_normalize() of 0/0 returned NaN instead of its fallback, which made the world sun's direction
// NaN and dropped all volume lighting. Setting the attribute to "false" keeps compares IEEE; the other fast-math
// options stay. AMD_NAN_FIX=0 turns this off.
static unsigned keepCompareNaNs(void *module) {
    const char *setting = getenv("AMD_NAN_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.addFnAttr) return 0;
    static const char kKind[] = "no-nans-fp-math", kValue[] = "false";
    char *functions = (char *)module + kModuleFunctions;
    unsigned changed = 0;
    for (char *fn = nextNode(functions); fn != functions; fn = nextNode(fn)) {
        char *function = fn - kFunctionNode;
        if (*(void **)(function + kFunctionParent) != module) return changed;  // layout mismatch
        char *blocks = function + kFunctionBlocks;
        if (nextNode(blocks) == blocks) continue;  // a declaration
        api.addFnAttr(function, kKind, sizeof kKind - 1, kValue, sizeof kValue - 1);
        changed++;
    }
    return changed;
}

// ldexp on half is broken in libAMDIL902 at every width (WebGPU CTS builtin,ldexp:f16). half, half2 and half4 reach a
// runtime.amdil.builtin routine that returns wrong values (0, inf). half3 crashes MTLCompilerService: PrepareIR renames
// air.ldexp.* to air.fast_ldexp.*, then IntrinsicsActionWidenVec3 looks up the vec4 form by name, and its table has no
// air.fast_ldexp.v4f16, so lookupName returns 0 and getDeclaration reads out of bounds. The float forms work, and every
// half is exact as a float, so compute there. The half declarations have to go too: a vec3 one is widened even with no
// calls left. AMD_LDEXP_FIX=0 turns this off.
static unsigned ldexpHalfAsFloat(void *module) {
    const char *setting = getenv("AMD_LDEXP_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.eraseFunction || !api.getFloatTy) return 0;
    static const struct { const char *half, *wide; unsigned width; } kForms[] = {
        {"air.ldexp.f16", "air.ldexp.f32", 1},
        {"air.ldexp.v2f16", "air.ldexp.v2f32", 2},
        {"air.ldexp.v3f16", "air.ldexp.v3f32", 3},
        {"air.ldexp.v4f16", "air.ldexp.v4f32", 4},
    };
    unsigned changed = 0;
    for (size_t f = 0; f < sizeof kForms / sizeof kForms[0]; f++) {
        void *half = api.getFunction(module, kForms[f].half, strlen(kForms[f].half));
        if (!half) continue;
        void *context = api.getContext(half);
        void *wide = api.getFloatTy(context), *i32 = api.getInt32Ty(context);
        void *exponent = i32;
        if (kForms[f].width > 1) {
            wide = api.vectorTypeGet(wide, kForms[f].width);
            exponent = api.vectorTypeGet(i32, kForms[f].width);
        }
        void *params[2] = {wide, exponent};
        void *type = api.functionTypeGet(wide, params, 2, false);
        void *floatForm = api.getOrInsertFunction(module, kForms[f].wide, strlen(kForms[f].wide), type);
        if (!floatForm || subclassID(floatForm) != subclassID(half)) continue;  // a bitcast: existing declaration of another type
        for (void *use = firstUse(half); use;) {
            void *call = api.getUser(use);
            use = nextUse(use);
            if (!isCall(call, half, 3) || typeOf(operand(call, 1)) != exponent) continue;
            void *args[2] = {api.castCreate(kOpcodeFPExt, operand(call, 0), wide, &kNoName, call), operand(call, 1)};
            void *result = createCall(floatForm, type, args, 2, call);
            api.replaceAllUsesWith(call, api.castCreate(kOpcodeFPTrunc, result, typeOf(call), &kNoName, call));
            api.eraseFromParent(call);
            changed++;
        }
        if (!firstUse(half)) api.eraseFunction(half);
    }
    return changed;
}

static bool gatherFixEnabled(void) {
    const char *setting = getenv("AMD_GATHER_FIX");
    return !(setting && !strcmp(setting, "0"));
}

// Gather on integer textures (WebGPU CTS builtin,textureGather) has two problems. libAMDIL902 asks fetch4 for unnormalized
// coordinates but passes the shader's normalized ones, so every gather returns the texels at the texture's corner;
// normalizeFetch4 turns that back. And GCN hardware forces nearest filtering on integer formats, which leaves gather half
// a texel off (AMD's open-source drivers subtract 0.5 / size for the same reason), so do that here. It takes normalized
// coordinates because unnormalized ones can't wrap. Cube textures aren't covered: their faces need another shift.
static unsigned shiftIntegerGatherCoords(void *module) {
    if (!gatherFixEnabled() || !api.getFloatTy || !api.binaryCreate || !api.constantFP) return 0;
    static const char *const kDimensions[] = {"2d", "2d_array"}, *const kTypes[] = {"s.v4i32", "u.v4i32", "s.v4i16", "u.v4i16"};
    unsigned shifted = 0;
    for (size_t dim = 0; dim < sizeof kDimensions / sizeof kDimensions[0]; dim++)
    for (size_t t = 0; t < sizeof kTypes / sizeof kTypes[0]; t++) {
        char name[64];
        snprintf(name, sizeof name, "air.gather_texture_%s.%s", kDimensions[dim], kTypes[t]);
        void *gather = api.getFunction(module, name, strlen(name));
        if (!gather) continue;
        void *context = api.getContext(gather);
        void *i32 = api.getInt32Ty(context), *f32 = api.getFloatTy(context);
        void *half = api.constantFP(f32, 0.5), *zero = api.constantIntGet(i32, 0, false);
        for (void *use = firstUse(gather); use; use = nextUse(use)) {
            void *call = api.getUser(use);
            if (hungOffUses(call) || numOperands(call) < 3 || operand(call, numOperands(call) - 1) != gather) continue;
            void *texture = operand(call, 0), *coord = operand(call, 2), *result = coord;
            for (unsigned c = 0; c < 2; c++) {
                char sizeName[64];
                snprintf(sizeName, sizeof sizeName, "air.get_%s_texture_%s", c ? "height" : "width", kDimensions[dim]);
                void *params[2] = {typeOf(texture), i32}, *args[2] = {texture, zero};
                void *type = api.functionTypeGet(i32, params, 2, false);
                void *size = api.getOrInsertFunction(module, sizeName, strlen(sizeName), type);
                if (!size || subclassID(size) != subclassID(gather)) return shifted;  // a bitcast: existing declaration of another type
                void *index = api.constantIntGet(i32, c, false);
                void *value = api.userNew(96, 2), *merged = api.userNew(96, 3);
                void *texels = api.castCreate(kOpcodeUIToFP, createCall(size, type, args, 2, call), f32, &kNoName, call);
                void *delta = api.binaryCreate(kOpcodeFDiv, half, texels, &kNoName, call);
                api.extractElement(value, coord, index, &kNoName, call);
                api.insertElement(merged, result, api.binaryCreate(kOpcodeFSub, value, delta, &kNoName, call), index, &kNoName, call);
                result = merged;
            }
            api.replaceUsesOfWith(call, coord, result);
            shifted++;
        }
    }
    return shifted;
}

// Gather on integer cube textures: the forced nearest filtering above hits cube textures too (every point but the texel
// centres reads the footprint one texel over), and no shifted coordinate fixes it, because the footprint of a point near
// a face edge takes texels from the neighbouring face and integer fetch4 doesn't cross edges. So such a gather becomes 4
// nearest samples at level 0, at the centres of the footprint's texels, found in face space with Metal's (Vulkan's)
// face selection: the two coordinates across the face snap to the 2x2 texel centres around the point, and a centre past
// an edge moves onto the neighbouring face (that coordinate clamped to +-1, the major one scaled by 1 - 1 / size: the
// centre of the neighbour's edge row; extending the face plane instead would land near texel boundaries on big faces).
// Corners, where gather is undefined, give one of the three texels. AMD_CUBE_GATHER_FIX=0 turns it off. Test: a17.
enum { kOpcodeFAdd = 12, kCubeFMul = 16, kOpcodeAndBits = 26, kOpcodeOrBits = 27, kOpcodeFCmp = 52, kOpcodeExtractValue = 62,
       kPredicateOGT = 2, kPredicateOGE = 3, kPredicateOLT = 4 };

typedef struct { void *before, *f32, *i32, *i1; } CubeEmit;
static void *cgSelect(CubeEmit *e, void *c, void *a, void *b) {
    char *s = api.userNew(96, 3);
    api.selectInit(s, c, a, b, &kNoName, e->before);
    return s;
}
static void *cgOp(CubeEmit *e, unsigned op, void *a, void *b) { return api.binaryCreate(op, a, b, &kNoName, e->before); }
static void *cgCmp(CubeEmit *e, unsigned p, void *a, void *b) { return api.cmpCreate(kOpcodeFCmp, p, a, b, &kNoName, e->before); }
static void *cgF(CubeEmit *e, double v) { return api.constantFP(e->f32, v); }
static void *cgCall(CubeEmit *e, void *function, void *type, void **args, unsigned count) {
    return createCall(function, type, args, count, e->before);
}
static void *cgGet(CubeEmit *e, void *vector, void *index) {
    char *x = api.userNew(96, 2);
    api.extractElement(x, vector, index, &kNoName, e->before);
    return x;
}
static void *cgSet(CubeEmit *e, void *vector, void *value, unsigned index) {
    char *x = api.userNew(96, 3);
    api.insertElement(x, vector, value, api.constantIntGet(e->i32, index, false), &kNoName, e->before);
    return x;
}

static unsigned cubeIntegerGathers(void *module) {
    const char *setting = getenv("AMD_CUBE_GATHER_FIX");
    if (!gatherFixEnabled() || (setting && !strcmp(setting, "0")) || !api.getFloatTy || !api.binaryCreate ||
        !api.constantFP || !api.selectInit || !api.extractValueCreate || !api.getInt1Ty)
        return 0;
    static const char *const kTypes[] = {"s.v4i32", "u.v4i32", "s.v4i16", "u.v4i16"};
    unsigned rewritten = 0;
    for (unsigned array = 0; array < 2; array++)
    for (size_t t = 0; t < sizeof kTypes / sizeof kTypes[0]; t++) {
        const char *dim = array ? "cube_array" : "cube";
        char name[64];
        snprintf(name, sizeof name, "air.gather_texture_%s.%s", dim, kTypes[t]);
        void *gather = api.getFunction(module, name, strlen(name));
        if (!gather) continue;
        void *context = api.getContext(gather);
        CubeEmit e = {NULL, api.getFloatTy(context), api.getInt32Ty(context), api.getInt1Ty(context)};
        void *next;
        for (void *use = firstUse(gather); use; use = next) {
            next = nextUse(use);
            void *call = api.getUser(use);
            if (hungOffUses(call) || numOperands(call) != 6 + array || operand(call, numOperands(call) - 1) != gather) continue;
            void *texture = operand(call, 0), *sampler = operand(call, 1), *coord = operand(call, 2);
            void *layer = array ? operand(call, 3) : NULL, *component = operand(call, 3 + array);
            // Every function it calls, before anything changes: a declaration of another type (a bitcast) stops here.
            void *fParams[1] = {e.f32}, *fType = api.functionTypeGet(e.f32, fParams, 1, false);
            void *floorF = api.getOrInsertFunction(module, "air.floor.f32", strlen("air.floor.f32"), fType);
            void *fabsF = api.getOrInsertFunction(module, "air.fabs.f32", strlen("air.fabs.f32"), fType);
            char widthName[64], sampleName[64];
            snprintf(widthName, sizeof widthName, "air.get_width_texture_%s", dim);
            snprintf(sampleName, sizeof sampleName, "air.sample_texture_%s.%s", dim, kTypes[t]);
            void *wParams[2] = {typeOf(texture), e.i32}, *wType = api.functionTypeGet(e.i32, wParams, 2, false);
            void *widthF = api.getOrInsertFunction(module, widthName, strlen(widthName), wType);
            void *sParams[8] = {typeOf(texture), typeOf(sampler), typeOf(coord), e.i32, e.i1, e.f32, e.f32, e.i32};
            if (!array) memmove(sParams + 3, sParams + 4, 4 * sizeof sParams[0]);
            void *sType = api.functionTypeGet(typeOf(call), sParams, 7 + array, false);
            void *sampleF = api.getOrInsertFunction(module, sampleName, strlen(sampleName), sType);
            if (!floorF || !fabsF || !widthF || !sampleF || subclassID(floorF) != kValueFunction || subclassID(fabsF) != kValueFunction ||
                subclassID(widthF) != kValueFunction || subclassID(sampleF) != kValueFunction)
                return rewritten;
            e.before = call;
            void *zero = api.constantIntGet(e.i32, 0, false), *yes = api.constantIntGet(e.i1, 1, false), *no = api.constantIntGet(e.i1, 0, false);
            void *wArgs[2] = {texture, zero};
            void *size = api.castCreate(kOpcodeUIToFP, cgCall(&e, widthF, wType, wArgs, 2), e.f32, &kNoName, call);
            void *d[3], *a[3];
            for (unsigned c = 0; c < 3; c++) {
                d[c] = cgGet(&e, coord, api.constantIntGet(e.i32, c, false));
                a[c] = cgCall(&e, fabsF, fType, &d[c], 1);
            }
            // Face selection: x on ties with y or z, then y on a tie with z.
            void *isX = cgOp(&e, kOpcodeAndBits, cgCmp(&e, kPredicateOGE, a[0], a[1]), cgCmp(&e, kPredicateOGE, a[0], a[2]));
            void *isY = cgSelect(&e, isX, no, cgCmp(&e, kPredicateOGE, a[1], a[2]));
            void *major = cgSelect(&e, isX, a[0], cgSelect(&e, isY, a[1], a[2]));
            void *p[3];
            for (unsigned c = 0; c < 3; c++) p[c] = cgOp(&e, kOpcodeFDiv, d[c], major);
            // On the face plane: sv, tv the coordinates along the face's s and t axes (s = sc / ma, t = tc / ma, maybe negated).
            void *sv = cgSelect(&e, isX, p[2], p[0]), *tv = cgSelect(&e, isY, p[2], p[1]);
            void *pm = cgSelect(&e, isX, p[0], cgSelect(&e, isY, p[1], p[2]));
            void *sNeg = cgSelect(&e, isX, cgCmp(&e, kPredicateOGT, d[0], cgF(&e, 0)), cgSelect(&e, isY, no, cgCmp(&e, kPredicateOLT, d[2], cgF(&e, 0))));
            void *tNeg = cgSelect(&e, isY, cgCmp(&e, kPredicateOLT, d[1], cgF(&e, 0)), yes);
            void *negZero = cgF(&e, -0.0), *halfSize = cgOp(&e, kCubeFMul, size, cgF(&e, 0.5));
            void *step = cgOp(&e, kOpcodeFDiv, cgF(&e, 2), size);
            void *lo[2], *hi[2], *axis[2] = {sv, tv}, *neg[2] = {sNeg, tNeg};
            for (unsigned c = 0; c < 2; c++) {
                void *st = cgSelect(&e, neg[c], cgOp(&e, kOpcodeFSub, negZero, axis[c]), axis[c]);
                void *texels = cgOp(&e, kOpcodeFSub, cgOp(&e, kCubeFMul, cgOp(&e, kOpcodeFAdd, st, cgF(&e, 1)), halfSize), cgF(&e, 0.5));
                void *first = cgCall(&e, floorF, fType, &texels, 1);
                void *centre0 = cgOp(&e, kOpcodeFSub, cgOp(&e, kCubeFMul, cgOp(&e, kOpcodeFAdd, first, cgF(&e, 0.5)), step), cgF(&e, 1));
                void *centre1 = cgOp(&e, kOpcodeFAdd, centre0, step);
                lo[c] = cgSelect(&e, neg[c], cgOp(&e, kOpcodeFSub, negZero, centre0), centre0);
                hi[c] = cgSelect(&e, neg[c], cgOp(&e, kOpcodeFSub, negZero, centre1), centre1);
            }
            void *inner = cgOp(&e, kCubeFMul, pm, cgOp(&e, kOpcodeFSub, cgF(&e, 1), cgOp(&e, kOpcodeFDiv, cgF(&e, 1), size)));
            // Gather order: (u0, v1), (u1, v1), (u1, v0), (u0, v0).
            void *corners[4][2] = {{lo[0], hi[1]}, {hi[0], hi[1]}, {hi[0], lo[1]}, {lo[0], lo[1]}}, *result = NULL;
            for (unsigned k = 0; k < 4; k++) {
                void *over[2], *clamped[2];
                for (unsigned c = 0; c < 2; c++) {
                    void *v = corners[k][c], *above = cgCmp(&e, kPredicateOGT, v, cgF(&e, 1)), *below = cgCmp(&e, kPredicateOLT, v, cgF(&e, -1));
                    over[c] = cgOp(&e, kOpcodeOrBits, above, below);
                    clamped[c] = cgSelect(&e, above, cgF(&e, 1), cgSelect(&e, below, cgF(&e, -1), v));
                }
                void *m = cgSelect(&e, cgOp(&e, kOpcodeOrBits, over[0], over[1]), inner, pm);
                void *qx = cgSelect(&e, isX, m, clamped[0]);
                void *qy = cgSelect(&e, isX, clamped[1], cgSelect(&e, isY, m, clamped[1]));
                void *qz = cgSelect(&e, isX, clamped[0], cgSelect(&e, isY, clamped[1], m));
                void *q = cgSet(&e, cgSet(&e, cgSet(&e, coord, qx, 0), qy, 1), qz, 2);
                void *sArgs[8] = {texture, sampler, q, layer, yes, cgF(&e, 0), cgF(&e, 0), zero};
                if (!array) memmove(sArgs + 3, sArgs + 4, 4 * sizeof sArgs[0]);
                void *sample = cgCall(&e, sampleF, sType, sArgs, 7 + array);
                unsigned first = 0;
                void *texel = api.extractValueCreate(sample, (ArrayRef){(void **)&first, 1}, &kNoName, call);
                result = cgSet(&e, result ? result : texel, cgGet(&e, texel, component), k);
            }
            // The gather's texels (extractvalue 0, the vector) come from the samples now; the call itself is left to dead
            // code elimination, or to whatever reads its residency byte.
            void *after;
            for (void *u = firstUse(call); u; u = after) {
                after = nextUse(u);
                void *user = api.getUser(u);
                if (subclassID(user) == kValueInstruction + kOpcodeExtractValue && typeOf(user) == typeOf(result))
                    api.replaceAllUsesWith(user, result);
            }
            rewritten++;
        }
    }
    return rewritten;
}

// Float atomics (MSL 3.0 atomic_float in device memory: fetch_add, fetch_sub, exchange, compare_exchange) are a Mac2
// feature this GPU claims, but libAMDIL902 has no float forms and stops with an internal error (wgpu float32_atomic).
// Exchange and compare-exchange are the same on the bits, so they become the 32-bit integer calls through bitcasts. GCN1
// has no float atomic add, so fetch_add / fetch_sub become a compare-exchange loop: the current value (a plain load
// first, then what each failed compare-exchange read, which comes from L2, not a stale L1) plus the operand, swapped in
// if the value hasn't changed meanwhile; the result is the value it was added to. AMD_FLOAT_ATOMIC_FIX=0 turns this off.
// Test: a19.
static void *firstInstruction(void *block) { return (char *)nextNode((char *)block + kBlockInstructions) - kInstructionNode; }
static unsigned floatAtomicsAsInteger(void *module) {
    const char *setting = getenv("AMD_FLOAT_ATOMIC_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.splitBasicBlock || !api.branchInit || !api.condBranchInit || !api.allocaInit ||
        !api.binaryCreate || !api.castCreate || !api.getFloatTy || !api.getInt1Ty)
        return 0;
    static const char *const kSpaces[] = {"global", "local"};
    static const unsigned kAddressSpaces[] = {1, 3};
    static const char *const kOps[] = {"xchg", "cmpxchg.weak", "cmpxchg.strong", "add", "sub"};
    unsigned rewritten = 0;
    for (size_t sp = 0; sp < 2; sp++)
    for (size_t op = 0; op < sizeof kOps / sizeof kOps[0]; op++) {
        char name[64], intName[64];
        snprintf(name, sizeof name, "air.atomic.%s.%s.f32", kSpaces[sp], kOps[op]);
        void *atomic = api.getFunction(module, name, strlen(name));
        if (!atomic) continue;
        bool compare = op == 1 || op == 2, loop = op >= 3;
        snprintf(intName, sizeof intName, "air.atomic.%s.%s.i32", kSpaces[sp], loop ? "cmpxchg.weak" : kOps[op]);
        void *context = api.getContext(atomic);
        void *i32 = api.getInt32Ty(context), *f32 = api.getFloatTy(context), *i1 = api.getInt1Ty(context);
        void *pointer = api.pointerTypeGet(i32, kAddressSpaces[sp]), *privatePointer = api.pointerTypeGet(i32, 0);
        void *params[7] = {pointer, i32, i32, i32, i1}, *intType;
        if (compare || loop) {
            void *cp[7] = {pointer, privatePointer, i32, i32, i32, i32, i1};
            memcpy(params, cp, sizeof cp);
            intType = api.functionTypeGet(i32, params, 7, false);
        } else intType = api.functionTypeGet(i32, params, 5, false);
        void *intAtomic = api.getOrInsertFunction(module, intName, strlen(intName), intType);
        if (!intAtomic || subclassID(intAtomic) != kValueFunction) continue;  // a bitcast: another declaration
        void *next;
        for (void *use = firstUse(atomic); use; use = next) {
            next = nextUse(use);
            void *call = api.getUser(use);
            unsigned args = compare || loop ? (loop ? 5 : 7) : 5;
            if (hungOffUses(call) || numOperands(call) != args + 1 || operand(call, args) != atomic) continue;
            void *address = api.castCreate(kOpcodeBitCast, operand(call, 0), pointer, &kNoName, call);
            if (!loop) {
                void *a[7];
                for (unsigned i = 0; i < args; i++) a[i] = operand(call, i);
                a[0] = address;
                if (compare) {
                    a[1] = api.castCreate(kOpcodeBitCast, a[1], privatePointer, &kNoName, call);
                    a[2] = api.castCreate(kOpcodeBitCast, a[2], i32, &kNoName, call);
                } else a[1] = api.castCreate(kOpcodeBitCast, a[1], i32, &kNoName, call);
                void *result = createCall(intAtomic, intType, a, args, call);
                api.replaceAllUsesWith(call, api.castCreate(kOpcodeBitCast, result, f32, &kNoName, call));
                api.eraseFromParent(call);
                rewritten++;
                continue;
            }
            // add / sub: slot (private) holds the value expected in memory.
            void *block = *(void **)((char *)call + kInstructionParent), *function = *(void **)((char *)block + kBlockParent);
            void *entry = (char *)nextNode((char *)function + kFunctionBlocks) - kBlockNode;
            char *slot = api.userNew(96, 1);
            api.allocaInit(slot, i32, 0, &kNoName, firstInstruction(entry));
            char *initial = api.userNew(96, 1);
            api.loadInst(initial, i32, address, &kNoName, true, call);
            char *first = api.userNew(96, 2);
            api.storeInst(first, initial, slot, call);
            void *tail = api.splitBasicBlock(block, (char *)call + kInstructionNode, &kNoName);  // tail starts at the call
            void *jump = (char *)prevNode((char *)block + kBlockInstructions) - kInstructionNode;      // block's new branch to tail
            void *body = api.splitBasicBlock(block, (char *)jump + kInstructionNode, &kNoName); // body: just that branch
            void *bodyJump = firstInstruction(body);
            char *expected = api.userNew(96, 1);
            api.loadInst(expected, i32, slot, &kNoName, false, bodyJump);
            void *value = api.castCreate(kOpcodeBitCast, expected, f32, &kNoName, bodyJump);
            void *sum = api.binaryCreate(op == 3 ? kOpcodeFAdd : kOpcodeFSub, value, operand(call, 1), &kNoName, bodyJump);
            void *a[7] = {address, slot, api.castCreate(kOpcodeBitCast, sum, i32, &kNoName, bodyJump), operand(call, 2),
                          api.constantIntGet(i32, 0, false), operand(call, 3), operand(call, 4)};
            void *seen = createCall(intAtomic, intType, a, 7, bodyJump);
            void *same = api.cmpCreate(kOpcodeICmp, kPredicateEQ, seen, expected, &kNoName, bodyJump);
            char *branch = api.userNew(96, 3);
            api.condBranchInit(branch, tail, body, same, bodyJump);
            api.eraseFromParent(bodyJump);
            api.replaceAllUsesWith(call, api.castCreate(kOpcodeBitCast, expected, f32, &kNoName, call));
            api.eraseFromParent(call);
            rewritten++;
        }
    }
    return rewritten;
}

// A cube array index below 0 reads the wrong face: the hardware clamps the slice, 8 * index + face, so -1 reads the first
// face of the first cube whatever the direction. (2D arrays and indices past the end come out right.) WebKit passes WGSL's
// array index on as it is, and WebGPU asks for the nearest layer (CTS builtin,textureSample and the others, every cube array
// case with a negative index), so raise the index to 0 first.
static unsigned clampCubeArrayIndices(void *module) {
    const char *setting = getenv("AMD_CUBE_ARRAY_FIX");
    if (setting && !strcmp(setting, "0")) return 0;
    static const struct { const char *name; unsigned index; } kForms[] = {
        {"air.sample_texture_cube_array", 3},
        {"air.sample_texture_cube_array_grad", 3},
        {"air.gather_texture_cube_array", 3},
        {"air.sample_depth_cube_array", 4},
        {"air.sample_compare_depth_cube_array", 4},
        {"air.gather_depth_cube_array", 4},
        {"air.gather_compare_depth_cube_array", 4},
    };
    static const char *const kTypes[] = {"f32", "f16", "v4f32", "v4f16", "s.v4i32", "u.v4i32", "s.v4i16", "u.v4i16"};
    enum { kMaxArguments = 15 };
    unsigned clamped = 0;
    for (size_t f = 0; f < sizeof kForms / sizeof kForms[0]; f++)
    for (size_t t = 0; t < sizeof kTypes / sizeof kTypes[0]; t++) {
        char name[64];
        snprintf(name, sizeof name, "%s.%s", kForms[f].name, kTypes[t]);
        void *sample = api.getFunction(module, name, strlen(name));
        if (!sample) continue;
        void *i32 = api.getInt32Ty(api.getContext(sample)), *maxParams[2] = {i32, i32};
        void *maxType = api.functionTypeGet(i32, maxParams, 2, false);
        void *max = api.getOrInsertFunction(module, "air.max.s.i32", strlen("air.max.s.i32"), maxType);
        if (!max || subclassID(max) != subclassID(sample)) return clamped;  // a bitcast: existing declaration of another type
        void *sampleType = *(void **)((char *)sample + kFunctionValueType);
        for (void *use = firstUse(sample); use;) {
            void *call = api.getUser(use);
            use = nextUse(use);
            if (hungOffUses(call) || numOperands(call) <= kForms[f].index + 1 || numOperands(call) > kMaxArguments + 1 ||
                operand(call, numOperands(call) - 1) != sample || typeOf(operand(call, kForms[f].index)) != i32)
                continue;
            // A new call rather than replaceUsesOfWith: a constant index is the same value as other constant operands.
            void *args[kMaxArguments], *maxArgs[2] = {operand(call, kForms[f].index), api.constantIntGet(i32, 0, false)};
            unsigned count = numOperands(call) - 1;
            for (unsigned a = 0; a < count; a++) args[a] = operand(call, a);
            args[kForms[f].index] = createCall(max, maxType, maxArgs, 2, call);
            api.replaceAllUsesWith(call, createCall(sample, sampleType, args, count, call));
            api.eraseFromParent(call);
            clamped++;
        }
    }
    return clamped;
}

// LLVM shrinks a threadgroup variable that only ever holds two values to an i1 global, and libAMDIL902 then miscompiles zext
// of its load: `iand load, r` with r holding whatever 0 it last materialized, so the variable always reads as false (WebGPU CTS
// builtin,workgroupUniformLoad:types, type="bool", in Safari). Its stores write the byte as 0 or 0xFF, so load the byte and
// compare it with 0. libAMDIL902 runs the same shrinking itself, after this, on a variable the front end left a byte (a
// threadgroup bool set and read between barriers, found by differential fuzzing): every load of a scalar threadgroup
// variable is made volatile, which stops LLVM's global optimizer from touching the variable. AMD_LDS_BOOL_FIX=0 turns
// this off.
static unsigned loadThreadgroupBoolsAsBytes(void *module) {
    const char *setting = getenv("AMD_LDS_BOOL_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.getInt1Ty || !api.getInt8Ty) return 0;
    enum { kAddressSpaceThreadgroup = 3, kMaxLoads = 256 };
    void *loads[kMaxLoads];
    unsigned numLoads = 0;
    void *i1 = NULL, *i8 = NULL, *boolPointer = NULL, *bytePointer = NULL, *zero = NULL;
    char *functions = (char *)module + kModuleFunctions;
    for (char *fn = nextNode(functions); fn != functions; fn = nextNode(fn)) {
        char *function = fn - kFunctionNode, *blocks = function + kFunctionBlocks;
        if (*(void **)(function + kFunctionParent) != module) return 0;  // layout mismatch: leave the module alone
        if (nextNode(blocks) == blocks) continue;  // a declaration
        if (!i1) {
            void *context = api.getContext(function);
            i1 = api.getInt1Ty(context);
            i8 = api.getInt8Ty(context);
            boolPointer = api.pointerTypeGet(i1, kAddressSpaceThreadgroup);
            bytePointer = api.pointerTypeGet(i8, kAddressSpaceThreadgroup);
            zero = api.constantIntGet(i8, 0, false);
        }
        for (char *bn = nextNode(blocks); bn != blocks; bn = nextNode(bn)) {
            char *block = bn - kBlockNode, *insts = block + kBlockInstructions;
            if (*(void **)(block + kBlockParent) != function) return 0;
            for (char *in = nextNode(insts); in != insts; in = nextNode(in)) {
                char *inst = in - kInstructionNode;
                if (*(void **)(inst + kInstructionParent) != block) return 0;
                if (!isInstruction(inst, kOpcodeLoad) || hungOffUses(inst) || numOperands(inst) != 1 || numLoads == kMaxLoads) continue;
                void *pointer = operand(inst, 0), *type = typeOf(inst);
                if (type == i1 && typeOf(pointer) == boolPointer) {
                    loads[numLoads++] = inst;
                } else if (subclassID(pointer) == kValueGlobalVariable && typeID(type) != kTypeStruct && typeID(type) != kTypeArray &&
                           typeOf(pointer) == api.pointerTypeGet(type, kAddressSpaceThreadgroup) && !isVolatileLoad(inst)) {
                    loads[numLoads++] = inst;  // a scalar threadgroup variable, loaded straight from the global
                }
            }
        }
    }
    for (unsigned l = 0; l < numLoads; l++) {
        void *load = loads[l], *value;
        if (typeOf(load) == i1) {
            void *pointer = api.castCreate(kOpcodeBitCast, operand(load, 0), bytePointer, &kNoName, load);
            void *byte = api.userNew(96, 1);  // sizeof(LoadInst) is 56 in LLVM 5; extra room is harmless
            api.loadInst(byte, i8, pointer, &kNoName, false, load);
            value = api.cmpCreate(kOpcodeICmp, kPredicateNE, byte, zero, &kNoName, load);
        } else {
            value = api.userNew(96, 1);
            api.loadInst(value, typeOf(load), operand(load, 0), &kNoName, true, load);
        }
        api.replaceAllUsesWith(load, value);
        api.eraseFromParent(load);
    }
    return numLoads;
}

// libAMDIL902's air.unpack.snorm2x16 / unorm2x16 come out up to 6 / 2 ulp off in every shader stage (all 65536 values on
// the R9 M370X); GLSL ES 3.0 (and dEQP shaderpackingfunction, in WebGL 2) allows 1, and the Iris Pro stays within it.
// Each call becomes the arithmetic the specification describes: each half sign- or zero-extended, converted to float and
// multiplied by the float 1 / 32767 (1 / 65535), the signed one clamped to -1 by raising -32768 to -32767 first. That's
// within 1 ulp of the exact quotient for every value. The 4x8 forms are already within 1 ulp and stay as they are.
// AMD_UNPACK_FIX=0 turns this off.
enum { kOpcodeFMul = 16, kOpcodeShl = 23, kOpcodeLShr = 24, kOpcodeAShr = 25, kOpcodeAnd = 26, kOpcodeSIToFP = 42 };
static unsigned exactUnpackNorm(void *module) {
    const char *setting = getenv("AMD_UNPACK_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.getFloatTy || !api.binaryCreate || !api.constantFP) return 0;
    static const struct { const char *name; unsigned fields, bits; bool isSigned; } kForms[] = {
        {"air.unpack.snorm2x16.v2f32", 2, 16, true},
        {"air.unpack.unorm2x16.v2f32", 2, 16, false},
    };
    unsigned rewritten = 0;
    for (size_t f = 0; f < sizeof kForms / sizeof kForms[0]; f++) {
        void *unpack = api.getFunction(module, kForms[f].name, strlen(kForms[f].name));
        if (!unpack) continue;
        void *context = api.getContext(unpack);
        void *i32 = api.getInt32Ty(context), *f32 = api.getFloatTy(context), *maxParams[2] = {i32, i32};
        void *maxType = api.functionTypeGet(i32, maxParams, 2, false);
        void *max = kForms[f].isSigned ? api.getOrInsertFunction(module, "air.max.s.i32", strlen("air.max.s.i32"), maxType) : NULL;
        if (kForms[f].isSigned && (!max || subclassID(max) != subclassID(unpack))) continue;  // a bitcast: another declaration
        unsigned largest = kForms[f].isSigned ? (1u << (kForms[f].bits - 1)) - 1 : (1u << kForms[f].bits) - 1;
        void *scale = api.constantFP(f32, (double)(1.0f / (float)largest));
        void *lowest = api.constantIntGet(i32, (uint64_t)-(int64_t)largest, true);
        void *mask = api.constantIntGet(i32, (1u << kForms[f].bits) - 1, false);
        for (void *use = firstUse(unpack); use;) {
            void *call = api.getUser(use);
            use = nextUse(use);
            if (!isCall(call, unpack, 2) || typeOf(operand(call, 0)) != i32) continue;
            void *packed = operand(call, 0), *result = api.splat(kForms[f].fields, api.constantFP(f32, 0.0));
            for (unsigned c = 0; c < kForms[f].fields; c++) {
                void *field;
                if (kForms[f].isSigned) {  // the field's top bit to bit 31, then an arithmetic shift down: sign-extended
                    void *up = api.constantIntGet(i32, 32 - kForms[f].bits * (c + 1), false);
                    void *down = api.constantIntGet(i32, 32 - kForms[f].bits, false);
                    field = api.binaryCreate(kOpcodeAShr, api.binaryCreate(kOpcodeShl, packed, up, &kNoName, call), down, &kNoName, call);
                    void *args[2] = {field, lowest};
                    field = api.castCreate(kOpcodeSIToFP, createCall(max, maxType, args, 2, call), f32, &kNoName, call);
                } else {
                    void *shift = api.constantIntGet(i32, kForms[f].bits * c, false);
                    field = api.binaryCreate(kOpcodeAnd, api.binaryCreate(kOpcodeLShr, packed, shift, &kNoName, call), mask, &kNoName, call);
                    field = api.castCreate(kOpcodeUIToFP, field, f32, &kNoName, call);
                }
                void *merged = api.userNew(96, 3);
                api.insertElement(merged, result, api.binaryCreate(kOpcodeFMul, field, scale, &kNoName, call),
                                  api.constantIntGet(i32, c, false), &kNoName, call);
                result = merged;
            }
            api.replaceAllUsesWith(call, result);
            api.eraseFromParent(call);
            rewritten++;
        }
        if (!firstUse(unpack) && api.eraseFunction) api.eraseFunction(unpack);
    }
    return rewritten;
}

// SC (ATIRadeonX4000SCLib) keeps small private arrays in VGPRs: constant indexes become plain register writes, variable
// ones M0-relative writes (v_movreld in a loop over the lanes' distinct indexes). Its handling of those writes loses
// updates, found by differential fuzzing against a CPU reference (the IL is right, SC's output isn't):
//   - `if (c) p[2] = a; else p[i] = b; p[j] = 1;` leaves p[2] as it was: SC drops the whole first branch;
//   - `for (...) { p[i] += 1; p[j] = 1; }` loses the first write from the second iteration on.
// A select between two element pointers counts as a variable index. Arrays of up to 32 scalars or vectors get each
// variable-index store rewritten as one conditional store per element, `p[k] = i == k ? v : p[k]`, so SC only sees
// constant-index writes, and each variable-index load of the same arrays as a chain of selects, `v = i == k ? p[k] : v`:
// with the loads left indexed, SC merges them across the constant-index stores between them once a loop is unrolled
// (`for (...) { p[k & 7] = a; s ^= p[i]; }` with k known: four of five loads read one value). Arrays only read at
// variable indexes (lookup tables) stay as they are. AMD_PRIVATE_STORE_FIX=0 turns this off.
enum { kOpcodeStore = 31, kMaxArrayLength = 32, kMaxIndexed = 64, kAllocaAllocatedType = 0x38, kGEPSourceType = 0x38 };
typedef struct { void *access, *array; } IndexedAccess;

static bool isAllocaInstruction(void *v) { return isInstruction(v, kOpcodeAlloca); }

// The array alloca a store's pointer addresses, and the element index: a constant (*constant) or a value (*index).
static void *storedArrayElement(void *pointer, void *i64, void **index, int *constant, void *before) {
    *index = NULL;
    *constant = -1;
    if (isInstruction(pointer, kOpcodeGEP) && !hungOffUses(pointer) && numOperands(pointer) == 3) {
        void *array = operand(pointer, 0), *zero = operand(pointer, 1), *element = operand(pointer, 2);
        if (!isAllocaInstruction(array) || zero != api.constantIntGet(typeOf(zero), 0, false)) return NULL;
        void *type = *(void **)((char *)array + kAllocaAllocatedType);
        if (typeID(type) != kTypeArray || arrayLength(type) > kMaxArrayLength || *(void **)((char *)pointer + kGEPSourceType) != type)
            return NULL;
        unsigned elementKind = typeID(elementType(type));  // Type::TypeID: half 1, float 2, double 3, integer 11, vector 16
        if (elementKind != 1 && elementKind != 2 && elementKind != 3 && elementKind != 11 && elementKind != 16) return NULL;
        for (unsigned k = 0; k < arrayLength(type); k++)
            if (element == api.constantIntGet(typeOf(element), k, false)) { *constant = (int)k; return array; }
        *index = element;
        return array;
    }
    if (isInstruction(pointer, kOpcodeSelect) && !hungOffUses(pointer) && numOperands(pointer) == 3 && i64) {
        void *a, *b;
        int ka, kb;
        void *arrayA = storedArrayElement(operand(pointer, 1), i64, &a, &ka, NULL);
        void *arrayB = storedArrayElement(operand(pointer, 2), i64, &b, &kb, NULL);
        if (!arrayA || arrayA != arrayB || ka < 0 || kb < 0) return NULL;
        if (before) {  // the index the select picks
            char *pick = api.userNew(96, 3);
            api.selectInit(pick, operand(pointer, 0), api.constantIntGet(i64, ka, false), api.constantIntGet(i64, kb, false), &kNoName,
                           before);
            *index = pick;
        } else {
            *index = pointer;  // just classifying
        }
        return arrayA;
    }
    return NULL;
}

static unsigned privateArrayIndexedStores(void *module) {
    const char *setting = getenv("AMD_PRIVATE_STORE_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.gepCreate || !api.selectInit) return 0;
    unsigned rewritten = 0;
    char *functions = (char *)module + kModuleFunctions;
    for (char *fn = nextNode(functions); fn != functions; fn = nextNode(fn)) {
        char *function = fn - kFunctionNode, *blocks = function + kFunctionBlocks;
        if (*(void **)(function + kFunctionParent) != module) return rewritten;  // layout mismatch: leave the module alone
        if (nextNode(blocks) == blocks) continue;
        void *i64 = api.getInt64Ty(api.getContext(function));
        IndexedAccess stores[kMaxIndexed], loads[kMaxIndexed];
        unsigned numStores = 0, numLoads = 0;
        for (char *bn = nextNode(blocks); bn != blocks; bn = nextNode(bn)) {
            char *block = bn - kBlockNode, *insts = block + kBlockInstructions;
            if (*(void **)(block + kBlockParent) != function) return rewritten;
            for (char *in = nextNode(insts); in != insts; in = nextNode(in)) {
                char *inst = in - kInstructionNode;
                if (*(void **)(inst + kInstructionParent) != block) return rewritten;
                bool store = isInstruction(inst, kOpcodeStore) && !hungOffUses(inst) && numOperands(inst) == 2;
                bool load = isInstruction(inst, kOpcodeLoad) && !hungOffUses(inst) && numOperands(inst) == 1 && !isVolatileLoad(inst);
                if (!store && !load) continue;
                void *index;
                int constant;
                void *array = storedArrayElement(operand(inst, store ? 1 : 0), i64, &index, &constant, NULL);
                if (!array || !index) continue;
                if (store && numStores < kMaxIndexed) stores[numStores++] = (IndexedAccess){inst, array};
                if (load && numLoads < kMaxIndexed) loads[numLoads++] = (IndexedAccess){inst, array};
            }
        }
        // The arrays written at a variable index: all their variable-index accesses become constant-index ones.
        void *arrays[kMaxIndexed];
        unsigned numArrays = 0;
        for (unsigned s = 0; s < numStores; s++) {
            unsigned a = 0;
            while (a < numArrays && arrays[a] != stores[s].array) a++;
            if (a == numArrays) arrays[numArrays++] = stores[s].array;
        }
        for (unsigned s = 0; s < numStores; s++) {
            void *store = stores[s].access, *array = stores[s].array, *value = operand(store, 0);
            void *type = *(void **)((char *)array + kAllocaAllocatedType), *element = elementType(type);
            void *index;
            int constant;
            storedArrayElement(operand(store, 1), i64, &index, &constant, store);  // builds the select of indexes if needed
            if (!index) continue;
            void *indexType = typeOf(index);
            for (unsigned k = 0; k < arrayLength(type); k++) {  // p[k] = i == k ? v : p[k]
                void *indices[2] = {api.constantIntGet(indexType, 0, false), api.constantIntGet(indexType, k, false)};
                void *slot = api.gepCreate(type, array, (ArrayRef){indices, 2}, &kNoName, store);
                char *old = api.userNew(96, 1);
                api.loadInst(old, element, slot, &kNoName, false, store);
                void *hit = api.cmpCreate(kOpcodeICmp, kPredicateEQ, index, indices[1], &kNoName, store);
                char *merged = api.userNew(96, 3);
                api.selectInit(merged, hit, value, old, &kNoName, store);
                char *write = api.userNew(96, 2);
                api.storeInst(write, merged, slot, store);
            }
            api.eraseFromParent(store);
            rewritten++;
        }
        for (unsigned l = 0; l < numLoads; l++) {
            void *load = loads[l].access, *array = loads[l].array;
            unsigned a = 0;
            while (a < numArrays && arrays[a] != array) a++;
            if (a == numArrays) continue;  // only read at variable indexes: SC handles that
            void *type = *(void **)((char *)array + kAllocaAllocatedType), *element = elementType(type);
            if (typeOf(load) != element) continue;
            void *index;
            int constant;
            storedArrayElement(operand(load, 0), i64, &index, &constant, load);
            if (!index) continue;
            void *indexType = typeOf(index), *value = NULL;
            for (unsigned k = 0; k < arrayLength(type); k++) {  // v = p[0]; v = i == k ? p[k] : v
                void *indices[2] = {api.constantIntGet(indexType, 0, false), api.constantIntGet(indexType, k, false)};
                void *slot = api.gepCreate(type, array, (ArrayRef){indices, 2}, &kNoName, load);
                char *read = api.userNew(96, 1);
                api.loadInst(read, element, slot, &kNoName, false, load);
                if (!value) {
                    value = read;
                    continue;
                }
                void *hit = api.cmpCreate(kOpcodeICmp, kPredicateEQ, index, indices[1], &kNoName, load);
                char *merged = api.userNew(96, 3);
                api.selectInit(merged, hit, read, value, &kNoName, load);
                value = merged;
            }
            api.replaceAllUsesWith(load, value);
            api.eraseFromParent(load);
            rewritten++;
        }
    }
    return rewritten;
}

// SC lowers the AMD IL's usub_sat / uadd_sat right only while the second operand isn't known to be 0: `usub_sat x, 0`
// (and uadd_sat) becomes `v_max_f32 x, x clamp`, a float clamp to [0, 1], so subsat(x, z) with z = 0 in the shader gives
// 0 for x >= 0x80000000 and 0x3f800000 for other large x (found by differential fuzzing; the signed forms and madsat are
// right). Every air.add_sat.u / air.sub_sat.u call becomes the arithmetic, with nothing left for SC to fold:
//   add_sat(a, b) = a + b < a ? ~0 : a + b        sub_sat(a, b) = a < b ? 0 : a - b
// Scalars and vectors of 8 to 64 bits. AMD_SATURATE_FIX=0 turns this off.
enum { kOpcodeAdd = 11, kOpcodeSub = 13, kPredicateULT = 36, kTypeInteger = 11, kTypeVector = 16 };
static unsigned plainSaturatingAddSub(void *module) {
    const char *setting = getenv("AMD_SATURATE_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.binaryCreate || !api.selectInit || !api.splat) return 0;
    static const char *const kOps[] = {"add", "sub"}, *const kTypes[] = {"i8", "i16", "i32", "i64"}, *const kWidths[] = {"", "v2", "v3", "v4"};
    unsigned rewritten = 0;
    for (int o = 0; o < 2; o++)
        for (int w = 0; w < 4; w++)
            for (int t = 0; t < 4; t++) {
                char name[48];
                snprintf(name, sizeof name, "air.%s_sat.u.%s%s", kOps[o], kWidths[w], kTypes[t]);
                void *function = api.getFunction(module, name, strlen(name));
                if (!function) continue;
                for (void *use = firstUse(function); use;) {
                    void *call = api.getUser(use);
                    use = nextUse(use);
                    if (!isCall(call, function, 3)) continue;
                    void *a = operand(call, 0), *b = operand(call, 1), *type = typeOf(a);
                    if (typeOf(b) != type || typeOf(call) != type) continue;
                    bool vector = typeID(type) == kTypeVector;
                    void *element = vector ? elementType(type) : type;
                    if (typeID(element) != kTypeInteger) continue;
                    void *limit = api.constantIntGet(element, o == 0 ? ~0ull : 0, false);  // ~0 is truncated to the width
                    if (vector) limit = api.splat((unsigned)arrayLength(type), limit);
                    void *value = api.binaryCreate(o == 0 ? kOpcodeAdd : kOpcodeSub, a, b, &kNoName, call);
                    void *clamped = o == 0 ? api.cmpCreate(kOpcodeICmp, kPredicateULT, value, a, &kNoName, call)
                                           : api.cmpCreate(kOpcodeICmp, kPredicateULT, a, b, &kNoName, call);
                    char *result = api.userNew(96, 3);
                    api.selectInit(result, clamped, limit, value, &kNoName, call);
                    api.replaceAllUsesWith(call, result);
                    api.eraseFromParent(call);
                    rewritten++;
                }
            }
    return rewritten;
}

// libAMDIL902 lowers air.rotate to the IL's bitalign (a rotate right by width - n), which is right; but when SC knows both
// operands it folds bitalign by a multiple of 8 the other way: rotate(37u, 24u) is 0x2500 and rotate(37u, 8u) 0x25000000
// (found by differential fuzzing; other amounts, and either operand at run time, are right). Every air.rotate call
// becomes (x << m) | (x >> ((width - m) & (width - 1))) with m = n & (width - 1): LLVM folds that itself when it can,
// and otherwise the back end still selects a rotate. Scalars and vectors of 8 to 64 bits. AMD_ROTATE_FIX=0 turns this
// off.
enum { kOpcodeOr = 27 };
static unsigned rotatesAsShifts(void *module) {
    const char *setting = getenv("AMD_ROTATE_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.binaryCreate || !api.splat) return 0;
    static const char *const kTypes[] = {"i8", "i16", "i32", "i64"}, *const kWidths[] = {"", "v2", "v3", "v4"};
    static const unsigned kBits[] = {8, 16, 32, 64};
    unsigned rewritten = 0;
    for (int w = 0; w < 4; w++)
        for (int t = 0; t < 4; t++) {
            char name[48];
            snprintf(name, sizeof name, "air.rotate.%s%s", kWidths[w], kTypes[t]);
            void *function = api.getFunction(module, name, strlen(name));
            if (!function) continue;
            for (void *use = firstUse(function); use;) {
                void *call = api.getUser(use);
                use = nextUse(use);
                if (!isCall(call, function, 3)) continue;
                void *x = operand(call, 0), *n = operand(call, 1), *type = typeOf(x);
                if (typeOf(n) != type || typeOf(call) != type) continue;
                bool vector = typeID(type) == kTypeVector;
                void *element = vector ? elementType(type) : type;
                if (typeID(element) != kTypeInteger) continue;
                void *mask = api.constantIntGet(element, kBits[t] - 1, false), *width = api.constantIntGet(element, kBits[t], false);
                if (vector) {
                    mask = api.splat((unsigned)arrayLength(type), mask);
                    width = api.splat((unsigned)arrayLength(type), width);
                }
                void *m = api.binaryCreate(kOpcodeAnd, n, mask, &kNoName, call);
                void *back = api.binaryCreate(kOpcodeAnd, api.binaryCreate(kOpcodeSub, width, m, &kNoName, call), mask, &kNoName, call);
                void *left = api.binaryCreate(kOpcodeShl, x, m, &kNoName, call);
                void *right = api.binaryCreate(kOpcodeLShr, x, back, &kNoName, call);
                api.replaceAllUsesWith(call, api.binaryCreate(kOpcodeOr, left, right, &kNoName, call));
                api.eraseFromParent(call);
                rewritten++;
            }
        }
    return rewritten;
}

// `(x & 2^k) != 0` / `== 0` (32-bit) as `extract_bits(x, k, 1) != 0` / `== 0`: libAMDIL902 treats booleans as 0 / 1
// when it simplifies (it turns `(x & 1) != 0` into `x & 1`, then drops the `& 1` where only bit 0 is said to matter, as
// in an or with another boolean), but its branches test the whole register: `odd(x) || c` branches on `x | c`, so code
// guarded by "x even and not c" runs only for x == 0 (found by differential fuzzing, in loops and branches; 9 of the 16
// random kernels the AMD compiler still got wrong). Its optimizer turns a shift back into the and, but doesn't look into
// air.extract_bits (the IL's ubit_extract), so the comparison stays a comparison. AMD_BIT_TEST_FIX=0 turns this off.
enum { kValueConstantInt = 18, kOpcodeICmpPredicateMask = 0x3f };
static bool constantIntValue(void *v, uint64_t *value) {
    if (subclassID(v) != kValueConstantInt || typeID(typeOf(v)) != kTypeInteger) return false;
    if (*(uint32_t *)((char *)v + 0x20) > 64) return false;  // APInt BitWidth @0x20, VAL @0x18 (inline up to 64 bits)
    *value = *(uint64_t *)((char *)v + 0x18);
    return true;
}
static unsigned singleBitTestsAsExtracts(void *module, void *function, void *i32) {
    unsigned rewritten = 0;
    void *extract = NULL, *extractType = NULL;
    char *blocks = (char *)function + kFunctionBlocks;
    for (char *bn = nextNode(blocks); bn != blocks; bn = nextNode(bn)) {
        char *block = bn - kBlockNode, *insts = block + kBlockInstructions;
        for (char *in = nextNode(insts); in != insts; in = nextNode(in)) {
            char *inst = in - kInstructionNode;
            if (!isInstruction(inst, kOpcodeICmp) || hungOffUses(inst) || numOperands(inst) != 2) continue;
            unsigned predicate = *(uint16_t *)(inst + 0x12) & kOpcodeICmpPredicateMask;
            uint64_t zero, mask;
            void *masked = operand(inst, 0);
            if ((predicate != kPredicateEQ && predicate != kPredicateNE) || !constantIntValue(operand(inst, 1), &zero) || zero ||
                !isInstruction(masked, kOpcodeAnd) || hungOffUses(masked) || numOperands(masked) != 2 || typeOf(masked) != i32 ||
                !constantIntValue(operand(masked, 1), &mask) || !mask || (mask & (mask - 1)) || mask > 0xffffffffu)
                continue;
            if (!extract) {
                void *params[3] = {i32, i32, i32};
                extractType = api.functionTypeGet(i32, params, 3, false);
                extract = api.getOrInsertFunction(module, "air.extract_bits.u.i32", strlen("air.extract_bits.u.i32"), extractType);
                if (!extract || subclassID(extract) != kValueFunction) return rewritten;  // a bitcast: another declaration
            }
            void *args[3] = {operand(masked, 0), api.constantIntGet(i32, (uint64_t)__builtin_ctzll(mask), false), api.constantIntGet(i32, 1, false)};
            api.replaceUsesOfWith(inst, masked, createCall(extract, extractType, args, 3, inst));
            rewritten++;
        }
    }
    return rewritten;
}

// A vector reinterpreted with narrower lanes (`as_type<uchar4>(ushort2 v)`, or the bitcast the front end itself makes
// when only the low bytes of a ushort2's lanes are used, as in `uchar(vf(a & b))`) comes out with the other byte of lane 1
// still in the register of its narrow lanes 2 and 3: libAMDIL902 doesn't shift and mask them into place. Stored into a
// uchar array the compiler keeps in registers (4 elements packed into one), those bits land in the neighbouring elements
// (found by differential fuzzing with narrow vectors; the bytes of lane 0 come out right). So each such bitcast of an
// integer vector to one with narrower integer lanes becomes a vector built lane by lane: the wide lane extracted,
// shifted and truncated, which store right (the shifts then go through narrowUnsignedConstants).
// AMD_BITCAST_LANE_FIX=0 turns this off. Test: a18.
enum { kOpcodeExtractElement = 59, kLaneOpTrunc = 36 };
static unsigned intBits(void *type) { return *(uint32_t *)((char *)type + 8) >> 8; }  // IntegerType width: Type SubclassData
static unsigned bitcastLaneExtracts(void *module) {
    const char *setting = getenv("AMD_BITCAST_LANE_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.binaryCreate || !api.castCreate || !api.undefGet) return 0;
    enum { kMax = 512 };
    void *found[kMax];
    unsigned count = 0, rewritten = 0;
    char *functions = (char *)module + kModuleFunctions;
    for (char *fn = nextNode(functions); fn != functions; fn = nextNode(fn)) {
        char *function = fn - kFunctionNode, *blocks = function + kFunctionBlocks;
        if (*(void **)(function + kFunctionParent) != module) return 0;  // layout mismatch: leave the module alone
        for (char *bn = nextNode(blocks); bn != blocks; bn = nextNode(bn)) {
            char *block = bn - kBlockNode, *insts = block + kBlockInstructions;
            if (*(void **)(block + kBlockParent) != function) return 0;
            for (char *in = nextNode(insts); in != insts; in = nextNode(in)) {
                char *inst = in - kInstructionNode;
                if (*(void **)(inst + kInstructionParent) != block) return 0;
                if (!isInstruction(inst, kOpcodeBitCast) || hungOffUses(inst) || numOperands(inst) != 1 || count == kMax) continue;
                void *to = typeOf(inst), *from = typeOf(operand(inst, 0));
                if (typeID(to) != kTypeVector || typeID(from) != kTypeVector) continue;
                void *narrow = elementType(to), *wide = elementType(from);
                if (typeID(narrow) != kTypeInteger || typeID(wide) != kTypeInteger) continue;
                unsigned narrowBits = intBits(narrow), wideBits = intBits(wide);
                if (wideBits <= narrowBits || wideBits > 32 || wideBits % narrowBits || arrayLength(to) > 16) continue;
                found[count++] = inst;
            }
        }
    }
    for (unsigned c = 0; c < count; c++) {
        void *cast = found[c], *source = operand(cast, 0), *to = typeOf(cast), *narrow = elementType(to);
        void *wide = elementType(typeOf(source)), *i32 = api.getInt32Ty(api.getContext(cast));
        unsigned narrowBits = intBits(narrow), ratio = intBits(wide) / narrowBits, lanes = (unsigned)arrayLength(to);
        void *vector = api.undefGet(to);
        for (unsigned k = 0; k < lanes; k++) {
            char *lane = api.userNew(96, 2);
            api.extractElement(lane, source, api.constantIntGet(i32, k / ratio, false), &kNoName, cast);
            void *value = lane;
            if (k % ratio) value = api.binaryCreate(kOpcodeLShr, value, api.constantIntGet(wide, (k % ratio) * narrowBits, false), &kNoName, cast);
            value = api.castCreate(kLaneOpTrunc, value, narrow, &kNoName, cast);
            char *merged = api.userNew(96, 3);
            api.insertElement(merged, vector, value, api.constantIntGet(i32, k, false), &kNoName, cast);
            vector = merged;
        }
        api.replaceAllUsesWith(cast, vector);
        rewritten++;
    }
    return rewritten;
}

// The front end narrows 32-bit integer code to i8 / i16 when the values fit (`136u / (c[1] | 1u)` with c a uchar array
// becomes `udiv i8 -120, %c`). libAMDIL902 keeps such values in 32-bit registers without clearing or extending their
// upper bits: it widens a narrow constant by sign extension (the IL divides 0xFFFFFF88 by the zero-extended divisor),
// and a narrow value computed by 32-bit operations and truncated (`uchar(~x)`, kept in a register once job 11 has made
// a uchar array registers) goes into the division as it is. Operations whose result depends on those upper bits come
// out wrong (found by differential fuzzing; a uchar4 lane holding uchar(~x) divides wrong too). Each udiv / urem / sdiv
// / srem / lshr / ashr and each comparison on i8 / i16 scalars and 2- to 4-element vectors is done in i32 instead:
// scalar constants zero- or sign-extended as the operation needs, other operands through air.extract_bits (zero-
// extending, or sign-extending for the signed operations; the optimizer can't see through it and narrow back), the
// result truncated. AMD_NARROW_CONSTANT_FIX=0 turns this off.
enum { kOpcodeUDiv = 17, kOpcodeSDiv = 18, kOpcodeURem = 20, kOpcodeSRem = 21, kOpcodeTrunc = 36, kPredicateUGT = 34,
       kPredicateULE = 37, kPredicateSGT = 38, kPredicateSLE = 41 };
// A narrow (i8 / i16) value the back end holds exactly, nothing above its width: constants below the top bit (the back
// end sign-extends immediates: uchar 136 becomes -120), arguments, loads from memory (not private arrays, which live
// in registers with whatever a truncation left there), lanes of
// such vectors, zext, add / mul / shl that can't wrap (nuw), lshr / udiv / urem of an exact value, and / or / xor of
// exact values (and: either), phis and selects of exact values. What remains (trunc, sub, add without nuw, not, ...)
// can carry the garbage this job is for. Exact operands compare and divide right natively: rewriting them anyway keeps
// loop counters from being seen (the opaque extract_bits hides trip counts), and Apple's MPS kernels in Geekbench came
// out wrong and many times slower that way (ushort counters with `i == 4` exits, ushort2 thread positions).
enum { kOpcodeExtractElementValue = 59, kOpcodePHI = 53, kOpcodeOr2 = 27, kOpcodeXor2 = 28, kOpcodeMul2 = 15 };
static void *anyOperand(void *user, unsigned i) {  // fixed or hung-off (phi) operands
    if (!hungOffUses(user)) return operand(user, i);
    char *uses = *(char **)((char *)user - sizeof(void *));
    return *(void **)(uses + i * kUseSize);
}
static bool exactNarrow(void *v, void **stack, int depth) {
    if (depth >= 12) return false;
    unsigned char id = subclassID(v);
    uint64_t value;
    if (constantIntValue(v, &value)) return !((value >> (intBits(typeOf(v)) - 1)) & 1);  // immediates with the top bit set come out sign-extended
    if (id == kValueArgument) return true;
    if (isInstruction(v, kOpcodeZExt)) return true;
    if (isInstruction(v, kOpcodeLoad))  // memory loads zero-extend; private arrays live in registers, garbage included
        return (*(uint32_t *)((char *)typeOf(operand(v, 0)) + 8) >> 8) != 0;  // PointerType address space: SubclassData
    for (int d = 0; d < depth; d++) if (stack[d] == v) return true;  // a cycle through phis: the other inputs decide
    stack[depth] = v;
    unsigned n = numOperands(v);
    bool nuw = (*(unsigned char *)((char *)v + 17) >> 1) & 1;  // byte 17: HasValueHandle:1, SubclassOptionalData:7 (bit 0 there: NoUnsignedWrap)
    if (isInstruction(v, kOpcodeExtractElementValue)) return exactNarrow(operand(v, 0), stack, depth + 1);
    if ((isInstruction(v, kOpcodeAdd) || isInstruction(v, kOpcodeMul2) || isInstruction(v, kOpcodeShl)) && nuw)
        return exactNarrow(operand(v, 0), stack, depth + 1) && exactNarrow(operand(v, 1), stack, depth + 1);
    if (isInstruction(v, kOpcodeLShr) || isInstruction(v, kOpcodeUDiv) || isInstruction(v, kOpcodeURem))
        return exactNarrow(operand(v, 0), stack, depth + 1);
    if (isInstruction(v, kOpcodeAnd))
        return exactNarrow(operand(v, 0), stack, depth + 1) || exactNarrow(operand(v, 1), stack, depth + 1);
    if (isInstruction(v, kOpcodeOr2) || (isInstruction(v, kOpcodeXor2) && subclassID(operand(v, 1)) != kValueConstantInt))
        return exactNarrow(operand(v, 0), stack, depth + 1) && exactNarrow(operand(v, 1), stack, depth + 1);
    if (isInstruction(v, kOpcodeSelect)) return exactNarrow(operand(v, 1), stack, depth + 1) && exactNarrow(operand(v, 2), stack, depth + 1);
    if (isInstruction(v, kOpcodePHI)) {
        for (unsigned i = 0; i < n; i++) if (!exactNarrow(anyOperand(v, i), stack, depth + 1)) return false;
        return n > 0;
    }
    return false;
}

static unsigned narrowUnsignedConstants(void *module) {
    const char *setting = getenv("AMD_NARROW_CONSTANT_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.binaryCreate || !api.castCreate || !api.functionTypeGet || !api.getOrInsertFunction ||
        !api.vectorTypeGet)
        return 0;
    enum { kMax = 512 };
    static const unsigned kBinary[] = {kOpcodeUDiv, kOpcodeSDiv, kOpcodeURem, kOpcodeSRem, kOpcodeLShr, kOpcodeAShr};
    void *found[kMax];
    unsigned count = 0, rewritten = 0;
    void *i32 = NULL, *extract[2][5] = {{NULL}}, *extractType[5] = {NULL};  // [signed][lanes: 1 scalar, 2-4 vectors]
    char *functions = (char *)module + kModuleFunctions;
    for (char *fn = nextNode(functions); fn != functions; fn = nextNode(fn)) {
        char *function = fn - kFunctionNode, *blocks = function + kFunctionBlocks;
        if (*(void **)(function + kFunctionParent) != module) return 0;  // layout mismatch: leave the module alone
        if (nextNode(blocks) == blocks) continue;
        if (!i32) i32 = api.getInt32Ty(api.getContext(function));
        for (char *bn = nextNode(blocks); bn != blocks; bn = nextNode(bn)) {
            char *block = bn - kBlockNode, *insts = block + kBlockInstructions;
            if (*(void **)(block + kBlockParent) != function) return 0;
            for (char *in = nextNode(insts); in != insts; in = nextNode(in)) {
                char *inst = in - kInstructionNode;
                if (*(void **)(inst + kInstructionParent) != block) return 0;
                bool candidate = isInstruction(inst, kOpcodeICmp);
                for (size_t k = 0; k < sizeof kBinary / sizeof *kBinary && !candidate; k++) candidate = isInstruction(inst, kBinary[k]);
                if (!candidate || hungOffUses(inst) || numOperands(inst) != 2 || count == kMax) continue;
                void *type = typeOf(operand(inst, 0)), *element = type;
                if (typeID(type) == kTypeVector) {
                    if (arrayLength(type) < 2 || arrayLength(type) > 4) continue;
                    element = elementType(type);
                }
                if (typeID(element) != kTypeInteger) continue;
                unsigned width = *(uint32_t *)((char *)element + 8) >> 8;  // IntegerType bit width: Type SubclassData
                if (width != 8 && width != 16) continue;
                bool isSignedOp = isInstruction(inst, kOpcodeSDiv) || isInstruction(inst, kOpcodeSRem) || isInstruction(inst, kOpcodeAShr);
                if (isInstruction(inst, kOpcodeICmp)) {
                    unsigned p = *(uint16_t *)(inst + 0x12) & kOpcodeICmpPredicateMask;
                    isSignedOp = p >= kPredicateSGT && p <= kPredicateSLE;
                }
                void *stack[12];
                if (!isSignedOp && exactNarrow(operand(inst, 0), stack, 0) && exactNarrow(operand(inst, 1), stack, 0)) continue;
                found[count++] = inst;
            }
        }
    }
    for (unsigned c = 0; c < count; c++) {
        void *inst = found[c], *type = typeOf(operand(inst, 0)), *element = type, *wide[2];
        unsigned lanes = 1;
        if (typeID(type) == kTypeVector) {
            lanes = (unsigned)arrayLength(type);
            element = elementType(type);
        }
        void *wideType = lanes > 1 ? api.vectorTypeGet(i32, lanes) : i32;
        unsigned width = *(uint32_t *)((char *)element + 8) >> 8, predicate = 0, opcode = 0;
        bool compare = isInstruction(inst, kOpcodeICmp), isSigned;
        if (compare) {
            predicate = *(uint16_t *)((char *)inst + 0x12) & kOpcodeICmpPredicateMask;
            isSigned = predicate >= kPredicateSGT && predicate <= kPredicateSLE;
        } else {
            for (size_t k = 0; k < sizeof kBinary / sizeof *kBinary; k++)
                if (isInstruction(inst, kBinary[k])) opcode = kBinary[k];
            isSigned = opcode == kOpcodeSDiv || opcode == kOpcodeSRem || opcode == kOpcodeAShr;
        }
        for (int k = 0; k < 2; k++) {
            bool extendSigned = isSigned && !(opcode == kOpcodeAShr && k == 1);  // a shift amount is unsigned
            uint64_t value;
            void *v = operand(inst, k);
            if (lanes == 1 && constantIntValue(v, &value)) {
                value &= (1ull << width) - 1;
                if (extendSigned && (value >> (width - 1)) & 1) value |= ~((1ull << width) - 1);
                wide[k] = api.constantIntGet(i32, value & 0xffffffffu, false);
                continue;
            }
            int s = extendSigned ? 1 : 0;
            if (!extract[s][lanes]) {
                if (!extractType[lanes]) {
                    void *params[3] = {wideType, i32, i32};
                    extractType[lanes] = api.functionTypeGet(wideType, params, 3, false);
                }
                char name[40];
                if (lanes > 1) snprintf(name, sizeof name, "air.extract_bits.%c.v%ui32", s ? 's' : 'u', lanes);
                else snprintf(name, sizeof name, "air.extract_bits.%c.i32", s ? 's' : 'u');
                extract[s][lanes] = api.getOrInsertFunction(module, name, strlen(name), extractType[lanes]);
                if (!extract[s][lanes] || subclassID(extract[s][lanes]) != kValueFunction) return rewritten;  // a bitcast: another declaration
            }
            void *args[3] = {api.castCreate(kOpcodeZExt, v, wideType, &kNoName, inst), api.constantIntGet(i32, 0, false), api.constantIntGet(i32, width, false)};
            wide[k] = createCall(extract[s][lanes], extractType[lanes], args, 3, inst);
        }
        void *result = compare ? api.cmpCreate(kOpcodeICmp, predicate, wide[0], wide[1], &kNoName, inst)
                               : api.castCreate(kOpcodeTrunc, api.binaryCreate(opcode, wide[0], wide[1], &kNoName, inst), type, &kNoName, inst);
        api.replaceAllUsesWith(inst, result);
        api.eraseFromParent(inst);
        rewritten++;
    }
    return rewritten;
}

// A 64-bit comparison whose result is sign-extended or branched on (`x -= (uint)(bool)(w & m)` with w a ulong, or `if`
// on one) stops libAMDIL902 with "Cannot select": its setcc on i64 operands has an i64 result, which no select or brcond
// pattern takes (found by fuzzing with 64-bit integers). So every i64 comparison is done on the 32-bit halves:
// equality as (lo ^ lo') | (hi ^ hi') against 0, an ordered comparison as the high halves compared (signed or unsigned
// as asked), or equal high halves and the low halves compared unsigned. AMD_WIDE_COMPARE_FIX=0 turns this off. Test a20.
enum { kWideXor = 28, kPredicateUGE = 35, kPredicateSGE = 39, kPredicateSLT = 40 };
static unsigned wideCompares(void *module) {
    const char *setting = getenv("AMD_WIDE_COMPARE_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.binaryCreate || !api.castCreate || !api.getInt64Ty) return 0;
    enum { kMax = 512 };
    void *found[kMax];
    unsigned count = 0, rewritten = 0;
    char *functions = (char *)module + kModuleFunctions;
    for (char *fn = nextNode(functions); fn != functions; fn = nextNode(fn)) {
        char *function = fn - kFunctionNode, *blocks = function + kFunctionBlocks;
        if (*(void **)(function + kFunctionParent) != module) return 0;  // layout mismatch: leave the module alone
        for (char *bn = nextNode(blocks); bn != blocks; bn = nextNode(bn)) {
            char *block = bn - kBlockNode, *insts = block + kBlockInstructions;
            if (*(void **)(block + kBlockParent) != function) return 0;
            for (char *in = nextNode(insts); in != insts; in = nextNode(in)) {
                char *inst = in - kInstructionNode;
                if (*(void **)(inst + kInstructionParent) != block) return 0;
                if (!isInstruction(inst, kOpcodeICmp) || hungOffUses(inst) || numOperands(inst) != 2 || count == kMax) continue;
                void *type = typeOf(operand(inst, 0));
                if (typeID(type) == kTypeInteger && intBits(type) == 64) found[count++] = inst;
            }
        }
    }
    for (unsigned c = 0; c < count; c++) {
        void *inst = found[c], *i64 = typeOf(operand(inst, 0)), *i32 = api.getInt32Ty(api.getContext(inst));
        unsigned predicate = *(unsigned short *)((char *)inst + 0x12) & kOpcodeICmpPredicateMask;  // CmpInst predicate: SubclassData
        void *lo[2], *hi[2];
        for (unsigned k = 0; k < 2; k++) {
            void *v = operand(inst, k);
            lo[k] = api.castCreate(kOpcodeTrunc, v, i32, &kNoName, inst);
            hi[k] = api.castCreate(kOpcodeTrunc, api.binaryCreate(kOpcodeLShr, v, api.constantIntGet(i64, 32, false), &kNoName, inst), i32, &kNoName, inst);
        }
        void *result;
        if (predicate == kPredicateEQ || predicate == kPredicateNE) {
            void *diff = api.binaryCreate(kOpcodeOrBits, api.binaryCreate(kWideXor, lo[0], lo[1], &kNoName, inst),
                                          api.binaryCreate(kWideXor, hi[0], hi[1], &kNoName, inst), &kNoName, inst);
            result = api.cmpCreate(kOpcodeICmp, predicate, diff, api.constantIntGet(i32, 0, false), &kNoName, inst);
        } else if (predicate >= kPredicateUGT && predicate <= kPredicateSLE) {
            bool isSigned = predicate >= kPredicateSGT;
            unsigned unsignedForm = isSigned ? predicate - 4 : predicate;              // SGT..SLE -> UGT..ULE
            unsigned strict = (unsignedForm == kPredicateUGE) ? kPredicateUGT : (unsignedForm == kPredicateULE) ? kPredicateULT : unsignedForm;
            unsigned highStrict = isSigned ? strict + 4 : strict;
            void *higher = api.cmpCreate(kOpcodeICmp, highStrict, hi[0], hi[1], &kNoName, inst);
            void *same = api.cmpCreate(kOpcodeICmp, kPredicateEQ, hi[0], hi[1], &kNoName, inst);
            void *low = api.cmpCreate(kOpcodeICmp, unsignedForm, lo[0], lo[1], &kNoName, inst);
            result = api.binaryCreate(kOpcodeOrBits, higher, api.binaryCreate(kOpcodeAndBits, same, low, &kNoName, inst), &kNoName, inst);
        } else continue;
        api.replaceAllUsesWith(inst, result);
        api.eraseFromParent(inst);
        rewritten++;
    }
    return rewritten;
}

// A branch on one bit of a 64-bit value (`(x >> 16) & 1 ? a : b` with x a ulong, or a switch on `uint(x >> 16) & 3`,
// which the switch lowering splits on bit 0) stops compilation with "LLVM ERROR: Cannot select: brcond (i64 setcc ...)":
// libAMDIL902's DAG combiner turns `brcond (trunc (srl (and x, 2^k), k))` into a compare of the 64-bit `and` with 0,
// whose result type is i64 on this target, and its brcond patterns only take a 32-bit condition (found by fuzzing
// with 64-bit integers; wideCompares splits the i64 comparisons in the IR, these the combiner makes itself). The DAG
// is built per block, so only conditions worked out in the branch's own block from a 64-bit instruction or argument
// need it: a conditional branch's condition is tested through `extract_bits(zext c, 0, 1) != 0`, and a 32-bit switch
// value goes through extract_bits (`extract_bits(x, 0, w)` for `x & (2^w - 1)`, else as two 16-bit halves), which the
// combiner doesn't look into. Code without 64-bit integers is left alone. AMD_WIDE_BRANCH_FIX=0 turns this off.
// Test a21.
enum { kOpcodeBr = 2, kOpcodeSwitch = 3, kOpcodeInsertElement = 60 };
static bool fromWide(void *v, void *block, int depth) {  // a 64-bit instruction or argument (not a constant) feeds v
    void *type = typeOf(v);
    unsigned char id = subclassID(v);
    if (typeID(type) == kTypeInteger && intBits(type) == 64) return id >= kValueInstruction || id == kValueArgument;
    if (depth >= 8 || id < kValueInstruction || *(void **)((char *)v + kInstructionParent) != block) return false;
    if (isInstruction(v, kOpcodePHI) || isInstruction(v, kOpcodeCall) || isInstruction(v, kOpcodeLoad) || hungOffUses(v)) return false;
    unsigned n = numOperands(v);
    if (isInstruction(v, kOpcodeExtractElement) || isInstruction(v, kOpcodeInsertElement)) n--;  // not the lane index
    for (unsigned i = 0; i < n; i++)
        if (fromWide(operand(v, i), block, depth + 1)) return true;
    return false;
}
static unsigned wideBitBranches(void *module) {
    const char *setting = getenv("AMD_WIDE_BRANCH_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.binaryCreate || !api.castCreate || !api.cmpCreate || !api.functionTypeGet ||
        !api.getOrInsertFunction || !api.replaceUsesOfWith)
        return 0;
    enum { kMax = 512 };
    void *found[kMax];
    unsigned count = 0, rewritten = 0;
    char *functions = (char *)module + kModuleFunctions;
    for (char *fn = nextNode(functions); fn != functions; fn = nextNode(fn)) {
        char *function = fn - kFunctionNode, *blocks = function + kFunctionBlocks;
        if (*(void **)(function + kFunctionParent) != module) return 0;  // layout mismatch: leave the module alone
        for (char *bn = nextNode(blocks); bn != blocks; bn = nextNode(bn)) {
            char *block = bn - kBlockNode, *insts = block + kBlockInstructions;
            if (*(void **)(block + kBlockParent) != function) return 0;
            char *last = prevNode(insts);  // the sentinel's Prev: the block's last instruction
            if (last == insts || count == kMax) continue;
            char *term = last - kInstructionNode;
            if (*(void **)(term + kInstructionParent) != block) return 0;
            bool branch = isInstruction(term, kOpcodeBr) && !hungOffUses(term) && numOperands(term) == 3;
            bool sw = isInstruction(term, kOpcodeSwitch) && hungOffUses(term);
            if (!branch && !sw) continue;
            void *cond = anyOperand(term, 0), *type = typeOf(cond);
            if (sw && (typeID(type) != kTypeInteger || intBits(type) != 32)) continue;  // i64 switches: not seen, not handled
            if (subclassID(cond) < kValueInstruction || !fromWide(cond, block, 0)) continue;
            found[count++] = term;
        }
    }
    if (!count) return 0;
    void *i32 = api.getInt32Ty(api.getContext(found[0]));
    void *params[3] = {i32, i32, i32};
    void *extractType = api.functionTypeGet(i32, params, 3, false);
    void *extract = api.getOrInsertFunction(module, "air.extract_bits.u.i32", strlen("air.extract_bits.u.i32"), extractType);
    if (!extract || subclassID(extract) != kValueFunction) return 0;  // a bitcast: another declaration
    for (unsigned c = 0; c < count; c++) {
        void *term = found[c], *cond = anyOperand(term, 0), *replacement;
        if (isInstruction(term, kOpcodeBr)) {
            void *args[3] = {api.castCreate(kOpcodeZExt, cond, i32, &kNoName, term), api.constantIntGet(i32, 0, false),
                             api.constantIntGet(i32, 1, false)};
            replacement = api.cmpCreate(kOpcodeICmp, kPredicateNE, createCall(extract, extractType, args, 3, term),
                                        api.constantIntGet(i32, 0, false), &kNoName, term);
        } else {
            uint64_t mask = 0;
            if (isInstruction(cond, kOpcodeAnd) && !hungOffUses(cond) && numOperands(cond) == 2 && constantIntValue(operand(cond, 1), &mask) &&
                mask && mask < 0xffffffffu && !(mask & (mask + 1))) {
                void *args[3] = {operand(cond, 0), api.constantIntGet(i32, 0, false), api.constantIntGet(i32, (uint64_t)__builtin_popcountll(mask), false)};
                replacement = createCall(extract, extractType, args, 3, term);
            } else {  // the whole value, as two 16-bit halves
                void *lo[3] = {cond, api.constantIntGet(i32, 0, false), api.constantIntGet(i32, 16, false)};
                void *hi[3] = {cond, api.constantIntGet(i32, 16, false), api.constantIntGet(i32, 16, false)};
                void *high = api.binaryCreate(kOpcodeShl, createCall(extract, extractType, hi, 3, term), api.constantIntGet(i32, 16, false), &kNoName, term);
                replacement = api.binaryCreate(kOpcodeOrBits, createCall(extract, extractType, lo, 3, term), high, &kNoName, term);
            }
        }
        api.replaceUsesOfWith(term, cond, replacement);
        rewritten++;
    }
    return rewritten;
}

// A signed division or remainder whose dividend is 32 bits cut from the middle of a 64-bit value, `(int)uint(x >> k) / c`
// with 0 < k < 32, comes out as the unsigned one (`(int)uint(x >> 31) / 65535` gives uint(x >> 31) / 65535 for
// negative dividends, and / -3 is as wrong): found by fuzzing with 64-bit integers. Built from the halves,
// `(uint(x) >> k) | (uint(x >> 32) << (32 - k))`, the same value divides right (anything between the cut and the
// division, an xor or a select, does too). So such dividends are built that way. AMD_SHIFTED_DIVIDEND_FIX=0 turns this
// off. Test a22.
static unsigned shiftedDividends(void *module) {
    const char *setting = getenv("AMD_SHIFTED_DIVIDEND_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.binaryCreate || !api.castCreate || !api.replaceUsesOfWith) return 0;
    enum { kMax = 512 };
    void *found[kMax];
    unsigned count = 0, rewritten = 0;
    char *functions = (char *)module + kModuleFunctions;
    for (char *fn = nextNode(functions); fn != functions; fn = nextNode(fn)) {
        char *function = fn - kFunctionNode, *blocks = function + kFunctionBlocks;
        if (*(void **)(function + kFunctionParent) != module) return 0;  // layout mismatch: leave the module alone
        for (char *bn = nextNode(blocks); bn != blocks; bn = nextNode(bn)) {
            char *block = bn - kBlockNode, *insts = block + kBlockInstructions;
            if (*(void **)(block + kBlockParent) != function) return 0;
            for (char *in = nextNode(insts); in != insts; in = nextNode(in)) {
                char *inst = in - kInstructionNode;
                if (*(void **)(inst + kInstructionParent) != block) return 0;
                if ((!isInstruction(inst, kOpcodeSDiv) && !isInstruction(inst, kOpcodeSRem)) || hungOffUses(inst) || numOperands(inst) != 2 ||
                    count == kMax)
                    continue;
                void *cut = operand(inst, 0), *type = typeOf(inst), *shift;
                uint64_t k;
                if (typeID(type) != kTypeInteger || intBits(type) != 32 || !isInstruction(cut, kOpcodeTrunc) || hungOffUses(cut) ||
                    numOperands(cut) != 1)
                    continue;
                shift = operand(cut, 0);
                if ((!isInstruction(shift, kOpcodeLShr) && !isInstruction(shift, kOpcodeAShr)) || hungOffUses(shift) || numOperands(shift) != 2 ||
                    intBits(typeOf(shift)) != 64 || !constantIntValue(operand(shift, 1), &k) || k == 0 || k >= 32)
                    continue;
                found[count++] = inst;
            }
        }
    }
    for (unsigned c = 0; c < count; c++) {
        void *inst = found[c], *cut = operand(inst, 0), *shift = operand(cut, 0), *x = operand(shift, 0);
        void *i32 = typeOf(inst), *i64 = typeOf(x);
        uint64_t k;
        constantIntValue(operand(shift, 1), &k);
        void *lo = api.castCreate(kOpcodeTrunc, x, i32, &kNoName, inst);
        void *hi = api.castCreate(kOpcodeTrunc, api.binaryCreate(kOpcodeLShr, x, api.constantIntGet(i64, 32, false), &kNoName, inst), i32, &kNoName, inst);
        void *value = api.binaryCreate(kOpcodeOrBits, api.binaryCreate(kOpcodeLShr, lo, api.constantIntGet(i32, k, false), &kNoName, inst),
                                       api.binaryCreate(kOpcodeShl, hi, api.constantIntGet(i32, 32 - k, false), &kNoName, inst), &kNoName, inst);
        api.replaceUsesOfWith(inst, cut, value);
        rewritten++;
    }
    return rewritten;
}

static unsigned singleBitTests(void *module) {
    const char *setting = getenv("AMD_BIT_TEST_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.functionTypeGet || !api.getOrInsertFunction) return 0;
    unsigned rewritten = 0;
    char *functions = (char *)module + kModuleFunctions;
    for (char *fn = nextNode(functions); fn != functions; fn = nextNode(fn)) {
        char *function = fn - kFunctionNode, *blocks = function + kFunctionBlocks;
        if (*(void **)(function + kFunctionParent) != module) return rewritten;  // layout mismatch: leave the module alone
        if (nextNode(blocks) == blocks) continue;
        rewritten += singleBitTestsAsExtracts(module, function, api.getInt32Ty(api.getContext(function)));
    }
    return rewritten;
}

// The front end in Xcode 26 writes a constexpr sampler (!air.sampler_states) as a [2 x i64] constant: the sampler word with
// bit 63 clear, then 0. Older front ends, including the runtime compiler that libAMDIL902 was built with, write one i64:
// the same word with bit 63 set. ILSetupConstantSampler turns the global's initializer into an integer-to-pointer
// constant, which only works with the one-word form, so such a sampler reads as 0 (i05: a clamp-to-edge read returns 0).
// Each such global gets the one-word initializer. The global keeps its declared type: ILSetupConstantSampler only reads
// the initializer and then erases the global. AMD_SAMPLER_STATE_FIX=0 turns this off.
// Metadata (LLVM 5): kind u8 @0; MDNode: NumOperands u32 @8, operands (Metadata *) right before the node;
// ConstantAsMetadata (kind 1): Value * @0x80, after Metadata (8 bytes) and its ReplaceableMetadataImpl base (Context,
// NextIndex, a SmallDenseMap with 4 inline buckets: 120 bytes). The global found there must name this module as its
// parent. ConstantDataSequential: DataElements @24.
enum { kMDNodeNumOperands = 8, kConstantAsMetadataKind = 1, kValueAsMetadataValue = 0x80, kConstantDataElements = 24 };
static unsigned twoWordSamplerStates(void *module) {
    const char *setting = getenv("AMD_SAMPLER_STATE_FIX");
    if ((setting && !strcmp(setting, "0")) || !api.getNamedMetadata || !api.namedMDNumOperands || !api.namedMDGetOperand ||
        !api.setInitializer)
        return 0;
    Twine name = {"air.sampler_states", NULL, kTwineCString, kTwineEmpty};
    void *states = api.getNamedMetadata(module, &name);
    if (!states) return 0;
    unsigned fixed = 0;
    void *i64 = NULL;
    for (unsigned i = 0, n = api.namedMDNumOperands(states); i < n; i++) {
        char *node = api.namedMDGetOperand(states, i);  // !{!"air.sampler_state", [2 x i64] addrspace(2)* @sampler}
        if (!node || *(uint32_t *)(node + kMDNodeNumOperands) != 2) continue;
        char *global = ((char **)node)[-1];
        if (!global || *(unsigned char *)global != kConstantAsMetadataKind) continue;
        global = *(char **)(global + kValueAsMetadataValue);
        if (!global || *(void **)(global + kFunctionParent) != module) continue;  // GlobalValue::Parent, as for functions
        if (hungOffUses(global) || numOperands(global) != 1) continue;  // a global with an initializer
        char *words = operand(global, 0);
        void *type = words ? typeOf(words) : NULL;
        if (!i64 && type) i64 = api.getInt64Ty(api.getContext(global));
        if (!type || typeID(type) != kTypeArray || arrayLength(type) != 2 || elementType(type) != i64) continue;
        const uint64_t *data = *(const uint64_t **)(words + kConstantDataElements);
        if (!data || (data[0] >> 63) || data[1]) continue;  // not the two-word form described above
        api.setInitializer(global, api.constantIntGet(i64, data[0] | 1ull << 63, false));
        fixed++;
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
        unsigned nanSafe = keepCompareNaNs(module);
        if (nanSafe && logging()) fprintf(stderr, "[texatomic] %u function(s) compiled with NaN-safe compares\n", nanSafe);
        unsigned ldexps = ldexpHalfAsFloat(module);
        if (ldexps && logging()) fprintf(stderr, "[texatomic] %u half ldexp call(s) computed as float\n", ldexps);
        unsigned gathers = shiftIntegerGatherCoords(module);
        if (gathers && logging()) fprintf(stderr, "[texatomic] %u integer gather(s): coordinates shifted half a texel\n", gathers);
        unsigned cubeGathers = cubeIntegerGathers(module);
        if (cubeGathers && logging()) fprintf(stderr, "[texatomic] %u integer cube gather(s): 4 samples each\n", cubeGathers);
        unsigned cubeArrays = clampCubeArrayIndices(module);
        if (cubeArrays && logging()) fprintf(stderr, "[texatomic] %u cube array index(es) clamped\n", cubeArrays);
        unsigned bools = loadThreadgroupBoolsAsBytes(module);
        if (bools && logging()) fprintf(stderr, "[texatomic] %u threadgroup bool load(s) done as bytes\n", bools);
        unsigned samplers = twoWordSamplerStates(module);
        if (samplers && logging()) fprintf(stderr, "[texatomic] %u constexpr sampler(s) rewritten in the one-word form\n", samplers);
        unsigned unpacks = exactUnpackNorm(module);
        if (unpacks && logging()) fprintf(stderr, "[texatomic] %u unpack call(s) computed exactly\n", unpacks);
        unsigned floats = floatAtomicsAsInteger(module);
        if (floats && logging()) fprintf(stderr, "[texatomic] %u float atomic(s) done on the integer bits\n", floats);
        unsigned wide = wideCompares(module);
        if (wide && logging()) fprintf(stderr, "[texatomic] %u 64-bit comparison(s) done on the 32-bit halves\n", wide);
        unsigned wideBranches = wideBitBranches(module);
        if (wideBranches && logging()) fprintf(stderr, "[texatomic] %u branch(es) on bits of a 64-bit value tested through extract_bits\n", wideBranches);
        unsigned dividends = shiftedDividends(module);
        if (dividends && logging()) fprintf(stderr, "[texatomic] %u signed division(s) of a cut 64-bit value: dividend built from the halves\n", dividends);
        unsigned lanes = bitcastLaneExtracts(module);
        if (lanes && logging()) fprintf(stderr, "[texatomic] %u vector bitcast(s) to narrower lanes built lane by lane\n", lanes);
        unsigned narrow = narrowUnsignedConstants(module);
        if (narrow && logging()) fprintf(stderr, "[texatomic] %u narrow division(s), shift(s) or comparison(s) done in 32 bits\n", narrow);
        unsigned bitTests = singleBitTests(module);
        if (bitTests && logging()) fprintf(stderr, "[texatomic] %u single-bit test(s) done as bit-field extracts\n", bitTests);
        unsigned saturating = plainSaturatingAddSub(module);
        if (saturating && logging()) fprintf(stderr, "[texatomic] %u unsigned saturating add/sub call(s) done as arithmetic\n", saturating);
        unsigned rotates = rotatesAsShifts(module);
        if (rotates && logging()) fprintf(stderr, "[texatomic] %u rotate call(s) done as shifts\n", rotates);
        unsigned arrayStores = privateArrayIndexedStores(module);
        if (arrayStores && logging()) fprintf(stderr, "[texatomic] %u variable-index private array store(s) done per element\n", arrayStores);
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

// See shiftIntegerGatherCoords: fetch4 on integer textures takes the normalized coordinates the shader computed.
static int normalizeFetch4(char *il) {
    static const char kFetch4[] = "fetch4", kUnnormalized[] = "coordtype(unnormalized)";
    int n = 0;
    for (char *p = il; (p = strstr(p, kFetch4)); p += sizeof kFetch4 - 1) {
        char *eol = strchr(p, '\n'), *c = strstr(p, kUnnormalized);
        if (!c || (eol && c > eol)) continue;
        c += strlen("coordtype(");
        memmove(c, c + 2, strlen(c + 2) + 1);  // "unnormalized" -> "normalized"
        if (eol) eol -= 2;
        n++;
    }
    return n;
}

// The eighth job's driver check: only the 12.5-24 copy of AMDMTLBronzeDriver links OCLP's impostor.dylib.
static bool fmaskFixEnabled(void) {
    const char *setting = getenv("AMD_FMASK_FIX");
    if (setting) return strcmp(setting, "0") != 0;
    static int installed = -1;
    if (installed < 0)
        installed = !access("/System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/impostor.dylib", F_OK);
    return installed;
}

// Each FMASK lookup (`load_fptr... rD.mask, coords, imgDescN, samDescN`) becomes the identity map, which SC folds into
// the sample index, so the shader no longer loads the FMASK descriptor.
static int identityFmaskLookups(const char *in, Text *out) {
    static const char kIdentity[] = ", 0x76543210, 0x76543210, 0x76543210, 0x76543210\n";
    int n = 0;
    for (const char *p = in; *p;) {
        const char *eol = strchr(p, '\n');
        size_t length = eol ? (size_t)(eol - p + 1) : strlen(p);
        const char *op = p + strspn(p, " \t");  // indented inside loops and branches
        const char *space = strchr(op, ' '), *comma = space ? strchr(space, ',') : NULL;
        if (!strncmp(op, "load_fptr", 9) && comma && comma < p + length) {
            append(out, p, op - p);
            append(out, "mov_lit", 7);
            append(out, space, comma - space);
            append(out, kIdentity, sizeof kIdentity - 1);
            n++;
        } else {
            append(out, p, length);
        }
        p += length;
    }
    return n;
}

// SC's code for a loop that ends in
//     if_logicalnz c            ; or if_logicalz
//         ...  break_logicalz a  continue
//     else
//         ...  break_logicalz b  continue
//     endif
//   endloop
// (what libAMDIL902 makes of `while (n < 8) { n++; ...; if (odd && x) break; }`) is wrong once the threads diverge: when
// some threads leave through the first branch's break, SC sets exec to the threads still in the loop and then falls into
// the else branch's mask computation, which takes those as the first branch's threads, so the else branch runs for none
// of them that iteration; they skip its exit check and run the loop once more (found by differential fuzzing; a barrier
// before the loop is enough to get this layout). The continues are redundant there (endloop follows), so each branch
// sets a flag instead and one break follows the endif:
//     if_logicalnz c  ...  mov f, a  else  ...  mov f, b  endif  break_logicalz f  endloop
// A branch without a break sets the flag to "stay". Both branches' breaks must test the same way. AMD_LOOP_EXIT_FIX=0
// turns this off.
static int ilIndent(const char *line) { return (int)strspn(line, " "); }
static bool ilIs(const char *line, const char *word) {
    const char *t = line + ilIndent(line);
    size_t n = strlen(word);
    return !strncmp(t, word, n) && (t[n] == 0 || t[n] == ' ');
}
static int singleLoopExits(const char *in, Text *out) {
    const char *setting = getenv("AMD_LOOP_EXIT_FIX");
    if ((setting && !strcmp(setting, "0")) || !strstr(in, "continue")) return 0;
    char *copy = strdup(in);
    size_t count = 0, cap = 1024;
    char **lines = malloc(cap * sizeof *lines);
    for (char *save, *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (count == cap) lines = realloc(lines, (cap *= 2) * sizeof *lines);
        lines[count++] = line;
    }
    unsigned maxReg = 0;  // a free temporary for the flags: above every r<n> under the special r8192+
    for (const char *p = in; (p = strchr(p, 'r'));) {
        p++;
        if (p[-2] != ' ' && p[-2] != ',' && p[-2] != '(') continue;
        unsigned r = (unsigned)strtoul(p, NULL, 10);
        if (r < 8192 && r > maxReg) maxReg = r;
    }
    unsigned flag = maxReg + 1;
    // per line: 0 keep, 1 drop, 2 replace with replacement[i]; extra[i]: a line to add after line i
    char *action = calloc(count, 1), **replacement = calloc(count, sizeof *replacement), **extra = calloc(count, sizeof *extra);
    int n = 0;
    for (size_t i = 0; i < count && flag < 8192; i++) {
        if (!ilIs(lines[i], "if_logicalnz") && !ilIs(lines[i], "if_logicalz")) continue;
        int ind = ilIndent(lines[i]);
        size_t elseLine = 0, endifLine = 0;
        for (size_t j = i + 1; j < count; j++) {
            int k = ilIndent(lines[j]);
            if (k < ind) break;
            if (k > ind) continue;
            if (!elseLine && ilIs(lines[j], "else")) { elseLine = j; continue; }
            if (ilIs(lines[j], "endif")) endifLine = j;
            break;
        }
        if (!elseLine || !endifLine || endifLine + 1 >= count || !ilIs(lines[endifLine + 1], "endloop") ||
            ilIndent(lines[endifLine + 1]) != ind - 4)
            continue;
        size_t ends[2] = {elseLine - 1, endifLine - 1}, starts[2] = {i + 1, elseLine + 1};
        bool ok = true;
        const char *breakOp = NULL, *operand[2] = {NULL, NULL};
        for (int b = 0; b < 2 && ok; b++) {
            size_t e = ends[b];
            ok = e >= starts[b] && ilIndent(lines[e]) == ind + 4 && ilIs(lines[e], "continue");
            if (!ok) break;
            if (e > starts[b] && ilIndent(lines[e - 1]) == ind + 4 && (ilIs(lines[e - 1], "break_logicalz") || ilIs(lines[e - 1], "break_logicalnz"))) {
                const char *t = lines[e - 1] + ilIndent(lines[e - 1]);
                const char *op = ilIs(lines[e - 1], "break_logicalz") ? "break_logicalz" : "break_logicalnz";
                if (breakOp && strcmp(breakOp, op)) ok = false;
                breakOp = op;
                operand[b] = t + strlen(op) + 1;
            }
        }
        if (!ok) continue;
        for (int b = 0; b < 2; b++) {
            size_t e = ends[b];
            action[e] = 1;  // the continue
            if (!breakOp) continue;
            char *line = malloc(160);
            if (operand[b]) {
                snprintf(line, 160, "%*smov r%u.x___, %s", ind + 4, "", flag, operand[b]);
                action[e - 1] = 2;
                replacement[e - 1] = line;
            } else {  // stays in the loop: break_logicalz needs nonzero, break_logicalnz zero
                snprintf(line, 160, "%*smov_lit r%u.x___, %s, 0x00000000, 0x00000000, 0x00000000", ind + 4, "", flag,
                         !strcmp(breakOp, "break_logicalz") ? "0xFFFFFFFF" : "0x00000000");
                action[e] = 2;
                replacement[e] = line;
            }
        }
        if (breakOp) {
            char *line = malloc(96);
            snprintf(line, 96, "%*s%s r%u.x", ind, "", breakOp, flag);
            extra[endifLine] = line;
            flag++;
        }
        n++;
    }
    if (n)
        for (size_t i = 0; i < count; i++) {
            if (action[i] != 1) {
                const char *line = action[i] == 2 ? replacement[i] : lines[i];
                append(out, line, strlen(line));
                append(out, "\n", 1);
            }
            if (extra[i]) {
                append(out, extra[i], strlen(extra[i]));
                append(out, "\n", 1);
            }
        }
    for (size_t i = 0; i < count; i++) {
        free(replacement[i]);
        free(extra[i]);
    }
    free(action);
    free(replacement);
    free(extra);
    free(lines);
    free(copy);
    return n;
}

static int hookedSCCompileShader(void *sc, void *src, void *out) {
    void **tokens = (void **)((char *)src + kSrcTokens);
    uint32_t *size = (uint32_t *)((char *)src + kSrcSize);
    Text il = {0};
    SCDumpILShader(&il, *tokens, *size, appendFormatted);
    int fmasks = 0;
    if (il.buf && strstr(il.buf, "load_fptr") && fmaskFixEnabled()) {
        Text identity = {0};
        fmasks = identityFmaskLookups(il.buf, &identity);
        free(il.buf);
        il = identity;
    }
    const char *ldsSetting = getenv("AMD_LDS_BASE_FIX");
    bool atomics = il.buf && (strstr(il.buf, "0x7A70") || strstr(il.buf, "0x7A71"));
    bool ldsBase = scFamily == kFamilySI && il.buf && !strncmp(il.buf, "il_cs", 5) && strstr(il.buf, "dcl_lds_id(") &&
                   strstr(il.buf, kThreadgroupBaseSlot) && !(ldsSetting && !strcmp(ldsSetting, "0"));
    int gathers = il.buf && gatherFixEnabled() ? normalizeFetch4(il.buf) : 0;
    Text exits = {0};
    int loops = il.buf ? singleLoopExits(il.buf, &exits) : 0;
    if (loops) {
        free(il.buf);
        il = exits;
    }
    if (atomics || ldsBase || gathers || fmasks || loops) {
        Text edited = {0}, based = {0};
        int n = atomics ? rewriteIL(il.buf, &edited) : 0;
        if (atomics && n == 0) atomics = false;  // "0x7A70" / "0x7A71" in an unrelated constant (0x7A71AD9B): no tags
        int k = ldsBase && (!atomics || n > 0) ? dropThreadgroupBase(atomics ? edited.buf : il.buf, &based) : 0;
        const char *text = k > 0 ? based.buf : atomics && n > 0 ? edited.buf : gathers || fmasks || loops ? il.buf : NULL;
        void *binary = NULL;
        unsigned dwords = 0;
        int ok = text ? ilXltTextToBinary(text, &binary, &dwords) : 0;
        if (logging()) {
            if (atomics) fprintf(stderr, "[texatomic] IL: %d texture atomic(s) rewritten\n", n);
            if (k) fprintf(stderr, "[texatomic] IL: %d threadgroup address(es): data-segment base (API slot 8) dropped\n", k);
            if (gathers) fprintf(stderr, "[texatomic] IL: %d integer gather(s) use normalized coordinates\n", gathers);
            if (fmasks) fprintf(stderr, "[texatomic] IL: %d multisample read(s) without FMASK\n", fmasks);
            if (loops) fprintf(stderr, "[texatomic] IL: %d loop(s) given a single exit\n", loops);
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
