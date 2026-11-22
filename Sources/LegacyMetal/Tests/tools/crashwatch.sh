#!/usr/bin/env bash
# crashwatch.sh start <state file>: notes the time and the crash reports there are now.
# crashwatch.sh new <state file> <name prefix>...: prints the crash reports written since (one per line) whose process name
# starts with one of the prefixes (MTLCompilerService, a test's name, an app's executable).
# crashwatch.sh log <state file>: prints how many compiler failures the unified log has had since: a client's "Compiler failed
# with XPC_ERROR..." (one per crashed request, also when ReportCrash, which throttles repeats, wrote no report) and
# MTLCompilerService's "Compiler encountered an internal error" / "LLVM ERROR".
# By file name and the time in it (<process>-YYYY-MM-DD-HHMMSS.ips), not by modification time: macOS rewrites old reports
# in ~/Library/Logs/DiagnosticReports now and then, sometimes under a new name.
dir=~/Library/Logs/DiagnosticReports
case ${1:-} in
    start) { date '+%Y-%m-%d-%H%M%S'; ls "$dir" 2>/dev/null | sort; } > "$2" ;;
    new) state=$2; shift 2
        since=$(head -1 "$state")
        ls "$dir" 2>/dev/null | sort | comm -13 <(tail -n +2 "$state") - | while IFS= read -r f; do
            case $f in *.ips|*.crash) ;; *) continue ;; esac
            stamp=$(grep -o -E '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' <<< "$f" | tail -1)
            [ -n "$stamp" ] && [[ $stamp < $since ]] && continue  # an old report under a new name
            for p in "$@"; do [[ $f == "$p"* ]] && { echo "$f"; break; }; done
        done ;;
    log) s=$(head -1 "$2"); start="${s:0:10} ${s:11:2}:${s:13:2}:${s:15:2}"
        log show --start "$start" --style compact --predicate 'eventMessage BEGINSWITH "Compiler failed with XPC_ERROR" OR (process == "MTLCompilerService" AND (eventMessage CONTAINS "Compiler encountered an internal error" OR eventMessage CONTAINS "LLVM ERROR"))' 2>/dev/null |
            grep -c -E 'Compiler failed with XPC_ERROR|Compiler encountered an internal error|LLVM ERROR' ;;
    *) sed -n '2,9s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
