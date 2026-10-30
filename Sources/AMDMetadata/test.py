#!/usr/bin/env python3
"""Build the release adapter and run a CPU regression. Never install anything."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

SOURCE = Path(__file__).resolve().parent
OUTPUT = SOURCE.parents[1] / "build/amd-metadata-minimal"
LIBRARY = Path("/System/Library/Extensions/AMDShared.bundle/Contents/PlugIns/libAMDIL902.dylib")
PROVIDER_SHA = "62c83e55dec12b849f98a6df6f012fc0c9def83311ed89685bff76843ea3ee37"
PLUGIN_SHA = "0af3a1666713d9e2986abfae1744756d7f8811bc1d67e4515347ae7c03c5e745"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, expected=0):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=120)
    with (OUTPUT / "commands.txt").open("a") as log:
        log.write(json.dumps([str(a) for a in args]) + "\n" + result.stdout + result.stderr)
    if result.returncode != expected:
        raise RuntimeError(f"Unexpected exit {result.returncode}: {result.stdout}{result.stderr}")
    return result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stock-bundle", required=True, type=Path, help="Unmodified AMDShared 12.5 bundle")
    args = parser.parse_args()
    stock = args.stock_bundle.resolve()
    if digest(LIBRARY) != PROVIDER_SHA or digest(stock / "Contents/PlugIns/libAMDIL902.dylib") != PROVIDER_SHA:
        raise RuntimeError("Unsupported compiler provider")
    if digest(stock / "Contents/MacOS/AMDShared") != PLUGIN_SHA:
        raise RuntimeError("Unsupported stock AMDShared")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "results.json").unlink(missing_ok=True)
    symbols = [line.split()[-1] for line in run(["nm", "-gU", LIBRARY]).splitlines() if len(line.split()) == 3]
    stub = OUTPUT / "AMDIL902.tbd"
    stub.write_text("--- !tapi-tbd\ntbd-version: 4\ntargets: [ x86_64-macos ]\ninstall-name: " + json.dumps(str(LIBRARY)) +
                    "\nexports:\n  - targets: [ x86_64-macos ]\n    symbols: " + json.dumps(symbols) + "\n...\n")
    wrapper = OUTPUT / "MetadataCompat.dylib"
    flags = ["xcrun", "clang++", "-arch", "x86_64", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations"]
    run(flags + ["-O2", "-dynamiclib", "-fvisibility=hidden", SOURCE / "normalize.cpp", "-Wl,-reexport_library," + str(stub),
                 "-install_name", "@loader_path/MetadataCompat.dylib", "-o", wrapper])
    run(["codesign", "--force", "--sign", "-", wrapper])
    run(["codesign", "--verify", "--strict", wrapper])
    exported = [line.split()[-1] for line in run(["nm", "-gU", wrapper]).splitlines() if len(line.split()) == 3]
    if exported != ["__ZN4llvm12amdMtlPlugin14ILPluginHelperC1EPKvm"]:
        raise RuntimeError("Unexpected adapter exports: " + repr(exported))
    binary = wrapper.read_bytes()
    if any(token in binary for token in [b"OCLP_METADATA_", b"oclp_metadata_", b"__interpose"]):
        raise RuntimeError("Diagnostic/test code in release adapter")
    plugin = OUTPUT / "AMDShared"
    shutil.copyfile(stock / "Contents/MacOS/AMDShared", plugin)
    plugin.chmod(0o755)
    run(["install_name_tool", "-change", LIBRARY, "@loader_path/MetadataCompat.dylib", plugin])
    run(["codesign", "--force", "--sign", "-", plugin])
    regression = OUTPUT / "regression"
    run(flags + ["-UNDEBUG", SOURCE / "regression.cpp", stub, "-o", regression])
    results = []
    for name, pairs, mode, expected in [("argument-air27", 2, "original", 3), ("argument-air27", 2, "repaired", 0),
                                        ("argument-air24", 0, "original", 0), ("argument-air24", 0, "repaired", 0)]:
        output = run([regression, plugin, SOURCE / "fixtures" / (name + ".bin"), pairs, mode], expected)
        if expected == 3 and "exact_delta=0 parser_wrapper=0" not in output:
            raise RuntimeError("Negative control did not reproduce the missing-wrapper bug")
        results.append(dict(fixture=name, mode=mode, expectedExit=expected, output=output.strip()))
    if digest(LIBRARY) != PROVIDER_SHA:
        raise RuntimeError("Installed provider changed during test")
    (OUTPUT / "results.json").write_text(json.dumps(dict(status="passed", results=results,
        wrapperSHA256=digest(wrapper), sourceSHA256={p.name: digest(p) for p in SOURCE.glob("*.*")},
        releaseExports=exported, installedProviderUnchanged=True), indent=2) + "\n")
    print("PASS negative control fails, repair restores parser wrapper, compatible AIR unchanged; release has one export and no diagnostics")
    print("Results: " + str(OUTPUT / "results.json"))


if __name__ == "__main__":
    main()
