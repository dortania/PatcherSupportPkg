#!/usr/bin/env bash
# wallpaper-check.sh <wallpaper> [seconds]: sets a wallpaper on the installed stack, watches it for [seconds] (default 30)
# and puts the user's wallpaper back exactly. Wallpapers are drawn by WallpaperAgent and its extensions (dynamic HEIC,
# Aerial video, Sequoia's own), system processes that ignore DYLD_INSERT_LIBRARIES, so only a root-patched build is
# tested. <wallpaper>: an image file (a dynamic HEIC such as "/System/Library/Desktop Pictures/Sonoma.heic" stays
# dynamic; set through NSWorkspace, as apps and System Settings' "Add Photo" do), or a saved wallpaper store
# (an Index.plist captured after choosing the wallpaper in System Settings, e.g. data/wallpaper-sequoia.plist).
# FAIL: the store changed back by itself (the wallpaper didn't stick: macOS falls back to its default), a crash
# report from WallpaperAgent, a wallpaper extension or MTLCompilerService, or a compiler failure in the log.
# Exit status: 0 PASS, 1 FAIL, 2 usage or setup error.
set -u
T=$(cd "$(dirname "$0")/.." && pwd)
want=${1:-} secs=${2:-30}
[ -n "$want" ] && [ -e "$want" ] || { sed -n '2,10s/^# \{0,1\}//p' "$0" >&2; exit 2; }
store=~/Library/Application\ Support/com.apple.wallpaper/Store/Index.plist
[ -f "$store" ] || { echo "no wallpaper store at $store" >&2; exit 2; }
out=$(mktemp -d)
cp -p "$store" "$out/before.plist"
restore() {  # the user's own wallpaper, exactly as it was
    cp -p "$out/before.plist" "$store" && killall WallpaperAgent 2>/dev/null
    sleep 3
    cmp -s "$out/before.plist" "$store" || echo "WARNING wallpaper-check: the store differs after restoring; the saved copy is $out/before.plist" >&2
}
trap 'restore; [ -f "$out/before.plist" ] && cmp -s "$out/before.plist" "$store" && rm -rf "$out"' EXIT
"$T/tools/crashwatch.sh" start "$out/reports"
start=$(date '+%Y-%m-%d %H:%M:%S')
case $want in
    *.plist)  # a captured store: the wallpaper it names
        cp "$want" "$store" && killall WallpaperAgent 2>/dev/null ;;
    *)
        helper=$T/build/setdesktop
        [ -x "$helper" ] && [ "$helper" -nt "$T/tools/setdesktop.m" ] ||
            clang -fobjc-arc -framework AppKit "$T/tools/setdesktop.m" -o "$helper" || exit 2
        "$helper" "$want" || exit 2 ;;
esac
sleep 5
cp -p "$store" "$out/set.plist"  # what the wallpaper looks like right after it was set
sleep "$secs"
name=$(basename "$want")
plutil -p "$out/set.plist" > "$out/set.txt" 2>/dev/null; plutil -p "$store" > "$out/now.txt" 2>/dev/null
crashes=$("$T/tools/crashwatch.sh" new "$out/reports" WallpaperAgent Wallpaper MTLCompilerService | tr '\n' ' ')
errors=$("$T/tools/crashwatch.sh" log "$out/reports")
# the wallpaper processes' own complaints meanwhile (for the report; not a verdict by themselves)
/usr/bin/log show --start "$start" --style compact --predicate 'process CONTAINS "Wallpaper" AND messageType == error' 2>/dev/null |
    grep -v -E '^(Timestamp|Filtering)' | tail -5 > "$out/errors.txt"
if [ -n "$crashes" ]; then echo "FAIL $name: crash report(s): $crashes"; result=1
elif [ "${errors:-0}" != 0 ]; then echo "FAIL $name: $errors compiler failure(s) in the log"; result=1
elif cmp -s "$out/set.plist" "$out/before.plist" && [ "${want##*.}" != plist ]; then
    echo "FAIL $name: the wallpaper store didn't change (not applied)"; result=1
elif ! diff -q "$out/set.txt" "$out/now.txt" > /dev/null; then
    echo "FAIL $name: the wallpaper changed back by itself within ${secs}s:"; diff "$out/set.txt" "$out/now.txt" | head -8; result=1
else
    echo "PASS $name: applied and still set after ${secs}s, no crash report or compiler failure"; result=0
fi
[ -s "$out/errors.txt" ] && { echo "  wallpaper processes' errors meanwhile:"; cut -c1-200 "$out/errors.txt" | sed 's/^/    /'; }
exit $result
