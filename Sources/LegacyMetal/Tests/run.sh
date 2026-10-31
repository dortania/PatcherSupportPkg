#!/usr/bin/env bash
# run.sh [GPU substring]: runs every repro program in build/ one after another (never two GPU jobs at once) and prints
# a summary. Clears the Metal shader cache of unbundled command-line tools first, so a pipeline cached by an earlier
# run (on another stack) can't hide the current result. Exit status: number of FAILs.
cd "$(dirname "$0")/build" || { echo "run ./build.sh first" >&2; exit 2; }
rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.metal"
pass=0 fail=0 skip=0
for t in $(ls | sort); do
    [ -x "$t" ] && [ -f "$t" ] || continue  # the test programs (s09-msl-3.2 has a dot; data/ and metallibs aren't)
    case "$t" in *.metallib|*.air) continue ;; esac
    line=$(./"$t" "$@" 2>/dev/null | grep -E '^(PASS|FAIL|SKIP) ' | tail -1)
    [ -n "$line" ] || line="FAIL $t: no result line (crashed?)"
    echo "$line"
    case "$line" in PASS*) pass=$((pass + 1)) ;; SKIP*) skip=$((skip + 1)) ;; *) fail=$((fail + 1)) ;; esac
done
echo "== $pass passed, $fail failed, $skip skipped"
exit $fail
