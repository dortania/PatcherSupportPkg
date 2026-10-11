# Legacy AMD argument metadata repair

On the tested Radeon Pro 450, the legacy AMD argument parser misses structure information after encountering `air.address_space, i32 2`. The missing argument wrapper causes later argument-buffer analysis to fail. [Validation and limits](VALIDATION.md).

The adapter removes that pair from the observed argument/resource metadata after the vendor constructor parses the module. **AIR (Apple Intermediate Representation)** is the compiler input; its version and shader instructions stay unchanged. We retain the original LLVM context and metadata APIs. Unsupported shapes or a different provider preserve existing behavior.

Release code is [normalize.cpp](normalize.cpp) and [pinned_llvm.hpp](pinned_llvm.hpp). Only the ILPluginHelper C1 constructor is defined as an export; the other provider symbols are reexported. The library contains no logging, counters, environment switches, tracing or test interposition. Full-file SHA-256 and UUID checks restrict private layouts and symbols to the inspected, released AMDShared 12.5 provider.

## One CPU regression

On an Intel Mac with the verified original libAMDIL902 installed, run:

```sh
python3 Sources/AMDMetadata/test.py --stock-bundle /path/to/released-1.9.7/AMDShared.bundle
```

Requires Xcode command-line tools. Builds and signs only workspace copies in `build/amd-metadata-minimal`; no installation, GPU dispatch, driver changes or debugger. The test exercises AMDShared's actual constructor import with RTLD_LOCAL, then the vendor argument parser. The test-only stub/parser addresses never appear in the release adapter and are used only with verified provider/plugin bytes.

- Original AIR 2.7 argument input: the same test fails, with missing parser wrapper and incorrect metadata.
- Repaired AIR 2.7: exactly two pairs removed; all remaining argument metadata equal; parser wrapper constructed.
- Already compatible AIR 2.4: original and repaired paths both pass with unchanged argument metadata.
- The release binary must define exactly one export and contain no diagnostic/test strings or interposition section.

The two fixtures are compiler-generated backend inputs captured from our authored native MSL reproduction on macOS 15.8. They contain a vertex function reading `args.data->value`, where `Params` is `{ float value; }` and `Args` is `{ constant Params *data [[id(0)]]; }`, passed as `constant Args &args [[buffer(0)]]`. `argument-air27.bin` is the unmodified newer metadata case; `argument-air24.bin` is the older compatible metadata control. They contain no application/BIMx assets. Fixture/compiler versions matter; a newer offline compiler is not an equivalent replacement for this regression.

## Build the payload

From the repository root, with the output variant absent:

```sh
python3 Sources/AMDMetadata/build.py --stock-bundle /path/to/released-1.9.7/AMDShared.bundle
```

Use the bundle from the **released 1.9.7 support image**. Its signed provider matches the runtime guard. The source repository's ad-hoc copy has different full-file bytes.

The script runs the regression, copies the stock bundle into `Universal-Binaries/12.5-24H23-metadata`, adds the library and changes AMDShared's import to `@loader_path/MetadataCompat.dylib`. It verifies unchanged vendor files and original executable sections. The output uses development signatures and is never installed by this script.

## Before release

- Agree the source location and variant name with maintainers.
- Sign the adapter and modified bundle through the maintainer release process. Preserve the already signed provider; changing its bytes invalidates the guard.
- Verify the final provider hash, bundle seals and ordinary compiler-service loading after signing. Repeat hardware tests with the exact stripped release binary.
- Publish the support package before merging the dependent OpenCore Legacy Patcher selector and version update.
