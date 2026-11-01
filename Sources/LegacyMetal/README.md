# LegacyMetal

Sources for the legacy Metal fixes in `Universal-Binaries/13.2.1-24` and `13.2.1-25` (Metal.framework), `Universal-Binaries/12.5`
(AMDShared.bundle, AppleIntelHD5000GraphicsMTLDriver.bundle) and `Universal-Binaries/12.5-GCN-25` (Tahoe's
AMDShared.bundle): a compatibility library for MetalOld, adapters for the 12.5 AMD and 3802 Intel shader compilers,
the libAMDIL902 patches, and fixes for the 12.5 AMD Metal driver (`AMDBronzeCompat.dylib`, loaded by
`AMDMTLBronzeDriver.bundle` in `12.5`, `12.5-24`, `12.5-25` and `12.5-GCN-SKL-*`).

`build.sh` also writes Tahoe's compiler for this stack into `13.6-25` and `13.2.1-25`: the `14.2 Beta 1` compiler under the
`Versions/31001` paths (`tools/make_tahoe_compiler.py`).

## Build

    ./build.sh

Rebuilds the libraries and the patched files from the stock payload in git and writes them to `Universal-Binaries/`.

## Test

On a Mac with OCLP's legacy Metal stack:

    cd Tests && ./build.sh && ./verify.sh

`verify.sh` runs each test without and with its fix, without installing anything. `PAYLOAD=12.5-GCN-25 ./verify.sh`
runs the AMD compiler tests with Tahoe's AMDShared files (they load on Sequoia too). `run.sh` runs them against what is
installed. On Tahoe, use `run.sh`: `verify.sh` compiles in the test process through `tools/localcc.dylib`, which crashed there when last tried.
