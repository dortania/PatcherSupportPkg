#!/usr/bin/env bash
# verify.sh [GPU substring]: runs every test twice without installing anything, and writes RESULTS.md:
#   with the fixes   the payload built by ../build.sh (shim, AMD and Intel adapters, patched libAMDIL902)
#   without the fix  the same, minus only the fix the test is about:
#                      shim tests          the no-op MetalOldCompat build (same load commands, does nothing)
#                      s12, s25, s26, s29, s44, s43@AMD, s46, s47, s48, s37@AMD, s56, s65@AMD
#                                          AMDBronzeCompat off (not injected, AMD_BRONZE_COMPAT=0 in case it is installed)
#                      s17                 AMDBronzeCompat off and MTLSHIM_STENCIL_SUBRESOURCE=0
#                      s19                 AMDBronzeCompat off and INTEL_COMPUTE_TRILINEAR_FIX=0
#                      s09, s30            AMDBronzeCompat off and the no-op MetalOldCompat build
#                      s27                 the no-op MetalOldCompat build and AMD_BRONZE_MEMORYLESS=0
#                      r03                 AMD_BRONZE_STENCIL_DEPTH_STATE=0 (item 12 without its state copies)
#                      s60                 MTLSHIM_ARGUMENT_ENCODER_GUARD=0 and MTLSHIM_IVB_ARGUMENT_BUFFERS=0
#                      s61                 MTLSHIM_IVB_ARGUMENT_BUFFERS=0 and INTEL_IVB_ARGUMENT_BUFFER_FIX=0
#                      a01, a05@Intel, i01 the stock AMDShared / libMTLIntelCompilerPlugin (adapters not loaded)
#                      a02, a04-a34, r01   the AMD adapter's own switch (AMD_SI_HAZARD_FIX=0, AMD_LDS_BASE_FIX=0,
#                                          AMD_HANDLE_FIX=0 + INTEL_HANDLE_FIX=0, AMD_NAN_FIX=0, AMD_LDEXP_FIX=0,
#                                          AMD_GATHER_FIX=0 + INTEL_INTEGER_OFFSET_FIX=0,
#                                          AMD_CUBE_ARRAY_FIX=0, AMD_LDS_BOOL_FIX=0 + INTEL_THREADGROUP_BOOL_FIX=0,
#                                          AMD_FMASK_FIX=0, AMD_UNPACK_FIX=0, AMD_PRIVATE_STORE_FIX=0,
#                                          AMD_SATURATE_FIX=0 + AMD_ROTATE_FIX=0, AMD_BIT_TEST_FIX=0 + AMD_LOOP_EXIT_FIX=0,
#                                          AMD_NARROW_CONSTANT_FIX=0, AMD_CUBE_GATHER_FIX=0,
#                                          AMD_BITCAST_LANE_FIX=0, AMD_FLOAT_ATOMIC_FIX=0,
#                                          AMD_WIDE_COMPARE_FIX=0, AMD_WIDE_BRANCH_FIX=0,
#                                          AMD_SHIFTED_DIVIDEND_FIX=0, AMD_CONSTANT_MINMAX_FIX=0,
#                                          AMD_ZEXT_SHIFT_FIX=0, AMD_BOOL_AND_NOT_FIX=0, AMD_AVERAGE_FIX=0,
#                                          AMD_DIVERGENT_LOOP_FIX=0, AMD_WIDE_MULHI_FIX=0)
#                      i02-i16             the Intel adapter's switch (INTEL_SIGNED_SUBWORD_FIX=0, INTEL_COMPARE_BIAS_FIX=0,
#                                          INTEL_INTEGER_OFFSET_FIX=0, INTEL_SAMPLER_STATE_FIX=0, INTEL_VERTEX_FLOAT3_FIX=0,
#                                          INTEL_PRIVATE_ARRAY_FIX=0, INTEL_KERNEL_GRADIENT_FIX=0,
#                                          INTEL_FRAGMENT_FLOAT3_FIX=0, INTEL_NUM_SAMPLES_FIX=0, INTEL_SWIZZLE_IMMEDIATE_FIX=0,
#                                          INTEL_BRANCH_CHAIN_FIX=0, INTEL_BASE_VERTEX_FIX=0 + MTLSHIM_IVB_DRAW_PARAMETERS=0,
#                                          INTEL_SIMD16_CLOBBER_FIX=0, INTEL_FINE_DERIVATIVES_FIX=0, INTEL_TYPE_PUN_FIX=0)
#                      c01, c02            the stock libAMDIL902
#                      c03                 libAMDIL902 without patch 4 and INTEL_PRIVATE_ALIGN_FIX=0
#                      c04                 libAMDIL902 without patch 5
#                      c05                 libAMDIL902 without patch 6
#                      sweeps (s75)        none of the fixes: the no-op MetalOldCompat build and the stock compiler plugins
#                                          (adapters not loaded); a sweep covers many fixes at once, so its "without" column
#                                          shows what the unfixed stack does and only "with" has to pass
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
# warnings about this Mac (a kext the next boot loses, a staged macOS update), without stopping the run
[ -x tools/preflight.sh ] && { tools/preflight.sh || echo "(preflight warnings above; continuing)"; }
GPU=${1:-}  # GPU name substring for every test (optional)
B=$(cd .. && pwd)/build
[ -f "$B/AMDTextureAtomics.dylib" ] || { echo "run ../build.sh first" >&2; exit 2; }
# (re)build the tests when any one is missing: a test added since the last build would otherwise count as crashed
for src in [a-z][0-9]*.m; do [ -x "build/${src%.m}" ] || { ./build.sh > /dev/null; break; }; done
[ -f tools/localcc.dylib ] || clang++ -std=c++17 -fblocks -dynamiclib tools/localcc.cpp -o tools/localcc.dylib
[ -f tools/bronzeload.dylib ] || clang -fobjc-arc -dynamiclib tools/bronzeload.m -framework Foundation -framework Metal \
    -o tools/bronzeload.dylib
# The shim sets MTL_USE_AIRNT_BA=0 (s18's fix) in the processes it loads into, and children inherit it.
unset MTL_USE_AIRNT_BA
V=  # the AMDShared copy: "" (12.5) or -GCN-25
case ${PAYLOAD:-12.5} in 12.5) ;; 12.5-GCN-25) V=-GCN-25 ;; *) echo "PAYLOAD: 12.5 or 12.5-GCN-25" >&2; exit 2 ;; esac
FIXED=$(mktemp -d) NOADAPTER=$(mktemp -d) STOCK=$(mktemp -d) PATCH3=$(mktemp -d) PATCH4=$(mktemp -d) PATCH5=$(mktemp -d)
# AMDBronzeCompat goes in the library folders too: where it is installed, the driver loads it by leaf name from there
# instead of the installed copy, which would otherwise take the driver code first.
# The Intel compiler plugin of this Mac's own Intel driver: on Ivy Bridge (HD 4000) the one from OCLP's 11.7.10
# AppleIntelHD4000GraphicsMTLDriver, which build.sh writes as libMTLIntelCompilerPlugin-IVB.dylib; the Haswell one fails
# most Intel pipelines there ("Compilation failed").
IVB=
ioreg -rc IntelAccelerator -d1 -w0 2>/dev/null | grep -q AppleIntelHD4000Graphics && IVB=-IVB
# Known Ivy Bridge limitations (FIXES.md, Known limitations), which fail with every fix on the HD 4000: reported as SKIP
# there instead of being run. They still run on every other GPU (the Iris Pro and the R9 pass them).
IVB_KNOWN="s37-intel-stencil-subresources s41-intel-stencil-copy-rows s43-intel-stencil-view-mips s46-amd-stencil-view-subresources
           s48-amd-stencil8-levels-slices a17-amd-integer-cube-gather"
cp "$B/AMDTextureAtomics.dylib" "$B/IntelTextureAtomics.dylib" "$B/AMDBronzeCompat.dylib" "$FIXED/"
cp "$B/libMTLIntelCompilerPlugin$IVB.dylib" "$FIXED/libMTLIntelCompilerPlugin.dylib"
cp "$B/AMDShared$V" "$FIXED/AMDShared"
cp "$B/libAMDIL902$V.dylib" "$FIXED/libAMDIL902.dylib"
for d in "$NOADAPTER" "$STOCK" "$PATCH3" "$PATCH4" "$PATCH5"; do cp "$FIXED"/* "$d/"; done
cp "$B/stock/AMDShared$V" "$NOADAPTER/AMDShared"
cp "$B/stock/libMTLIntelCompilerPlugin$IVB.dylib" "$NOADAPTER/libMTLIntelCompilerPlugin.dylib"
# Kepler: GeForceAIRPlugin, taken by leaf name like the others but from a copy of its bundle (it opens its built-in
# library, Resources/metal_runtime.metallib, from there): the patched one (weak load of GeForceAIRCompat.dylib), or the
# stock one for "without the adapter"
keplerBundle() {  # <folder> <plugin>
    local c=$1/GeForceAIRPlugin.bundle/Contents s=/System/Library/Extensions/GeForceAIRPlugin.bundle/Contents
    mkdir -p "$c/MacOS" "$c/Resources"
    [ -d "$s" ] && cp "$s/Info.plist" "$s/PkgInfo" "$s/version.plist" "$c/" && cp "$s/Resources/"* "$c/Resources/"
    cp "$2" "$c/MacOS/GeForceAIRPlugin" && cp "$B/GeForceAIRCompat.dylib" "$c/MacOS/"
}
for d in "$FIXED" "$STOCK" "$PATCH3" "$PATCH4" "$PATCH5"; do keplerBundle "$d" "$B/GeForceAIRPlugin"; done
keplerBundle "$NOADAPTER" "$B/stock/GeForceAIRPlugin"
cp "$B/stock/libAMDIL902$V.dylib" "$STOCK/libAMDIL902.dylib"
PARSERFIX_SKIP_GEP_SELECT=1 python3 -I ../libAMDIL902/make_parser_fix.py "$B/stock/libAMDIL902$V.dylib" \
    "$PATCH3/libAMDIL902.dylib" > /dev/null
PARSERFIX_SKIP_STRUCT_MAP=1 python3 -I ../libAMDIL902/make_parser_fix.py "$B/stock/libAMDIL902$V.dylib" \
    "$PATCH4/libAMDIL902.dylib" > /dev/null
PARSERFIX_SKIP_BFE_GUARD=1 python3 -I ../libAMDIL902/make_parser_fix.py "$B/stock/libAMDIL902$V.dylib" \
    "$PATCH5/libAMDIL902.dylib" > /dev/null
codesign -f -s - "$PATCH3/libAMDIL902.dylib" "$PATCH4/libAMDIL902.dylib" "$PATCH5/libAMDIL902.dylib" 2> /dev/null
SHIM=$B/MetalOldCompat.dylib NOOP=$B/MetalOldCompat-noop.dylib CC=$PWD/tools/localcc.dylib BRONZELOAD=$PWD/tools/bronzeload.dylib
[ -f /System/Library/Frameworks/Metal.framework/Versions/A/MetalOld.dylib ] || SHIM= NOOP=

# <test[@gpu]>:<what "without the fix" removes>
CASES="s01-device-methods:shim s02-reflection:shim s03-shader-atomic-usage:shim s27-memoryless-texture:memoryless s07-vertex-descriptor:shim
s08-sdk-properties:shim s09-msl-3.2:bronzeshim s10-device-over-release:shim s12-srgb-mipmaps:bronze s13-new-air-metallib:shim
s14-safari-argument-encoders:shim s60-intel-argument-encoder-abort:encguard s61-intel-argument-buffers:ivbab s15a-intel-msaa-resolve:shim s15b-intel-narrow-clear:shim s16-intel-array-view:shim
s17-amd-depth-stencil-view:bronzestencil s18-pipeline-cache-key:shim s19-amd-trilinear-blend:trilinear s25-amd-srgb-resolve:bronzeresolve s26-amd-depth-stencil-copy-pitch:bronze s29-amd-webkit-vertex-stride:bronze s30-amd-webkit-sample-mask:bronzeshim s44-amd-depth-stencil-mip-read:bronze s43-intel-stencil-view-mips@AMD:bronze s46-amd-stencil-view-subresources:bronzeview s47-amd-stencil-only-attachment:bronze s48-amd-stencil8-levels-slices:bronze s37-intel-stencil-subresources@AMD:bronze s56-default-viewport-slots:bronze
s20-intel-fill-buffer:shim s21-intel-depth-only-pipeline:shim s22-intel-depth-hiz-levels:shim s23-intel-3d-mip-plane:shim
s24-intel-narrow-mip-clear:shim s31-angle-family-one:shim s32-intel-depth-stencil-blit:shim s33-intel-nil-argument-buffer:shim s34-intel-small-integer-cube:shim s35-intel-encoder-lod-clamp:shim s36-intel-swizzle-view:shim s37-intel-stencil-subresources:shim s38-intel-coverage-without-writes:shim s39-intel-mps-statistics:shim s40-intel-msaa-stencil8-read:shim s41-intel-stencil-copy-rows:shim s55-intel-stencil-slice-copy:shim s62-intel-stencil-readback-rows:shim s63-safari-angle-msaa-resolve:shim s64-firefox-angle-display:shim s65-intel-view-blits:shim s65-intel-view-blits@AMD:bronze r03-amd-stencil-only-depth-state:bronzedepthstate s66-intel-msaa-depth-clear-read:shim s67-intel-sample-mask-stencil:stencilwithdepth s70-intel-depth-array-level-blits:depthlevelblits s71-intel-depth-clears:depthcleardraw s72-intel-depth-level-passes:depthlevelrepair s73-intel-srgb-pair-copies:srgbcopy s74-chromium-angle-libraries:oldangle s75-air-version-matrix:sweep s79-render-without-attachments:shim s80-msl32-fences:shim s81-moltenvk-heap-default:shim s83-msaa-two-samples:msaa2 s84-scenekit-spritekit:sweep s85-angle-pixel-local-storage:noattachments s86-intel-argument-buffer-textures:abtex s87-intel-concurrent-blits:blitlock s88-intel-32-vertex-inputs:vinputs s89-zero-depth-textures:zerodepth s90-intel-stencil-level-keeps-depth:keepdepth s82-function-cache-reuse:shim s76-coreimage-builtin-filters:sweep s77-coreimage-kernel-kinds:sweep s78-mps-kernels:sweep s56-default-viewport-slots@Intel:shim s42-shim-owned-returns:shim s43-intel-stencil-view-mips:shim s45-intel-writable-view-size:shim s49-intel-writable-array-view-layers:targetdepth s50-intel-compute-compare-sampler:computecompare s51-intel-compute-lod-preclamp:lodpreclamp s52-intel-integer-cube-compare-sampler:nearestcube a01-texture-atomics:adapter
a01-texture-atomics@Intel:adapter a02-si-smrd-hazard:smrd a04-si-threadgroup-pointer:ldsbase
a05-escaped-texture-pointer:handle a05-escaped-texture-pointer@Intel:handle a06-fast-math-nan-compare:nan a07-half-ldexp:ldexp a08-integer-gather:gather a09-cube-array-index:cubearray a10-threadgroup-bool:ldsbool a12-amd-unpack-norm:unpack a13-amd-private-array-stores:privatestore a14-amd-integer-builtins:intbuiltins a15-amd-branch-conditions:branchcond a16-amd-narrow-constants:narrowconst a17-amd-integer-cube-gather:amdcubegather a18-amd-bitcast-lanes:bitcastlane a19-amd-float-atomics:floatatomic a20-amd-wide-compares:widecompare a21-amd-wide-bit-branches:widebranch a22-amd-shifted-dividend:shifteddividend a23-amd-constant-min-max:constminmax a24-amd-zext-shift-halves:zextshift a25-amd-square-bit-loop-exit:bittestloop a26-amd-bool-and-not:boolandnot a27-amd-loop-dividend:shifteddividend a28-amd-loop-min-max:constminmax a29-amd-lane-trunc:bitcastlane a30-amd-clamp-equal-bounds:constminmax a31-amd-counter-bit-test:countertest a32-amd-wide-average-product:average a33-amd-divergent-inner-loop:divergentloop a34-amd-wide-mulhi:widemulhi a11-msaa-shader-read:fmask
c01-amdil-argument-buffer:stock c02-amdil-color-input:stock c03-amdil-gep-select:patch3 c04-amdil-struct-type-map:patch4 c05-amdil-bfe-constant:patch5
i01-intel-array-struct-arg:adapter i02-intel-vertex-signed-subword:subword i03-intel-shadow-compare-bias:comparebias i04-intel-integer-texel-offset:intoffset i05-intel-constexpr-sampler:samplerstate i05-intel-constexpr-sampler@AMD:samplerstate i06-intel-vertex-float3-input:float3 i07-intel-private-array-index:privatearray i08-intel-kernel-integer-gradient:kernelgradient i09-intel-fragment-float3-compare:fragfloat3 i10-intel-num-samples:numsamples i11-intel-swizzle-immediate:swizzleimm i12-intel-branch-chain-compile:branchchain i13-intel-indirect-vertex-id:basevertex i14-intel-simd16-clobber:simd16clobber i15-intel-fine-derivatives:finederiv i16-intel-type-punned-buffer:typepun i17-intel-private-pointer-select:privateselect i18-intel-buffer-copy-after-store:typepun i19-intel-kernel-gather-offset:kernelgather i20-intel-cube-gather-seam:cubegather i21-intel-mad-sat-mul-hi:madsat i22-intel-narrow-min-max:narrowminmax i23-intel-buffer-pointer-select:bufferselect i24-intel-compute-compare-level:samplelod i26-intel-signed-div-negated:signeddivneg i27-intel-64bit-multiply:mul64 i28-intel-signed-div-pow2:sdivpow2 i29-intel-narrow-mask:narrowmask i30-intel-narrow-udiv:narrowudiv i31-intel-narrow-div:narrowdiv i32-intel-narrow-mask-copies:narrowmask i33-intel-wide-div-lane:widedivlane i34-intel-private-array-variable-only:privatearray i35-intel-narrow-vector-constant-lanes:constantlanes i36-intel-constant-call-fold:constantcall i37-intel-narrow-negation:narrownegate i38-intel-saturating-add-zero:constsat i39-intel-constant-bit-fields:constantcall i40-intel-narrow-shift-merge:narrowshift i41-intel-loop-exit-copy:loopexitcopy i42-intel-folded-bitcast:constantcall i43-intel-narrow-mask-shift:narrowmask i44-intel-private-array-partial:privatearray i45-intel-sign-extend-merge:signextend i46-intel-narrow-max-operand:narrowshift i47-intel-narrow-private-array:narrowprivate i48-intel-narrow-saturating-add:narrowshiftsat i49-intel-uniform-dependency:uniformdep i50-intel-rg32-green-gather:gathergreen i72-intel-half-green-gather:gathergreen i73-intel-ivb-inline-constants:inlineconst i74-intel-ivb-ldst-walk:valueused i75-intel-ivb-byte-halfwords:bytehalves i76-intel-ivb-mask-or:maskor i77-intel-pixel-divide-simd8:pixeldivide i78-intel-gradient-compare-level:gradientcompare i79-intel-cube-array-compare-level:cubearraylevel i80-intel-threadgroup-copy-after-store:copyexpand i81-inline-asm-loop:inlineasm i82-intel-padded-argument-buffer:paddedab i83-intel-argument-buffer-references:emuref i84-intel-argument-buffer-render-offsets:aboffsets i85-intel-argument-buffer-dynamic-offset:ivbab i86-intel-threadgroup-atomic-two-values:tgatomic i87-intel-stale-reload:reload i51-intel-narrow-constant-or:constantlanes i52-intel-narrow-divide-copy:narrowshift i53-intel-switch-phi-entries:branchchain i54-intel-narrow-widened-shift:narrowshift i55-intel-narrow-udiv-mask:narrowshift i56-intel-constant-saturation-chain:constantcallsat i57-intel-vector-sign-extend:signextend i58-intel-constant-min3:constantcall i59-intel-zero-width-bit-field:constantcall i60-intel-negated-dividend-copy:signeddivneg i61-intel-negated-dividend-fold:signeddivneg i62-intel-halfword-bytes:halfwordbytes i63-intel-late-saturation:latesat i64-intel-byte-vector-compare:bytecompare i65-intel-sum-sign-compare:sumsign i66-intel-byte-vector-arithmetic:bytearith i67-intel-render-int64:renderint64 i68-intel-bit-test-compare:bittest i69-intel-half3-bits:bytearith i70-intel-narrow-vector-divide:narrowvecdiv i71-intel-outer-axis-reduction:endlessloop s53-coreimageold-portrait-kernels:sdoflibrary s68-coreimage-metal-kernels:shim s57-intel-mps-matmul:mpsmatmul s58-intel-metalfx-temporal:metalfxtemporal s59-metal4-texture-reads:readsampler s59-metal4-texture-reads@Intel:readsampler s54-validation-layers:shim r01-amd-slot8-data-segment:ldsbase r02-amd-short3-bounds-load:narrowload3
n01-kepler-count-of-zero:countzero n02-kepler-narrow-private-array:nvnarrow n03-kepler-narrow-product:nvmul16 n04-kepler-texture-atomics:texatomics n05-kepler-gradient-compare:gradientcompare n06-kepler-shift-threadgroup:nvshift s69-safari-webgl-arb-sync:shim n07-kepler-fragment-oob-load:nvfragguard n08-kepler-visibility-sum:nvvissum n09-kepler-zero-buffers:nvzero n10-kepler-discard-demote:nvdemote n11-kepler-depth-channels:nvdepth n12-kepler-large-copy:nvcopy n13-kepler-half-constant:nvhalfconst n14-kepler-cube-read-level:nvcuberead n15-kepler-volume-copy-stride:nvvolumecopy n16-kepler-masked-draw-occlusion:nvmaskeddraws n17-kepler-bc-edge-upload:nvblockedge n18-kepler-threadgroup-cmpxchg:nvlocalcmpxchg n19-kepler-signed-vector-bool:nvsignedbool n20-kepler-guard-band:nvguardband n21-kepler-reversed-depth-range:nvreverseddepth n22-kepler-sample-positions:nvsamplepositions n23-kepler-wide-point-clipping:nvpointguardband n24-kepler-viewport-scissor:nvviewportscissor n25-kepler-atomic-join-operand:nvatomicjoin n26-kepler-private-constant-loads:nvconstantloads n27-kepler-cube-gradient-level:nvcubegradient n28-kepler-overflow-check:nvoverflow n30-kepler-saturating-multiply-add:nvmadsat n31-kepler-fragment-private-constant-loads:nvconstantgraphics n32-kepler-divisor-one:nvdivisorone n33-kepler-three-lane-narrow-vectors:nvoddvectors n34-kepler-sign-extended-dividend:nvsextdivision n35-kepler-vector-lane-constants:nvvectorconstant n36-kepler-saturated-product:nvsatproduct n37-kepler-narrow-vector-loop-exit:nvnarrowvector n38-kepler-subtracted-not:nvsubnot n39-kepler-narrow-vector-select:nvnarrowselect n40-kepler-private-final-loads:nvfinalloads n41-kepler-narrow-compares:nvnarrowcompare n42-kepler-wide-constant-product:nvwideconstant n43-kepler-narrow-division:nvnarrowdivision n44-kepler-metal-array-constant-loads:nvarraystruct n45-kepler-metal-array-narrow:nvarraystruct n46-kepler-metal-array-fragment:nvarraystruct n47-kepler-narrow-shift-amount:nvnarrowshift n48-kepler-depth-copy-option:nvdepthcopy n49-kepler-stencil-clear-mask:stencilclear n50-kepler-managed-upload-race:nvmodifiedretain n52-kepler-negative-array-layer:nvarraylayer n53-kepler-sample-bias-clamp:biasclamp"

[ -n "$V" ] && CASES=$(for c in $CASES; do case $c in (*@*|i*|s*) ;; (*) echo "$c" ;; esac; done)
[ -n "$GPU" ] && CASES=$(for c in $CASES; do case $c in (*@*) ;; (*) echo "$c" ;; esac; done)
# ONLY="n0 s69": just the tests whose names start with one of these (a quick check of a few fixes)
[ -n "${ONLY:-}" ] && CASES=$(for c in $CASES; do for o in $ONLY; do case $c in ("$o"*) echo "$c"; break ;; esac; done; done)

# The Kepler adapter's 64-bit fixes, off: the "without the fix" run of the tests whose bug on Kepler they fix (no effect on other GPUs)
NVAIR_OFF="NVAIR_INTRINSICS=0 NVAIR_I64_FIX=0"
run() {  # <test[@gpu]> <removed fix or "fixed">
    local t=${1%%@*} gpu=$GPU shim=$SHIM libs=$FIXED
    [[ $1 == *@* ]] && gpu=${1#*@}
    local inject=$BRONZELOAD
    local -a env=()
    case $2 in
        bronze) inject= env=(AMD_BRONZE_COMPAT=0) ;; bronzeresolve) inject= env=(AMD_BRONZE_COMPAT=0 MTLSHIM_NV_RESOLVE_LEVEL=0) ;; bronzeview) inject= env=(AMD_BRONZE_COMPAT=0 MTLSHIM_NV_VIEW_OF_VIEW=0) ;; bronzestencil) inject= env=(AMD_BRONZE_COMPAT=0 MTLSHIM_STENCIL_SUBRESOURCE=0) ;; bronzeshim) inject= shim=$NOOP env=(AMD_BRONZE_COMPAT=0) ;; trilinear) inject= env=(AMD_BRONZE_COMPAT=0 INTEL_COMPUTE_TRILINEAR_FIX=0) ;; shim) shim=$NOOP ;; sweep) shim=$NOOP libs=$NOADAPTER ;; memoryless) shim=$NOOP env=(AMD_BRONZE_MEMORYLESS=0) ;; bronzedepthstate) env=(AMD_BRONZE_STENCIL_DEPTH_STATE=0) ;; adapter) libs=$NOADAPTER ;; stock) libs=$STOCK ;; patch3) libs=$PATCH3 env=(INTEL_PRIVATE_ALIGN_FIX=0) ;; patch4) libs=$PATCH4 ;; patch5) libs=$PATCH5 ;;
        smrd) env=(AMD_SI_HAZARD_FIX=0) ;; ldsbase) env=(AMD_LDS_BASE_FIX=0) ;; handle) env=(AMD_HANDLE_FIX=0 INTEL_HANDLE_FIX=0) ;;
        nan) env=(AMD_NAN_FIX=0) ;; ldexp) env=(AMD_LDEXP_FIX=0) ;; gather) env=(AMD_GATHER_FIX=0 INTEL_INTEGER_OFFSET_FIX=0 INTEL_KERNEL_GATHER_OFFSET_FIX=0) ;; cubearray) env=(AMD_CUBE_ARRAY_FIX=0 NVAIR_ARRAY_LAYER_CLAMP=0) ;; ldsbool) env=(AMD_LDS_BOOL_FIX=0 INTEL_THREADGROUP_BOOL_FIX=0 NVAIR_THREADGROUP_BOOL_FIX=0) ;; fmask) env=(AMD_FMASK_FIX=0) ;; unpack) env=(AMD_UNPACK_FIX=0) ;; privatestore) env=(AMD_PRIVATE_STORE_FIX=0) ;; intbuiltins) env=(AMD_SATURATE_FIX=0 AMD_ROTATE_FIX=0 $NVAIR_OFF) ;; branchcond) env=(AMD_BIT_TEST_FIX=0 AMD_LOOP_EXIT_FIX=0) ;; narrowconst) env=(AMD_NARROW_CONSTANT_FIX=0) ;; narrowload3) env=(AMD_NARROW_LOAD3_FIX=0 __XPC_AMD_NARROW_LOAD3_FIX=0) ;; amdcubegather) env=(AMD_CUBE_GATHER_FIX=0) ;; bitcastlane) env=(AMD_BITCAST_LANE_FIX=0) ;; floatatomic) env=(AMD_FLOAT_ATOMIC_FIX=0) ;; widecompare) env=(AMD_WIDE_COMPARE_FIX=0) ;; widebranch) env=(AMD_WIDE_BRANCH_FIX=0 $NVAIR_OFF) ;; shifteddividend) env=(AMD_SHIFTED_DIVIDEND_FIX=0 $NVAIR_OFF) ;; constminmax) env=(AMD_CONSTANT_MINMAX_FIX=0) ;; zextshift) env=(AMD_ZEXT_SHIFT_FIX=0 AMD_AVERAGE_FIX=0) ;; bittestloop) env=(AMD_BIT_TEST_FIX=0) ;; boolandnot) env=(AMD_BOOL_AND_NOT_FIX=0) ;; average) env=(AMD_AVERAGE_FIX=0 AMD_WIDE_MULHI_FIX=0 $NVAIR_OFF) ;; divergentloop) env=(AMD_DIVERGENT_LOOP_FIX=0) ;; widemulhi) env=(AMD_WIDE_MULHI_FIX=0 $NVAIR_OFF) ;; countertest) env=(AMD_BIT_TEST_FIX=0 AMD_DIVERGENT_LOOP_FIX=0) ;;
        subword) env=(INTEL_SIGNED_SUBWORD_FIX=0) ;; comparebias) env=(INTEL_COMPARE_BIAS_FIX=0 NVAIR_COMPARE_LEVEL_FIX=0) ;; intoffset) env=(INTEL_INTEGER_OFFSET_FIX=0) ;; samplerstate) env=(INTEL_SAMPLER_STATE_FIX=0 AMD_SAMPLER_STATE_FIX=0 __XPC_AMD_SAMPLER_STATE_FIX=0 __XPC_NVAIR_SAMPLER_STATE_FIX=0) ;; float3) env=(INTEL_VERTEX_FLOAT3_FIX=0) ;; privatearray) env=(INTEL_PRIVATE_ARRAY_FIX=0) ;; kernelgradient) env=(INTEL_KERNEL_GRADIENT_FIX=0 NVAIR_GRADIENT_FIX=0) ;; fragfloat3) env=(INTEL_FRAGMENT_FLOAT3_FIX=0) ;; numsamples) env=(INTEL_NUM_SAMPLES_FIX=0) ;; swizzleimm) env=(INTEL_SWIZZLE_IMMEDIATE_FIX=0) ;; branchchain) env=(INTEL_BRANCH_CHAIN_FIX=0) ;; basevertex) env=(INTEL_BASE_VERTEX_FIX=0 MTLSHIM_IVB_DRAW_PARAMETERS=0) ;; simd16clobber) env=(INTEL_SIMD16_CLOBBER_FIX=0) ;; finederiv) env=(INTEL_FINE_DERIVATIVES_FIX=0) ;; typepun) env=(INTEL_TYPE_PUN_FIX=0) ;; privateselect) env=(INTEL_PRIVATE_SELECT_FIX=0) ;; kernelgather) env=(INTEL_KERNEL_GATHER_OFFSET_FIX=0) ;; cubegather) env=(INTEL_CUBE_GATHER_SAMPLER_FIX=0) ;; madsat) env=(INTEL_MAD_SAT_FIX=0) ;; narrowminmax) env=(INTEL_NARROW_MINMAX_FIX=0) ;; bufferselect) env=(INTEL_BUFFER_SELECT_FIX=0) ;; samplelod) env=(INTEL_SAMPLE_LOD_OPERAND_FIX=0) ;; cubearraylevel) env=(INTEL_CUBE_ARRAY_LEVEL_FIX=0) ;; signeddivneg) env=(INTEL_SIGNED_DIV_NEG_FIX=0) ;; mul64) env=(INTEL_MUL64_FIX=0 $NVAIR_OFF) ;; sdivpow2) env=(INTEL_SDIV_POW2_FIX=0) ;; narrowmask) env=(INTEL_NARROW_MASK_FIX=0) ;; narrowudiv) env=(INTEL_NARROW_UDIV_FIX=0) ;; narrowdiv) env=(INTEL_NARROW_DIV_FIX=0) ;; constantlanes) env=(INTEL_NARROW_CONSTANT_LANES_FIX=0) ;; constantcall) env=(INTEL_CONSTANT_CALL_FIX=0) ;; narrownegate) env=(INTEL_NARROW_NEGATE_FIX=0) ;; constsat) env=(INTEL_CONST_SAT_FIX=0) ;; widedivlane) env=(INTEL_WIDE_DIV_INDEX_FIX=0 $NVAIR_OFF) ;; narrowshift) env=(INTEL_NARROW_SHIFT_FIX=0 $NVAIR_OFF) ;; loopexitcopy) env=(INTEL_LOOP_EXIT_COPY_FIX=0) ;; signextend) env=(INTEL_SIGN_EXTEND_FIX=0) ;; narrowprivate) env=(INTEL_NARROW_PRIVATE_ARRAY_FIX=0 NVAIR_NARROW_PRIVATE_ARRAY_FIX=0) ;; uniformdep) env=(INTEL_UNIFORM_DEPENDENCY_FIX=0 $NVAIR_OFF) ;; gathergreen) env=(INTEL_GATHER_GREEN_FIX=0) ;; halfwordbytes) env=(INTEL_HALFWORD_BYTES_FIX=0) ;; latesat) env=(INTEL_LATE_SAT_FIX=0) ;; bytecompare) env=(INTEL_NARROW_VECTOR_COMPARE_FIX=0) ;; sumsign) env=(INTEL_SUM_SIGN_TEST_FIX=0) ;; bytearith) env=(INTEL_NARROW_VECTOR_ARITH_FIX=0) ;; renderint64) env=(INTEL_RENDER_INT64_FIX=0 $NVAIR_OFF) ;; bittest) env=(INTEL_BIT_TEST_COMPARE_FIX=0) ;; narrowvecdiv) env=(INTEL_NARROW_VECTOR_OPERAND_FIX=0) ;; endlessloop) env=(INTEL_INFINITE_LOOP_FIX=0 __XPC_INTEL_INFINITE_LOOP_FIX=0 MTLSHIM_MPSGRAPH_SOFTMAX=0) ;; narrowshiftsat) env=(INTEL_NARROW_SHIFT_FIX=0 INTEL_LATE_SAT_FIX=0) ;; constantcallsat) env=(INTEL_CONSTANT_CALL_FIX=0 INTEL_LATE_SAT_FIX=0) ;; targetdepth) env=(MTLSHIM_TARGET_DEPTH=0) ;; encguard) env=(MTLSHIM_ARGUMENT_ENCODER_GUARD=0 MTLSHIM_IVB_ARGUMENT_BUFFERS=0) ;; inlineconst) env=(INTEL_IVB_INLINE_CONSTANT_FIX=0) ;; stencilwithdepth) env=(MTLSHIM_STENCIL_WITH_DEPTH=0) ;; depthlevelblits) env=(MTLSHIM_DEPTH_LEVEL_BLITS=0) ;; depthcleardraw) env=(MTLSHIM_DEPTH_CLEAR_DRAW=0) ;; depthlevelrepair) env=(MTLSHIM_DEPTH_LEVEL_REPAIR=0) ;; srgbcopy) env=(MTLSHIM_SRGB_COPY=0) ;; valueused) env=(INTEL_VALUE_USED_FIX=0) ;; bytehalves) env=(INTEL_BYTE_HALFWORDS_FIX=0) ;; maskor) env=(INTEL_MASK_OR_FIX=0) ;; pixeldivide) env=(INTEL_PIXEL_DIVIDE_SIMD8_FIX=0) ;; ivbab) env=(MTLSHIM_IVB_ARGUMENT_BUFFERS=0 INTEL_IVB_ARGUMENT_BUFFER_FIX=0) ;; tgatomic) env=(INTEL_THREADGROUP_ATOMIC_FIX=0) ;; reload) env=(INTEL_STALE_RELOAD_FIX=0) ;; computecompare) env=(MTLSHIM_COMPUTE_SAMPLER_COMPARE=0) ;; lodpreclamp) env=(MTLSHIM_COMPUTE_LOD_PRECLAMP=0) ;; nearestcube) env=(MTLSHIM_NEAREST_CUBE_CLAMP=0) ;; sdoflibrary) env=(MTLSHIM_SDOF_LIBRARY=0) ;; mpsmatmul) env=(MTLSHIM_MPS_MATMUL=0) ;; metalfxtemporal) env=(MTLSHIM_METALFX_TEMPORAL=0) ;; readsampler) env=(__XPC_MTLSHIM_READ_SAMPLER=0) ;; countzero) env=(NVAIR_COUNT_ZERO_FIX=0) ;; nvnarrow) env=(NVAIR_NARROW_PRIVATE_ARRAY_FIX=0) ;; nvmul16) env=(NVAIR_NARROW_MULTIPLY_FIX=0) ;; texatomics) env=(NVAIR_TEXTURE_ATOMICS=0 MTLSHIM_NV_TEXTURE_ATOMICS=0) ;; gradientcompare) env=(NVAIR_COMPARE_GRADIENT_FIX=0 INTEL_COMPARE_GRADIENT_FIX=0) ;; nvshift) env=(NVAIR_SHIFT_FIX=0) ;; nvfragguard) env=(NVAIR_FRAGMENT_LOAD_GUARD=0) ;; nvvissum) env=(MTLSHIM_NV_VISIBILITY_SUM=0) ;; nvzero) env=(MTLSHIM_NV_ZERO_BUFFERS=0) ;; nvdemote) env=(NVAIR_DEMOTE_DISCARD=0) ;; nvdepth) env=(MTLSHIM_NV_DEPTH_CHANNELS=0 NVAIR_DEPTH_CHANNELS=0) ;; nvcopy) env=(NVAIR_LARGE_COPY_LOOP=0 INTEL_COPY_EXPAND_FIX=0) ;; copyexpand) env=(INTEL_COPY_EXPAND_FIX=0) ;; nvhalfconst) env=(NVAIR_HALF_CONSTANT_FIX=0 INTEL_HALF_CONSTANT_FIX=0) ;; nvcuberead) env=(NVAIR_CUBE_READ_LEVEL=0) ;; nvvolumecopy) env=(MTLSHIM_NV_VOLUME_COPY=0) ;; nvmaskeddraws) env=(MTLSHIM_NV_MASKED_DRAWS=0) ;; nvblockedge) env=(MTLSHIM_NV_BLOCK_EDGE=0) ;; nvlocalcmpxchg) env=(NVAIR_LOCAL_CMPXCHG=0) ;; nvsignedbool) env=(NVAIR_SIGNED_BOOL_FIX=0) ;; nvguardband) env=(MTLSHIM_NV_GUARD_BAND=0) ;; nvreverseddepth) env=(MTLSHIM_NV_REVERSED_DEPTH=0) ;; nvsamplepositions) env=(MTLSHIM_NV_SAMPLE_POSITIONS=0) ;; nvpointguardband) env=(MTLSHIM_NV_POINT_GUARD_BAND=0) ;; nvviewportscissor) env=(MTLSHIM_NV_VIEWPORT_SCISSOR=0) ;; nvatomicjoin) env=(NVAIR_ATOMIC_JOIN_FIX=0) ;; nvconstantloads) env=(NVAIR_PRIVATE_CONSTANT_LOAD_FIX=0) ;; nvfinalloads) env=(NVAIR_PRIVATE_FINAL_LOADS_FIX=0) ;; nvnarrowcompare) env=(NVAIR_NARROW_COMPARE_FIX=0) ;; nvwideconstant) env=(NVAIR_WIDE_CONSTANT_PRODUCT_FIX=0) ;; nvarraystruct) env=(NVAIR_ARRAY_STRUCT_FIX=0) ;; nvnarrowshift) env=(NVAIR_NARROW_SHIFT_FIX=0) ;; nvdepthcopy) env=(MTLSHIM_NV_DEPTH_COPY=0) ;; stencilclear) env=(MTLSHIM_STENCIL_CLEAR_MASK=0) ;; nvmodifiedretain) env=(MTLSHIM_NV_MODIFIED_RETAIN=0) ;; nvarraylayer) env=(NVAIR_ARRAY_LAYER_CLAMP=0) ;; biasclamp) env=(NVAIR_BIAS_CLAMP=0) ;; noattachments) env=(MTLSHIM_NO_ATTACHMENTS=0) ;; nvnarrowdivision) env=(NVAIR_NARROW_DIVISION_FIX=0) ;; nvsextdivision) env=(NVAIR_SEXT_DIVIDEND_FIX=0 NVAIR_NARROW_DIVISION_FIX=0) ;; inlineasm) env=(INTEL_INLINE_ASM_FIX=0 NVAIR_INLINE_ASM_FIX=0) ;; oldangle) env=(MTLSHIM_OLD_ANGLE_LIBRARY=0) ;; nvnarrowselect) env=(NVAIR_NARROW_VECTOR_FIX=0 NVAIR_NARROW_COMPARE_FIX=0) ;; nvcubegradient) env=(NVAIR_CUBE_GRADIENT_FIX=0) ;; nvoverflow) env=(NVAIR_OVERFLOW_FIX=0) ;; nvmadsat) env=(NVAIR_MAD_SAT_FIX=0) ;; nvconstantgraphics) env=(NVAIR_PRIVATE_CONSTANT_GRAPHICS_FIX=0) ;; nvdivisorone) env=(NVAIR_DIVISOR_ONE_FIX=0) ;; nvoddvectors) env=(NVAIR_ODD_VECTOR_FIX=0) ;; nvsextdividend) env=(NVAIR_SEXT_DIVIDEND_FIX=0) ;; nvvectorconstant) env=(NVAIR_VECTOR_CONSTANT_FIX=0) ;; nvsatproduct) env=(NVAIR_SATURATED_PRODUCT_FIX=0) ;; nvnarrowvector) env=(NVAIR_NARROW_VECTOR_FIX=0) ;; nvsubnot) env=(NVAIR_SUB_NOT_FIX=0) ;; msaa2) env=(MTLSHIM_MSAA2=0) ;; paddedab) env=(INTEL_IVB_PADDED_ARGUMENT_BUFFER_FIX=0) ;; emuref) env=(INTEL_EMULATED_REFERENCE_FIX=0) ;; abtex) env=(MTLSHIM_IVB_ARGUMENT_BUFFER_TEXTURES=0 INTEL_IVB_ARGUMENT_BUFFER_TEXTURES=0) ;; aboffsets) env=(INTEL_IVB_ARGUMENT_BUFFER_OFFSETS=0) ;; blitlock) env=(MTLSHIM_IVB_BLIT_LOCK=0) ;; vinputs) env=(MTLSHIM_IVB_VERTEX_INPUTS=0) ;; keepdepth) env=(MTLSHIM_STENCIL_KEEPS_DEPTH=0) ;; zerodepth) env=(MTLSHIM_ZERO_DEPTH=0) ;;
    esac
    # s13's fix (item 25) works in MTLCompilerService, which gets the shim under test this way (i05's metallib needs it
    # too, and so does s68's macOS 15.0 Core Image kernel); so does s59's (item 45), whose bug is in Tahoe's out-of-process
    # compiler only, and s74's, s75's and s76's (item 75; s76: Core Image's built-in kernels): the downgrade for the Intel
    # and Kepler back ends runs in the service even when localcc compiles in the test process
    [ "$t" = s13-new-air-metallib ] || [ "$t" = i05-intel-constexpr-sampler ] || [ "$t" = s59-metal4-texture-reads ] ||
        [ "$t" = s68-coreimage-metal-kernels ] || [ "$t" = s74-chromium-angle-libraries ] || [ "$t" = s75-air-version-matrix ] ||
        [ "$t" = s76-coreimage-builtin-filters ] &&
        env+=("__XPC_DYLD_INSERT_LIBRARIES=$shim")
    # On the AMD GPU the in-process compiler can't load i05's macOS 15.4 library ("image not loaded"), so there it compiles
    # in MTLCompilerService, which takes the build's compiler files by leaf name
    local cc=$CC
    [ "$t" = i05-intel-constexpr-sampler ] && [[ $gpu == *AMD* || $gpu == *NVIDIA* || $gpu == *GeForce* || $gpu == *GTX* ]] && cc= &&
        env+=("__XPC_DYLD_LIBRARY_PATH=$libs:$libs/GeForceAIRPlugin.bundle/Contents/MacOS")
    [ "$t" = s59-metal4-texture-reads ] && cc= && env+=("__XPC_DYLD_LIBRARY_PATH=$libs")
    # s76 (a sweep) compiles in MTLCompilerService, as apps do: on Tahoe, OCLP's fixIr crashes on Core Image's built-in
    # kernels when the compiler runs in the test process (it doesn't in the service)
    [ "$t" = s76-coreimage-builtin-filters ] && cc= && env+=("__XPC_DYLD_LIBRARY_PATH=$libs")
    local inserted
    inserted=$(printf '%s\n' "$shim" "$cc" "$inject" | grep . | paste -sd: -)
    [ "$t" = s64-firefox-angle-display ] && env+=("DYLD_FALLBACK_LIBRARY_PATH=${S64_FIREFOX_APP:-/Applications/Firefox.app}/Contents/MacOS")
    rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.metal" "$(getconf DARWIN_USER_CACHE_DIR)com.apple.metalfe"
    env ${env[@]+"${env[@]}"} AMD_BRONZE_COMPAT_PATH="$libs/AMDBronzeCompat.dylib" \
        DYLD_INSERT_LIBRARIES="$inserted" DYLD_LIBRARY_PATH="$libs:$libs/GeForceAIRPlugin.bundle/Contents/MacOS" ./build/"$t" ${gpu:+"$gpu"} 2>/dev/null |
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
        if [ -n "$IVB" ] && [[ " $(echo $IVB_KNOWN) " == *" ${t%%@*} "* ]]; then
            before="SKIP ${t%%@*}: a known Ivy Bridge limitation (FIXES.md, Known limitations)" after=$before
        elif [ -z "$SHIM" ] && [ "$removed" = shim ]; then
            before="SKIP ${t%%@*}: MetalOldCompat needs OCLP's MetalOld wrapper" after=$before
        else
            before=$(run "$t" "$removed"); before=${before:-FAIL: crashed (in-process compiler)}
            # with the fixes, a crash report from MTLCompilerService fails the test even if it passed: MetalOld retries a
            # crashed compile, and a pipeline that builds on the retry or isn't checked hid the crash (a Chromium GPU process stuck)
            # (only MTLCompilerService's reports: the test's own crash already shows as "crashed"; ReportCrash writes a report a
            # moment after the crash, so the run without the fix gets a second to finish its own before the window opens)
            sleep 1; mark=$(mktemp); tools/crashwatch.sh start "$mark"
            after=$(run "$t" fixed); after=${after:-FAIL: crashed (in-process compiler)}
            sleep 1
            crashes=$(tools/crashwatch.sh new "$mark" MTLCompilerService | wc -l | tr -d ' ')
            rm -f "$mark"
            [ "$crashes" != 0 ] && [[ $after == PASS* ]] && after="FAIL ${t%%@*}: passed, but MTLCompilerService wrote $crashes crash report(s) meanwhile"
        fi
        echo "$t" >&2; echo "  without: $before" >&2; echo "  with:    $after" >&2
        echo "| ${t/@/ on } | $before | $after |"
    done
} > "RESULTS${V:+-12.5$V}${GPU:+-$GPU}${ONLY:+-only}.md"  # an ONLY run keeps the full table
rm -rf "$FIXED" "$NOADAPTER" "$STOCK" "$PATCH3" "$PATCH4" "$PATCH5"
