#!/usr/bin/env bash
# fetch-apps.sh [what...]: downloads the apps and runtimes that apps.sh and s74 test with, into Tests/apps/ (gitignored;
# APPS_DIR=<dir> for another folder). Each app is a plain copy there: nothing is installed, no login item or helper is set
# up, and apps.sh runs each in a throwaway profile. What to fetch (default: all):
#   electron [first last]   the latest stable patch of each Electron major (default the last 18 majors): one Chromium and
#                           ANGLE version each, as bundled by Electron apps, which lag Chrome by up to a couple of years
#   chrome [first last step]  Chrome for Testing builds, one per milestone (default every 4th of the last 40)
#   vscode firefox firefox-esr blender godot obsidian discord slack signal anki ppsspp retroarch retroarch-extras   single apps (latest
#                           release), chosen for the different ways they reach Metal: Chromium/ANGLE in Electron apps,
#                           Qt WebEngine (Anki), Firefox's own ANGLE and wgpu, native Metal renderers (Blender, Godot),
#                           MoltenVK as a bundled library of its own version (PPSSPP, RetroArch's Vulkan driver)
# Needs curl, ditto and hdiutil (macOS); Python 3 for the release indexes. Intel builds (x64), or universal where only that exists.
set -u
T=$(cd "$(dirname "$0")/.." && pwd)
dir=${APPS_DIR:-$T/apps}; mkdir -p "$dir/.dl"; cd "$dir" || exit 1
ua="fetch-apps.sh"
get() { curl -fsSL -A "$ua" -o "$2" "$1"; }

unzip_app() {  # <zip> <app name inside, or ""> <destination .app name>
    local x=.dl/x.$$; rm -rf "$x"; mkdir -p "$x"; ditto -x -k "$1" "$x" || { rm -rf "$x"; return 1; }
    local src; src=$(find "$x" -maxdepth 3 -name "${2:-*}.app" -type d | head -1)
    [ -n "$src" ] && rm -rf "$3" && mv "$src" "$3"; rm -rf "$x" "$1"; [ -d "$3" ]
}
dmg_app() {  # <dmg> <app name inside, or ""> <destination .app name>
    local m=.dl/m.$$; mkdir -p "$m"
    yes | hdiutil attach -nobrowse -noautoopen -readonly -mountpoint "$m" "$1" > /dev/null 2>&1 || { rm -rf "$m"; return 1; }
    local src; src=$(find "$m" -maxdepth 2 -name "${2:-*}.app" -type d | head -1)
    [ -n "$src" ] && rm -rf "$3" && ditto "$src" "$3"; hdiutil detach "$m" -quiet; rm -rf "$m" "$1"; [ -d "$3" ]
}
github_asset() {  # <owner/repo> <regex for the asset name>: URL of the latest release's matching asset
    get "https://api.github.com/repos/$1/releases/latest" .dl/gh.json &&
        python3 -I -c 'import json,re,sys; a=[x["browser_download_url"] for x in json.load(open(".dl/gh.json"))["assets"] if re.search(sys.argv[1], x["name"])]; print(a[0] if a else "")' "$2"
}
report() { if [ -d "$1" ]; then echo "got $1"; else echo "FAILED $1"; fi; }

electron() {
    get https://releases.electronjs.org/releases.json .dl/electron.json || { echo "FAILED Electron index"; return; }
    python3 -I - .dl/electron.json "${1:-}" "${2:-}" <<'PY' > .dl/electron.txt
import json, sys, re
best = {}
for r in json.load(open(sys.argv[1])):
    v = r.get('version', '')
    if re.fullmatch(r'\d+\.\d+\.\d+', v):
        m, k = int(v.split('.')[0]), tuple(map(int, v.split('.')))
        if m not in best or k > best[m][0]: best[m] = (k, v, r.get('chrome', '?'))
majors = sorted(best); lo = int(sys.argv[2]) if sys.argv[2] else majors[-18]; hi = int(sys.argv[3]) if sys.argv[3] else majors[-1]
for m in majors:
    if lo <= m <= hi: print(best[m][1], best[m][2])
PY
    while read -r v chrome; do
        local app="Electron $v (Chromium ${chrome%%.*}).app"; [ -d "$app" ] && { echo "have $app"; continue; }
        get "https://github.com/electron/electron/releases/download/v$v/electron-v$v-darwin-x64.zip" .dl/e.zip &&
            unzip_app .dl/e.zip Electron "$app"; report "$app"
    done < .dl/electron.txt
}

chrome() {
    get https://googlechromelabs.github.io/chrome-for-testing/latest-versions-per-milestone-with-downloads.json .dl/cft.json ||
        { echo "FAILED Chrome for Testing index"; return; }
    python3 -I - .dl/cft.json "${1:-}" "${2:-}" "${3:-4}" <<'PY' > .dl/cft.txt
import json, sys
ms = json.load(open(sys.argv[1]))['milestones']; nums = sorted(int(m) for m in ms)
lo = int(sys.argv[2]) if sys.argv[2] else nums[-40]; hi = int(sys.argv[3]) if sys.argv[3] else nums[-1]; step = int(sys.argv[4])
for n in nums:
    if lo <= n <= hi and (hi - n) % step == 0:
        m = ms[str(n)]; url = [d['url'] for d in m.get('downloads', {}).get('chrome', []) if d['platform'] == 'mac-x64']
        if url: print(m['version'], url[0])
PY
    while read -r v url; do
        local app="Chrome for Testing $v.app"; [ -d "$app" ] && { echo "have $app"; continue; }
        get "$url" .dl/c.zip && unzip_app .dl/c.zip "Google Chrome for Testing" "$app"; report "$app"
    done < .dl/cft.txt
}

single() {
    local app url
    case $1 in
        vscode) app="Visual Studio Code.app"; get https://update.code.visualstudio.com/latest/darwin/stable .dl/a.zip && unzip_app .dl/a.zip "Visual Studio Code" "$app" ;;
        firefox) app="Firefox.app"; get "https://download.mozilla.org/?product=firefox-latest-ssl&os=osx&lang=en-US" .dl/a.dmg && dmg_app .dl/a.dmg Firefox "$app" ;;
        firefox-esr) app="Firefox ESR.app"; get "https://download.mozilla.org/?product=firefox-esr-latest-ssl&os=osx&lang=en-US" .dl/a.dmg && dmg_app .dl/a.dmg Firefox "$app" ;;
        blender) app="Blender.app"
            # the newest release with an Intel build (Blender 5 is arm64-only on macOS)
            local rel; url=
            for rel in $(curl -fsSL -A "$ua" https://download.blender.org/release/ | grep -o 'Blender[0-9]*\.[0-9]*/' | sort -u | sort -rV); do
                url=$(curl -fsSL -A "$ua" "https://download.blender.org/release/$rel" | grep -o 'blender-[0-9.]*-macos-x64\.dmg' | sort -V | tail -1)
                [ -n "$url" ] && break
            done
            [ -n "$url" ] && get "https://download.blender.org/release/$rel$url" .dl/a.dmg && dmg_app .dl/a.dmg Blender "$app" ;;
        godot) app="Godot.app"; url=$(github_asset godotengine/godot 'stable_macos\.universal\.zip$') && [ -n "$url" ] && get "$url" .dl/a.zip && unzip_app .dl/a.zip Godot "$app" ;;
        obsidian) app="Obsidian.app"; url=$(github_asset obsidianmd/obsidian-releases '\.dmg$') && [ -n "$url" ] && get "$url" .dl/a.dmg && dmg_app .dl/a.dmg Obsidian "$app" ;;
        discord) app="Discord.app"; get "https://discord.com/api/download?platform=osx" .dl/a.dmg && dmg_app .dl/a.dmg Discord "$app" ;;
        slack) app="Slack.app"; get "https://slack.com/ssb/download-osx" .dl/a.dmg && dmg_app .dl/a.dmg Slack "$app" ;;
        signal) app="Signal.app"
            get https://updates.signal.org/desktop/latest-mac.yml .dl/signal.yml &&
                url=$(grep -o 'signal-desktop-mac-x64-[0-9.]*\.zip' .dl/signal.yml | head -1) && [ -n "$url" ] &&
                get "https://updates.signal.org/desktop/$url" .dl/a.zip && unzip_app .dl/a.zip Signal "$app" ;;
        anki) app="Anki.app"; url=$(github_asset ankitects/anki 'mac-intel.*\.dmg$') && [ -n "$url" ] && get "$url" .dl/a.dmg && dmg_app .dl/a.dmg Anki "$app" ;;
        ppsspp) app="PPSSPP.app"
            url=$(curl -fsSL -A "$ua" https://www.ppsspp.org/download | grep -o '/files/[0-9_]*/PPSSPP_macOS\.dmg' | sort -t/ -k3 -V | tail -1)
            [ -n "$url" ] && get "https://www.ppsspp.org$url" .dl/a.dmg && dmg_app .dl/a.dmg PPSSPP "$app" ;;
        retroarch) app="RetroArch.app"
            url=$(curl -fsSL -A "$ua" https://buildbot.libretro.com/stable/ | grep -o '/stable/[0-9.]*/' | sort -t/ -k3 -V | tail -1)
            [ -n "$url" ] && get "https://buildbot.libretro.com${url}apple/osx/universal/RetroArch_Metal.dmg" .dl/a.dmg && dmg_app .dl/a.dmg RetroArch "$app" ;;
        retroarch-extras) app="retroarch-extras"  # for tools/ra-sweep.py: the slang shader pack and the content-less 2048 core
            mkdir -p "$app" && get https://buildbot.libretro.com/assets/frontend/shaders_slang.zip .dl/s.zip && rm -rf "$app/shaders_slang" &&
                unzip -q .dl/s.zip -d "$app/shaders_slang" && rm -f .dl/s.zip &&
                get https://buildbot.libretro.com/nightly/apple/osx/x86_64/latest/2048_libretro.dylib.zip .dl/c.zip && unzip -q -o .dl/c.zip -d "$app" && rm -f .dl/c.zip
            [ -f "$app/2048_libretro.dylib" ] || rm -rf "$app" ;;
        *) echo "unknown: $1" >&2; return ;;
    esac
    report "$app"
}

[ $# -gt 0 ] || set -- all
while [ $# -gt 0 ]; do
    case $1 in
        all) electron; chrome; for a in vscode firefox firefox-esr blender godot obsidian discord slack signal anki ppsspp retroarch; do single $a; done; shift ;;
        electron) a=${2:-}; b=${3:-}; [[ $a =~ ^[0-9]+$ ]] && [[ $b =~ ^[0-9]+$ ]] && shift 2 || { a=; b=; }; electron "$a" "$b"; shift ;;
        chrome) a=${2:-}; b=${3:-}; c=${4:-}; if [[ $a =~ ^[0-9]+$ ]] && [[ $b =~ ^[0-9]+$ ]]; then shift 2; [[ $c =~ ^[0-9]+$ ]] && shift || c=; else a=; b=; c=; fi
            chrome "$a" "$b" "$c"; shift ;;
        *) single "$1"; shift ;;
    esac
done
rm -rf .dl/gh.json .dl/*.json .dl/*.txt .dl/*.yml 2>/dev/null
echo "apps in $dir: $(ls -d "$dir"/*.app 2>/dev/null | wc -l | tr -d ' ')"
