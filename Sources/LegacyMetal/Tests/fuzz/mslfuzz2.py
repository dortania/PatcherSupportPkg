#!/usr/bin/env python3
# mslfuzz2.py <seed> [stmts]: like mslfuzz.py (same kernel signature and harness, integer only, bit-exact on every
# conforming compiler), with what mslfuzz.py leaves out: Metal's integer builtins (popcount, clz, ctz, reverse_bits,
# rotate, mulhi, madhi, madsat, absdiff, addsat, subsat, hadd, rhadd, min3/max3/median3, extract_bits, insert_bits),
# signed arithmetic (division, remainder, min/max, compares, arithmetic shifts), narrow types (uchar/char/ushort/short
# conversions, a private uchar array), vector elements at variable indexes, threadgroup memory at variable indexes,
# switch statements and while loops with break. Every operation is defined for every input: divisors are odd and
# positive, shift and bit-field amounts are masked into range, indexes are masked into their arrays.
import random, sys

seed = int(sys.argv[1])
nstmts = int(sys.argv[2]) if len(sys.argv) > 2 else 24
import os
FRAG = bool(os.environ.get('FRAG'))  # fragment function instead of a kernel: no threadgroup memory, barriers or atomics
# VEC=1: also narrow vectors (char/uchar/short/ushort 2-4: division, remainder, shifts, lane-wise compares with select,
# min/max, any/all) and narrow scalar division, remainder, shifts and compares. Off by default so seeds stay as they were.
VEC = bool(os.environ.get('VEC'))
# ASTYPE=1 (with VEC=1): also as_type reinterpretations between uchar4 / char4, ushort2 / short2 and uint.
ASTYPE = bool(os.environ.get('ASTYPE'))
# LONG=1: also 64-bit integers (ulong / long: multiply, high halves, division, remainder, shifts, compares, min/max).
LONG = bool(os.environ.get('LONG'))
R = random.Random(seed * 7919 + 1)
NV = 6
lines = []
depth = 0


def var():
    return f'v{R.randrange(NV)}'


def const():
    return R.choice([f'{R.randrange(1 << 32)}u', f'{R.randrange(256)}u', f'{R.choice([0, 1, 2, 31, 32, 255, 256, 65535, 65536, 0x7fffffff, 0x80000000, 0xffffffff])}u'])


def expr(d=0):
    if VEC and d < 2 and R.random() < 0.3: return vecexpr(d)
    if LONG and d < 2 and R.random() < 0.3: return longexpr(d)
    k = R.randrange(34 if d < 3 else 4)
    if k == 0: return var()
    if k == 1: return const()
    if k == 2: return f'in[(t * 4u + {R.randrange(4)}u)]'
    if k == 3: return f'({var()} ^ t)'
    a, b = expr(d + 1), expr(d + 1)
    if k == 4: return f'({a} {R.choice(["+", "-", "*", "&", "|", "^"])} {b})'
    if k == 5: return f'({a} {R.choice(["<<", ">>"])} ({b} & 31u))'
    if k == 6: return f'({a} / ({b} | 1u))'
    if k == 7: return f'({a} {R.choice(["<", ">", "<=", ">=", "==", "!="])} {b} ? {expr(d + 1)} : {expr(d + 1)})'
    if k == 8: return f'{R.choice(["popcount", "clz", "ctz", "reverse_bits"])}({a})'
    if k == 9: return f'rotate({a}, {b})'
    if k == 10: return f'mulhi({a}, {b})'
    if k == 11: return f'{R.choice(["absdiff", "addsat", "subsat", "hadd", "rhadd"])}({a}, {b})'
    if k == 12: return f'{R.choice(["madhi", "madsat", "min3", "max3", "median3"])}({a}, {b}, {expr(d + 1)})'
    if k == 13: return f'extract_bits({a}, uint({b} & 15u), uint({expr(d + 1)} & 15u))'
    if k == 14: return f'insert_bits({a}, {b}, uint({expr(d + 1)} & 15u), uint({expr(d + 1)} & 15u))'
    if k == 15: return f'uint(int({a}) / int(({b} | 1u) & 0x7fffffffu))'
    if k == 16: return f'uint(int({a}) % int(({b} | 1u) & 0x7fffffffu))'
    if k == 17: return f'uint({R.choice(["min", "max"])}(int({a}), int({b})))'
    if k == 18: return f'(int({a}) {R.choice(["<", ">", "<=", ">="])} int({b}) ? {expr(d + 1)} : {expr(d + 1)})'
    if k == 19: return f'uint(int({a}) >> int({b} & 31u))'
    if k == 20: return f'uint({R.choice(["uchar", "ushort", "char", "short"])}({a}))'
    if k == 21: return R.choice([f'uint(uchar({a}) {R.choice(["+", "*", "^", "-"])} uchar({b}))', f'uint(ushort({a}) {R.choice(["+", "^", "-", "|"])} ushort({b}))'])
    if k == 22: return f'(uint(int({R.choice(["char", "short"])}({a}))) {R.choice(["+", "*", "-", "^"])} {b})'
    if k == 23: return f'uint({R.choice(["uchar", "ushort"])}({a}) >> ({b} & 7u))'
    if k == 24: return f'uint(pc[({a}) & 7u])'
    if k == 25: return f'(({a} & 1u) != 0u ? {b} : {expr(d + 1)})'
    if k == 26: return f'uint(select(int({a}), int({b}), ({expr(d + 1)} & 2u) != 0u))'
    if k == 27: return f'(({a} % ({b} | 1u)))'
    if k == 28: return f'{R.choice(["min", "max"])}({a}, {b})'
    if k == 29: return f'(uint(ushort({a})) * uint(ushort({b})))'
    if k == 30: return f'uint(bool({a} & {b}))'
    if k == 31: return f'uint(!({a} > {b}))'
    if k == 32: return f'(~{a})'
    return f'uint(-int({a} & 0x7fffffffu))'


NARROW = {'uchar': (8, False), 'char': (8, True), 'ushort': (16, False), 'short': (16, True)}


def vconst(t, n, lo=None, hi=None):
    w, sg = NARROW[t]
    lo = lo if lo is not None else (-(1 << (w - 1)) if sg else 0)
    hi = hi if hi is not None else ((1 << (w - 1)) - 1 if sg else (1 << w) - 1)
    return f'{t}{n}(' + ', '.join(f'{t}({R.randint(lo, hi)})' for _ in range(n)) + ')'


def vexpr(t, n, d):  # an expression of type <t><n>, every lane defined for every input
    w, sg = NARROW[t]
    if ASTYPE and d < 2 and R.random() < 0.25:
        if n == 4 and w == 8: return f'as_type<{t}4>({vexpr(R.choice(["ushort", "short"]), 2, d + 1) if R.random() < 0.7 else expr(2)})'
        if n == 2 and w == 16: return f'as_type<{t}2>({vexpr(R.choice(["uchar", "char"]), 4, d + 1) if R.random() < 0.7 else expr(2)})'
    k = R.randrange(9 if d < 2 else 2)
    if k == 0: return f'{t}{n}(' + ', '.join(f'{t}({expr(2)})' for _ in range(n)) + ')'
    if k == 1: return vconst(t, n)
    a, b = vexpr(t, n, d + 1), vexpr(t, n, d + 1)
    if k == 2:  # divisors nonzero and, for signed lanes, positive (no x / 0, no MIN / -1)
        one, top = vconst(t, n, 1, 1), (1 << (w - 1)) - 1
        div = f'(({b}) & {vconst(t, n, top, top)} | {one})' if sg else f'(({b}) | {one})'
        if R.random() < 0.4: div = vconst(t, n, 1, top)  # constant divisors take another path in the adapter
        return f'({a} {R.choice(["/", "%"])} {div})'
    if k == 3:
        amt = f'(({b}) & {vconst(t, n, w - 1, w - 1)})' if R.random() < 0.6 else vconst(t, n, 0, w - 1)
        return f'({a} {">>" if sg else R.choice([">>", "<<"])} {amt})'
    if k == 4:
        op = R.choice(['&', '|', '^'] + ([] if sg else ['+', '-', '*']))
        return f'({a} {op} {b})'
    if k == 5:
        return f'select({a}, {b}, {vexpr(t, n, d + 1)} {R.choice(["<", ">", "<=", ">=", "==", "!="])} {vexpr(t, n, d + 1)})'
    if k == 6: return f'{R.choice(["min", "max"])}({a}, {b})'
    if k == 7 and n < 4: return f'({a}).{"yx" if n == 2 else "zxy"}'  # lane permutes (4-letter swizzles mean uint4 in cpuref)
    return f'({a} & {b})'


def vfold(t, n, v):  # a narrow vector folded into a uint, every lane counting (vf: VECHELPERS, also in cpuref.py)
    return f'vf({v})'


VECHELPERS = [f'static uint vf({t}{n} v) {{ return ' + ' ^ '.join(f'(uint(v.{c}) * {m}u)' for c, m in zip('xyzw'[:n], (1, 257, 65599, 16777619))) + '; }'
              for t in NARROW for n in (2, 3, 4)]


def vecexpr(d):
    t = R.choice(list(NARROW)); n = R.randrange(2, 5); w, sg = NARROW[t]
    k = R.randrange(6)
    if k <= 2: return vfold(t, n, f'({vexpr(t, n, 0)})')
    if k == 3: return f'uint({R.choice(["any", "all"])}({vexpr(t, n, 1)} {R.choice(["<", ">", "<=", ">=", "==", "!="])} {vexpr(t, n, 1)}))'
    a, b = expr(d + 1), expr(d + 1)  # narrow scalars: promoted to int in MSL, narrowed again by the optimizer
    if k == 4:
        if sg: return f'uint(int({t}({a}) {R.choice(["/", "%"])} {t}(({b} & {(1 << (w - 1)) - 1}u) | 1u)))'
        return f'uint({t}({a}) {R.choice(["/", "%"])} {t}({b} | 1u))'
    if k == 5:
        if R.random() < 0.5: return f'uint(int({t}({a}) >> ({b} & {w - 1}u)))'
        return f'({t}({a}) {R.choice(["<", ">", "<=", ">=", "==", "!="])} {t}({b}) ? {expr(d + 1)} : {expr(d + 1)})'


def wide(d):  # a ulong from two uint expressions
    return f'((ulong({expr(d + 1)}) << 32) | ulong({expr(d + 1)}))'


def longexpr(d):
    k = R.randrange(10)
    a, b = wide(d), wide(d)
    if k == 0: return f'uint((({a}) * ({b})) >> {R.randrange(0, 64)})'
    if k == 1: return f'uint(({a}) / (({b}) | 1ul))'
    if k == 2: return f'uint((({a}) % (({b}) | 1ul)) >> {R.randrange(0, 33)})'
    if k == 3: return f'uint(mulhi({a}, {b}) >> {R.randrange(0, 33)})'
    if k == 4: return f'(({a}) {R.choice(["<", ">", "<=", ">=", "==", "!="])} ({b}) ? {expr(d + 1)} : {expr(d + 1)})'
    if k == 5: return f'uint(long({a}) >> ({expr(d + 1)} & 63u))'
    if k == 6: return f'uint(long({a}) / long((({b}) & 0x7ffffffffffffffful) | 1ul))'
    if k == 7: return f'uint((long({a}) {R.choice(["<", ">", "<=", ">="])} long({b})) ? ({a}) >> 7 : ({b}) >> 11)'
    if k == 8: return f'uint({R.choice(["min", "max"])}({a}, {b}) >> {R.randrange(0, 33)})'
    return f'uint((({a}) << ({expr(d + 1)} & 63u)) >> 32)'


def emit(s):
    lines.append('    ' * (depth + 1) + s)


def block(n):
    global depth
    depth += 1
    for _ in range(n): stmt()
    depth -= 1


def stmt():
    global depth
    k = R.randrange(16)
    if k <= 3:
        emit(f'{var()} {R.choice(["=", "+=", "^=", "-="])} {expr()};')
    elif k == 4 and depth < 2:
        emit(f'if ({expr(1)} {R.choice(["<", ">", "==", "!="])} {expr(1)}) {{')
        block(R.randrange(1, 4))
        if R.random() < 0.5:
            emit('} else {')
            block(R.randrange(1, 3))
        emit('}')
    elif k == 5 and depth < 2:
        i = f'i{depth}'
        emit(f'for (uint {i} = 0; {i} < {R.randrange(1, 6)}u; {i}++) {{')
        depth += 1
        emit(f'{var()} += {i} * {R.randrange(1, 9)}u;')
        depth -= 1
        block(R.randrange(1, 3))
        emit('}')
    elif k == 6 and depth < 2:  # while with a data-dependent break, at most 8 trips
        n = f'n{depth}'
        emit(f'{{ uint {n} = 0u; while ({n} < 8u) {{ {n}++;')
        block(R.randrange(1, 3))
        emit(f'    if ((({expr(1)}) & 3u) == 0u) break; }} {var()} += {n}; }}')
    elif k == 7 and depth < 2:
        emit(f'switch (({expr(1)}) & 3u) {{')
        for c in range(R.randrange(1, 4)):
            emit(f'case {c}u: {{')
            block(R.randrange(1, 3))
            emit('    break; }' if R.random() < 0.8 else '    }')  # sometimes falls through
        emit('default: {')
        block(1)
        emit('    break; }')
        emit('}')
    elif k == 8:
        emit(f'p[({expr(1)}) & 7u] = {expr(1)};')
    elif k == 9:
        emit(f'{var()} ^= p[({expr(1)}) & 7u];')
    elif k == 10:
        emit(f'pc[({expr(1)}) & 7u] = uchar({expr(1)});')
    elif k == 11:  # vector elements at variable indexes
        emit(f'{{ uint4 w = uint4({expr(1)}, {var()}, {expr(1)}, {var()}); w[({expr(1)}) & 3u] = {expr(1)}; '
             f'{var()} += w[({expr(1)}) & 3u] ^ (w.y << 1u) ^ w.w; }}')
    elif k == 12 and depth == 0 and not FRAG:  # threadgroup memory at a variable index between barriers
        emit(f'{{ tg[l] = {expr(1)}; threadgroup_barrier(mem_flags::mem_threadgroup); '
             f'{var()} += tg[({expr(1)}) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }}')
    elif k == 13 and depth == 0 and not FRAG:  # threadgroup uchar array
        emit(f'{{ tc[l] = uchar({expr(1)}); threadgroup_barrier(mem_flags::mem_threadgroup); '
             f'{var()} += uint(tc[({expr(1)}) & 63u]) * {R.randrange(1, 300)}u; threadgroup_barrier(mem_flags::mem_threadgroup); }}')
    elif k == 14 and not FRAG:
        emit(f'atomic_fetch_add_explicit(&ta, ({expr(1)}) & 255u, memory_order_relaxed);')
    else:
        emit(f'{var()} = {expr()};')


HEAD = ['#include <metal_stdlib>', 'using namespace metal;',
       'kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],',
       '              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {',
       '    threadgroup uint tg[64];', '    threadgroup uchar tc[64];', '    threadgroup atomic_uint ta;',
       '    if (l == 0) atomic_store_explicit(&ta, 0u, memory_order_relaxed);',
       '    threadgroup_barrier(mem_flags::mem_threadgroup);']
if FRAG:
    HEAD = ['#include <metal_stdlib>', 'using namespace metal;',
            'vertex float4 vfull(uint vid [[vertex_id]]) { float2 q = float2((vid << 1) & 2, vid & 2); return float4(q * 2.0 - 1.0, 0.0, 1.0); }',
            'fragment float4 k(float4 pos [[position]], device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]]) {',
            '    uint t = uint(pos.x);']
if VEC: HEAD = HEAD[:2] + VECHELPERS + HEAD[2:]
src = HEAD + [
       '    uint p[8];', '    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;',
       '    uchar pc[8];', '    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[(t * 4u + (j & 3u))] >> j);']
src += [f'    uint v{i} = in[(t * 4u + {i % 4}u)] * {2 * i + 1}u + t;' for i in range(NV)]
for _ in range(nstmts): stmt()
# C-style casts: nested functional casts like uint(short(in[i])) parse as declarations in C++ (and MSL).
import re
lines = [re.sub(r'\b(uint|int|uchar|ushort|char|short|bool|ulong|long)\(', r'(\1)(', l) for l in lines]
lines.append('    threadgroup_barrier(mem_flags::mem_threadgroup);' if not FRAG else '    // end')
src += lines
src += [f'    out[t * 8u + {i}u] = v{i};' for i in range(NV)]
src += ['    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ '
        '(uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^ '
        '(uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);',
        '    out[t * 8u + 7u] = 0u;' if FRAG else '    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);']
if FRAG: src.append('    return float4(0.0);')
src.append('}')
print('\n'.join(src))
