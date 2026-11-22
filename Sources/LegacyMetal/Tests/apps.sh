#!/usr/bin/env bash
# apps.sh [seconds]: smoke test of the Chromium-based apps installed (Chrome, Edge, Brave, Chromium, and Electron apps such
# as VS Code or OpenVPN Connect) on this build. Each app starts in a throwaway profile with the build's shim injected and
# MTLCompilerService given the build's compiler libraries, as verify.sh's "with the fixes" column does; the browsers open
# apps-page.html, which makes their GPU process build ANGLE's pipelines (WebGL 2 with loops, texture reads, mipmaps, a copy
# and a multisample resolve, 2D canvas blits, CSS blurs and shadows), and the Electron apps draw their own window. After
# [seconds] (default 25) the app is quit. FAIL: MTLCompilerService or one of the app's processes wrote a crash report
# meanwhile, it logged a compiler error (internal error, LLVM ERROR), or a browser's page didn't log "apps.sh: done". INSTALLED=1: the installed stack, nothing injected (after a
# root patch). APPS=<dir>[:<dir>...]: where to look (default Tests/apps, which tools/fetch-apps.sh fills, /Applications
# and ~/Applications). Exit status: FAIL count.
# The apps run in-process (--in-process-gpu) so that the shim, inserted into the app, is in the process that uses Metal.
# Apps that reach Metal without Chromium run too, each with its settings in the throwaway folder: Godot's editor (Vulkan
# through MoltenVK, whose SPIRV-Cross writes the MSL), Blender (its own Metal back end) and Firefox (apps-page.html).
# Firefox is hardened without allow-dyld-environment-variables: it ignores DYLD_INSERT_LIBRARIES, so it runs with the
# installed shim (its compiler service still gets this build's compiler libraries).
# Those also FAIL if they quit before [seconds].
set -u
T=$(cd "$(dirname "$0")" && pwd); P=$(cd "$T/.." && pwd)
# warnings about this Mac (a kext the next boot loses, a staged macOS update), without stopping the run
[ -x "$T/tools/preflight.sh" ] && { "$T/tools/preflight.sh" || echo "(preflight warnings above; continuing)"; }
secs=${1:-25}
inject=()
if [ -z "${INSTALLED:-}" ]; then
    [ -f "$P/build/MetalOldCompat.dylib" ] || { echo "run ../build.sh first (or INSTALLED=1)" >&2; exit 2; }
    # the compiler libraries in a folder of their own, the way fuzz/gpu.sh lays them out (BUILD=1): it does so on each run
    k=$(mktemp -d)/k.metal
    printf 'kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) { out[t] = in[t]; }\n' > "$k"
    BUILD=1 bash "$T/fuzz/gpu.sh" "$k" "" > /dev/null 2>&1
    L=$T/fuzz/build/libs
    [ -d "$L" ] || { echo "fuzz/gpu.sh didn't lay out $L" >&2; exit 2; }
    inject=(DYLD_INSERT_LIBRARIES="$P/build/MetalOldCompat.dylib" __XPC_DYLD_LIBRARY_PATH="$L:$L/GeForceAIRPlugin.bundle/Contents/MacOS")
fi
# APPS_IGPU=1: the shim gives Chromium the integrated GPU on a dual-GPU Mac (MTLSHIM_TEST_IGPU_ONLY), to run once per GPU
[ -n "${APPS_IGPU:-}" ] && inject+=(MTLSHIM_TEST_IGPU_ONLY=1)
pass=0 fail=0 skip=0
# the logs of apps that fail are kept here
logs=${APPS_LOGS:-$T/build/apps-logs}; mkdir -p "$logs"
IFS=: read -r -a dirs <<< "${APPS:-$T/apps:/Applications:$HOME/Applications}"  # Tests/apps: tools/fetch-apps.sh
for dir in "${dirs[@]}"; do
    for app in "$dir"/*.app; do
        [ -d "$app" ] || continue
        id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)
        native=; case "$id" in org.godotengine.godot|org.blenderfoundation.blender|org.mozilla.firefox) native=1 ;; esac
        fw=$(ls -d "$app"/Contents/Frameworks/*" Framework.framework" 2>/dev/null | head -1)
        [ -n "$native$fw" ] || [ -f "$app/Contents/Frameworks/libGLESv2.dylib" ] || continue  # neither Chromium-based nor known
        name=$(basename "$app" .app)
        exe=$(defaults read "$app/Contents/Info.plist" CFBundleExecutable 2>/dev/null)
        [ -n "$exe" ] && [ -x "$app/Contents/MacOS/$exe" ] || { echo "SKIP $name: no executable"; skip=$((skip + 1)); continue; }
        # browsers, and a bare Electron runtime (its default app opens a file or URL given to it), get the page
        browser=; case "$id" in *chrome*|*Chrome*|*edgemac*|*brave*|*chromium*|*Chromium*|*vivaldi*|*opera*|com.github.Electron) browser=1 ;; esac
        before=$fail
        out=$(mktemp -d); prof=$out/profile; marker=$out/started; touch "$marker"; "$T/tools/crashwatch.sh" start "$out/reports"
        # the app's Metal shader cache: a pipeline that failed before comes back as a cached failure, without a compile or a crash
        rm -rf "$(getconf DARWIN_USER_CACHE_DIR)$id/com.apple.metal" "$(getconf DARWIN_USER_CACHE_DIR)$id.helper/com.apple.metal"
        # MTLCompilerService instances keep the compiler libraries they started with: stop this user's
        ps -axo pid,user,command | grep '[M]TLCompilerService' | awk -v me="$(whoami)" '$2 == me {print $1}' | xargs kill -9 2>/dev/null
        # --use-mock-keychain: the app's "Safe Storage" key stays in memory. Otherwise each app reads it from the login keychain,
        # and every differently signed copy (each Electron or Chrome version) brings up a keychain password prompt.
        # LogJsConsoleMessages: Chromium 128-150 stopped printing the page's console messages to stderr without it.
        args=(--user-data-dir="$prof" --no-first-run --no-default-browser-check --use-mock-keychain --in-process-gpu
              --enable-logging=stderr --v=0 --enable-features=LogJsConsoleMessages)
        [ -n "$browser" ] && args+=("file://$T/apps-page.html")
        extra=()
        case "$id" in
            org.godotengine.godot)  # the editor on an empty project; ._sc_ next to the binary: settings in editor_data/ there
                touch "$app/Contents/MacOS/._sc_"; mkdir -p "$out/project"
                printf 'config_version=5\n\n[application]\n\nconfig/name="apps.sh"\n' > "$out/project/project.godot"
                args=(--editor --path "$out/project" --rendering-driver vulkan) ;;
            org.blenderfoundation.blender)
                extra=(BLENDER_USER_CONFIG="$prof/config" BLENDER_USER_SCRIPTS="$prof/scripts" BLENDER_USER_DATAFILES="$prof/data")
                args=(--factory-startup --gpu-backend metal --debug-gpu) ;;  # --debug-gpu: it then says why it refuses a GPU
            org.mozilla.firefox)  # console.log to stdout, so that the page's result reaches the log
                # Firefox 160's GPU-process sandbox allows reading its own bundle only on the volume it was started from
                # as the kernel resolves it: run from another volume than the boot one (a repo on a second macOS
                # install's volume), the GPU process can't load ANGLE and the page gets no WebGL 2, whatever the GPU
                # stack does. That copy runs without the GPU sandbox (copies on the boot volume keep it).
                [ "$(stat -f %d "$app/Contents/MacOS/$exe")" = "$(stat -f %d /System/Volumes/Data)" ] ||
                    [ "$(stat -f %d "$app/Contents/MacOS/$exe")" = "$(stat -f %d /)" ] || { extra=(MOZ_DISABLE_GPU_SANDBOX=1); name="$name (GPU sandbox off: not on the boot volume)"; }
                browser=1; mkdir -p "$prof"
                printf 'user_pref("devtools.console.stdout.content", true);\nuser_pref("browser.shell.checkDefaultBrowser", false);\nuser_pref("app.update.enabled", false);\n' > "$prof/user.js"
                args=(-profile "$prof" -no-remote "file://$T/apps-page.html") ;;
        esac
        env ${inject[@]+"${inject[@]}"} ${extra[@]+"${extra[@]}"} "$app/Contents/MacOS/$exe" "${args[@]}" > "$out/log" 2>&1 & pid=$!
        sleep "$secs"
        alive=1; kill -0 "$pid" 2>/dev/null || alive=
        kill "$pid" 2>/dev/null; pkill -f "$prof" 2>/dev/null; pkill -f "$out/project" 2>/dev/null; sleep 2
        pkill -9 -f "$prof" 2>/dev/null; pkill -9 -f "$out/project" 2>/dev/null; kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        sleep 1; crashlist=$("$T/tools/crashwatch.sh" new "$out/reports" MTLCompilerService "$exe")
        crashes=$(printf '%s' "$crashlist" | grep -c .)
        page=; [ -n "$browser" ] && page=$(grep -o 'apps.sh: [^"]*' "$out/log" | tail -1)
        # compiler failures the log had meanwhile, crash report or not: a client's "Compiler failed with XPC_ERROR" (one per crashed
        # request; ReportCrash throttles repeated crashes), "Compiler encountered an internal error", "LLVM ERROR"
        errors=$("$T/tools/crashwatch.sh" log "$out/reports")
        [ "$id" = org.blenderfoundation.blender ] && grep -q 'does not support metal 2.2' "$out/log" && crashes=0  # see below
        if [ "$crashes" != 0 ]; then
            echo "FAIL $name: $crashes crash report(s): $(head -3 <<< "$crashlist" | tr '\n' ' ')"
            fail=$((fail + 1))
        elif [ "${errors:-0}" != 0 ]; then
            echo "FAIL $name: $errors compiler failure(s) in the log (Compiler failed with XPC_ERROR / internal error / LLVM ERROR)"
            fail=$((fail + 1))
        elif [ "$id" = org.blenderfoundation.blender ] && grep -q 'does not support metal 2.2' "$out/log"; then
            # Blender 4 is Metal-only on macOS and needs a Metal family-2 GPU; on family 1 it says so and then crashes
            echo "SKIP $name: needs a Metal family-2 GPU (Blender 3.6 LTS still has OpenGL)"; skip=$((skip + 1))
        elif [ -n "$native" ] && [ -z "$alive" ] && [ "$page" != "apps.sh: done" ]; then  # a browser may relaunch itself once its page is done
            echo "FAIL $name: quit before ${secs}s: $(grep -v '^\s*$' "$out/log" | tail -2 | tr '\n' ' ' | cut -c1-200)"; fail=$((fail + 1))
        elif [ -n "$browser" ] && [ "$page" != "apps.sh: done" ]; then
            echo "FAIL $name: page: ${page:-no result in ${secs}s (stuck?)}"; fail=$((fail + 1))
        else
            echo "PASS $name: ${page:+page done, }no crash report in ${secs}s"; pass=$((pass + 1))
        fi
        [ "$fail" != "$before" ] && cp "$out/log" "$logs/$name.log" && echo "  (log: $logs/$name.log)"
        rm -rf "$out"
    done
done
echo "== $pass passed, $fail failed, $skip skipped${INSTALLED:+ (installed stack)}"
exit $fail
