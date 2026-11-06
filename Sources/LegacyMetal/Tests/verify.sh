#!/usr/bin/env bash
# verify.sh [GPU substring]: runs every test twice without installing anything, and writes RESULTS.md:
#   with the fixes   the payload built by ../build.sh (shim, AMD and Intel adapters, patched libAMDIL902)
#   without the fix  the same, minus only the fix the test is about:
#                      shim tests          the no-op MetalOldCompat build (same load commands, does nothing)
#                      s12, s17, s19       AMDBronzeCompat not loaded
#                      s27                 the no-op MetalOldCompat build and AMD_BRONZE_MEMORYLESS=0
#                      a01, a05@Intel, i01 the stock AMDShared / libMTLIntelCompilerPlugin (adapters not loaded)
#                      a02, a04-a10, r01   the AMD adapter's own switch (AMD_SI_HAZARD_FIX=0, AMD_LDS_BASE_FIX=0,
#                                          AMD_HANDLE_FIX=0 + INTEL_HANDLE_FIX=0, AMD_NAN_FIX=0, AMD_LDEXP_FIX=0, AMD_GATHER_FIX=0,
#                                          AMD_CUBE_ARRAY_FIX=0, AMD_LDS_BOOL_FIX=0)
#                      i02                 the Intel adapter's switch (INTEL_SIGNED_SUBWORD_FIX=0)
#                      c01, c02            the stock libAMDIL902
#                      c03                 libAMDIL902 without patch 4
#                      c04                 libAMDIL902 without patch 5
# PAYLOAD=12.5-GCN-25 runs only the AMD compiler tests, with Tahoe's AMDShared copies (built for macOS 12.5, so they
# load on Sequoia too), and writes RESULTS-12.5-GCN-25.md.
# A GPU substring runs every test on that GPU, as with run.sh. Without one, each test uses the GPU its bug is about
# and reports SKIP (no such GPU) where that GPU is missing, so on a Mac without the AMD GPU run ./verify.sh Intel. The
# @GPU cases then run once, and the table goes to RESULTS-<GPU>.md.
# Needs: ../build.sh run first (its build/ folder, including build/stock/), an OCLP-patched Mac with the legacy Metal
# stack (the tests drive the real GPUs), Xcode command-line tools. MetalOldCompat links MetalOld.dylib, which only Macs
# with OCLP's MetalOld wrapper have (not GCN-only ones); without it the shim tests report SKIP and the rest run without it.
# How it works without installing: tools/localcc.dylib runs Metal's GPU-compiler requests inside the test process
# instead of in MTLCompilerService, so DYLD_LIBRARY_PATH picks the compiler files by name; the shim is loaded with
# DYLD_INSERT_LIBRARIES. A crash inside the in-process compiler leaves no result line and counts as the bug reproducing
# (out of process it is a compile error). tools/bronzeload.dylib loads AMDBronzeCompat once Metal has loaded the AMD
# driver, which the driver's load command does when installed. a03 needs Blender: run a03-si-stale-l1-blender.sh separately.
set -u
cd "$(dirname "$0")"
GPU=${1:-}  # GPU name substring for every test (optional)
B=$(cd .. && pwd)/build
[ -f "$B/AMDTextureAtomics.dylib" ] || { echo "run ../build.sh first" >&2; exit 2; }
[ -x build/s01-device-methods ] || ./build.sh > /dev/null
[ -f tools/localcc.dylib ] || clang++ -std=c++17 -fblocks -dynamiclib tools/localcc.cpp -o tools/localcc.dylib
[ -f tools/bronzeload.dylib ] || clang -fobjc-arc -dynamiclib tools/bronzeload.m -framework Foundation -framework Metal \
    -o tools/bronzeload.dylib
# The shim sets MTL_USE_AIRNT_BA=0 (s18's fix) in the processes it loads into, and children inherit it.
unset MTL_USE_AIRNT_BA
V=  # the AMDShared copy: "" (12.5) or -GCN-25
case ${PAYLOAD:-12.5} in 12.5) ;; 12.5-GCN-25) V=-GCN-25 ;; *) echo "PAYLOAD: 12.5 or 12.5-GCN-25" >&2; exit 2 ;; esac
FIXED=$(mktemp -d) NOADAPTER=$(mktemp -d) STOCK=$(mktemp -d) PATCH3=$(mktemp -d) PATCH4=$(mktemp -d)
cp "$B/AMDTextureAtomics.dylib" "$B/IntelTextureAtomics.dylib" "$B/libMTLIntelCompilerPlugin.dylib" "$FIXED/"
cp "$B/AMDShared$V" "$FIXED/AMDShared"
cp "$B/libAMDIL902$V.dylib" "$FIXED/libAMDIL902.dylib"
for d in "$NOADAPTER" "$STOCK" "$PATCH3" "$PATCH4"; do cp "$FIXED"/* "$d/"; done
cp "$B/stock/AMDShared$V" "$NOADAPTER/AMDShared"
cp "$B/stock/libMTLIntelCompilerPlugin.dylib" "$NOADAPTER/"
cp "$B/stock/libAMDIL902$V.dylib" "$STOCK/libAMDIL902.dylib"
PARSERFIX_SKIP_GEP_SELECT=1 python3 -I ../libAMDIL902/make_parser_fix.py "$B/stock/libAMDIL902$V.dylib" \
    "$PATCH3/libAMDIL902.dylib" > /dev/null
PARSERFIX_SKIP_STRUCT_MAP=1 python3 -I ../libAMDIL902/make_parser_fix.py "$B/stock/libAMDIL902$V.dylib" \
    "$PATCH4/libAMDIL902.dylib" > /dev/null
codesign -f -s - "$PATCH3/libAMDIL902.dylib" "$PATCH4/libAMDIL902.dylib" 2> /dev/null
SHIM=$B/MetalOldCompat.dylib NOOP=$B/MetalOldCompat-noop.dylib CC=$PWD/tools/localcc.dylib BRONZELOAD=$PWD/tools/bronzeload.dylib
[ -f /System/Library/Frameworks/Metal.framework/Versions/A/MetalOld.dylib ] || SHIM= NOOP=

# <test[@gpu]>:<what "without the fix" removes>
CASES="s01-device-methods:shim s02-reflection:shim s03-shader-atomic-usage:shim s27-memoryless-texture:memoryless s07-vertex-descriptor:shim
s08-sdk-properties:shim s09-msl-3.2:shim s10-device-over-release:shim s12-srgb-mipmaps:bronze s13-new-air-metallib:shim
s14-safari-argument-encoders:shim s15a-intel-msaa-resolve:shim s15b-intel-narrow-clear:shim s16-intel-array-view:shim
s17-amd-depth-stencil-view:bronze s18-pipeline-cache-key:shim s19-amd-trilinear-blend:bronze s25-amd-srgb-resolve:bronze s26-amd-depth-stencil-copy-pitch:bronze s29-amd-webkit-vertex-stride:bronze s30-amd-webkit-sample-mask:bronze
s20-intel-fill-buffer:shim s21-intel-depth-only-pipeline:shim s22-intel-depth-hiz-levels:shim s23-intel-3d-mip-plane:shim
s24-intel-narrow-mip-clear:shim a01-texture-atomics:adapter
a01-texture-atomics@Intel:adapter a02-si-smrd-hazard:smrd a04-si-threadgroup-pointer:ldsbase
a05-escaped-texture-pointer:handle a05-escaped-texture-pointer@Intel:handle a06-fast-math-nan-compare:nan a07-half-ldexp:ldexp a08-integer-gather:gather a09-cube-array-index:cubearray a10-threadgroup-bool:ldsbool
c01-amdil-argument-buffer:stock c02-amdil-color-input:stock c03-amdil-gep-select:patch3 c04-amdil-struct-type-map:patch4
i01-intel-array-struct-arg:adapter i02-intel-vertex-signed-subword:subword r01-amd-slot8-data-segment:ldsbase"

[ -n "$V" ] && CASES=$(for c in $CASES; do case $c in (*@*|i*|s*) ;; (*) echo "$c" ;; esac; done)
[ -n "$GPU" ] && CASES=$(for c in $CASES; do case $c in (*@*) ;; (*) echo "$c" ;; esac; done)

run() {  # <test[@gpu]> <removed fix or "fixed">
    local t=${1%%@*} gpu=$GPU shim=$SHIM libs=$FIXED
    [[ $1 == *@* ]] && gpu=${1#*@}
    local inject=$BRONZELOAD
    local -a env=()
    case $2 in
        bronze) inject= ;; shim) shim=$NOOP ;; memoryless) shim=$NOOP env=(AMD_BRONZE_MEMORYLESS=0) ;; adapter) libs=$NOADAPTER ;; stock) libs=$STOCK ;; patch3) libs=$PATCH3 ;; patch4) libs=$PATCH4 ;;
        smrd) env=(AMD_SI_HAZARD_FIX=0) ;; ldsbase) env=(AMD_LDS_BASE_FIX=0) ;; handle) env=(AMD_HANDLE_FIX=0 INTEL_HANDLE_FIX=0) ;;
        nan) env=(AMD_NAN_FIX=0) ;; ldexp) env=(AMD_LDEXP_FIX=0) ;; gather) env=(AMD_GATHER_FIX=0) ;; cubearray) env=(AMD_CUBE_ARRAY_FIX=0) ;; ldsbool) env=(AMD_LDS_BOOL_FIX=0) ;;
        subword) env=(INTEL_SIGNED_SUBWORD_FIX=0) ;;
    esac
    # s13's fix (item 25) works in MTLCompilerService, which gets the shim under test this way
    [ "$t" = s13-new-air-metallib ] && env+=(__XPC_DYLD_INSERT_LIBRARIES=$shim)
    rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.metal"
    env ${env[@]+"${env[@]}"} AMD_BRONZE_COMPAT_PATH=$B/AMDBronzeCompat.dylib \
        DYLD_INSERT_LIBRARIES=${shim:+$shim:}$CC${inject:+:$inject} DYLD_LIBRARY_PATH=$libs ./build/"$t" ${gpu:+"$gpu"} 2>/dev/null |
        grep -E '^(PASS|FAIL|SKIP) ' | tail -1
}

{
    echo "# Test results on $(sysctl -n hw.model), macOS $(sw_vers -productVersion) ($(date '+%Y-%m-%d %H:%M'))" \
        "${V:+(AMDShared from 12.5$V)}${GPU:+(every test on the GPU matching \"$GPU\")}"
    echo
    echo "Each test runs once without the fix it is about (everything else fixed) and once with all fixes; the GPU"
    echo "compilers run in the test process. \"crashed\" = the in-process compiler took the test down (a compile"
    echo "error out of process)."
    echo
    echo "| test | without the fix | with the fixes |"
    echo "|---|---|---|"
    for c in $CASES; do
        t=${c%%:*} removed=${c#*:}
        if [ -z "$SHIM" ] && [ "$removed" = shim ]; then
            before="SKIP ${t%%@*}: MetalOldCompat needs OCLP's MetalOld wrapper" after=$before
        else
            before=$(run "$t" "$removed"); before=${before:-FAIL: crashed (in-process compiler)}
            after=$(run "$t" fixed); after=${after:-FAIL: crashed (in-process compiler)}
        fi
        echo "$t" >&2; echo "  without: $before" >&2; echo "  with:    $after" >&2
        echo "| ${t/@/ on } | $before | $after |"
    done
} > "RESULTS${V:+-12.5$V}${GPU:+-$GPU}.md"
rm -rf "$FIXED" "$NOADAPTER" "$STOCK" "$PATCH3" "$PATCH4"
