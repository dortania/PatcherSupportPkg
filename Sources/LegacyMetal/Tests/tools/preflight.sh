#!/bin/bash
# preflight.sh: checks the Mac's root-patched state before a test run, and warns about what would make results (or the
# next boot) wrong. Exit 0: nothing found; 1: warnings (printed). Run on its own or from the test scripts.
#  - a kext in the auxiliary kext collection (OCLP puts some root patches in /Library/Extensions on Sequoia) whose bundle
#    is gone from disk: it still runs from the loaded collection, but the next boot comes up without it. Preparing the
#    macOS 26 update with automatic downloads on deleted OCLP's AppleIntelHD4000Graphics.kext and GeForce.kext from
#    /Library/Extensions on two Sequoia test Macs, and both lost GPU acceleration (or would have) at their next restart.
#  - a macOS update downloaded or staged (System/Volumes/Update), and automatic downloads switched on.
warn=0
say() { echo "WARNING preflight: $*" >&2; warn=1; }
while read -r bundle; do
    [ -n "$bundle" ] || continue
    found=$(find /Library/Extensions -maxdepth 3 -name Info.plist -path '*.kext/Contents/*' -exec /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' {} \; 2>/dev/null | grep -Fx "$bundle")
    [ -n "$found" ] || say "kext $bundle is loaded from the auxiliary kext collection but its bundle is gone from /Library/Extensions: the next boot won't have it (re-run OCLP's root patch, or restore it, before restarting)"
done < <(kmutil showloaded --collection aux 2>/dev/null | awk 'NR > 1 {print $6}')
staged=$(du -sk /System/Volumes/Update 2>/dev/null | awk '{print $1}')
[ "${staged:-0}" -gt 102400 ] && say "a macOS update is staged in /System/Volumes/Update ($((staged / 1024)) MB): it can replace or remove root-patched files and block OCLP's root patch; restore any missing kext first, then unstage it without a restart with MobileSoftwareUpdate's MSUPurgeSuspendedUpdate (a small ad-hoc signed tool with the softwareupdated helper entitlements, amfi=0x80)"
[ "$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload 2>/dev/null)" = 1 ] &&
    say "automatic macOS update downloads are on: preparing an update has deleted OCLP's /Library/Extensions kexts on Sequoia"
exit $warn
