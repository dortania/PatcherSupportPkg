#!/usr/bin/env bash
# gpu.sh <kernel.metal> <GPU substring> [input seed]: runs a kernel on a GPU with fuzzrun (built into build/ on first use)
# and prints its output, compiled afresh every time. Gives up after 90 s (a GPU hang or a compiler loop): TIMEOUT.
# By default the kernel compiles with the Metal stack the Mac has installed. BUILD=1 uses the payload built by
# ../../build.sh instead, without installing it, as verify.sh's "with the fixes" column does: the compiler runs in the
# fuzzrun process (../tools/localcc.dylib) and takes the adapters and patched compiler files from that build.
# Other VAR=val settings in the environment reach the compiler too (an adapter's fix switch, e.g. INTEL_NARROW_SHIFT_FIX=0).
set -u
H=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$H/build"
if [ ! -x "$H/build/fuzzrun" ] || [ "$H/fuzzrun.m" -nt "$H/build/fuzzrun" ]; then
    clang -mmacosx-version-min=12.0 -fobjc-arc -O1 -framework Foundation -framework Metal "$H/fuzzrun.m" \
        -o "$H/build/fuzzrun" || exit 2
fi
run=("$H/build/fuzzrun" "$@")
if [ -n "${BUILD:-}" ]; then
    B=$(cd "$H/../.." && pwd)/build T=$(cd "$H/.." && pwd)
    [ -f "$B/IntelTextureAtomics.dylib" ] || { echo "BUILD=1: run ../../build.sh first" >&2; exit 2; }
    [ -f "$T/tools/localcc.dylib" ] || clang++ -std=c++17 -fblocks -dynamiclib "$T/tools/localcc.cpp" -o "$T/tools/localcc.dylib"
    [ -f "$T/tools/bronzeload.dylib" ] || clang -fobjc-arc -dynamiclib "$T/tools/bronzeload.m" -framework Foundation \
        -framework Metal -o "$T/tools/bronzeload.dylib"
    # The compiler files by their leaf names in a folder of their own (build/ also holds a Metal, which must not load).
    L=$H/build/libs; mkdir -p "$L"
    for f in AMDTextureAtomics.dylib IntelTextureAtomics.dylib libMTLIntelCompilerPlugin.dylib AMDBronzeCompat.dylib \
        AMDShared libAMDIL902.dylib; do
        [ "$B/$f" -nt "$L/$f" ] && cp -p "$B/$f" "$L/$f"
    done
    inserted=$T/tools/localcc.dylib:$T/tools/bronzeload.dylib
    [ -f /System/Library/Frameworks/Metal.framework/Versions/A/MetalOld.dylib ] && inserted=$B/MetalOldCompat.dylib:$inserted
    unset MTL_USE_AIRNT_BA
    run=(env AMD_BRONZE_COMPAT_PATH="$L/AMDBronzeCompat.dylib" DYLD_INSERT_LIBRARIES="$inserted" DYLD_LIBRARY_PATH="$L"
        "${run[@]}")
fi
# Metal's shader cache is keyed on the kernel, not on the compiler or its settings: without this, a kernel run again
# with other settings (BUILD=1, a fix switch, another installed stack) gets the first run's binary back. This is the cache
# of unbundled command-line tools, which run.sh and verify.sh drop too.
rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.metal"
out=$(perl -e 'alarm 90; exec @ARGV' "${run[@]}" 2>/dev/null)
[ $? -eq 142 ] && out=TIMEOUT  # SIGALRM
printf '%s\n' "$out"
