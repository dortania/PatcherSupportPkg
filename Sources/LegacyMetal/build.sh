#!/usr/bin/env bash
# build.sh: builds MetalOldCompat, AMDTextureAtomics and IntelTextureAtomics from source and regenerates the patched
# payload files in Universal-Binaries/ from PatcherSupportPkg's stock copies:
#   13.2.1-24 Metal.framework/Versions/A/   Metal (+ weak load of MetalOldCompat.dylib), MetalOldCompat.dylib
#   12.5 AMDShared.bundle/Contents/         MacOS/AMDShared (+ weak load of AMDTextureAtomics.dylib),
#                                           MacOS/AMDTextureAtomics.dylib, PlugIns/libAMDIL902.dylib (patches 1-4)
#   12.5 AppleIntelHD5000GraphicsMTLDriver.bundle/Contents/MacOS/
#                                           libMTLIntelCompilerPlugin.dylib (+ weak load), IntelTextureAtomics.dylib
# The stock inputs come from git (STOCK_REF, default: the merge base with origin/HEAD, the upstream default branch), never from the patched files
# in the working tree, so re-running it gives the same output. STOCK_DIR=<dir> takes them from a folder instead
# (files: Metal MetalOld.dylib AMDShared libAMDIL902.dylib libMTLIntelCompilerPlugin.dylib).
# Everything is ad-hoc signed; release signing happens as for the rest of the payload. Needs Xcode command-line tools.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
UB=$ROOT/Universal-Binaries B=$HERE/build
WRAPPER=13.2.1-24/System/Library/Frameworks/Metal.framework/Versions/A
AMD=12.5/System/Library/Extensions/AMDShared.bundle/Contents
INTEL=12.5/System/Library/Extensions/AppleIntelHD5000GraphicsMTLDriver.bundle/Contents/MacOS
rm -rf "$B"; mkdir -p "$B/stock"
stock() {  # <path under Universal-Binaries> <file name>
    if [ -n "${STOCK_DIR:-}" ]; then cp "$STOCK_DIR/$2" "$B/stock/$2"; return; fi
    local ref=${STOCK_REF:-$(git -C "$ROOT" merge-base HEAD origin/HEAD)}
    git -C "$ROOT" show "$ref:Universal-Binaries/$1" > "$B/stock/$2"
}
stock "$WRAPPER/Metal" Metal
stock "$WRAPPER/MetalOld.dylib" MetalOld.dylib
stock "$AMD/MacOS/AMDShared" AMDShared
stock "$AMD/PlugIns/libAMDIL902.dylib" libAMDIL902.dylib
stock "$INTEL/libMTLIntelCompilerPlugin.dylib" libMTLIntelCompilerPlugin.dylib

# 1. MetalOldCompat, and the no-op build the tests use for "without the fix" (same load commands, does nothing)
for variant in "" -noop; do
    clang -arch x86_64 -mmacosx-version-min=15.0 -dynamiclib -fobjc-arc -Wall -O2 ${variant:+-DMETALOLDCOMPAT_NOOP} \
        -install_name /System/Library/Frameworks/Metal.framework/Versions/A/MetalOldCompat.dylib \
        -framework Foundation -framework IOKit -Wl,-no_warn_inits -Wl,-not_for_dyld_shared_cache \
        "$B/stock/MetalOld.dylib" "$HERE/MetalOldCompat/MetalOldCompat.m" -o "$B/MetalOldCompat$variant.dylib"
done
# 2. AMD adapter (the 12.5 AMDShared and Intel bundles are also installed on macOS 13 and 14)
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
# 4. vendor files: libAMDIL902 patches, weak load commands
python3 -I "$HERE/libAMDIL902/make_parser_fix.py" "$B/stock/libAMDIL902.dylib" "$B/libAMDIL902.dylib"
weak() {  # <stock file> <output> <dylib path>
    cp "$B/stock/$1" "$B/$1.unsigned"
    codesign --remove-signature "$B/$1.unsigned"
    python3 -I "$HERE/tools/add_weak_dylib.py" "$B/$1.unsigned" "$B/$2" "$3"
}
weak Metal Metal /System/Library/Frameworks/Metal.framework/Versions/A/MetalOldCompat.dylib
weak AMDShared AMDShared @loader_path/AMDTextureAtomics.dylib
weak libMTLIntelCompilerPlugin.dylib libMTLIntelCompilerPlugin.dylib @loader_path/IntelTextureAtomics.dylib
cd "$B"
codesign -f -s - MetalOldCompat.dylib MetalOldCompat-noop.dylib AMDTextureAtomics.dylib IntelTextureAtomics.dylib \
    libAMDIL902.dylib Metal AMDShared libMTLIntelCompilerPlugin.dylib 2>/dev/null
# 5. into the payload
cp Metal MetalOldCompat.dylib "$UB/$WRAPPER/"
cp AMDShared AMDTextureAtomics.dylib "$UB/$AMD/MacOS/"
cp libAMDIL902.dylib "$UB/$AMD/PlugIns/"
cp libMTLIntelCompilerPlugin.dylib IntelTextureAtomics.dylib "$UB/$INTEL/"
shasum -a 256 MetalOldCompat.dylib AMDTextureAtomics.dylib IntelTextureAtomics.dylib libAMDIL902.dylib Metal AMDShared \
    libMTLIntelCompilerPlugin.dylib
