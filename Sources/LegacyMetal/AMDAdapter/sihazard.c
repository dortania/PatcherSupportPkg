// sihazard.c: inserts the wait states the 12.5 AMD shader compiler (ATIRadeonX4000SCLib) leaves out on Southern
// Islands (GCN1: Tahiti, Pitcairn, Cape Verde, Oland) between a scalar ALU write of an SGPR and an s_buffer_load that
// reads it as its descriptor (or SGPR offset).
//
// The hardware reads the old register value, so the load uses a half-written descriptor. LLVM's AMDGPU backend works
// around the same undocumented SI behaviour with 4 wait states (GCNHazardRecognizer::checkSMRDHazards). The 2022 compiler
// hits it whenever a shader loads through a pointer that came from memory: Metal argument buffers (ANGLE puts every
// WebGL uniform block in one), where each pointer is expanded into a buffer descriptor with s_mov/s_movk right before
// the load. With a stale num_records the load is out of range and returns 0 (deqp ubo.random.basic_types.19:
// `s_movk_i32 s2, 0xffff` immediately followed by `s_buffer_load_dwordx4 s[16:19], s[0:3], 0x40`).
//
// siFixBufferLoadHazards() decodes the SI machine code, inserts `s_nop` before each such load and moves the branch
// offsets past the inserted instructions. Code it can't decode completely is left unchanged.
//
// siBypassL1ForWrittenResources(): a wavefront that stores to memory and reads the same address back can
// get the OLD value from SI's vector L1 cache (a load that misses while the write-through store is still on its way to
// L2 fills the line with stale data, and later loads hit it). The 12.5 compiler keeps private structs in scratch memory
// and does exactly that: Blender EEVEE's G-buffer writer stores normal_len (buffer_store_byte ... offset:638) and loads
// it straight back; wavefronts that read the stale 0 wrote the glass thickness over the surface normal (black 8x8
// blocks behind glass and water). Setting GLC (bypass L1) on every load from a buffer that the shader also writes -
// same descriptor SGPRs as a store or atomic - and on image loads in shaders that store to images fixes it
// (shader/object_info: 6/6 broken -> 0/6, identical to the reference). Read-only data (constants, vertex fetch,
// sampled textures) keeps its L1 caching.
#include "sihazard.h"
#include <stdlib.h>
#include <string.h>

enum { kWaitStates = 4 };  // LLVM: SmrdSgprWaitStates

typedef struct {
    uint32_t offset;    // byte offset
    uint8_t dwords;     // instruction length
    uint8_t waits;      // wait states this instruction provides (s_nop N: N + 1)
    uint8_t branch;     // relative branch (SOPP simm16)
    uint8_t terminator; // s_branch / s_endpgm: the next instruction is not a fall-through successor
    uint8_t label;      // a branch target
    uint8_t smrdBuffer; // s_buffer_load_*
    uint32_t writes[2]; // SGPR mask (0..63) written by a scalar ALU instruction
    uint32_t reads[2];  // SGPR mask read by an s_buffer_load (descriptor, SGPR offset)
} Inst;

static void setReg(uint32_t mask[2], unsigned reg) {
    if (reg < 64) mask[reg / 32] |= 1u << (reg % 32);
}

static bool overlaps(const uint32_t a[2], const uint32_t b[2]) { return (a[0] & b[0]) || (a[1] & b[1]); }

// Decodes one SI instruction. Returns false for encodings this file doesn't know (the caller then changes nothing).
static bool decode(const uint32_t *code, uint32_t count, uint32_t index, Inst *in, bool *indirect) {
    uint32_t w = code[index];
    memset(in, 0, sizeof *in);
    in->offset = index * 4;
    in->dwords = 1;
    in->waits = 1;
    if ((w >> 23) == 0x17d) {  // SOP1: s_mov_b32 etc.
        unsigned op = (w >> 8) & 0xff, sdst = (w >> 16) & 0x7f, ssrc0 = w & 0xff;
        if ((op >= 31 && op <= 34) || op == 50) *indirect = true;  // getpc/setpc/swappc/rfe, cbranch_join
        in->dwords += ssrc0 == 255;
        setReg(in->writes, sdst);
        setReg(in->writes, sdst + 1);  // 64-bit forms (conservative for 32-bit ones)
    } else if ((w >> 23) == 0x17e) {  // SOPC: writes SCC only
        in->dwords += (w & 0xff) == 255 || ((w >> 8) & 0xff) == 255;
    } else if ((w >> 23) == 0x17f) {  // SOPP
        unsigned op = (w >> 16) & 0x7f;
        if (op == 0) in->waits = (w & 0x7) + 1;  // s_nop
        if (op == 1 || op == 2) in->terminator = true;  // s_endpgm, s_branch
        if (op == 2 || (op >= 4 && op <= 9)) in->branch = true;
        if (op >= 23 && op <= 26) *indirect = true;  // cbranch_cdbg*: not expected; don't touch
    } else if ((w >> 28) == 0xb) {  // SOPK
        unsigned op = (w >> 23) & 0x1f, sdst = (w >> 16) & 0x7f;
        if (op == 17) *indirect = true;  // s_cbranch_i_fork
        if (op == 21) in->dwords = 2;    // s_setreg_imm32_b32
        if (op == 0 || op == 2 || op == 15 || op == 16 || op == 18) setReg(in->writes, sdst);
    } else if ((w >> 30) == 0x2) {  // SOP2
        unsigned op = (w >> 23) & 0x7f, sdst = (w >> 16) & 0x7f;
        if (op == 43) *indirect = true;  // s_cbranch_g_fork
        in->dwords += (w & 0xff) == 255 || ((w >> 8) & 0xff) == 255;
        setReg(in->writes, sdst);
        setReg(in->writes, sdst + 1);
    } else if ((w >> 27) == 0x18) {  // SMRD
        unsigned op = (w >> 22) & 0x1f, sbase = ((w >> 9) & 0x3f) * 2, imm = (w >> 8) & 1, offset = w & 0xff;
        if (op >= 8 && op <= 12) {
            in->smrdBuffer = true;
            for (unsigned r = 0; r < 4; r++) setReg(in->reads, sbase + r);
            if (!imm) setReg(in->reads, offset);
        }
    } else if ((w >> 25) == 0x3f || (w >> 25) == 0x3e) {  // VOP1, VOPC
        in->dwords += (w & 0x1ff) == 255;
    } else if ((w >> 31) == 0) {  // VOP2
        unsigned op = (w >> 25) & 0x3f;
        in->dwords += (w & 0x1ff) == 255 || op == 32 || op == 33;  // v_madmk_f32 / v_madak_f32 carry a constant
    } else {
        switch (w >> 26) {
        case 0x34: case 0x36: case 0x38: case 0x3a: case 0x3c: case 0x3e:  // VOP3, DS, MUBUF, MTBUF, MIMG, EXP
            in->dwords = 2;
            break;
        case 0x32:  // VINTRP
            break;
        default:
            return false;
        }
    }
    return index + in->dwords <= count;
}

uint32_t *siFixBufferLoadHazards(const uint32_t *code, uint32_t bytes, uint32_t *newBytes, unsigned *inserted,
                                 const char **unsupported) {
    *inserted = 0;
    *unsupported = NULL;
    uint32_t count = bytes / 4;
    if (!count || bytes % 4) return NULL;
    Inst *insts = calloc(count, sizeof *insts);
    uint32_t *instAt = malloc((count + 1) * sizeof *instAt);  // dword index -> instruction index (or UINT32_MAX)
    uint8_t *nops = calloc(count, 1);
    uint32_t *out = NULL;
    if (!insts || !instAt || !nops) goto done;
    uint32_t n = 0;
    bool indirect = false;
    for (uint32_t i = 0; i <= count; i++) instAt[i] = UINT32_MAX;
    for (uint32_t i = 0; i < count; i += insts[n++].dwords) {
        instAt[i] = n;
        if (!decode(code, count, i, &insts[n], &indirect)) { *unsupported = "unknown encoding"; goto done; }
    }
    instAt[count] = n;  // the end is a valid branch target
    if (indirect) { *unsupported = "indirect branch or PC access"; goto done; }
    for (uint32_t i = 0; i < n; i++) {
        if (!insts[i].branch) continue;
        int16_t simm = (int16_t)(code[insts[i].offset / 4] & 0xffff);
        int64_t target = (int64_t)insts[i].offset / 4 + 1 + simm;
        if (target < 0 || target > count || instAt[target] == UINT32_MAX) { *unsupported = "branch target"; goto done; }
        if (instAt[target] < n) insts[instAt[target]].label = true;
    }
    // Wait states before each s_buffer_load since the last scalar write of a register it reads. Walking back stops at
    // a label (other predecessors: assume the worst) and at a terminator (no fall-through).
    for (uint32_t i = 0; i < n; i++) {
        if (!insts[i].smrdBuffer) continue;
        unsigned waits = 0;
        int need = 0;
        if (insts[i].label) need = kWaitStates;
        for (int64_t j = (int64_t)i - 1; !need && j >= 0 && waits < kWaitStates; j--) {
            if (insts[j].terminator) break;
            if (overlaps(insts[j].writes, insts[i].reads)) { need = kWaitStates - waits; break; }
            waits += insts[j].waits;
            if (insts[j].label && waits < kWaitStates) need = kWaitStates - waits;
        }
        if (need > 0) { nops[i] = (uint8_t)need; (*inserted)++; }
    }
    if (!*inserted) goto done;
    // New layout: slot[i] = where instruction i's inserted s_nop (or the instruction) starts.
    uint32_t *slot = malloc((n + 1) * sizeof *slot);
    if (!slot) goto done;
    uint32_t total = 0;
    for (uint32_t i = 0; i < n; i++) {
        slot[i] = total;
        total += (nops[i] ? 1 : 0) + insts[i].dwords;
    }
    slot[n] = total;
    out = malloc(total * 4);
    if (!out) { free(slot); goto done; }
    for (uint32_t i = 0; i < n; i++) {
        uint32_t at = slot[i];
        if (nops[i]) out[at++] = 0xbf800000u | (uint32_t)(nops[i] - 1);  // s_nop (waits - 1)
        memcpy(out + at, code + insts[i].offset / 4, insts[i].dwords * 4);
        if (insts[i].branch) {
            int16_t simm = (int16_t)(code[insts[i].offset / 4] & 0xffff);
            uint32_t target = instAt[insts[i].offset / 4 + 1 + simm];
            int64_t moved = (int64_t)slot[target] - (at + 1);
            if (moved < INT16_MIN || moved > INT16_MAX) {
                *unsupported = "branch out of range";
                free(out);
                out = NULL;
                free(slot);
                goto done;
            }
            out[at] = (out[at] & 0xffff0000u) | ((uint32_t)moved & 0xffff);
        }
    }
    free(slot);
    *newBytes = total * 4;
done:
    if (!out) *inserted = 0;
    free(insts);
    free(instAt);
    free(nops);
    return out;
}

// MUBUF/MTBUF/MIMG classification for siBypassL1ForWrittenResources. Opcodes: SI ISA (2012) chapter 12.
static bool mubufLoad(unsigned op) { return op <= 3 || (op >= 8 && op <= 14); }          // load_format_*, load_ubyte..dwordx4
static bool mubufWrite(unsigned op) { return (op >= 4 && op <= 7) || (op >= 24 && op <= 30) || op >= 48; }  // stores, atomics
static bool mtbufLoad(unsigned op) { return op <= 3; }                                    // tbuffer_load_format_*
static bool mimgLoad(unsigned op) { return op <= 3; }                                     // image_load, _mip, _pck, _pck_sgn
static bool mimgWrite(unsigned op) { return (op >= 8 && op <= 11) || (op >= 15 && op <= 31); }  // image_store*, atomics

unsigned siBypassL1ForWrittenResources(uint32_t *code, uint32_t bytes, const char **unsupported) {
    *unsupported = NULL;
    uint32_t count = bytes / 4;
    if (!count || bytes % 4) return 0;
    uint32_t written[2] = {0, 0};  // buffer descriptor SGPRs (first of 4) used by a store or atomic
    bool imageWrites = false, indirect = false;
    Inst in;
    for (int pass = 0; pass < 2; pass++) {
        unsigned changed = 0;
        for (uint32_t i = 0; i < count; i += in.dwords) {
            if (!decode(code, count, i, &in, &indirect)) { *unsupported = "unknown encoding"; return 0; }
            uint32_t w = code[i], w1 = in.dwords > 1 ? code[i + 1] : 0;  // never past the end (1-dword s_endpgm last)
            unsigned fmt = w >> 26, srsrc = ((w1 >> 16) & 0x1f) * 4;
            if (fmt == 0x38 || fmt == 0x3a) {  // MUBUF, MTBUF
                unsigned op = fmt == 0x38 ? (w >> 18) & 0x7f : (w >> 16) & 0x7;
                bool load = fmt == 0x38 ? mubufLoad(op) : mtbufLoad(op), write = fmt == 0x38 ? mubufWrite(op) : !mtbufLoad(op);
                uint32_t mask[2] = {0, 0};
                setReg(mask, srsrc);
                if (pass == 0 && write) setReg(written, srsrc);
                if (pass == 1 && load && overlaps(mask, written) && !(w & (1u << 14))) { code[i] = w | (1u << 14); changed++; }
            } else if (fmt == 0x3c) {  // MIMG: GLC is bit 13
                unsigned op = (w >> 18) & 0x7f;
                if (pass == 0 && mimgWrite(op)) imageWrites = true;
                if (pass == 1 && imageWrites && mimgLoad(op) && !(w & (1u << 13))) { code[i] = w | (1u << 13); changed++; }
            }
        }
        if (pass == 1) return changed;
    }
    return 0;
}
