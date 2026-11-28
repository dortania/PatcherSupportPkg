#!/usr/bin/env python3
# mslfuzz.py <seed> [stmts]: prints a random Metal compute kernel for differential testing across GPUs (fuzzrun). Integer
# only, so every conforming compiler must give bit-identical results: unsigned arithmetic (wraps by definition), shifts
# masked to 0..31, divisions and remainders by values forced odd (never 0), loops with constant trip counts, array
# indexes masked into range. Covers what the old compilers got wrong before: private arrays with variable indexes,
# pointer selects, threadgroup memory with barriers, bools in threadgroup memory, atomics, vector swizzles.
# Kernel signature: kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[tid]],
# uint l [[lid]]): each thread reads in[t*4..t*4+3] and writes out[t*8..t*8+7]; 64 threads per threadgroup.
import random, sys

seed = int(sys.argv[1])
nstmts = int(sys.argv[2]) if len(sys.argv) > 2 else 24
R = random.Random(seed)
NV = 6  # scalar uint variables v0..v5
lines = []
depth = 0


def var():
    return f'v{R.randrange(NV)}'


def expr(d=0):
    k = R.randrange(14 if d < 3 else 4)
    if k == 0: return var()
    if k == 1: return f'{R.randrange(1 << 32)}u'
    if k == 2: return f'in[(t * 4u + {R.randrange(4)}u)]'
    if k == 3: return f'({var()} ^ t)'
    a, b = expr(d + 1), expr(d + 1)
    if k == 4: return f'({a} + {b})'
    if k == 5: return f'({a} - {b})'
    if k == 6: return f'({a} * {b})'
    if k == 7: return f'({a} {R.choice(["&", "|", "^"])} {b})'
    if k == 8: return f'({a} {R.choice(["<<", ">>"])} ({b} & 31u))'
    if k == 9: return f'({a} / ({b} | 1u))'
    if k == 10: return f'({a} % ({b} | 1u))'
    if k == 11: return f'({a} {R.choice(["<", ">", "<=", ">=", "==", "!="])} {b} ? {expr(d + 1)} : {expr(d + 1)})'
    if k == 12: return f'{R.choice(["min", "max"])}({a}, {b})'
    return f'uint(int({a}) >> int({b} & 31u))'  # arithmetic shift of a reinterpreted value


def emit(s):
    lines.append('    ' * (depth + 1) + s)


def stmt():
    global depth
    k = R.randrange(13)
    if k <= 3:
        emit(f'{var()} = {expr()};')
    elif k == 4 and depth < 2:
        emit(f'if ({expr(1)} {R.choice(["<", ">", "==", "!="])} {expr(1)}) {{')
        depth += 1
        for _ in range(R.randrange(1, 4)): stmt()
        depth -= 1
        if R.random() < 0.5:
            emit('} else {')
            depth += 1
            for _ in range(R.randrange(1, 3)): stmt()
            depth -= 1
        emit('}')
    elif k == 5 and depth < 2:
        i = f'i{depth}'
        emit(f'for (uint {i} = 0; {i} < {R.randrange(1, 6)}u; {i}++) {{')
        depth += 1
        emit(f'{var()} += {i} * {R.randrange(1, 9)}u;')
        for _ in range(R.randrange(1, 3)): stmt()
        depth -= 1
        emit('}')
    elif k == 6:  # private array, variable index
        emit(f'p[({expr(1)}) & 7u] = {expr(1)};')
    elif k == 7:
        emit(f'{var()} ^= p[({expr(1)}) & 7u];')
    elif k == 8:  # pointer select (c03's shape)
        emit(f'{{ thread uint *q = ({expr(1)} & 1u) ? &p[{R.randrange(8)}] : &p[{R.randrange(8)}]; *q += {expr(1)}; {var()} += *q; }}')
    elif k == 9 and depth == 0:  # threadgroup round trip with a barrier (top level only: barriers must be uniform)
        emit(f'{{ tg[l] = {expr(1)}; threadgroup_barrier(mem_flags::mem_threadgroup); '
             f'{var()} += tg[(l + {R.randrange(1, 64)}u) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }}')
    elif k == 10 and depth == 0:  # threadgroup bool (a10's shape)
        emit(f'{{ if (l == 0) tb = false; threadgroup_barrier(mem_flags::mem_threadgroup); '
             f'if ((({expr(1)}) & 3u) == 0u) tb = true; threadgroup_barrier(mem_flags::mem_threadgroup); '
             f'{var()} += tb ? 1u : 2u; threadgroup_barrier(mem_flags::mem_threadgroup); }}')
    elif k in (9, 10, 11):  # vector math with swizzles (also where a barrier statement isn't allowed)
        emit(f'{{ uint4 w = uint4({expr(1)}, {expr(1)}, {var()}, {var()}); w = w.{"".join(R.choice("xyzw") for _ in range(4))} + uint4({var()}); {var()} = w.x ^ w.y ^ (w.z << 1u) ^ (w.w >> 1u); }}')
    elif k == 12:  # atomic, result order-independent: a sum over the threadgroup
        emit(f'atomic_fetch_add_explicit(&ta, ({expr(1)}) & 255u, memory_order_relaxed);')


src = ['#include <metal_stdlib>', 'using namespace metal;',
       'kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],',
       '              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {',
       '    threadgroup uint tg[64];', '    threadgroup bool tb;', '    threadgroup atomic_uint ta;',
       '    if (l == 0) atomic_store_explicit(&ta, 0u, memory_order_relaxed);',
       '    threadgroup_barrier(mem_flags::mem_threadgroup);',
       '    uint p[8];', '    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;']
src += [f'    uint v{i} = in[(t * 4u + {i % 4}u)] * {2 * i + 1}u + t;' for i in range(NV)]
for _ in range(nstmts): stmt()
lines.append('    threadgroup_barrier(mem_flags::mem_threadgroup);')
src += lines
src += [f'    out[t * 8u + {i}u] = v{i};' for i in range(NV)]
src += ['    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7];',
        '    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);', '}']
print('\n'.join(src))
