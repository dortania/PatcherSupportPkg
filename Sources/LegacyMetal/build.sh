#!/usr/bin/env bash
# build.sh: builds MetalOldCompat, AMDTextureAtomics and IntelTextureAtomics from source and regenerates the patched
# payload files in Universal-Binaries/ from PatcherSupportPkg's stock copies:
#   13.2.1-24 and 13.2.1-25 (Tahoe) Metal.framework/Versions/A/
#                                           Metal (+ weak load of MetalOldCompat.dylib), MetalOldCompat.dylib
#   13.6-25 MTLCompiler.framework and 13.2.1-25 GPUCompiler.framework, Versions/31001/
#                                           Tahoe's compiler: 14.2 Beta 1 under the 31001 paths (tools/make_tahoe_compiler.py)
#   12.5 AMDShared.bundle/Contents/         MacOS/AMDShared (+ weak load of AMDTextureAtomics.dylib),
#                                           MacOS/AMDTextureAtomics.dylib, PlugIns/libAMDIL902.dylib (patches 1-5)
#   12.5-GCN-25 AMDShared.bundle/Contents/  the same for Tahoe, from OCLP's GCN-25 copies (libAMDIL902: patches 2-5,
#                                           OCLP's initializeIABArgTypeSet stub kept instead of patch 1)
#   12.5 AppleIntelHD5000GraphicsMTLDriver.bundle/Contents/MacOS/
#                                           libMTLIntelCompilerPlugin.dylib (+ weak load), IntelTextureAtomics.dylib
#   AMDMTLBronzeDriver.bundle/Contents/MacOS/ in 12.5, 12.5-24, 12.5-25 and 12.5-GCN-SKL-22..25:
#                                           AMDMTLBronzeDriver (+ weak load of AMDBronzeCompat.dylib), AMDBronzeCompat.dylib
# The stock inputs come from git (STOCK_REF, default: the merge base with origin/HEAD, the upstream default branch), never from the patched files
# in the working tree, so re-running it gives the same output. STOCK_DIR=<dir> takes them from a folder instead
# (files: Metal Metal-25 MetalOld.dylib AMDShared libAMDIL902.dylib AMDShared-GCN-25 libAMDIL902-GCN-25.dylib
# libMTLIntelCompilerPlugin.dylib AMDMTLBronzeDriver-<variant>).
# Everything is ad-hoc signed; release signing happens as for the rest of the payload. Needs Xcode command-line tools.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
UB=$ROOT/Universal-Binaries B=$HERE/build
WRAPPER=13.2.1-24/System/Library/Frameworks/Metal.framework/Versions/A
WRAPPER25=13.2.1-25/System/Library/Frameworks/Metal.framework/Versions/A
AMD=12.5/System/Library/Extensions/AMDShared.bundle/Contents
GCN25=12.5-GCN-25/System/Library/Extensions/AMDShared.bundle/Contents
BRONZE=System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS
BRONZE_VARIANTS="12.5 12.5-24 12.5-25 12.5-GCN-SKL-22 12.5-GCN-SKL-23 12.5-GCN-SKL-24 12.5-GCN-SKL-25"
INTEL=12.5/System/Library/Extensions/AppleIntelHD5000GraphicsMTLDriver.bundle/Contents/MacOS
rm -rf "$B"; mkdir -p "$B/stock"
stock() {  # <path under Universal-Binaries> <file name>
    if [ -n "${STOCK_DIR:-}" ]; then cp "$STOCK_DIR/$2" "$B/stock/$2"; return; fi
    local ref=${STOCK_REF:-$(git -C "$ROOT" merge-base HEAD origin/HEAD)}
    git -C "$ROOT" show "$ref:Universal-Binaries/$1" > "$B/stock/$2"
}
stock "$WRAPPER/Metal" Metal
stock "$WRAPPER25/Metal" Metal-25
stock "$WRAPPER/MetalOld.dylib" MetalOld.dylib
stock "$AMD/MacOS/AMDShared" AMDShared
stock "$AMD/PlugIns/libAMDIL902.dylib" libAMDIL902.dylib
stock "$GCN25/MacOS/AMDShared" AMDShared-GCN-25
stock "$GCN25/PlugIns/libAMDIL902.dylib" libAMDIL902-GCN-25.dylib
stock "$INTEL/libMTLIntelCompilerPlugin.dylib" libMTLIntelCompilerPlugin.dylib
for v in $BRONZE_VARIANTS; do stock "$v/$BRONZE/AMDMTLBronzeDriver" "AMDMTLBronzeDriver-$v"; done

# 1. MetalOldCompat, and the no-op build the tests use for "without the fix" (same load commands, does nothing)
for variant in "" -noop; do
    clang -arch x86_64 -mmacosx-version-min=15.0 -dynamiclib -fobjc-arc -Wall -O2 ${variant:+-DMETALOLDCOMPAT_NOOP} \
        -install_name /System/Library/Frameworks/Metal.framework/Versions/A/MetalOldCompat.dylib \
        -framework Foundation -framework IOKit -Wl,-no_warn_inits -Wl,-not_for_dyld_shared_cache \
        "$B/stock/MetalOld.dylib" "$HERE/MetalOldCompat/MetalOldCompat.m" -o "$B/MetalOldCompat$variant.dylib"
done
# 2. AMD adapter, for both AMDShared copies (the 12.5 AMDShared and Intel bundles are also installed on macOS 13 and 14)
clang -arch x86_64 -mmacosx-version-min=13.0 -dynamiclib -O2 -Wall -Wl,-no_warn_inits \
    -install_name /System/Library/Extensions/AMDShared.bundle/Contents/MacOS/AMDTextureAtomics.dylib \
    "$HERE/AMDAdapter/texatomic.c" "$HERE/AMDAdapter/sihazard.c" "$HERE/AMDAdapter/SCLib.tbd" \
    "$HERE/AMDAdapter/libAMDIL902.tbd" -lc++ -o "$B/AMDTextureAtomics.dylib"
# 3. Intel adapter (only the Command Line Tools need their libc++ headers named)
CXXINC=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1
[[ "$(xcode-select -p)" == *CommandLineTools* ]] && export CPLUS_INCLUDE_PATH=$CXXINC
clang++ -arch x86_64 -mmacosx-version-min=13.0 -std=c++17 -dynamiclib -O2 -Wall -Wl,-no_warn_inits \
    -install_name /System/Library/Extensions/AppleIntelHD5000GraphicsMTLDriver.bundle/Contents/MacOS/IntelTextureAtomics.dylib \
    "$HERE/IntelAdapter/intelatomics.cpp" "$HERE/IntelAdapter/libLLVM3802.tbd" -o "$B/IntelTextureAtomics.dylib"
# 4. AMD driver fixes (the 12.5 driver is also installed on macOS 13 and 14)
clang -arch x86_64 -mmacosx-version-min=13.0 -dynamiclib -fobjc-arc -O2 -Wall -Wl,-no_warn_inits \
    -install_name /System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/AMDBronzeCompat.dylib \
    -framework Foundation -framework Metal "$HERE/BronzeCompat/BronzeCompat.m" -o "$B/AMDBronzeCompat.dylib"
# 5. vendor files: libAMDIL902 patches, weak load commands
python3 -I "$HERE/libAMDIL902/make_parser_fix.py" "$B/stock/libAMDIL902.dylib" "$B/libAMDIL902.dylib"
python3 -I "$HERE/libAMDIL902/make_parser_fix.py" "$B/stock/libAMDIL902-GCN-25.dylib" "$B/libAMDIL902-GCN-25.dylib"
weak() {  # <stock file> <output> <dylib path>
    cp "$B/stock/$1" "$B/$1.unsigned"
    codesign --remove-signature "$B/$1.unsigned"
    python3 -I "$HERE/tools/add_weak_dylib.py" "$B/$1.unsigned" "$B/$2" "$3"
}
weak Metal Metal /System/Library/Frameworks/Metal.framework/Versions/A/MetalOldCompat.dylib
weak Metal-25 Metal-25 @loader_path/MetalOldCompat.dylib  # this wrapper has no room for the full path
weak AMDShared AMDShared @loader_path/AMDTextureAtomics.dylib
weak AMDShared-GCN-25 AMDShared-GCN-25 @loader_path/AMDTextureAtomics.dylib
weak libMTLIntelCompilerPlugin.dylib libMTLIntelCompilerPlugin.dylib @loader_path/IntelTextureAtomics.dylib
for v in $BRONZE_VARIANTS; do weak "AMDMTLBronzeDriver-$v" "AMDMTLBronzeDriver-$v" @loader_path/AMDBronzeCompat.dylib; done
cd "$B"
codesign -f -s - MetalOldCompat.dylib MetalOldCompat-noop.dylib AMDTextureAtomics.dylib IntelTextureAtomics.dylib \
    libAMDIL902.dylib libAMDIL902-GCN-25.dylib Metal Metal-25 AMDShared AMDShared-GCN-25 libMTLIntelCompilerPlugin.dylib \
    2>/dev/null
codesign -f -s - AMDBronzeCompat.dylib 2>/dev/null
for v in $BRONZE_VARIANTS; do codesign -f -s - "AMDMTLBronzeDriver-$v" 2>/dev/null; done
# 6. into the payload
cp Metal MetalOldCompat.dylib "$UB/$WRAPPER/"
cp Metal-25 "$UB/$WRAPPER25/Metal"
cp MetalOldCompat.dylib "$UB/$WRAPPER25/"
cp AMDShared AMDTextureAtomics.dylib "$UB/$AMD/MacOS/"
cp libAMDIL902.dylib "$UB/$AMD/PlugIns/"
cp AMDShared-GCN-25 "$UB/$GCN25/MacOS/AMDShared"
cp AMDTextureAtomics.dylib "$UB/$GCN25/MacOS/"
cp libAMDIL902-GCN-25.dylib "$UB/$GCN25/PlugIns/libAMDIL902.dylib"
cp libMTLIntelCompilerPlugin.dylib IntelTextureAtomics.dylib "$UB/$INTEL/"
for v in $BRONZE_VARIANTS; do
    cp "AMDMTLBronzeDriver-$v" "$UB/$v/$BRONZE/AMDMTLBronzeDriver"
    cp AMDBronzeCompat.dylib "$UB/$v/$BRONZE/"
done
[ -n "${STOCK_DIR:-}" ] || python3 -I "$HERE/tools/make_tahoe_compiler.py" "$ROOT" "${STOCK_REF:-$(git -C "$ROOT" merge-base HEAD origin/HEAD)}"
shasum -a 256 MetalOldCompat.dylib AMDTextureAtomics.dylib IntelTextureAtomics.dylib AMDBronzeCompat.dylib libAMDIL902.dylib Metal \
    Metal-25 AMDShared libAMDIL902-GCN-25.dylib AMDShared-GCN-25 libMTLIntelCompilerPlugin.dylib
