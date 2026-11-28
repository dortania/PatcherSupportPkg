// LLVM 3.8 helpers shared by the Intel and Kepler adapters, whose compiler plugins link Apple's libLLVM 3802: object
// layouts the C API doesn't expose, metadata access, the PassManager::run import redirect and the inline asm walk.
#pragma once
#include "LLVMC.h"
#include <cstring>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <vector>

// ---- LLVM 3.8 object layouts -----------------------------------------------------------------------------------------
// Fields read where the C API has no accessor, laid out as in the LLVM that Apple's Intel plugin links (libLLVM3802).
namespace llvm38 {
enum ValueId : unsigned char {
    kFunctionValue = 5, kFirstInstruction = 0x18, kLoadInstruction = 0x36, kStoreInstruction = 0x37,
    kGEPInstruction = 0x38, kCallInstruction = 0x4e
};
inline unsigned char valueId(const void *value) { return ((const unsigned char *)value)[0x18]; }
inline const char *firstUse(const char *value) { return *(const char *const *)(value + 0x10); }
inline const char *nextUse(const char *use) { return *(const char *const *)(use + 8); }
const size_t kUseSize = 24;  // a User's operands (Uses) lie just before it
inline unsigned operandCount(const char *user) { return *(const uint32_t *)(user + 0x1c) & 0xfffffff; }
inline const char *operand(const char *user, unsigned i) {
    return *(const char *const *)(user - kUseSize * (size_t)(operandCount(user) - i));
}
inline const char *lastOperand(const char *user) { return *(const char *const *)(user - kUseSize); }
inline void *wrappedMetadata(LLVMValueRef metadataAsValue) { return *(void **)((char *)metadataAsValue + 0x20); }
inline unsigned mdNodeOperandCount(void *node) { return *(unsigned *)((char *)node + 8); }
// SelectionDAG nodes; operands are 0x28-byte SDUses, each starting with its SDValue
struct SDValue { char *node; unsigned resno; };
struct EVT { unsigned char simple; void *type; };
const size_t kSDUseSize = 0x28;
inline unsigned short sdOpcode(const char *node) { return *(unsigned short *)(node + 0x18); }
inline char *sdOperandList(const char *node) { return *(char **)(node + 0x20); }
inline SDValue sdOperandAt(const char *operandList, unsigned k) { return *(SDValue *)(operandList + k * kSDUseSize); }
inline unsigned short sdOperandCount(const char *node) { return *(unsigned short *)(node + 0x38); }
inline unsigned sdIROrder(const char *node) { return *(unsigned *)(node + 0x3c); }
inline EVT sdValueType(SDValue value) { return ((EVT *)*(char **)(value.node + 0x28))[value.resno]; }
}  // namespace llvm38

static inline std::vector<LLVMValueRef> metadataOperands(LLVMValueRef node) {
    std::vector<LLVMValueRef> out(node && LLVMIsAMDNode(node) ? LLVMGetMDNodeNumOperands(node) : 0);
    if (!out.empty()) LLVMGetMDNodeOperands(node, out.data());
    return out;
}
static inline bool isString(LLVMValueRef value, const char *text) {
    unsigned length = 0;
    const char *s = value && LLVMIsAMDString(value) ? LLVMGetMDString(value, &length) : nullptr;
    return s && length == strlen(text) && !memcmp(s, text, length);
}
// The MDNode a metadata value wraps, checked against its operand count.
static inline void *metadataOf(LLVMValueRef value) {
    if (!value || !LLVMIsAMDNode(value)) return nullptr;
    void *md = llvm38::wrappedMetadata(value);
    return md && llvm38::mdNodeOperandCount(md) == LLVMGetMDNodeNumOperands(value) ? md : nullptr;
}

// ANGLE writes __asm__("") into every loop it translates, and the plugins read the name of such a call's callee, which
// it doesn't have, and crash. Metal has no inline asm to run: unused inline asm calls are dropped.
static inline unsigned dropUnusedInlineAsmCalls(LLVMModuleRef module) {
    unsigned dropped = 0;
    for (LLVMValueRef f = LLVMGetFirstFunction(module); f; f = LLVMGetNextFunction(f))
        for (LLVMBasicBlockRef block = LLVMGetFirstBasicBlock(f); block; block = LLVMGetNextBasicBlock(block))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(block), next; inst; inst = next) {
                next = LLVMGetNextInstruction(inst);
                if (!LLVMIsACallInst(inst) || !LLVMIsAInlineAsm(LLVMGetCalledValue(inst)) || LLVMGetFirstUse(inst)) continue;
                LLVMInstructionEraseFromParent(inst);
                dropped++;
            }
    return dropped;
}

// Points the plugin's imported pointer to `original` (found by value in its data segments) at `replacement`.
static inline unsigned redirectImportedPointer(const mach_header_64 *header, intptr_t slide, void *original, void *replacement) {
    unsigned patched = 0;
    const char *p = (const char *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, p += ((const load_command *)p)->cmdsize) {
        const segment_command_64 *seg = (const segment_command_64 *)p;
        if (seg->cmd != LC_SEGMENT_64 || strncmp(seg->segname, "__DATA", 6)) continue;
        void **start = (void **)(seg->vmaddr + slide), **end = (void **)(seg->vmaddr + slide + seg->vmsize);
        for (void **slot = start; slot < end; slot++) {
            if (*slot != original) continue;
            vm_protect(mach_task_self(), (vm_address_t)slot & ~(vm_address_t)(vm_page_size - 1), vm_page_size, false,
                       VM_PROT_READ | VM_PROT_WRITE);
            *slot = replacement;
            patched++;
        }
    }
    return patched;
}
