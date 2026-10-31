#!/usr/bin/env bash
# verify.sh: runs every test twice without installing anything, and writes RESULTS.md:
#   with the fixes   the payload built by ../build.sh (shim, AMD and Intel adapters, patched libAMDIL902)
#   without the fix  the same, minus only the fix the test is about:
#                      shim tests          the no-op MetalOldCompat build (same load commands, does nothing)
#                      a01, a05@Intel, i01 the stock AMDShared / libMTLIntelCompilerPlugin (adapters not loaded)
#                      a02, a04, a05, r01  the AMD adapter's own switch (AMD_SI_HAZARD_FIX=0, AMD_LDS_BASE_FIX=0,
#                                          AMD_HANDLE_FIX=0 + INTEL_HANDLE_FIX=0)
#                      c01, c02            the stock libAMDIL902
#                      c03                 libAMDIL902 with patches 1-3 only
# Needs: ../build.sh run first (its build/ folder, including build/stock/), an OCLP-patched Mac with the legacy Metal
# stack (the tests drive the real GPUs), Xcode command-line tools.
# How it works without installing: tools/localcc.dylib runs Metal's GPU-compiler requests inside the test process
# instead of in MTLCompilerService, so DYLD_LIBRARY_PATH picks the compiler files by name; the shim is loaded with
# DYLD_INSERT_LIBRARIES. A crash inside the in-process compiler leaves no result line and counts as the bug reproducing
# (out of process it is a compile error). a03 needs Blender: run a03-si-stale-l1-blender.sh separately.
set -u
cd "$(dirname "$0")"
B=$(cd .. && pwd)/build
[ -f "$B/AMDTextureAtomics.dylib" ] || { echo "run ../build.sh first" >&2; exit 2; }
[ -x build/s01-device-methods ] || ./build.sh > /dev/null
[ -f tools/localcc.dylib ] || clang++ -std=c++17 -fblocks -dynamiclib tools/localcc.cpp -o tools/localcc.dylib
# The shim sets MTL_USE_AIRNT_BA=0 (s18's fix) in the processes it loads into, and children inherit it.
unset MTL_USE_AIRNT_BA
FIXED=$(mktemp -d) NOADAPTER=$(mktemp -d) STOCK=$(mktemp -d) PATCH3=$(mktemp -d)
cp "$B/AMDShared" "$B/AMDTextureAtomics.dylib" "$B/IntelTextureAtomics.dylib" "$B/libAMDIL902.dylib" \
   "$B/libMTLIntelCompilerPlugin.dylib" "$FIXED/"
for d in "$NOADAPTER" "$STOCK" "$PATCH3"; do cp "$FIXED"/* "$d/"; done
cp "$B/stock/AMDShared" "$B/stock/libMTLIntelCompilerPlugin.dylib" "$NOADAPTER/"
cp "$B/stock/libAMDIL902.dylib" "$STOCK/"
PARSERFIX_SKIP_GEP_SELECT=1 python3 -I ../libAMDIL902/make_parser_fix.py "$B/stock/libAMDIL902.dylib" "$PATCH3/libAMDIL902.dylib" > /dev/null
codesign -f -s - "$PATCH3/libAMDIL902.dylib" 2> /dev/null
SHIM=$B/MetalOldCompat.dylib NOOP=$B/MetalOldCompat-noop.dylib CC=$PWD/tools/localcc.dylib

# <test[@gpu]>:<what "without the fix" removes>
CASES="s01-device-methods:shim s02-reflection:shim s03-shader-atomic-usage:shim s07-vertex-descriptor:shim
s08-sdk-properties:shim s09-msl-3.2:shim s10-device-over-release:shim s12-srgb-mipmaps:shim s13-new-air-metallib:shim
s14-safari-argument-encoders:shim s15a-intel-msaa-resolve:shim s15b-intel-narrow-clear:shim s16-intel-array-view:shim
s17-amd-depth-stencil-view:shim s18-pipeline-cache-key:shim a01-texture-atomics:adapter a01-texture-atomics@Intel:adapter
a02-si-smrd-hazard:smrd a04-si-threadgroup-pointer:ldsbase a05-escaped-texture-pointer:handle
a05-escaped-texture-pointer@Intel:handle c01-amdil-argument-buffer:stock c02-amdil-color-input:stock
c03-amdil-gep-select:patch3 i01-intel-array-struct-arg:adapter r01-amd-slot8-data-segment:ldsbase"

run() {  # <test[@gpu]> <removed fix or "fixed">
    local t=${1%%@*} gpu= shim=$SHIM libs=$FIXED
    [[ $1 == *@* ]] && gpu=${1#*@}
    local -a env=()
    case $2 in
        shim) shim=$NOOP ;; adapter) libs=$NOADAPTER ;; stock) libs=$STOCK ;; patch3) libs=$PATCH3 ;;
        smrd) env=(AMD_SI_HAZARD_FIX=0) ;; ldsbase) env=(AMD_LDS_BASE_FIX=0) ;; handle) env=(AMD_HANDLE_FIX=0 INTEL_HANDLE_FIX=0) ;;
    esac
    rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.metal"
    env ${env[@]+"${env[@]}"} DYLD_INSERT_LIBRARIES=$shim:$CC DYLD_LIBRARY_PATH=$libs ./build/"$t" $gpu 2>/dev/null |
        grep -E '^(PASS|FAIL|SKIP) ' | tail -1
}

{
    echo "# Test results on $(sysctl -n hw.model), macOS $(sw_vers -productVersion) ($(date '+%Y-%m-%d %H:%M'))"
    echo
    echo "Each test runs once without the fix it is about (everything else fixed) and once with all fixes; the GPU"
    echo "compilers run in the test process. \"crashed\" = the in-process compiler took the test down (a compile error out"
    echo "of process). s13 shows a limitation that only Safari's case works around, so it fails both times."
    echo
    echo "| test | without the fix | with the fixes |"
    echo "|---|---|---|"
    for c in $CASES; do
        t=${c%%:*} removed=${c#*:}
        before=$(run "$t" "$removed"); before=${before:-FAIL: crashed (in-process compiler)}
        after=$(run "$t" fixed); after=${after:-FAIL: crashed (in-process compiler)}
        echo "$t" >&2; echo "  without: $before" >&2; echo "  with:    $after" >&2
        echo "| ${t/@/ on } | $before | $after |"
    done
} > RESULTS.md
rm -rf "$FIXED" "$NOADAPTER" "$STOCK" "$PATCH3"
