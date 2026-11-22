#!/usr/bin/env bash
# fuzz.sh <GPU substring> <first seed> <count> [VAR=val ...]: generates kernels first..first+count-1 with mslfuzz2.py, runs
# each on the GPU (gpu.sh) and on the CPU (cpuref.py), and reports every kernel whose output differs. The VAR=val
# settings reach the generator, the GPU run and the CPU reference alike:
#   VEC=1 ASTYPE=1   narrow vectors and as_type (the PR's "VEC" seeds)
#   LONG=1           64-bit integers (the PR's "LONG" seeds); none of the three: the "plain" seeds
#   FRAG=1           fragment functions instead of kernels
#   ANGLE=1          what Chromium's ANGLE writes: __asm__("") in loops, metal::array, function constants (mslfuzz2.py)
#   AIRMIN=10.14     each kernel built by Xcode's metal for that macOS target and loaded as a prebuilt metallib (gpu.sh)
#   BUILD=1          the payload built by ../../build.sh instead of the installed Metal stack (see gpu.sh)
#   GEN=mslfuzz.py   the first generator (pointer selects, threadgroup bools, uint4 swizzles) instead of mslfuzz2.py
#   an adapter's fix switch, e.g. INTEL_SIGNED_DIV_NEG_FIX=0, to see what a fix is for
# Results go to runs/<GPU>[-<settings>]/: all.txt (one "<seed> ok|WRONG" line per kernel, appended to across runs),
# diffs.txt ("<seed> [<GPU's first line>|<CPU's first line>]") and k<seed>.metal for every kernel that differed.
# Run one GPU job at a time: two at once can make the GPU drop work.
set -u
[ $# -ge 3 ] || { sed -n '2,15s/^# \{0,1\}//p' "$0" >&2; exit 2; }
H=$(cd "$(dirname "$0")" && pwd)
gpu=$1 first=$2 count=$3; shift 3
gen=mslfuzz2.py tag=$gpu
mark=$(mktemp); "$H/../tools/crashwatch.sh" start "$mark"  # crash reports written during the run are counted at the end
for kv in "$@"; do tag=$tag-$kv; case $kv in GEN=*) gen=${kv#GEN=} ;; esac; done
# AIRMIN needs Xcode's metal; with only the command-line tools selected every kernel would come back as a "difference"
case " $* " in *" AIRMIN="*) xcrun -sdk macosx -f metal > /dev/null 2>&1 ||
    { echo "AIRMIN: Xcode's metal compiler isn't selected (set DEVELOPER_DIR to Xcode's Contents/Developer, or xcode-select)" >&2; exit 2; } ;; esac
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
        # A dropped dispatch (seen under load on Haswell), or a run that printed nothing at all (once each on the HD 4000
        # and the Iris Pro; both right when run again), says nothing about the compiler: once more.
        { [ "$g1" = "RUN untouched" ] || [ -z "$g1" ]; } && g1=$(env "$@" "$H/gpu.sh" "$f" "$gpu" | head -1)
        n=$((n + 1))
        if [[ $c1 == HASH* ]] && [ "$g1" = "$c1" ]; then
            echo "$s ok" >> "$d/all.txt"; rm -f "$f"
        else
            echo "$s WRONG" >> "$d/all.txt"; echo "$s [$g1|$c1]" | tee -a "$d/diffs.txt"; wrong=$((wrong + 1))
        fi
    done
done
crashes=$("$H/../tools/crashwatch.sh" new "$mark" MTLCompilerService fuzzrun | wc -l | tr -d ' '); rm -f "$mark"
note=; [ "${crashes:-0}" != 0 ] && note=", $crashes crash report(s) from MTLCompilerService or fuzzrun written meanwhile"
echo "$gpu $first..$((first + count - 1))${*:+ $*}: $wrong of $n differ (runs/${d##*/runs/})$note"
