#!/usr/bin/env bash
# webkit-cts.sh <query> [minutes]: runs a WebGPU CTS query (webgpu:shader,execution,expression,call,builtin,textureSample:*,
# webgpu:api,operation,*, ...) from the hosted standalone runner (https://gpuweb.github.io/cts/standalone/) in WebKit, as
# Safari runs WebGPU (its WGSL compiler, argument buffers for every bind group), through tools/webkithost.m, an app of our
# own: Chrome's Dawn binds resources directly and never reaches the Ivy Bridge argument-buffer paths (MetalOldCompat items
# 47 and 79), WebKit does. [minutes]: time limit (default 120). Query one test at a time (...,textureSample:sampled_2d_coords:*)
# to get every case: for a broader query the page keeps the tree collapsed and lists only its tests.
# STACK=installed (default): the root-patched stack. STACK=build: ../build.sh's payload without installing it, as
# verify.sh's "with the fixes" column: MetalOldCompat (and bronzeload) injected into WebKit's GPU process, and the
# adapters and compiler files (fuzz/build/libs, refreshed as BUILD=1 fuzz/gpu.sh does) into the MTLCompilerService it
# starts. Other __XPC_ settings in the environment reach the GPU process (__XPC_MTLSHIM_TEST_IGPU_ONLY=1, a fix switch:
# __XPC_MTLSHIM_IVB_ARGUMENT_BUFFER_TEXTURES=0), __XPC___XPC_ ones the compiler service (__XPC___XPC_INTEL_IVB_...=0).
# Results: runs/webkit-cts-<time>/ (log.txt: the counts every 15 s, every failing node (CTSNODE) and the failure text of
# the first ten failing cases (CTSLOG); summary.txt: the query, the final counts and crash reports). FAIL (exit 1) when
# MTLCompilerService or a WebKit process wrote a crash report, or the page never finished; CTS failures are listed, not
# judged (compare with another GPU or browser). The window comes to the front; WebGPU runs behind a locked screen.
set -u
T=$(cd "$(dirname "$0")/.." && pwd)
query=${1:?usage: webkit-cts.sh <query> [minutes]} minutes=${2:-120}
host=$T/build/webkithost
mkdir -p "$T/build"
[ -x "$host" ] && [ "$host" -nt "$T/tools/webkithost.m" ] ||
    clang -fobjc-arc -framework Cocoa -framework WebKit "$T/tools/webkithost.m" -o "$host" || exit 2
out=$T/runs/webkit-cts-$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
env=()
if [ "${STACK:-installed}" = build ]; then
    B=$(cd "$T/.." && pwd)/build L=$T/fuzz/build/libs
    [ -f "$B/MetalOldCompat.dylib" ] || { echo "STACK=build: run ../build.sh first" >&2; exit 2; }
    # gpu.sh puts the build's compiler files in fuzz/build/libs (copied only when changed) and runs this kernel with them
    k=$(mktemp -d)/k.metal
    printf 'kernel void k(device uint *o [[buffer(0)]], uint t [[thread_position_in_grid]]) { o[t] = t; }\n' > "$k"
    BUILD=1 "$T/fuzz/gpu.sh" "$k" > /dev/null 2>&1
    rm -rf "${k%/k.metal}"
    [ -f "$L/IntelTextureAtomics.dylib" ] || { echo "STACK=build: fuzz/gpu.sh didn't make $L" >&2; exit 2; }
    env=(__XPC_DYLD_INSERT_LIBRARIES="$B/MetalOldCompat.dylib:$T/tools/bronzeload.dylib"
         __XPC_AMD_BRONZE_COMPAT_PATH="$L/AMDBronzeCompat.dylib"
         __XPC___XPC_DYLD_LIBRARY_PATH="$L:$L/GeForceAIRPlugin.bundle/Contents/MacOS")
fi
mark=$(mktemp)
"$T/tools/crashwatch.sh" start "$mark"
url="https://gpuweb.github.io/cts/standalone/?q=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=":,*=;"))' "$query")"
echo "$query (${STACK:-installed} stack): $url" | tee "$out/summary.txt"
# everything to log.txt, the counts as they come to the terminal
env ${env[@]+"${env[@]}"} WEBKITHOST_SCRIPT="$T/tools/webkit-cts.js" "$host" "$url" $((minutes * 60)) 2>&1 | tee "$out/log.txt" |
    grep --line-buffered -E '^log: CTS (started|[0-9]{2}:)' | sed -u 's/^log: //'
final=$(grep -m1 '^log: CTS final' "$out/log.txt" | sed 's/^log: CTS final //')
crashes=$("$T/tools/crashwatch.sh" new "$mark" MTLCompilerService com.apple.WebKit | tr '\n' ' ')
rm -f "$mark"
failing=$(grep '^log: CTSNODE fail .*[^*]$' "$out/log.txt" | sort -u | wc -l | tr -d ' ')
{ echo "final: ${final:-none (time limit or the page never ran)}"; echo "failing cases: $failing"; echo "crash reports: ${crashes:-none}"; } |
    tee -a "$out/summary.txt"
echo "results: $out"
[ -z "$crashes" ] && [ -n "$final" ] && [[ $final != *stalled* ]]
