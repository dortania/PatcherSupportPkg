#!/usr/bin/env bash
set -e

# Homebrew...
/usr/bin/xattr -rc Universal-Binaries || true
find Universal-Binaries -name .DS_Store -delete || true

# Size the DMG from the payload instead of hardcoding it:
# payload size (in 1K blocks) + 10% + 256MB headroom for HFS+ metadata
PAYLOAD_KB=$(du -sk Universal-Binaries | cut -f1)
DMG_SIZE_MB=$(( PAYLOAD_KB / 1024 ))
DMG_SIZE_MB=$(( DMG_SIZE_MB + DMG_SIZE_MB / 10 + 256 ))
echo "DMG size: ${DMG_SIZE_MB} MB"

hdiutil create -srcfolder Universal-Binaries tmp.dmg -volname "BridgePatcher Resources (Root Patching)" -fs HFS+ -ov -format UDRO -megabytes "$DMG_SIZE_MB"
hdiutil convert -format ULMO tmp.dmg -o Universal-Binaries.dmg -passphrase password -encryption -ov
codesign -s "OCLP Self Signed" Universal-Binaries.dmg
rm tmp.dmg
