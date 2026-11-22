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
