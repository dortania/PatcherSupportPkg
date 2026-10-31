# LegacyMetal

Sources for the legacy Metal fixes in `Universal-Binaries/13.2.1-24` (Metal.framework) and `Universal-Binaries/12.5`
(AMDShared.bundle, AppleIntelHD5000GraphicsMTLDriver.bundle): a compatibility library for MetalOld, adapters for the
12.5 AMD and 3802 Intel shader compilers, and the libAMDIL902 patches.

## Build

    ./build.sh

Rebuilds the libraries and the patched files from the stock payload in git and writes them to `Universal-Binaries/`.

## Test

On a Mac with OCLP's legacy Metal stack:

    cd Tests && ./build.sh && ./verify.sh

`verify.sh` runs each test without and with its fix, without installing anything. `run.sh` runs them against what is
installed.
