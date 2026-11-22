#!/usr/bin/env bash
# build.sh: builds every repro program into build/ (and s13's, i05's and s59's metallibs if Xcode's metal compiler is available).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
for src in [a-z][0-9]*.m; do
    name=${src%.m}
    extra=
    grep -q '<CoreImage/CoreImage.h>' "$src" && extra="-framework CoreImage -framework CoreGraphics"  # the Core Image tests only: the others stay without it
    grep -q '<MetalPerformanceShadersGraph/' "$src" && extra="-framework MetalPerformanceShaders -framework MetalPerformanceShadersGraph"  # s57
    grep -q '<MetalFX/' "$src" && extra="-framework MetalFX"  # s58
    # "// Info.plist: <bundle id>": an embedded Info.plist, so that Metal treats the program as that app (s82: function caches)
    id=$(sed -n 's|^// Info.plist: ||p' "$src")
    if [ -n "$id" ]; then
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>\n' "$id" > "build/$name.plist"
        extra="-sectcreate __TEXT __info_plist build/$name.plist"
    fi
    clang -arch x86_64 -mmacosx-version-min=12.0 -fobjc-arc -O1 -Wall -Wno-unguarded-availability-new \
        -framework Foundation -framework Metal $extra -o "build/$name" "$src"
done
[ -f tools/localcc.dylib ] || clang++ -std=c++17 -fblocks -dynamiclib tools/localcc.cpp -o tools/localcc.dylib  # c04 and verify.sh
[ -f tools/angle-caller/libANGLE-shared.dylib ] || clang -fobjc-arc -dynamiclib -framework Foundation -framework Metal \
    tools/angle-caller/anglecaller.m -o tools/angle-caller/libANGLE-shared.dylib  # s63 with S63_METALLIB
cp -R data build/
if xcrun -sdk macosx -f metal >/dev/null 2>&1; then
    for source in s13:s13-air i05:i05-samplers; do
        test=${source%%:*} file=${source#*:}
        for target in 14.0:macos14 15.4:macos15.4; do
            version=${target%%:*}; tag=${target#*:}
            xcrun -sdk macosx metal -mmacosx-version-min="$version" -c "data/$file.metal" -o "build/$test-$tag.air"
            xcrun -sdk macosx metallib "build/$test-$tag.air" -o "build/$test-air-$tag.metallib"
            rm -f "build/$test-$tag.air"
        done
    done
    # s75: one shader set built for each macOS target from 10.14 (AIR 2.1, Chromium's prebuilt ANGLE library) up
    for version in 10.14 10.15 11.0 12.0 13.0 14.0 15.0 26.0; do
        xcrun -sdk macosx metal -mmacosx-version-min="$version" -c data/s75-air.metal -o "build/s75-$version.air" 2>/dev/null &&
            xcrun -sdk macosx metallib "build/s75-$version.air" -o "build/s75-air-macos$version.metallib"
        rm -f "build/s75-$version.air"
    done
    # s68: a precompiled Core Image kernel for macOS 14.0 and 15.0 (AIR 2.7, as Office 16.115 ships), and a stitchable one
    for target in 14.0:macos14 15.0:macos15; do
        version=${target%%:*}; tag=${target#*:}
        xcrun -sdk macosx metal -fcikernel -mmacosx-version-min="$version" -c data/s68-ci-color.metal -o "build/s68-$tag.air"
        xcrun -sdk macosx metallib -cikernel "build/s68-$tag.air" -o "build/s68-ci-$tag.metallib"
        rm -f "build/s68-$tag.air"
    done
    xcrun -sdk macosx metal -mmacosx-version-min=14.0 -c data/s68-ci-stitchable.metal -o build/s68-stitchable.air
    xcrun -sdk macosx metal build/s68-stitchable.air -framework CoreImage -o build/s68-ci-stitchable.metallib
    rm -f build/s68-stitchable.air
    # s77: one Core Image kernel of each kind for every macOS target (AIR 2.0 to 2.8), and stitchable ones from macOS 12
    for version in 10.13 10.14 10.15 11.0 12.0 13.0 14.0 15.0 26.0; do
        xcrun -sdk macosx metal -fcikernel -mmacosx-version-min="$version" -c data/s77-ci-kernels.metal -o "build/s77-$version.air" &&
            xcrun -sdk macosx metallib -cikernel "build/s77-$version.air" -o "build/s77-ci-$version.metallib"
        rm -f "build/s77-$version.air"
    done
    for version in 12.0 14.0 15.0 26.0; do
        xcrun -sdk macosx metal -mmacosx-version-min="$version" -c data/s77-ci-stitchable.metal -o "build/s77-st-$version.air" &&
            xcrun -sdk macosx metal "build/s77-st-$version.air" -framework CoreImage -o "build/s77-ci-stitchable-$version.metallib"
        rm -f "build/s77-st-$version.air"
    done
    # s59: a Metal 4.0 library (Xcode 26), whose texture reads all go through the read sampler
    if xcrun -sdk macosx metal -std=metal4.0 -mmacosx-version-min=26.0 -c data/s59-reads.metal -o build/s59.air 2>/dev/null; then
        xcrun -sdk macosx metallib build/s59.air -o build/s59-metal4.metallib
        rm -f build/s59.air
    else
        echo "build.sh: this metal compiler has no Metal 4.0 (Xcode 26); s59 will SKIP" >&2
    fi
else
    echo "build.sh: Xcode's metal compiler not found; s13, i05 and s59 will SKIP, and s68 checks only the Metal half" >&2
fi
find build -maxdepth 1 -type f -perm -u+x ! -name '*.metallib' | wc -l | xargs echo "programs built:"
