# LegacyMetal

Sources for the legacy Metal fixes in `Universal-Binaries/13.2.1-24` and `13.2.1-25` (Metal.framework), `Universal-Binaries/12.5`
(AMDShared.bundle, AppleIntelHD5000GraphicsMTLDriver.bundle) and `Universal-Binaries/12.5-GCN-25` (Tahoe's
AMDShared.bundle): a compatibility library for MetalOld, adapters for the 12.5 AMD and 3802 Intel shader compilers,
the libAMDIL902 patches, and fixes for the 12.5 AMD Metal driver (`AMDBronzeCompat.dylib`, loaded by
`AMDMTLBronzeDriver.bundle` in `12.5`, `12.5-24`, `12.5-25` and `12.5-GCN-SKL-*`).

`build.sh` also writes Tahoe's compiler for this stack into `13.6-25` and `13.2.1-25`: the `14.2 Beta 1` compiler under the
`Versions/31001` paths (`tools/make_tahoe_compiler.py`).

What each fix does, the bug behind it and its test: [FIXES.md](FIXES.md). New fixes get their entry there.

## Build

    ./build.sh

Rebuilds the libraries and the patched files from the stock payload in git and writes them to `Universal-Binaries/`.
With Xcode 26 (macOS SDK 26.2, ld 1230) the output is byte-identical to the committed files. Older Command Line Tools
(for example 16.4, SDK 15.5) also build them, but the binaries differ.

## Test

On a Mac with OCLP's legacy Metal stack:

    cd Tests && ./build.sh && ./verify.sh

`verify.sh` runs each test without and with its fix, without installing anything. `PAYLOAD=12.5-GCN-25 ./verify.sh`
runs the AMD compiler tests with Tahoe's AMDShared files (they load on Sequoia too). `run.sh` runs them against what is
installed. On Tahoe, use `run.sh`: `verify.sh` compiles in the test process through `tools/localcc.dylib`, which crashed there when last tried.

Each test uses the GPU its bug is about and reports SKIP where that GPU is missing. Both scripts take a GPU name
substring to run every test on one GPU: on a Mac without the AMD GPU, use `./verify.sh Intel` and `./run.sh Intel`.
Without OCLP's MetalOld wrapper (GCN-only Macs), MetalOldCompat can't load, so `verify.sh` reports SKIP for its tests
and runs the rest without it.

### Real apps and runtimes

The repro tests and the fuzzer (`Tests/fuzz`) check what we thought of. Apps reach Metal in other ways (different shader
translators, years-old Chromium builds inside Electron apps, prebuilt metallibs), and two compiler-service crashes that a
tester found in minutes by using Chromium-based apps on Tahoe had gone through all of them. So:

    cd Tests && tools/fetch-apps.sh && ./apps.sh

`tools/fetch-apps.sh` downloads into `Tests/apps/` (gitignored; nothing is installed): the latest patch of each of the last
18 Electron majors (one Chromium and ANGLE version each), Chrome for Testing builds of older Chrome milestones, VS Code,
Firefox and Firefox ESR, Blender, Godot, Obsidian, Discord, Slack, Signal and Anki, chosen for how they reach Metal
(Chromium's ANGLE at many versions, Qt WebEngine, Firefox's own ANGLE and wgpu, native Metal renderers). Single apps or
ranges can be named: `tools/fetch-apps.sh electron 28 45`, `tools/fetch-apps.sh chrome 120 158 4`, `tools/fetch-apps.sh firefox`.

`apps.sh [seconds]` starts each Chromium-based app found there (and in `/Applications`, `~/Applications`), and Godot's
editor (MoltenVK), Blender and Firefox, in a throwaway profile with this build injected, as `verify.sh` does; browsers and bare Electron runtimes open `apps-page.html`, which makes
their GPU process build ANGLE's pipelines (WebGL 2 with loops, texture reads, mipmaps, copies, a multisample resolve, 2D canvas
blits, CSS blurs). An app fails if `MTLCompilerService` or one of its processes writes a crash report meanwhile, if the log
has a compiler failure (a client's "Compiler failed with XPC_ERROR", once per crashed request even when ReportCrash, which
throttles repeats, writes no report; "Compiler encountered an internal error"), or if the page doesn't finish. Each app's
Metal shader cache is cleared first, since a failed pipeline otherwise comes back as a cached failure without a crash.
`INSTALLED=1 ./apps.sh` checks the installed stack after a root patch, and `tools/safari-page.sh` runs the same page
in Safari (which only an installed build reaches; `tools/pageserver.py` takes the page's result back);
`tools/wallpaper-check.sh <image or saved store> [seconds]` sets a wallpaper (a dynamic HEIC such as Sonoma, or a store
captured after choosing one in System Settings), fails if it changes back by itself, crashes a wallpaper process or the
compiler service, and puts the user's wallpaper back; `APPS_IGPU=1` gives Chromium the integrated GPU on a
dual-GPU Mac (`MTLSHIM_TEST_IGPU_ONLY`), to run it once per GPU.

`verify.sh` runs two related tests: `s74` loads the prebuilt ANGLE library of every Chromium-based app found and builds every
pipeline ANGLE builds from it, and `s75` builds and runs one shader set compiled for each macOS target from 10.14 (AIR 2.1,
what Chromium's library is built for) to 26, as an app with a prebuilt metallib would bring it. `verify.sh` and `fuzz/fuzz.sh`
also count the crash reports `MTLCompilerService` writes during a run (`tools/crashwatch.sh`): with the fixes, a test that
passes while the compiler service crashed fails. Run `apps.sh` and `verify.sh` on every machine in the matrix below.

### Test matrix

A bug can live in one combination of macOS, GPU and client only: Chromium's ANGLE crashed the compiler service on
Intel under Tahoe, and nowhere else. Which machine covers which combination:

| Mac | macOS | GPUs | Chromium's ANGLE runs on | Boot flags |
| --- | --- | --- | --- | --- |
| MacBookPro11,5 | Tahoe 26.7 | Iris Pro + R9 M370X | R9; the Iris Pro with `MTLSHIM_TEST_IGPU_ONLY=1` | `amfi=0x80` |
| OptiPlex 3010 (iMac13,1) | Sequoia 15.8 | HD 4000 | HD 4000 | `amfi=0x80` |
| Z77 desktop | Sequoia 15.8 | GTX 770 | GTX 770 | `amfi=0x80` |

Not covered: Ivy Bridge and Kepler under Tahoe, Kepler laptops (GT 750M), and a boot without `amfi=0x80` (OCLP's
Disable Library Validation instead; a tester's MacBookPro11,3 boots that way). Run a change on every machine its code
reaches, and on a dual-GPU Mac run the browser and app tests once per GPU. A test passes only if it fails without its
fix, and only if the compiler service didn't crash during it (a crash counts as a FAIL even when the test's own check
passed: MetalOld retries a crashed request, and the page may still draw).

Before restarting a test Mac, run `Tests/tools/preflight.sh`. Preparing the macOS 26 update with automatic downloads on
deleted OCLP's kexts from /Library/Extensions on two Sequoia test Macs (the HD 4000 and Kepler ones); each kept running
from the loaded kext collection, and the next boot came up without acceleration. The script names any kext the
auxiliary kext collection loads whose bundle is gone, a staged update, and automatic downloads left on.
