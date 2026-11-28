#!/usr/bin/env bash
# quicklook-check.sh [file...]: has Quick Look make a thumbnail of each file through QLThumbnailGenerator (tools/qlthumb.m,
# the API Finder uses), on the installed stack: its thumbnailers are system processes that ignore DYLD_INSERT_LIBRARIES,
# and 3D models (USDZ) render on Metal. Default files, which every Mac has: Chess.app's king packed as a USDZ, the Sonoma
# wallpaper (HEIC) and one of its videos (MOV), and a PDF. (qlmanage -t has no 3D generator and waits forever; .usdc
# and .dae aren't thumbnail types at all: a blank thumbnail comes back.) FAIL per file: no thumbnail, or a blank one;
# and overall: a crash report from Quick Look's processes or MTLCompilerService, or a compiler failure in the log.
# Exit status: number of FAILs.
set -u
T=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
helper=$T/build/qlthumb
[ -x "$helper" ] && [ "$helper" -nt "$T/tools/qlthumb.m" ] ||
    clang -fobjc-arc -framework AppKit -framework QuickLookThumbnailing "$T/tools/qlthumb.m" -o "$helper" || exit 2
if [ $# -eq 0 ]; then
    king=/System/Applications/Chess.app/Contents/Resources/Meshes/king.usdc  # a USDZ is an uncompressed zip, the USD file first
    [ -f "$king" ] && (cd "$out" && cp "$king" king.usdc && zip -0 -q king.usdz king.usdc)
    set -- "$out/king.usdz" "/System/Library/Desktop Pictures/Sonoma.heic" \
        "/System/Library/Desktop Pictures/.wallpapers/Sonoma/Sonoma Graphic Light Landscape.mov" \
        "/System/Library/QuickLook/iWork.qlgenerator/Contents/Resources/fallback-image-bullet.pdf"
fi
"$T/tools/crashwatch.sh" start "$out/reports"
qlmanage -r cache > /dev/null 2>&1  # thumbnails made afresh, not from the cache
fail=0 pass=0
for f in "$@"; do
    [ -e "$f" ] || { echo "SKIP $(basename "$f"): not on this Mac"; continue; }
    result=$("$helper" "$f" "$out/thumb.png" 512); status=$?
    case $status in
        0) echo "PASS $(basename "$f"): $result"; pass=$((pass + 1)) ;;
        3) echo "FAIL $(basename "$f"): blank thumbnail ($result)"; fail=$((fail + 1)) ;;
        *) echo "FAIL $(basename "$f"): $result"; fail=$((fail + 1)) ;;
    esac
done
sleep 2
crashes=$("$T/tools/crashwatch.sh" new "$out/reports" QuickLook com.apple.quicklook Thumbnail MTLCompilerService | tr '\n' ' ')
errors=$("$T/tools/crashwatch.sh" log "$out/reports")
[ -n "$crashes" ] && { echo "FAIL crash report(s) meanwhile: $crashes"; fail=$((fail + 1)); }
[ "${errors:-0}" != 0 ] && { echo "FAIL $errors compiler failure(s) in the log meanwhile"; fail=$((fail + 1)); }
echo "== $pass passed, $fail failed"
exit $fail
