#!/usr/bin/env bash
set -e

# Homebrew...
/usr/bin/xattr -rc Universal-Binaries || true
find Universal-Binaries -name .DS_Store -delete || true
hdiutil create -srcfolder Universal-Binaries tmp.dmg -volname "BridgePatcher Resources (Root Patching)" -fs HFS+ -ov -format UDRO -megabytes 4096
hdiutil convert -format ULMO tmp.dmg -o Universal-Binaries.dmg -passphrase password -encryption -ov
codesign -s "OCLP Self Signed" Universal-Binaries.dmg
rm tmp.dmg
