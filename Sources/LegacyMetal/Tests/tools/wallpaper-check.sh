#!/usr/bin/env bash
# wallpaper-check.sh <wallpaper> [seconds]: sets a wallpaper on the installed stack, watches it for [seconds] (default 30)
# and puts the user's wallpaper back exactly. Wallpapers are drawn by WallpaperAgent and its extensions (dynamic HEIC,
# Aerial video, Sequoia's own), system processes that ignore DYLD_INSERT_LIBRARIES, so only a root-patched build is
# tested. <wallpaper>: an image file (a dynamic HEIC such as "/System/Library/Desktop Pictures/Sonoma.heic" stays
# dynamic; set through NSWorkspace, as apps and System Settings' "Add Photo" do), or a saved wallpaper store
# (an Index.plist captured after choosing the wallpaper in System Settings), or builtin:<name> for one of macOS's own:
# builtin:sequoia (Sequoia's 3D scene, which its extension renders with Metal), builtin:sonoma, builtin:ventura,
# builtin:monterey, builtin:macintosh; the user's store gets that wallpaper (dynamic style) in each of its desktop slots.
# FAIL: the store changed back by itself (the wallpaper didn't stick: macOS falls back to its default), WallpaperAgent
# didn't recognize it ("unknown" content) or couldn't snapshot it (the export macOS makes of every wallpaper, which
# needs the wallpaper's extension to render it), a crash report from WallpaperAgent, a wallpaper extension or
# MTLCompilerService, or a compiler failure in the log.
# Exit status: 0 PASS, 1 FAIL, 2 usage or setup error.
set -u
T=$(cd "$(dirname "$0")/.." && pwd)
want=${1:-} secs=${2:-30}
[ -n "$want" ] && { [ -e "$want" ] || [[ $want == builtin:* ]]; } || { sed -n '2,15s/^# \{0,1\}//p' "$0" >&2; exit 2; }
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
    builtin:*)  # the user's store with macOS's own wallpaper in every desktop slot (dynamic style, as System Settings sets it)
        python3 -I - "$out/before.plist" "$out/builtin.plist" "com.apple.wallpaper.choice.${want#builtin:}" <<'PY' || exit 2
import plistlib, sys
store = plistlib.load(open(sys.argv[1], 'rb'))
choice = {'Provider': sys.argv[3], 'Configuration': plistlib.dumps({'style': 0}, fmt=plistlib.FMT_BINARY), 'Files': []}
def walk(x, key=''):
    if isinstance(x, dict):
        for k, v in x.items():
            if k in ('Desktop', 'Linked') and isinstance(v, dict) and 'Content' in v: v['Content']['Choices'] = [dict(choice)]
            else: walk(v, k)
    elif isinstance(x, list):
        for v in x: walk(v)
walk(store)
plistlib.dump(store, open(sys.argv[2], 'wb'), fmt=plistlib.FMT_BINARY)
PY
        cp "$out/builtin.plist" "$store" && killall WallpaperAgent 2>/dev/null ;;
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
/usr/bin/log show --start "$start" --style compact --predicate 'process == "WallpaperAgent" AND (eventMessage CONTAINS "Create new wallpaper" OR eventMessage CONTAINS "Exporting wallpaper")' \
    2>/dev/null > "$out/agent.txt"
# the wallpaper processes' own complaints meanwhile (for the report; not a verdict by themselves)
/usr/bin/log show --start "$start" --style compact --predicate 'process CONTAINS "Wallpaper" AND messageType == error' 2>/dev/null |
    grep -v -E '^(Timestamp|Filtering)' | tail -5 > "$out/errors.txt"
if [ -n "$crashes" ]; then echo "FAIL $name: crash report(s): $crashes"; result=1
elif [ "${errors:-0}" != 0 ]; then echo "FAIL $name: $errors compiler failure(s) in the log"; result=1
elif grep -q ': unknown: <com.apple.wallpaper.choice' "$out/agent.txt"; then echo "FAIL $name: WallpaperAgent didn't recognize the wallpaper (unknown content)"; result=1
elif grep -q 'ERROR - Exporting wallpaper' "$out/agent.txt"; then
    echo "FAIL $name: no snapshot of the wallpaper: $(grep 'ERROR - Exporting wallpaper' "$out/agent.txt" | tail -1 | sed 's/.*ERROR - //' | cut -c1-140)"; result=1
elif ! grep -q 'END - Exporting wallpaper' "$out/agent.txt"; then echo "FAIL $name: no snapshot exported in ${secs}s (not rendered)"; result=1
elif cmp -s "$out/set.plist" "$out/before.plist" && [ "${want##*.}" != plist ]; then
    echo "FAIL $name: the wallpaper store didn't change (not applied)"; result=1
elif ! diff -q "$out/set.txt" "$out/now.txt" > /dev/null; then
    echo "FAIL $name: the wallpaper changed back by itself within ${secs}s:"; diff "$out/set.txt" "$out/now.txt" | head -8; result=1
else
    snap=$(grep -c 'END - Exporting wallpaper' "$out/agent.txt")
    echo "PASS $name: applied, rendered (snapshot exported ${snap}x) and still set after ${secs}s, no crash report or compiler failure"; result=0
fi
[ -s "$out/errors.txt" ] && { echo "  wallpaper processes' errors meanwhile:"; cut -c1-200 "$out/errors.txt" | sed 's/^/    /'; }
exit $result
