# Differential fuzzing of the legacy Metal shader compilers

`mslfuzz2.py` writes random integer-only Metal kernels. Every operation in them is defined for every input: divisors
are odd and positive, shift and bit-field amounts are masked into range, and array indexes are masked into their arrays.
So every conforming compiler must give bit-identical results. `fuzzrun` runs a kernel on a GPU, and `cpuref.py` runs
the same kernel on the CPU as C++. When the two outputs differ, there is a bug in the GPU's compiler or driver (or, now
and then, in `cpuref.py`).

Most of this PR's Intel compiler fixes from i21 on were found this way, and FIXES.md names the seed behind each one.
The kernels cover:
- Metal's integer builtins
- signed and narrow types, and narrow vectors
- 64-bit integers
- private, threadgroup and vector-element accesses at variable indexes
- switch statements and while loops with break
- barriers and atomics

There are no floats, textures or graphics state.

`mslfuzz.py`, the first generator, covers pointer selects, bools in threadgroup memory and `uint4` swizzles, which `mslfuzz2.py`
doesn't. It found i17, where the Intel back end gave wrong results for 128 of its first 300 kernels.

## Running it

You need a Mac with the GPU to test, the Xcode command-line tools (clang and clang++ with C++20) and python3. Then, from
this folder:

```sh
./fuzz.sh Intel 1 1000                 # the "plain" kernels, seeds 1-1000
./fuzz.sh Intel 1 1000 VEC=1 ASTYPE=1  # narrow vectors and as_type (the "VEC" seeds)
./fuzz.sh Intel 1 500 LONG=1           # 64-bit integers (the "LONG" seeds)
./fuzz.sh AMD 1 1000 FRAG=1            # fragment functions instead of kernels
./fuzz.sh AMD 1 1000 GEN=mslfuzz.py    # the first generator
```

The first argument is a substring of the GPU's Metal name, matched without case: Intel, AMD or Radeon, NVIDIA, or
"default". By default, kernels compile with the Metal stack the Mac has installed, such as OCLP's, with or without this
PR's payload. `BUILD=1` uses the payload built by `../../build.sh` instead, without installing it. It works the same
way as the "with the fixes" column of `../verify.sh`. Any other `VAR=val` reaches the compiler as well. For example,
`INTEL_SIGNED_DIV_NEG_FIX=0` turns that one adapter fix off, which shows which kernels the fix is for. On the
MacBookPro11,4, each kernel takes about 2 s, so 1000 take about 35 minutes.

Results go to `runs/<GPU>[-<settings>]/`:

| File | Contents |
|---|---|
| `all.txt` | `<seed> ok` or `<seed> WRONG` for every kernel run |
| `diffs.txt` | `<seed> [<GPU's first line>\|<CPU's first line>]` for every kernel that differed |
| `k<seed>.metal` | each kernel that differed |

Run one GPU job at a time, because two at once can make the GPU drop work. A run that completes without writing its
output (`RUN untouched`) is retried once. `gpu.sh` empties Metal's shader cache before every run. The cache is keyed on
the kernel's text, not on the compiler, so without this a kernel run again with other settings would get the first
run's binary back.

## When a kernel differs

1. **Rerun it.** Use `./gpu.sh runs/Intel/k123.metal Intel` and `python3 cpuref.py runs/Intel/k123.metal`, adding the
   same settings in front of both. Each prints `HASH` followed by 8 words per thread for 256 threads:
   - words 0-5: v0 to v5
   - word 6: the private arrays
   - word 7: the threadgroup atomic sum (0 for fragment functions)

   The word that differs points at the variable to follow.
2. **Check the reference.** `cpuref.py` has been wrong twice: an integer `clamp` went through a float overload, and a
   signed `extract_bits` didn't sign-extend. The Metal Shading Language specification decides which side is right.
3. **Compare with stock.** Run the kernel on a stack without the payload, or with `BUILD=1` and the fix switches of the
   suspect area turned off. This tells a new bug apart from one that a fix introduced.
4. **Reduce it.** `./reduce.py runs/Intel/k123.metal Intel k123-red.metal` shrinks the kernel while the GPU still gets
   the same output words wrong. The same settings apply when given in front. A reduction takes minutes to an hour. It
   writes its output after every step, so stopping it keeps what it has found. A reduction can drift onto another
   bug that gets the same words wrong, so check the result the same way as in step 3.
5. **Make it a test.** Follow `../i61-intel-negated-dividend-fold.m`: the kernel inline, run on inputs 1-3, and the
   output hash compared with the CPU's. Then register the test in `../verify.sh`.

## Seeds

A seed always generates the same kernel, so the seeds named in FIXES.md and in the tests can be regenerated:

- `python3 mslfuzz2.py 7727` is "plain seed 7727".
- `VEC=1 ASTYPE=1 python3 mslfuzz2.py 2642` is "VEC seed 2642".
- `LONG=1 python3 mslfuzz2.py 741` is "LONG seed 741", which is `../data/i49-long-fuzz-741.metal`.

This holds only while the generator stays as it is. A change to `mslfuzz2.py` changes what every later seed generates.
New constructs therefore go behind a new setting, as VEC, ASTYPE, LONG and FRAG did, and the default output stays the
same.

## Results so far

The MacBookPro11,4's Iris Pro 5200 (Haswell GT3e) was tested with this PR's payload at 479fcaf. Its final round found
no wrong kernel in plain seeds 7651-9650, VEC seeds 7921-8920 or LONG seeds 3521-4020. Results from other GPUs are
welcome, above all from GPUs this PR hasn't been tested on. When posting one, include:
- the GPU and macOS version
- the settings and seed range
- what is installed
- the lines of `diffs.txt`

## Files

| File | What it does |
|---|---|
| `mslfuzz2.py <seed> [statements]` | prints a kernel (24 statements by default) |
| `mslfuzz.py <seed> [statements]` | the first generator, with the same harness |
| `cpuref.py <kernel> [input seed]` | prints the CPU's output; `--batch` takes many kernels and prints the hash of each, and `--batch-full` prints the whole output |
| `fuzzrun.m` | the GPU runner, which `gpu.sh` builds into `build/` |
| `gpu.sh <kernel> <GPU> [input seed]` | runs a kernel on the GPU (`BUILD=1`: with `../../build`), giving up after 90 s |
| `fuzz.sh <GPU> <first seed> <count> [VAR=val ...]` | runs a seed range on the GPU and the CPU |
| `reduce.py <kernel> <GPU> <out>` | shrinks a kernel from either generator that differs |
