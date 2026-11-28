#!/usr/bin/env bash
# safari-page.sh [seconds]: runs apps-page.html (PAGE=webgpu-page.html: that page) in Safari against the installed stack, as apps.sh does for the other
# browsers. Safari ignores DYLD_INSERT_LIBRARIES (a platform binary), so only a root-patched build is tested, and it
# prints no page console, so tools/pageserver.py serves the page and takes its result back. Safari opens it as a new
# tab of the user's own Safari (close it afterwards). FAIL: no "apps.sh: done" within [seconds] (default 30), a crash
# report from MTLCompilerService or WebKit's processes, or a compiler failure in the log. Exit status: 0 PASS, 1 FAIL.
set -u
T=$(cd "$(dirname "$0")/.." && pwd)
secs=${1:-30} port=$((8700 + RANDOM % 200))
# The browsers' pages finish on requestAnimationFrame, which doesn't run while the display sleeps (every page then "no
# result", a false FAIL): wake the display and keep it awake for as long as this script runs
caffeinate -u -t 1 > /dev/null 2>&1; caffeinate -d -w $$ > /dev/null 2>&1 &
# A locked screen hides the browsers' windows too, and the pages wait for requestAnimationFrame forever: stop instead of
# reporting every page stuck. Only the user can unlock.
if ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
    echo "$(basename "$0"): the screen is locked; the pages can't finish behind the lock screen (unlock, then run again)" >&2; exit 2
fi
page_file=${PAGE:-apps-page.html}
out=$(mktemp -d)
trap 'pkill -f "pageserver.py $port" 2>/dev/null; rm -rf "$out"' EXIT
python3 -I "$T/tools/pageserver.py" "$port" "$out/result" > /dev/null 2>&1 &
sleep 1
"$T/tools/crashwatch.sh" start "$out/reports"
open -g -a Safari "http://127.0.0.1:$port/$page_file?report=1"
for ((i = 0; i < secs; i++)); do [ -s "$out/result" ] && break; sleep 1; done
sleep 2
page=$(tail -1 "$out/result" 2>/dev/null)
crashes=$("$T/tools/crashwatch.sh" new "$out/reports" MTLCompilerService com.apple.WebKit Safari | tr '\n' ' ')
errors=$("$T/tools/crashwatch.sh" log "$out/reports")
if [ -n "$crashes" ]; then echo "FAIL Safari: crash report(s): $crashes"; exit 1
elif [ "${errors:-0}" != 0 ]; then echo "FAIL Safari: $errors compiler failure(s) in the log"; exit 1
elif [ "$page" != "apps.sh: done" ]; then echo "FAIL Safari: page: ${page:-no result in ${secs}s (stuck?)}"; exit 1
fi
echo "PASS Safari: page done in ${i}s, no crash report"
