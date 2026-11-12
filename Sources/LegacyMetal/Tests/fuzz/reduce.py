#!/usr/bin/env python3
# reduce.py <kernel.metal> <GPU substring> <out.metal>: shrinks a mslfuzz2.py kernel while the GPU still differs from the
# CPU reference in the same output words. Each round tries every candidate at once: the GPU runs them one after the
# other (gpu.sh, so BUILD=1 and fix switches in the environment apply), the CPU reference compiles them all into one
# binary (cpuref.py --batch-full), and the round keeps the biggest candidate that still fails the same way. Statements at
# any depth (a line, or a block with balanced braces: if/for/while/switch/case), then parenthesized expressions
# (replaced by 1u, then v0), then long constants. Writes <out.metal> after every step, so stopping it keeps what was found.
# LOOSE=1 keeps any candidate the GPU still gets wrong; COMPILEFAIL=1 shrinks a kernel the GPU's compiler rejects.
import os, re, subprocess, sys, tempfile

path, gpu, outpath = sys.argv[1:4]
HERE = os.path.dirname(os.path.abspath(__file__))
WORK = tempfile.mkdtemp(prefix='reduce2-')
CHUNK = 60
LOOSE = bool(os.environ.get('LOOSE'))  # keep any candidate the GPU still gets wrong, not only the same output words


def gpu_words(paths):
    out = []
    for p in paths:
        try:
            r = subprocess.run([f'{HERE}/gpu.sh', p, gpu], capture_output=True, text=True, timeout=120).stdout.split('\n')
        except subprocess.TimeoutExpired:
            r = ['TIMEOUT']
        out.append(r)
    return out


def cpu_words(paths):
    r = subprocess.run(['python3', f'{HERE}/cpuref.py', '--batch-full'] + paths, capture_output=True, text=True, timeout=900).stdout.split('\n')
    res, i = {}, 0
    while i < len(r):
        if ' HASH ' in r[i]:
            name = r[i].split(' HASH ')[0]
            res[name] = ['HASH ' + r[i].split(' HASH ')[1]] + r[i + 1:i + 257]
            i += 257
        else:
            i += 1
    return [res.get(p) for p in paths]


COMPILEFAIL = bool(os.environ.get('COMPILEFAIL'))  # shrink a kernel the GPU's compiler fails on (the CPU's builds)


def wrong(g, c):
    if COMPILEFAIL:
        return frozenset({'compile'}) if g and c and g[0].startswith('COMPILE') and c[0].startswith('HASH') else None
    if not g or not c or not g[0].startswith('HASH') or not c[0].startswith('HASH'): return None
    words = set()
    for lg, lc in zip(g[1:257], c[1:257]):
        for w, (a, b) in enumerate(zip(lg.split(), lc.split())):
            if a != b: words.add(w)
    return frozenset(words)


def evaluate(texts):
    """wrong-word sets for each text (None: didn't build or run)."""
    results = []
    for n in range(0, len(texts), CHUNK):
        chunk = texts[n:n + CHUNK]
        paths = []
        for k, t in enumerate(chunk):
            p = os.path.join(WORK, f'c{n + k}.metal')
            open(p, 'w').write(t)
            paths.append(p)
        cs = cpu_words(paths)
        gs = gpu_words(paths)
        results += [wrong(g, c) for g, c in zip(gs, cs)]
    return results


def body_range(lines):
    start = next(i for i, l in enumerate(lines) if l.strip().startswith('uint v5 =')) + 1
    end = max(i for i, l in enumerate(lines) if l.strip() in ('threadgroup_barrier(mem_flags::mem_threadgroup);', '// end'))
    return start, end


def units(lines):
    """(a, b) line ranges of removable statements at any depth."""
    start, end = body_range(lines)
    out = []
    for i in range(start, end):
        s = lines[i].strip()
        if not s or s.startswith('}'): continue
        net = lines[i].count('{') - lines[i].count('}')
        if net < 0: continue
        if net == 0:
            out.append((i, i + 1))
            continue
        d, j = 0, i
        while j < end:
            d += lines[j].count('{') - lines[j].count('}')
            if d <= 0: break
            j += 1
        if d == 0: out.append((i, j + 1))
    return out


def same(r):
    return bool(r) if LOOSE else r == TARGET


def save(text):
    open(outpath, 'w').write(text)


text = open(path).read()
TARGET = evaluate([text])[0]
assert TARGET, 'not failing to begin with'
print(f'target words {sorted(TARGET)}', file=sys.stderr, flush=True)
save(text)

# 1. statements
while True:
    lines = text.split('\n')
    cands = []
    for a, b in units(lines):
        cands.append((b - a, '\n'.join(lines[:a] + lines[b:])))
    res = evaluate([c[1] for c in cands])
    good = [c for c, r in zip(cands, res) if same(r)]
    if not good: break
    text = max(good, key=lambda c: c[0])[1]
    save(text)
    print(f'statements: {len(units(text.split(chr(10))))} left', file=sys.stderr, flush=True)

# 2. expressions: parenthesized groups -> 1u, v0
def groups(t):
    a0, b0 = t.index('uint v5 ='), (t.rindex('// end') if '// end' in t else t.rindex('threadgroup_barrier'))
    a0 = t.index('\n', a0) + 1
    out, stack = [], []
    for i in range(a0, b0):
        if t[i] == '(':
            stack.append(i)
        elif t[i] == ')' and stack:
            out.append((stack.pop(), i + 1))
    return out

# A group that makes its value safe to use (an odd divisor, a masked shift amount or index, a masked value to negate)
# never becomes v0: the kernel would be undefined for some inputs, and the reduction would chase that instead.
MASKED = re.compile(r'(&\s*(0x[0-9a-fA-F]+|\d+)u|\|\s*1ul?)\s*$')
for repl in ('1u', 'v0'):
    while True:
        cands = []
        for a, b in groups(text):
            inner = text[a + 1:b - 1]
            if inner.strip() in ('1u', 'v0') or inner.startswith('thread ') or ('&p[' in inner and '?' not in inner): continue
            if a and (text[a - 1].isalnum() or text[a - 1] == '_'): continue  # a call's argument list
            if inner.strip() in ('uint', 'int', 'uchar', 'ushort', 'char', 'short', 'bool'): continue  # a cast
            if repl == 'v0' and MASKED.search(inner): continue
            cands.append((b - a, text[:a] + repl + text[b:]))
        if not cands: break
        cands.sort(key=lambda c: -c[0])
        res = evaluate([c[1] for c in cands])
        good = [c for c, r in zip(cands, res) if same(r)]
        if not good: break
        text = good[0][1]
        save(text)
        print(f'expressions ({repl}): {len(text)} chars', file=sys.stderr, flush=True)

# 3. constants
while True:
    ms = [m for m in re.finditer(r'\b\d{3,}u\b', text)]
    cands = [text[:m.start()] + '1u' + text[m.end():] for m in ms]
    if not cands: break
    res = evaluate(cands)
    good = [c for c, r in zip(cands, res) if same(r)]
    if not good: break
    text = good[0]
    save(text)
print('done', file=sys.stderr)
