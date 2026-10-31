#!/usr/bin/env bash
# build.sh: builds every repro program into build/ (and s13's two metallibs if Xcode's metal compiler is available).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
for src in [a-z][0-9]*.m; do
    name=${src%.m}
    clang -arch x86_64 -mmacosx-version-min=12.0 -fobjc-arc -O1 -Wall -Wno-unguarded-availability-new \
        -framework Foundation -framework Metal -o "build/$name" "$src"
done
cp -R data build/
if xcrun -sdk macosx -f metal >/dev/null 2>&1; then
    for target in 14.0:macos14 15.4:macos15.4; do
        version=${target%%:*}; tag=${target#*:}
        xcrun -sdk macosx metal -mmacosx-version-min="$version" -c data/s13-air.metal -o "build/s13-$tag.air"
        xcrun -sdk macosx metallib "build/s13-$tag.air" -o "build/s13-air-$tag.metallib"
        rm -f "build/s13-$tag.air"
    done
else
    echo "build.sh: Xcode's metal compiler not found; s13 will SKIP" >&2
fi
find build -maxdepth 1 -type f -perm -u+x ! -name '*.metallib' | wc -l | xargs echo "programs built:"
