#!/usr/bin/env python3
# cpuref.py <kernel.metal> [input seed]: runs a mslfuzz2.py kernel on the CPU as the reference: translates it to C++
# (Metal types, swizzles, narrow vectors as clang ext vectors, threadgroup memory shared by 64 std::threads per group,
# barriers as std::barrier, atomics as std::atomic), compiles it with clang++ and prints the same "HASH" + words as
# fuzzrun, for the same inputs. Kernels and fragment functions (FRAG=1) alike.
# cpuref.py --batch <kernel.metal>...: one binary for all of them; prints "<file> HASH xxxxxxxx" per kernel (much faster:
# compiling is most of the time). --batch-full prints every output word too, as the single-kernel form does.
# Every builtin follows the Metal Shading Language specification's definition. A disagreement with a GPU is worth
# checking here first: integer clamp once went through a float overload and rounded large values.
import atexit, os, re, shutil, subprocess, sys, tempfile

PRELUDE = r'''
#include <atomic>
#include <barrier>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>
typedef uint32_t uint;
struct uint4 {
    uint x, y, z, w;
    uint4(uint a, uint b, uint c, uint d) : x(a), y(b), z(c), w(d) {}
    explicit uint4(uint a) : x(a), y(a), z(a), w(a) {}
    uint at(int i) const { return i == 0 ? x : i == 1 ? y : i == 2 ? z : w; }
    uint4 swz(int a, int b, int c, int d) const { return uint4(at(a), at(b), at(c), at(d)); }
    uint4 operator+(const uint4 &o) const { return uint4(x + o.x, y + o.y, z + o.z, w + o.w); }
    uint &operator[](unsigned i) { return i == 0 ? x : i == 1 ? y : i == 2 ? z : w; }
};
static uint min(uint a, uint b) { return a < b ? a : b; }
static uint max(uint a, uint b) { return a > b ? a : b; }
static int min(int a, int b) { return a < b ? a : b; }
static int max(int a, int b) { return a > b ? a : b; }
// mslfuzz2's integer builtins, as the Metal Shading Language specification defines them
typedef uint64_t ulong_t;
#define ulong ulong_t
typedef uint8_t uchar;
typedef uint16_t ushort;
static uint popcount(uint x) { return __builtin_popcount(x); }
static uint clz(uint x) { return x ? __builtin_clz(x) : 32; }
static uint ctz(uint x) { return x ? __builtin_ctz(x) : 32; }
static uint reverse_bits(uint x) { uint r = 0; for (int i = 0; i < 32; i++) r |= ((x >> i) & 1u) << (31 - i); return r; }
static uint rotate(uint v, uint i) { uint s = i & 31; return s ? (v << s) | (v >> (32 - s)) : v; }
static uint mulhi(uint a, uint b) { return (uint)(((uint64_t)a * b) >> 32); }
static uint64_t mulhi(uint64_t a, uint64_t b) { return (uint64_t)(((unsigned __int128)a * b) >> 64); }
static uint64_t min(uint64_t a, uint64_t b) { return a < b ? a : b; }
static uint64_t max(uint64_t a, uint64_t b) { return a > b ? a : b; }
static uint madhi(uint a, uint b, uint c) { return mulhi(a, b) + c; }
static int mulhi(int a, int b) { return (int)(((int64_t)a * b) >> 32); }  // signed forms (from the 11,4 session)
static int madhi(int a, int b, int c) { return (int)((uint)mulhi(a, b) + (uint)c); }
static uint madsat(uint a, uint b, uint c) { uint64_t r = (uint64_t)a * b + c; return r > 0xffffffffull ? 0xffffffffu : (uint)r; }
static uint absdiff(uint a, uint b) { return a > b ? a - b : b - a; }
static uint addsat(uint a, uint b) { uint r = a + b; return r < a ? 0xffffffffu : r; }
static uint subsat(uint a, uint b) { return a > b ? a - b : 0; }
static int addsat(int a, int b) { long long r = (long long)a + b; return r > 2147483647 ? 2147483647 : r < -2147483647 - 1 ? -2147483647 - 1 : (int)r; }
static int subsat(int a, int b) { long long r = (long long)a - b; return r > 2147483647 ? 2147483647 : r < -2147483647 - 1 ? -2147483647 - 1 : (int)r; }
static uint hadd(uint a, uint b) { return (a >> 1) + (b >> 1) + (a & b & 1); }
static uint rhadd(uint a, uint b) { return (a >> 1) + (b >> 1) + ((a | b) & 1); }
static uint min3(uint a, uint b, uint c) { return min(min(a, b), c); }
static uint max3(uint a, uint b, uint c) { return max(max(a, b), c); }
static uint clamp(uint x, uint lo, uint hi) { return min(max(x, lo), hi); }  // integer clamp (a float one rounded 0x40302010)
static int clamp(int x, int lo, int hi) { return min(max(x, lo), hi); }
static uint median3(uint a, uint b, uint c) { return max(min(a, b), min(max(a, b), c)); }
static uint extract_bits(uint x, uint offset, uint bits) { return bits ? (x >> offset) & (bits == 32 ? 0xffffffffu : (1u << bits) - 1) : 0; }
// mslfuzz2 VEC=1: narrow vectors as clang ext vectors (lane-wise in the element type, as in MSL)
template<class E, int N> using vec = E __attribute__((ext_vector_type(N)));
template<class E, int N> static bool any(vec<E, N> m) { for (int i = 0; i < N; i++) if (m[i]) return true; return false; }
template<class E, int N> static bool all(vec<E, N> m) { for (int i = 0; i < N; i++) if (!m[i]) return false; return true; }
template<class E, int N> static vec<E, N> min(vec<E, N> a, vec<E, N> b) { return b < a ? b : a; }
template<class E, int N> static vec<E, N> max(vec<E, N> a, vec<E, N> b) { return b > a ? b : a; }
template<class E, int N, class M> static vec<E, N> select(vec<E, N> a, vec<E, N> b, M c) { return c ? b : a; }
typedef vec<unsigned char, 2> uchar2; static uchar2 mk_uchar2(unsigned char a, unsigned char b) { return uchar2{a, b}; }
typedef vec<unsigned char, 3> uchar3; static uchar3 mk_uchar3(unsigned char a, unsigned char b, unsigned char c) { return uchar3{a, b, c}; }
typedef vec<unsigned char, 4> uchar4; static uchar4 mk_uchar4(unsigned char a, unsigned char b, unsigned char c, unsigned char d) { return uchar4{a, b, c, d}; }
typedef vec<signed char, 2> char2; static char2 mk_char2(signed char a, signed char b) { return char2{a, b}; }
typedef vec<signed char, 3> char3; static char3 mk_char3(signed char a, signed char b, signed char c) { return char3{a, b, c}; }
typedef vec<signed char, 4> char4; static char4 mk_char4(signed char a, signed char b, signed char c, signed char d) { return char4{a, b, c, d}; }
typedef vec<unsigned short, 2> ushort2; static ushort2 mk_ushort2(unsigned short a, unsigned short b) { return ushort2{a, b}; }
typedef vec<unsigned short, 3> ushort3; static ushort3 mk_ushort3(unsigned short a, unsigned short b, unsigned short c) { return ushort3{a, b, c}; }
typedef vec<unsigned short, 4> ushort4; static ushort4 mk_ushort4(unsigned short a, unsigned short b, unsigned short c, unsigned short d) { return ushort4{a, b, c, d}; }
typedef vec<short, 2> short2; static short2 mk_short2(short a, short b) { return short2{a, b}; }
typedef vec<short, 3> short3; static short3 mk_short3(short a, short b, short c) { return short3{a, b, c}; }
typedef vec<short, 4> short4; static short4 mk_short4(short a, short b, short c, short d) { return short4{a, b, c, d}; }
// mslfuzz2.py VECHELPERS, the same text
static uint vf(uchar2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }
static uint vf(uchar3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }
static uint vf(uchar4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }
static uint vf(char2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }
static uint vf(char3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }
static uint vf(char4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }
static uint vf(ushort2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }
static uint vf(ushort3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }
static uint vf(ushort4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }
static uint vf(short2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }
static uint vf(short3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }
static uint vf(short4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }
static uint insert_bits(uint base, uint insert, uint offset, uint bits) {
    if (!bits) return base;
    uint mask = (bits == 32 ? 0xffffffffu : (1u << bits) - 1) << offset;
    return (base & ~mask) | ((insert << offset) & mask);
}
static int select(int a, int b, bool c) { return c ? b : a; }
// ASTYPE=1: as_type reinterpretations between narrow vectors and uint
template <typename T, typename F> static T as_type(F f) { static_assert(sizeof(T) == sizeof(F), "as_type size"); T r; memcpy(&r, &f, sizeof r); return r; }
typedef std::atomic<uint> atomic_uint;
static void atomic_store_explicit(atomic_uint *a, uint v, std::memory_order o) { a->store(v, o); }
static uint atomic_load_explicit(atomic_uint *a, std::memory_order o) { return a->load(o); }
static uint atomic_fetch_add_explicit(atomic_uint *a, uint v, std::memory_order o) { return a->fetch_add(v, o); }
struct Group { uint tg[64]; uchar tc[64]; bool tb; atomic_uint ta; std::barrier<> bar{64}; };
typedef void (*Kernel)(const uint *, uint *, uint, uint, Group *);
enum { T = 256 };
static uint32_t run(Kernel k, unsigned seed, std::vector<uint> &out) {
    std::vector<uint> in(T * 4);
    out.assign(T * 8, 0xcdcdcdcdu);
    uint32_t x = seed * 2654435761u + 12345u;
    for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; in[i] = (i % 7 == 0) ? (x & 0xff) : x; }
    for (int g = 0; g < T / 64; g++) {
        Group G;
        std::vector<std::thread> th;
        for (int l = 0; l < 64; l++) th.emplace_back(k, in.data(), out.data(), (uint)(g * 64 + l), (uint)l, &G);
        for (auto &t : th) t.join();
    }
    uint32_t h = 2166136261u;
    for (int i = 0; i < T * 8; i++) for (int b = 0; b < 4; b++) { h ^= (out[i] >> (8 * b)) & 0xff; h *= 16777619u; }
    return h;
}
'''


def translate(src):
    head = 'kernel void k' if 'kernel void k' in src else 'fragment float4 k'
    body = src[src.index('{', src.index(head)) + 1:src.rindex('}')]
    body = body.replace('    uint t = uint(pos.x);', '').replace('    return float4(0.0);', '')  # fragment form
    # Threadgroup variables become members of the shared group state.
    body = body.replace('threadgroup uint tg[64];', '').replace('threadgroup bool tb;', '').replace('threadgroup atomic_uint ta;', '')
    body = body.replace('threadgroup uchar tc[64];', '')
    body = re.sub(r'\btg\[', 'G->tg[', body)
    body = re.sub(r'\btc\[', 'G->tc[', body)
    body = re.sub(r'\btb\b', 'G->tb', body)
    body = body.replace('&ta', '&G->ta')
    body = body.replace('threadgroup_barrier(mem_flags::mem_threadgroup);', 'G->bar.arrive_and_wait();')
    body = body.replace('thread uint *', 'uint *')
    body = re.sub(r'\.([xyzw]{4})\b', lambda m: '.swz(' + ','.join(str('xyzw'.index(c)) for c in m.group(1)) + ')', body)
    # Functional casts as C-style casts: nested ones like uint(ushort(x)) can parse as declarations in C++.
    body = re.sub(r'\b(uint|int|uchar|ushort|char|short|bool|float|ulong|long)\(', r'(\1)(', body)
    body = re.sub(r'\b(u?char|u?short)([234])\(', r'mk_\1\2(', body)  # vector constructors (C++ has no vector literals)
    return body.replace('memory_order_relaxed', 'std::memory_order_relaxed')


def build(cpp):
    d = tempfile.mkdtemp(prefix='cpuref-')
    atexit.register(shutil.rmtree, d, True)  # a build per run, removed afterwards (kept builds filled a disk)
    exe = os.path.join(d, 'k')
    open(os.path.join(d, 'k.cpp'), 'w').write(cpp)
    r = subprocess.run(['clang++', '-std=c++20', '-O1', '-fwrapv', '-ffp-contract=off', '-w', '-o', exe, os.path.join(d, 'k.cpp')], capture_output=True, text=True)
    if r.returncode:
        print('CPPCOMPILE ' + r.stderr.replace('\n', ' ')[:300]); sys.exit(4)
    return exe


if sys.argv[1] in ('--batch', '--batch-full'):
    full = sys.argv[1] == '--batch-full'
    files = sys.argv[2:]
    cpp = PRELUDE + ''.join(f'static void k{i}(const uint *in, uint *out, uint t, uint l, Group *G) {{\n{translate(open(f).read())}\n}}\n'
                            for i, f in enumerate(files))
    cpp += 'static Kernel kernels[] = {' + ', '.join(f'k{i}' for i in range(len(files))) + '};\n'
    if full:  # every output word too, as the single-kernel form prints them
        cpp += r'''int main(int argc, char **argv) {
    std::vector<uint> out;
    for (int i = 1; i < argc; i++) {
        printf("%s HASH %08x\n", argv[i], run(kernels[i - 1], 1, out));
        for (int t = 0; t < T; t++) { for (int w = 0; w < 8; w++) printf("%08x ", out[t * 8 + w]); printf("\n"); }
    }
}
'''
    else:
        cpp += 'int main(int argc, char **argv) { std::vector<uint> out; for (int i = 1; i < argc; i++) printf("%s HASH %08x\\n", argv[i], run(kernels[i - 1], 1, out)); }\n'
    exe = build(cpp)
    sys.stdout.write(subprocess.run([exe] + files, capture_output=True, text=True).stdout)
else:
    seed = sys.argv[2] if len(sys.argv) > 2 else '1'
    cpp = PRELUDE + f'static void k(const uint *in, uint *out, uint t, uint l, Group *G) {{\n{translate(open(sys.argv[1]).read())}\n}}\n'
    cpp += r'''int main(int argc, char **argv) {
    std::vector<uint> out;
    uint32_t h = run(k, argc > 1 ? atoi(argv[1]) : 1, out);
    printf("HASH %08x\n", h);
    for (int t = 0; t < T; t++) { for (int w = 0; w < 8; w++) printf("%08x ", out[t * 8 + w]); printf("\n"); }
}
'''
    exe = build(cpp)
    sys.stdout.write(subprocess.run([exe, seed], capture_output=True, text=True).stdout)
