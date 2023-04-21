#!/usr/bin/env bash

hdiutil create -srcfolder Universal-Binaries tmp.dmg -volname payloads -fs HFS+ -ov -format UDRO
hdiutil convert -format ULMO tmp.dmg -o Universal-Binaries.dmg -passphrase password -encryption -ov
rm tmp.dmg
