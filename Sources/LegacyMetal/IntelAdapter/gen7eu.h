// gen7eu.h: just enough of the Gen7/7.5 (Ivy Bridge/Haswell) EU instruction format to follow which GRF bytes each
// instruction of a kernel reads and writes, for findCompareClobber() below. Field positions and the compaction tables
// are the hardware's (Intel's Ivy Bridge/Haswell PRMs, as Mesa's elk_inst.h / elk_eu_compact.c also encode them).
#pragma once
#include <stdint.h>
#include <string.h>
#include <vector>

namespace gen7eu {

static const uint32_t kControlIndex[32] = {
    0b0000000000000000010, 0b0000100000000000000, 0b0000100000000000001, 0b0000100000000000010,
    0b0000100000000000011, 0b0000100000000000100, 0b0000100000000000101, 0b0000100000000000111,
    0b0000100000000001000, 0b0000100000000001001, 0b0000100000000001101, 0b0000110000000000000,
    0b0000110000000000001, 0b0000110000000000010, 0b0000110000000000011, 0b0000110000000000100,
    0b0000110000000000101, 0b0000110000000000111, 0b0000110000000001001, 0b0000110000000001101,
    0b0000110000000010000, 0b0000110000100000000, 0b0001000000000000000, 0b0001000000000000010,
    0b0001000000000000100, 0b0001000000100000000, 0b0010110000000000000, 0b0010110000000010000,
    0b0011000000000000000, 0b0011000000100000000, 0b0101000000000000000, 0b0101000000100000000,
};
static const uint32_t kDatatypeIndex[32] = {
    0b001000000000000001, 0b001000000000100000, 0b001000000000100001, 0b001000000001100001,
    0b001000000010111101, 0b001000001011111101, 0b001000001110100001, 0b001000001110100101,
    0b001000001110111101, 0b001000010000100001, 0b001000110000100000, 0b001000110000100001,
    0b001001010010100101, 0b001001110010100100, 0b001001110010100101, 0b001111001110111101,
    0b001111011110011101, 0b001111011110111100, 0b001111011110111101, 0b001111111110111100,
    0b000000001000001100, 0b001000000000111101, 0b001000000010100101, 0b001000010000100000,
    0b001001010010100100, 0b001001110010000100, 0b001010010100001001, 0b001101111110111101,
    0b001111111110111101, 0b001011110110101100, 0b001010010100101000, 0b001010110100101000,
};
// Entry 10 is src0 subregister 20 (0b000001010000000): Mesa's gfx7_subreg_table has 0b000010100000000 (src0 8, src1
// 1), a bit off. iCBE uses it for scalar reads of .5 dwords, and only the corrected entry makes the SIMD8 and SIMD16
// kernels of the WebGL UBO pages agree (kdiff), which those pages need to pass on the GPU.
static const uint16_t kSubregIndex[32] = {
    0b000000000000000, 0b000000000000001, 0b000000000001000, 0b000000000001111, 0b000000000010000, 0b000000010000000,
    0b000000100000000, 0b000000110000000, 0b000001000000000, 0b000001000010000, 0b000001010000000, 0b001000000000000,
    0b001000000000001, 0b001000010000001, 0b001000010000010, 0b001000010000011, 0b001000010000100, 0b001000010000111,
    0b001000010001000, 0b001000010001110, 0b001000010001111, 0b001000110000000, 0b001000111101000, 0b010000000000000,
    0b010000110000000, 0b011000000000000, 0b011110010000111, 0b100000000000000, 0b101000000000000, 0b110000000000000,
    0b111000000000000, 0b111000000011100,
};
static const uint16_t kSrcIndex[32] = {
    0b000000000000, 0b000000000010, 0b000000010000, 0b000000010010, 0b000000011000, 0b000000100000, 0b000000101000,
    0b000001001000, 0b000001010000, 0b000001110000, 0b000001111000, 0b001100000000, 0b001100000010, 0b001100001000,
    0b001100010000, 0b001100010010, 0b001100100000, 0b001100101000, 0b001100111000, 0b001101000000, 0b001101000010,
    0b001101001000, 0b001101010000, 0b001101100000, 0b001101101000, 0b001101110000, 0b001101110001, 0b001101111000,
    0b010001101000, 0b010001101001, 0b010001101010, 0b010110001000,
};

struct Bits {
    uint64_t w[2] = {0, 0};
    uint64_t get(int hi, int lo) const {
        uint64_t v = 0;
        for (int b = hi; b >= lo; b--) v = (v << 1) | ((w[b >> 6] >> (b & 63)) & 1);
        return v;
    }
    void set(int hi, int lo, uint64_t v) {
        for (int b = lo; b <= hi; b++, v >>= 1) {
            uint64_t m = 1ull << (b & 63);
            w[b >> 6] = (v & 1) ? (w[b >> 6] | m) : (w[b >> 6] & ~m);
        }
    }
};

static inline Bits uncompact(uint64_t c) {
    auto f = [c](int hi, int lo) { return (c >> lo) & ((1ull << (hi - lo + 1)) - 1); };
    Bits n;
    n.set(6, 0, f(6, 0));
    n.set(30, 30, f(7, 7));
    uint32_t control = kControlIndex[f(12, 8)];
    n.set(31, 31, (control >> 16) & 1);
    n.set(23, 8, control & 0xffff);
    n.set(90, 89, control >> 17);
    uint32_t types = kDatatypeIndex[f(17, 13)];
    n.set(63, 61, types >> 15);
    n.set(46, 32, types & 0x7fff);
    uint16_t sub = kSubregIndex[f(22, 18)];
    n.set(100, 96, sub >> 10);
    n.set(68, 64, (sub >> 5) & 0x1f);
    n.set(52, 48, sub & 0x1f);
    n.set(88, 77, kSrcIndex[f(34, 30)]);
    if (n.get(38, 37) == 3 || n.get(43, 42) == 3) {
        uint32_t imm = (uint32_t)((f(39, 35) << 8) | f(63, 56));
        n.set(127, 96, (uint32_t)((int32_t)(imm << 19) >> 19));
    } else {
        n.set(120, 109, kSrcIndex[f(39, 35)]);
        n.set(108, 101, f(63, 56));
    }
    n.set(28, 28, f(23, 23));
    n.set(27, 24, f(27, 24));
    n.set(60, 53, f(47, 40));
    n.set(76, 69, f(55, 48));
    return n;
}

enum { kSel = 2, kSend = 49, kSendc = 50, kMath = 56, kPln = 90, kLine = 89, kNop = 126 };
static inline bool isFlow(unsigned op) { return op >= 32 && op <= 47; }
static inline bool isThreeSource(unsigned op) { return op == 24 || op == 26 || op == 91 || op == 92; }
static inline bool isOneSource(unsigned op) {
    return op == 1 || op == 3 || op == 4 || op == 19 || op == 20 || op == 23 || (op >= 67 && op <= 71) || (op >= 74 && op <= 77);
}
static inline int typeSize(unsigned t) { return t == 6 ? 8 : t == 2 || t == 3 ? 2 : t == 4 || t == 5 ? 1 : 4; }
static inline int strideOf(unsigned code) { return code ? 1 << (code - 1) : 0; }

// GRF byte ranges an instruction reads and writes. ok = false: something this doesn't follow (indirect addressing, a
// message descriptor in a register).
struct Access {
    bool ok = true, flagWrite = false, predicated = false, flow = false, eot = false;
    unsigned opcode = 0;
    std::vector<int> reads, writes;  // byte addresses (reg * 32 + offset)
};

static inline void region(std::vector<int> &out, int base, int lanes, int ts, int vs, int width, int hs) {
    if (width <= 0) width = 1;
    for (int i = 0; i < lanes; i++) {
        int addr = base + ((i / width) * vs + (i % width) * hs) * ts;
        for (int b = 0; b < ts; b++) out.push_back(addr + b);
    }
}

static inline Access decode(const Bits &n) {
    Access a;
    unsigned op = (unsigned)n.get(6, 0);
    a.opcode = op;
    int lanes = 1 << n.get(23, 21);
    if (isFlow(op)) { a.flow = true; return a; }
    if (op == kNop) return a;
    // bits 27:24 are a conditional modifier except in sel (min/max), math (the function) and sends (the shared function)
    a.flagWrite = n.get(27, 24) != 0 && op != kSend && op != kSendc && op != kSel && op != kMath;
    a.predicated = n.get(19, 16) != 0 && op != kSel;  // a predicated write keeps the old value in the other lanes
    if (isThreeSource(op)) {  // align16: dst and sources in whole dwords; a replicated source reads one
        int dst = (int)n.get(63, 56) * 32 + (int)n.get(55, 53) * 4;
        for (int i = 0; i < lanes * 4; i++) a.writes.push_back(dst + i);
        const int reg[3][2] = {{83, 76}, {104, 97}, {125, 118}}, sub[3][2] = {{75, 73}, {96, 94}, {117, 115}}, rep[3] = {64, 85, 106};
        for (int s = 0; s < 3; s++) {
            int base = (int)n.get(reg[s][0], reg[s][1]) * 32 + (int)n.get(sub[s][0], sub[s][1]) * 4;
            for (int i = 0; i < (n.get(rep[s], rep[s]) ? 4 : lanes * 4); i++) a.reads.push_back(base + i);
        }
        return a;
    }
    bool align16 = n.get(8, 8) != 0;
    unsigned dstFile = (unsigned)n.get(33, 32), src0File = (unsigned)n.get(38, 37), src1File = (unsigned)n.get(43, 42);
    if (n.get(63, 63) || (src0File == 1 && n.get(79, 79)) || (src1File == 1 && n.get(111, 111))) { a.ok = false; return a; }
    if (op == kSend || op == kSendc) {
        if (src1File != 3) { a.ok = false; return a; }
        uint32_t desc = (uint32_t)n.get(127, 96);
        int mlen = (desc >> 25) & 0xf, rlen = (desc >> 20) & 0x1f;
        a.eot = (desc >> 31) & 1;
        if (src0File == 1) for (int i = 0; i < mlen * 32; i++) a.reads.push_back((int)n.get(76, 69) * 32 + i);
        if (dstFile == 1) for (int i = 0; i < rlen * 32; i++) a.writes.push_back((int)n.get(60, 53) * 32 + i);
        return a;
    }
    if (dstFile == 1) {
        int ts = typeSize((unsigned)n.get(36, 34)), base = (int)n.get(60, 53) * 32 + (int)n.get(52, 48);
        if (align16) region(a.writes, (int)n.get(60, 53) * 32, lanes * 4 / ts, ts, 0, 1 << 30, 1);
        else region(a.writes, base, lanes, ts, 0, 1 << 30, strideOf((unsigned)n.get(62, 61)));
    }
    struct { unsigned file, type; int reg, sub, vs, w, hs; } src[2] = {
        {src0File, (unsigned)n.get(41, 39), (int)n.get(76, 69), (int)n.get(68, 64), (int)n.get(88, 85), (int)n.get(84, 82), (int)n.get(81, 80)},
        {src1File, (unsigned)n.get(46, 44), (int)n.get(108, 101), (int)n.get(100, 96), (int)n.get(120, 117), (int)n.get(116, 114), (int)n.get(113, 112)},
    };
    for (int s = 0; s < (isOneSource(op) ? 1 : 2); s++) {
        if (src[s].file != 1) continue;
        int ts = typeSize(src[s].type), base = src[s].reg * 32 + (align16 ? 0 : src[s].sub);
        if (align16) { region(a.reads, src[s].reg * 32, lanes * 4 / ts, ts, 0, 1 << 30, 1); continue; }
        if (src[s].vs == 15) { a.ok = false; return a; }
        if ((op == kPln || op == kLine) && s == 0) { region(a.reads, base, 4, 4, 0, 1 << 30, 1); continue; }
        if (op == kPln && s == 1) { region(a.reads, src[s].reg * 32, lanes * 2, 4, 0, 1 << 30, 1); continue; }
        region(a.reads, base, lanes, ts, strideOf(src[s].vs), 1 << src[s].w, strideOf(src[s].hs));
    }
    return a;
}

// iCBE's register allocator can give an instruction that writes a flag (cmp.nz.f0.0 gN, x, 0 before a predicated sel,
// the destination unused) a register that still holds a live value; the value is overwritten and its later read gets
// the compare's 0/-1. Optimized code doesn't leave dead stores, so the sign is: a flag-writing instruction overwrites
// bytes that a value-producing instruction wrote and nothing read since (no flow control in between; a flag-writing
// instruction's own destination is often unused, so overwriting that is fine), and those bytes are read before being
// written again. Returns the index of the clobbering instruction, -1 if none, -2 if the kernel couldn't be followed.
// Stops at the first EOT send. kernel/size: the kernel bytes.
struct Clobber { int writer = -1, clobber = -1, reader = -1; };
static inline int findCompareClobber(const uint8_t *kernel, size_t size, Clobber *found = nullptr) {
    enum { kRegs = 128 * 32 };
    std::vector<int> lastWrite(kRegs, -1);        // instruction that last wrote the byte
    std::vector<bool> unread(kRegs, false);       // a value written and not read since (and no flow control since)
    std::vector<int> clobberedBy(kRegs, -1);      // a flag-writing instruction overwrote an unread value here
    std::vector<int> clobberedFrom(kRegs, -1);
    int index = 0;
    for (size_t off = 0; off + 8 <= size; index++) {
        uint64_t lo, hi = 0;
        memcpy(&lo, kernel + off, 8);
        Bits n;
        if ((lo >> 29) & 1) { n = uncompact(lo); off += 8; }
        else {
            if (off + 16 > size) return -2;
            memcpy(&hi, kernel + off + 8, 8);
            n.w[0] = lo; n.w[1] = hi; off += 16;
        }
        Access a = decode(n);
        if (!a.ok) return -2;
        if (a.flow) {
            std::fill(unread.begin(), unread.end(), false);
            std::fill(clobberedBy.begin(), clobberedBy.end(), -1);
            continue;
        }
        for (int b : a.reads) {
            if (b < 0 || b >= kRegs) return -2;
            if (clobberedBy[b] >= 0) {
                if (found) { found->writer = clobberedFrom[b]; found->clobber = clobberedBy[b]; found->reader = index; }
                return clobberedBy[b];
            }
            unread[b] = false;
        }
        for (int b : a.writes) {
            if (b < 0 || b >= kRegs) return -2;
            if (a.predicated) { clobberedBy[b] = -1; continue; }  // merged with the old value: not an overwrite
            if (a.flagWrite && unread[b] && lastWrite[b] >= 0) { clobberedBy[b] = index; clobberedFrom[b] = lastWrite[b]; }
            else clobberedBy[b] = -1;
            lastWrite[b] = index;
            unread[b] = !a.flagWrite;
        }
        if (a.eot) break;
    }
    return -1;
}

}  // namespace gen7eu
