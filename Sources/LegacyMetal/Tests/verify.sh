#!/usr/bin/env bash
# verify.sh [GPU substring]: runs every test twice without installing anything, and writes RESULTS.md:
#   with the fixes   the payload built by ../build.sh (shim, AMD and Intel adapters, patched libAMDIL902)
#   without the fix  the same, minus only the fix the test is about:
#                      shim tests          the no-op MetalOldCompat build (same load commands, does nothing)
#                      s12, s25, s26, s29, s44, s43@AMD, s46, s47, s48, s37@AMD
#                                          AMDBronzeCompat off (not injected, AMD_BRONZE_COMPAT=0 in case it is installed)
#                      s17                 AMDBronzeCompat off and MTLSHIM_STENCIL_SUBRESOURCE=0
#                      s19                 AMDBronzeCompat off and INTEL_COMPUTE_TRILINEAR_FIX=0
#                      s09, s30            AMDBronzeCompat off and the no-op MetalOldCompat build
#                      s27                 the no-op MetalOldCompat build and AMD_BRONZE_MEMORYLESS=0
#                      a01, a05@Intel, i01 the stock AMDShared / libMTLIntelCompilerPlugin (adapters not loaded)
#                      a02, a04-a20, r01   the AMD adapter's own switch (AMD_SI_HAZARD_FIX=0, AMD_LDS_BASE_FIX=0,
#                                          AMD_HANDLE_FIX=0 + INTEL_HANDLE_FIX=0, AMD_NAN_FIX=0, AMD_LDEXP_FIX=0,
#                                          AMD_GATHER_FIX=0 + INTEL_INTEGER_OFFSET_FIX=0,
#                                          AMD_CUBE_ARRAY_FIX=0, AMD_LDS_BOOL_FIX=0 + INTEL_THREADGROUP_BOOL_FIX=0,
#                                          AMD_FMASK_FIX=0, AMD_UNPACK_FIX=0, AMD_PRIVATE_STORE_FIX=0,
#                                          AMD_SATURATE_FIX=0 + AMD_ROTATE_FIX=0, AMD_BIT_TEST_FIX=0 + AMD_LOOP_EXIT_FIX=0,
#                                          AMD_NARROW_CONSTANT_FIX=0, AMD_CUBE_GATHER_FIX=0,
#                                          AMD_BITCAST_LANE_FIX=0, AMD_FLOAT_ATOMIC_FIX=0,
#                                          AMD_WIDE_COMPARE_FIX=0)
#                      i02-i16             the Intel adapter's switch (INTEL_SIGNED_SUBWORD_FIX=0, INTEL_COMPARE_BIAS_FIX=0,
#                                          INTEL_INTEGER_OFFSET_FIX=0, INTEL_SAMPLER_STATE_FIX=0, INTEL_VERTEX_FLOAT3_FIX=0,
#                                          INTEL_PRIVATE_ARRAY_FIX=0, INTEL_KERNEL_GRADIENT_FIX=0,
#                                          INTEL_FRAGMENT_FLOAT3_FIX=0, INTEL_NUM_SAMPLES_FIX=0, INTEL_SWIZZLE_IMMEDIATE_FIX=0,
#                                          INTEL_BRANCH_CHAIN_FIX=0, INTEL_BASE_VERTEX_FIX=0,
#                                          INTEL_SIMD16_CLOBBER_FIX=0, INTEL_FINE_DERIVATIVES_FIX=0, INTEL_TYPE_PUN_FIX=0)
#                      c01, c02            the stock libAMDIL902
#                      c03                 libAMDIL902 without patch 4 and INTEL_PRIVATE_ALIGN_FIX=0
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
# AMDBronzeCompat goes in the library folders too: where it is installed, the driver loads it by leaf name from there
# instead of the installed copy, which would otherwise take the driver code first.
cp "$B/AMDTextureAtomics.dylib" "$B/IntelTextureAtomics.dylib" "$B/libMTLIntelCompilerPlugin.dylib" "$B/AMDBronzeCompat.dylib" "$FIXED/"
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
s08-sdk-properties:shim s09-msl-3.2:bronzeshim s10-device-over-release:shim s12-srgb-mipmaps:bronze s13-new-air-metallib:shim
s14-safari-argument-encoders:shim s15a-intel-msaa-resolve:shim s15b-intel-narrow-clear:shim s16-intel-array-view:shim
s17-amd-depth-stencil-view:bronzestencil s18-pipeline-cache-key:shim s19-amd-trilinear-blend:trilinear s25-amd-srgb-resolve:bronze s26-amd-depth-stencil-copy-pitch:bronze s29-amd-webkit-vertex-stride:bronze s30-amd-webkit-sample-mask:bronzeshim s44-amd-depth-stencil-mip-read:bronze s43-intel-stencil-view-mips@AMD:bronze s46-amd-stencil-view-subresources:bronze s47-amd-stencil-only-attachment:bronze s48-amd-stencil8-levels-slices:bronze s37-intel-stencil-subresources@AMD:bronze
s20-intel-fill-buffer:shim s21-intel-depth-only-pipeline:shim s22-intel-depth-hiz-levels:shim s23-intel-3d-mip-plane:shim
s24-intel-narrow-mip-clear:shim s31-angle-family-one:shim s32-intel-depth-stencil-blit:shim s33-intel-nil-argument-buffer:shim s34-intel-small-integer-cube:shim s35-intel-encoder-lod-clamp:shim s36-intel-swizzle-view:shim s37-intel-stencil-subresources:shim s38-intel-coverage-without-writes:shim s39-intel-mps-statistics:shim s40-intel-msaa-stencil8-read:shim s41-intel-stencil-copy-rows:shim s42-shim-owned-returns:shim s43-intel-stencil-view-mips:shim s45-intel-writable-view-size:shim s49-intel-writable-array-view-layers:targetdepth s50-intel-compute-compare-sampler:computecompare s51-intel-compute-lod-preclamp:lodpreclamp a01-texture-atomics:adapter
a01-texture-atomics@Intel:adapter a02-si-smrd-hazard:smrd a04-si-threadgroup-pointer:ldsbase
a05-escaped-texture-pointer:handle a05-escaped-texture-pointer@Intel:handle a06-fast-math-nan-compare:nan a07-half-ldexp:ldexp a08-integer-gather:gather a09-cube-array-index:cubearray a10-threadgroup-bool:ldsbool a12-amd-unpack-norm:unpack a13-amd-private-array-stores:privatestore a14-amd-integer-builtins:intbuiltins a15-amd-branch-conditions:branchcond a16-amd-narrow-constants:narrowconst a17-amd-integer-cube-gather:amdcubegather a18-amd-bitcast-lanes:bitcastlane a19-amd-float-atomics:floatatomic a20-amd-wide-compares:widecompare a11-msaa-shader-read:fmask
c01-amdil-argument-buffer:stock c02-amdil-color-input:stock c03-amdil-gep-select:patch3 c04-amdil-struct-type-map:patch4
i01-intel-array-struct-arg:adapter i02-intel-vertex-signed-subword:subword i03-intel-shadow-compare-bias:comparebias i04-intel-integer-texel-offset:intoffset i05-intel-constexpr-sampler:samplerstate i05-intel-constexpr-sampler@AMD:samplerstate i06-intel-vertex-float3-input:float3 i07-intel-private-array-index:privatearray i08-intel-kernel-integer-gradient:kernelgradient i09-intel-fragment-float3-compare:fragfloat3 i10-intel-num-samples:numsamples i11-intel-swizzle-immediate:swizzleimm i12-intel-branch-chain-compile:branchchain i13-intel-indirect-vertex-id:basevertex i14-intel-simd16-clobber:simd16clobber i15-intel-fine-derivatives:finederiv i16-intel-type-punned-buffer:typepun i17-intel-private-pointer-select:privateselect i18-intel-buffer-copy-after-store:typepun i19-intel-kernel-gather-offset:kernelgather i20-intel-cube-gather-seam:cubegather i21-intel-mad-sat-mul-hi:madsat i22-intel-narrow-min-max:narrowminmax i23-intel-buffer-pointer-select:bufferselect i24-intel-compute-compare-level:samplelod i26-intel-signed-div-negated:signeddivneg i27-intel-64bit-multiply:mul64 i28-intel-signed-div-pow2:sdivpow2 i29-intel-narrow-mask:narrowmask i30-intel-narrow-udiv:narrowudiv i31-intel-narrow-div:narrowdiv r01-amd-slot8-data-segment:ldsbase"

[ -n "$V" ] && CASES=$(for c in $CASES; do case $c in (*@*|i*|s*) ;; (*) echo "$c" ;; esac; done)
[ -n "$GPU" ] && CASES=$(for c in $CASES; do case $c in (*@*) ;; (*) echo "$c" ;; esac; done)

run() {  # <test[@gpu]> <removed fix or "fixed">
    local t=${1%%@*} gpu=$GPU shim=$SHIM libs=$FIXED
    [[ $1 == *@* ]] && gpu=${1#*@}
    local inject=$BRONZELOAD
    local -a env=()
    case $2 in
        bronze) inject= env=(AMD_BRONZE_COMPAT=0) ;; bronzestencil) inject= env=(AMD_BRONZE_COMPAT=0 MTLSHIM_STENCIL_SUBRESOURCE=0) ;; bronzeshim) inject= shim=$NOOP env=(AMD_BRONZE_COMPAT=0) ;; trilinear) inject= env=(AMD_BRONZE_COMPAT=0 INTEL_COMPUTE_TRILINEAR_FIX=0) ;; shim) shim=$NOOP ;; memoryless) shim=$NOOP env=(AMD_BRONZE_MEMORYLESS=0) ;; adapter) libs=$NOADAPTER ;; stock) libs=$STOCK ;; patch3) libs=$PATCH3 env=(INTEL_PRIVATE_ALIGN_FIX=0) ;; patch4) libs=$PATCH4 ;;
        smrd) env=(AMD_SI_HAZARD_FIX=0) ;; ldsbase) env=(AMD_LDS_BASE_FIX=0) ;; handle) env=(AMD_HANDLE_FIX=0 INTEL_HANDLE_FIX=0) ;;
        nan) env=(AMD_NAN_FIX=0) ;; ldexp) env=(AMD_LDEXP_FIX=0) ;; gather) env=(AMD_GATHER_FIX=0 INTEL_INTEGER_OFFSET_FIX=0 INTEL_KERNEL_GATHER_OFFSET_FIX=0) ;; cubearray) env=(AMD_CUBE_ARRAY_FIX=0) ;; ldsbool) env=(AMD_LDS_BOOL_FIX=0 INTEL_THREADGROUP_BOOL_FIX=0) ;; fmask) env=(AMD_FMASK_FIX=0) ;; unpack) env=(AMD_UNPACK_FIX=0) ;; privatestore) env=(AMD_PRIVATE_STORE_FIX=0) ;; intbuiltins) env=(AMD_SATURATE_FIX=0 AMD_ROTATE_FIX=0) ;; branchcond) env=(AMD_BIT_TEST_FIX=0 AMD_LOOP_EXIT_FIX=0) ;; narrowconst) env=(AMD_NARROW_CONSTANT_FIX=0) ;; amdcubegather) env=(AMD_CUBE_GATHER_FIX=0) ;; bitcastlane) env=(AMD_BITCAST_LANE_FIX=0) ;; floatatomic) env=(AMD_FLOAT_ATOMIC_FIX=0) ;; widecompare) env=(AMD_WIDE_COMPARE_FIX=0) ;;
        subword) env=(INTEL_SIGNED_SUBWORD_FIX=0) ;; comparebias) env=(INTEL_COMPARE_BIAS_FIX=0) ;; intoffset) env=(INTEL_INTEGER_OFFSET_FIX=0) ;; samplerstate) env=(INTEL_SAMPLER_STATE_FIX=0 AMD_SAMPLER_STATE_FIX=0 __XPC_AMD_SAMPLER_STATE_FIX=0) ;; float3) env=(INTEL_VERTEX_FLOAT3_FIX=0) ;; privatearray) env=(INTEL_PRIVATE_ARRAY_FIX=0) ;; kernelgradient) env=(INTEL_KERNEL_GRADIENT_FIX=0) ;; fragfloat3) env=(INTEL_FRAGMENT_FLOAT3_FIX=0) ;; numsamples) env=(INTEL_NUM_SAMPLES_FIX=0) ;; swizzleimm) env=(INTEL_SWIZZLE_IMMEDIATE_FIX=0) ;; branchchain) env=(INTEL_BRANCH_CHAIN_FIX=0) ;; basevertex) env=(INTEL_BASE_VERTEX_FIX=0) ;; simd16clobber) env=(INTEL_SIMD16_CLOBBER_FIX=0) ;; finederiv) env=(INTEL_FINE_DERIVATIVES_FIX=0) ;; typepun) env=(INTEL_TYPE_PUN_FIX=0) ;; privateselect) env=(INTEL_PRIVATE_SELECT_FIX=0) ;; kernelgather) env=(INTEL_KERNEL_GATHER_OFFSET_FIX=0) ;; cubegather) env=(INTEL_CUBE_GATHER_SAMPLER_FIX=0) ;; madsat) env=(INTEL_MAD_SAT_FIX=0) ;; narrowminmax) env=(INTEL_NARROW_MINMAX_FIX=0) ;; bufferselect) env=(INTEL_BUFFER_SELECT_FIX=0) ;; samplelod) env=(INTEL_SAMPLE_LOD_OPERAND_FIX=0) ;; signeddivneg) env=(INTEL_SIGNED_DIV_NEG_FIX=0) ;; mul64) env=(INTEL_MUL64_FIX=0) ;; sdivpow2) env=(INTEL_SDIV_POW2_FIX=0) ;; narrowmask) env=(INTEL_NARROW_MASK_FIX=0) ;; narrowudiv) env=(INTEL_NARROW_UDIV_FIX=0) ;; narrowdiv) env=(INTEL_NARROW_DIV_FIX=0) ;; targetdepth) env=(MTLSHIM_TARGET_DEPTH=0) ;; computecompare) env=(MTLSHIM_COMPUTE_SAMPLER_COMPARE=0) ;; lodpreclamp) env=(MTLSHIM_COMPUTE_LOD_PRECLAMP=0) ;;
    esac
    # s13's fix (item 25) works in MTLCompilerService, which gets the shim under test this way (i05's metallib needs it too)
    [ "$t" = s13-new-air-metallib ] || [ "$t" = i05-intel-constexpr-sampler ] && env+=(__XPC_DYLD_INSERT_LIBRARIES=$shim)
    # On the AMD GPU the in-process compiler can't load i05's macOS 15.4 library ("image not loaded"), so there it compiles
    # in MTLCompilerService, which takes the build's compiler files by leaf name
    local cc=$CC
    [ "$t" = i05-intel-constexpr-sampler ] && [[ $gpu == *AMD* ]] && cc= && env+=(__XPC_DYLD_LIBRARY_PATH=$libs)
    local inserted
    inserted=$(printf '%s\n' "$shim" "$cc" "$inject" | grep . | paste -sd: -)
    rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.metal"
    env ${env[@]+"${env[@]}"} AMD_BRONZE_COMPAT_PATH=$libs/AMDBronzeCompat.dylib \
        DYLD_INSERT_LIBRARIES=$inserted DYLD_LIBRARY_PATH=$libs ./build/"$t" ${gpu:+"$gpu"} 2>/dev/null |
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
