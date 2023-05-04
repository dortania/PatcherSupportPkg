#!/usr/bin/env bash

xattr -rc Universal-Binaries
find Universal-Binaries -name .DS_Store -delete
hdiutil create -srcfolder Universal-Binaries tmp.dmg -volname "OpenCore Patcher Resources (Root Patching)" -fs HFS+ -ov -format UDRO
hdiutil convert -format ULMO tmp.dmg -o Universal-Binaries.dmg -passphrase password -encryption -ov
rm tmp.dmg
