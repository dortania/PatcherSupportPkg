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

`verify.sh` runs each test without and with its fix, without installing anything. Every test FAILs on stock OCLP
and PASSes with the fixes unless its header says otherwise. `PAYLOAD=12.5-GCN-25 ./verify.sh`
runs the AMD compiler tests with Tahoe's AMDShared files (they load on Sequoia too). `run.sh` runs them against what is
installed. `verify.sh` works on Tahoe too: `tools/localcc.dylib` opens the compiler from "/" (OCLP's 31001 `libLLVM` wrapper names
`libLLVM_helper` by a relative path), and the shim's compiler-service fixes (items 25 and 75, the read sampler rewrite) also
install where `localcc` runs the compiler. Tests whose fix or compile happens in `MTLCompilerService` get the shim there.

Each test uses the GPU its bug is about and reports SKIP where that GPU is missing. Both scripts take a GPU name
substring to run every test on one GPU: on a Mac without the AMD GPU, use `./verify.sh Intel` and `./run.sh Intel`.
Without OCLP's MetalOld wrapper (GCN-only Macs), MetalOldCompat can't load, so `verify.sh` reports SKIP for its tests
and runs the rest without it.

### Real apps and runtimes

The repro tests and the fuzzer (`Tests/fuzz`) only check what we thought of; apps reach Metal through other shader
translators, old Chromium builds inside Electron apps and prebuilt metallibs. So:

    cd Tests && tools/fetch-apps.sh && ./apps.sh

`tools/fetch-apps.sh` downloads into `Tests/apps/` (gitignored, nothing installed): the last 18 Electron majors (one
Chromium and ANGLE each), older Chrome for Testing milestones, VS Code, Firefox and Firefox ESR, Blender, Godot, Obsidian,
Discord, Slack, Signal and Anki. Single apps or ranges: `tools/fetch-apps.sh electron 28 45`,
`tools/fetch-apps.sh chrome 120 158 4`, `tools/fetch-apps.sh firefox`.

`apps.sh [seconds]` starts each of them (and the Chromium-based apps in `/Applications`) in a throwaway profile with this
build injected; browsers open `apps-page.html`, which builds ANGLE's pipelines (WebGL 2, mipmaps, copies, a multisample
resolve, canvas blits, CSS blurs). An app fails if the compiler service crashes, the log has a compiler failure, or the
page doesn't finish; each app's Metal shader cache is cleared first. `INSTALLED=1 ./apps.sh` checks an installed stack
(and adds Chess, a SceneKit board); `APPS_IGPU=1` gives Chromium the integrated GPU of a dual-GPU Mac.
`tools/safari-page.sh` runs the page in Safari (installed builds only), `tools/wallpaper-check.sh` checks dynamic
wallpapers, and `tools/quicklook-check.sh` checks Quick Look thumbnails.

`verify.sh` has app-like tests too: `s74` builds every pipeline from the prebuilt ANGLE library of each Chromium-based app
found, `s84` renders SceneKit and SpriteKit scenes at every sample count, and `s75` runs one shader set compiled for every
macOS target from 10.14 to 26. `verify.sh` and `fuzz/fuzz.sh` count compiler-service crash reports
(`tools/crashwatch.sh`): a test that passes while the compiler service crashed fails.

### Test matrix

A bug can live in one combination of macOS, GPU and client only: Chromium's ANGLE crashed the compiler service on
Intel under Tahoe, and nowhere else. Which machine covers which combination:

| Mac | macOS | GPUs | Chromium's ANGLE runs on | Boot flags |
| --- | --- | --- | --- | --- |
| MacBookPro11,5 | Tahoe 26.7 | Iris Pro + R9 M370X | R9; the Iris Pro with `MTLSHIM_TEST_IGPU_ONLY=1` | `amfi=0x80` |
| OptiPlex 3010 (iMac13,1) | Sequoia 15.8, Tahoe 26.7 | HD 4000 | HD 4000 | `amfi=0x80` |
| Z77 desktop | Sequoia 15.8 | GTX 770 | GTX 770 | `amfi=0x80` |

Not covered: Kepler under Tahoe, Kepler laptops (GT 750M), and a boot without `amfi=0x80` (OCLP's
Disable Library Validation instead; a tester's MacBookPro11,3 boots that way). Run a change on every machine its code
reaches, and on a dual-GPU Mac run the browser and app tests once per GPU. A test passes only if it fails without its
fix, and only if the compiler service didn't crash during it (a crash counts as a FAIL even when the test's own check
passed: MetalOld retries a crashed request, and the page may still draw).

Before restarting a test Mac, run `Tests/tools/preflight.sh`: a macOS update prepared with automatic downloads on deleted
OCLP's kexts from /Library/Extensions on two test Macs, and the next boot had no acceleration. It names missing kexts the
auxiliary kext collection loads, a staged update, and automatic downloads left on.
