#!/usr/bin/env bash

# Homebrew...
/usr/bin/xattr -rc Universal-Binaries
find Universal-Binaries -name .DS_Store -delete
hdiutil create -srcfolder Universal-Binaries tmp.dmg -volname "OpenCore Patcher Resources (Root Patching)" -fs HFS+ -ov -format UDRO -megabytes 4096
hdiutil convert -format ULMO tmp.dmg -o Universal-Binaries.dmg -passphrase password -encryption -ov
codesign -s "OpenCore Legacy Patcher Software Signing" Universal-Binaries.dmg
rm tmp.dmg
