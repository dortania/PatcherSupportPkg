#!/usr/bin/env python3
"""Build and CPU-test the new payload in this checkout. Never install it."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

from test import OUTPUT, SOURCE, run


def files(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()}


def sections(path):
    data = path.read_bytes()
    assert struct.unpack_from("<I", data)[0] == 0xFEEDFACF
    result, offset = {}, 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        kind, size = struct.unpack_from("<II", data, offset)
        if kind == 0x19:
            for index in range(struct.unpack_from("<I", data, offset + 64)[0]):
                pos = offset + 72 + 80 * index
                name, segment, _, length, start = struct.unpack_from("<16s16sQQI", data, pos)
                flags = struct.unpack_from("<I", data, pos + 64)[0]
                result[(segment, name)] = (length, flags, None if flags & 0xFF in (1, 12, 18)
                                           else hashlib.sha256(data[start:start + length]).hexdigest())
        offset += size
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stock-bundle", type=Path, required=True, help="AMDShared from released support package 1.9.7")
    stock = parser.parse_args().stock_bundle.resolve()
    subprocess.run([sys.executable, str(SOURCE / "test.py"), "--stock-bundle", str(stock)], check=True)
    target = SOURCE.parents[1] / "Universal-Binaries/12.5-24H23-metadata/System/Library/Extensions/AMDShared.bundle"
    if target.exists():
        raise RuntimeError("Output bundle already exists; preserve it before building another candidate")
    shutil.copytree(stock, target)
    shutil.copy2(OUTPUT / "MetadataCompat.dylib", target / "Contents/MacOS/MetadataCompat.dylib")
    plugin = target / "Contents/MacOS/AMDShared"
    run(["install_name_tool", "-change", "/System/Library/Extensions/AMDShared.bundle/Contents/PlugIns/libAMDIL902.dylib",
         "@loader_path/MetadataCompat.dylib", plugin])
    # Preserve signed vendor providers. No --deep signing.
    run(["codesign", "--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags", target])
    run(["codesign", "--verify", "--strict", "--ignore-resources", target])
    run(["codesign", "--verify", "--strict", target / "Contents/MacOS/MetadataCompat.dylib"])
    before, after = files(stock), files(target)
    changed = sorted(p for p in before if before[p] != after.get(p))
    added = sorted(set(after) - set(before))
    if changed != ["Contents/MacOS/AMDShared", "Contents/_CodeSignature/CodeResources"] or added != ["Contents/MacOS/MetadataCompat.dylib"]:
        raise RuntimeError("Unexpected payload changes")
    if sections(stock / "Contents/MacOS/AMDShared") != sections(plugin):
        raise RuntimeError("Original executable code/data changed")
    (OUTPUT / "payload.json").write_text(json.dumps(dict(changed=changed, added=added, files=after,
        originalSectionsUnchanged=True, vendorFilesUnchanged=True,
        signatureCheck="adapter/main signature and exact resource hashes; stock nested trust unchanged"), indent=2) + "\n")
    print("PASS payload contains only dependency, adapter and signing changes; vendor files and all code/data sections unchanged")


if __name__ == "__main__":
    main()
