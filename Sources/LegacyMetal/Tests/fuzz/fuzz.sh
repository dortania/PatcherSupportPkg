#!/usr/bin/env bash
# fuzz.sh <GPU substring> <first seed> <count> [VAR=val ...]: generates kernels first..first+count-1 with mslfuzz2.py, runs
# each on the GPU (gpu.sh) and on the CPU (cpuref.py), and reports every kernel whose output differs. The VAR=val
# settings reach the generator, the GPU run and the CPU reference alike:
#   VEC=1 ASTYPE=1   narrow vectors and as_type (the PR's "VEC" seeds)
#   LONG=1           64-bit integers (the PR's "LONG" seeds); none of the three: the "plain" seeds
#   FRAG=1           fragment functions instead of kernels
#   BUILD=1          the payload built by ../../build.sh instead of the installed Metal stack (see gpu.sh)
#   GEN=mslfuzz.py   the first generator (pointer selects, threadgroup bools, uint4 swizzles) instead of mslfuzz2.py
#   an adapter's fix switch, e.g. INTEL_SIGNED_DIV_NEG_FIX=0, to see what a fix is for
# Results go to runs/<GPU>[-<settings>]/: all.txt (one "<seed> ok|WRONG" line per kernel, appended to across runs),
# diffs.txt ("<seed> [<GPU's first line>|<CPU's first line>]") and k<seed>.metal for every kernel that differed.
# Run one GPU job at a time: two at once can make the GPU drop work.
set -u
[ $# -ge 3 ] || { sed -n '2,13s/^# \{0,1\}//p' "$0" >&2; exit 2; }
H=$(cd "$(dirname "$0")" && pwd)
gpu=$1 first=$2 count=$3; shift 3
gen=mslfuzz2.py tag=$gpu
for kv in "$@"; do tag=$tag-$kv; case $kv in GEN=*) gen=${kv#GEN=} ;; esac; done
[ -f "$H/$gen" ] || { echo "no generator $gen" >&2; exit 2; }
[ "$(env "$@" "$H/gpu.sh" /dev/null "$gpu" | head -1)" = NODEVICE ] &&
    { echo "no GPU named like \"$gpu\" (see system_profiler SPDisplaysDataType)" >&2; exit 2; }
d=$H/runs/${tag//[^A-Za-z0-9=._-]/_}; mkdir -p "$d"
wrong=0 n=0
for ((c = first; c < first + count; c += 50)); do
    end=$((c + 50 < first + count ? c + 50 : first + count))
    files=()
    for ((s = c; s < end; s++)); do
        env "$@" python3 "$H/$gen" $s > "$d/k$s.metal"
        files+=("$d/k$s.metal")
    done
    # One CPU binary for the chunk (compiling is most of the time); a kernel it misses runs on its own below.
    cpu=$(env "$@" python3 "$H/cpuref.py" --batch "${files[@]}")
    for f in "${files[@]}"; do
        s=${f##*/k}; s=${s%.metal}
        c1=$(grep -F "$f HASH " <<< "$cpu" | cut -d' ' -f2-)
        [ -n "$c1" ] || c1=$(env "$@" python3 "$H/cpuref.py" "$f" | head -1)
        g1=$(env "$@" "$H/gpu.sh" "$f" "$gpu" | head -1)
        # A dropped dispatch (seen under load on Haswell) says nothing about the compiler: once more.
        [ "$g1" = "RUN untouched" ] && g1=$(env "$@" "$H/gpu.sh" "$f" "$gpu" | head -1)
        n=$((n + 1))
        if [[ $c1 == HASH* ]] && [ "$g1" = "$c1" ]; then
            echo "$s ok" >> "$d/all.txt"; rm -f "$f"
        else
            echo "$s WRONG" >> "$d/all.txt"; echo "$s [$g1|$c1]" | tee -a "$d/diffs.txt"; wrong=$((wrong + 1))
        fi
    done
done
echo "$gpu $first..$((first + count - 1))${*:+ $*}: $wrong of $n differ (runs/${d##*/runs/})"
