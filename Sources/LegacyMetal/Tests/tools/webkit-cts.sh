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
# judged (compare with another GPU or browser). The window comes to the front.
# SPLIT=1: runs each child of <query> (its next parameter: for a test, usually one query per format) as a query of its
# own, one after the other, and sums them up: in a tree of thousands of cases the page itself slows WebKit down so far
# that cases time out ("EXCEPTION: Error: endTestScope timed out", on the HD 4000 after about 17 s; every one of them
# passed run alone), and small trees run about ten times faster.
set -u
T=$(cd "$(dirname "$0")/.." && pwd)
query=${1:?usage: webkit-cts.sh <query> [minutes]} minutes=${2:-120}
# A single WebGPU page runs behind a locked screen, but the CTS page stalls there (WebKit throttles the hidden window
# between cases: nothing after the spec files load): stop instead of waiting out the time limit
if ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
    echo "$(basename "$0"): the screen is locked; the CTS page can't run behind the lock screen (unlock, then run again)" >&2; exit 2
fi
host=$T/build/webkithost
mkdir -p "$T/build"
[ -x "$host" ] && [ "$host" -nt "$T/tools/webkithost.m" ] ||
    clang -fobjc-arc -framework Cocoa -framework WebKit "$T/tools/webkithost.m" -o "$host" || exit 2
encode() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=":,*=;"))' "$1"; }
if [ -n "${SPLIT:-}" ]; then
    # the page's node queries; the children are the root without its "*" plus one more parameter, ending in ";*"
    children=$(WEBKITHOST_SCRIPT="$T/tools/webkit-cts.js" "$host" "https://gpuweb.github.io/cts/standalone/?q=$(encode "$query")#list" 300 2>&1 |
        sed -n 's/^log: CTSQUERY //p' | python3 -I -c '
import sys
root = sys.argv[1][:-1]
for q in sys.stdin.read().split():
    rest = q[len(root):]
    if q.startswith(root) and rest.endswith(";*") and ";" not in rest[:-2] and "=" in rest: print(q)' "$query")
    [ -n "$children" ] || { echo "SPLIT=1: no child queries under $query" >&2; exit 2; }
    status=0 total=0
    while read -r child; do
        echo "== $child"
        SPLIT= "$0" "$child" "$minutes" | grep -E '^(final|failing cases|crash reports|results):' | sed 's/^/   /' || status=1
        d=$(ls -td "$T"/runs/webkit-cts-* | head -1)
        n=$(sed -n 's/^failing cases: //p' "$d/summary.txt")
        total=$((total + ${n:-0}))
        [ -n "$n" ] || status=1  # the child stopped before its summary
        grep -q '^crash reports: none' "$d/summary.txt" && grep -q '^final: {' "$d/summary.txt" || status=1
    done <<< "$children"
    echo "SPLIT total: $(wc -l <<< "$children" | tr -d ' ') queries, $total failing cases"
    exit $status
fi
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
    # WebKit's GPU process keeps compiled functions in its own Metal cache, keyed on the code and the compiler plugin but
    # not on the adapters (item 76 clears it when the installed ones change, not these): without this a run after a
    # rebuild tests the functions the previous build compiled
    rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.WebKit.GPU+webkithost/com.apple.WebKit.GPU/com.apple.metal"
    env=(__XPC_DYLD_INSERT_LIBRARIES="$B/MetalOldCompat.dylib:$T/tools/bronzeload.dylib"
         __XPC_AMD_BRONZE_COMPAT_PATH="$L/AMDBronzeCompat.dylib"
         __XPC___XPC_DYLD_LIBRARY_PATH="$L:$L/GeForceAIRPlugin.bundle/Contents/MacOS")
fi
mark=$(mktemp)
"$T/tools/crashwatch.sh" start "$mark"
url="https://gpuweb.github.io/cts/standalone/?q=$(encode "$query")"
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
