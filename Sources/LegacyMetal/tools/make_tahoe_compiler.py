#!/usr/bin/env python3
"""make_tahoe_compiler.py <repo root> <git ref>: writes Tahoe's legacy Metal compiler into the 13.6-25 and 13.2.1-25 payloads.

It's the 14.2 Beta 1 compiler the Sequoia patches use (MSL 3.1), in place of the 13-era one (MSL 3.0). Its paths go from Versions/32023
to Versions/31001: Tahoe's native compiler lives at 32023, and MetalOld and MTLCompilerService load 31001. The libLLVM wrapper and
libLLVM_helper stay on top of it, renamed libLLVM_real as before, so Tahoe's AIR 2.8 shader libraries still get converted.
"""

import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

PF = "System/Library/PrivateFrameworks"
OLD = f"/{PF}/GPUCompiler.framework/Versions/32023/Libraries".encode()
NEW = f"/{PF}/GPUCompiler.framework/Versions/31001/Libraries".encode()
LIBRARIES = "libComposeFilters libGPUCompiler libGPUCompilerImpl libGPUCompilerImplLazy libGPUCompilerUtils libllvm-flatbuffers libllvm-lmdb"


def git_show(root, ref, path):
    return subprocess.run(["git", "-C", root, "show", f"{ref}:Universal-Binaries/{path}"], check=True, capture_output=True).stdout


def write_binary(path, data):
    with open(path, "wb") as f:
        f.write(data)
    os.chmod(path, 0o755)


def main():
    root, ref = sys.argv[1:3]
    src = f"14.2 Beta 1/{PF}"
    mtl = f"{root}/Universal-Binaries/13.6-25/{PF}/MTLCompiler.framework/Versions/31001"
    gpu = f"{root}/Universal-Binaries/13.2.1-25/{PF}/GPUCompiler.framework/Versions/31001/Libraries"
    wrapper = f"13.2.1-25/{PF}/GPUCompiler.framework/Versions/31001/Libraries"

    shutil.rmtree(f"{mtl}/Libraries", ignore_errors=True)
    shutil.rmtree(gpu)
    os.makedirs(gpu)

    write_binary(f"{mtl}/MTLCompiler", git_show(root, ref, f"{src}/MTLCompiler.framework/Versions/32023/MTLCompiler").replace(OLD, NEW))
    for name in LIBRARIES.split():
        data = git_show(root, ref, f"{src}/GPUCompiler.framework/Versions/32023/Libraries/{name}.dylib")
        write_binary(f"{gpu}/{name}.dylib", data.replace(OLD, NEW))
    write_binary(f"{gpu}/libLLVM_real.dylib", git_show(root, ref, f"{src}/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib").replace(OLD, NEW))
    subprocess.run(["install_name_tool", "-id", NEW.decode() + "/libLLVM_real.dylib", f"{gpu}/libLLVM_real.dylib"], check=True, stderr=subprocess.DEVNULL)
    for name in ("libLLVM", "libLLVM_helper"):
        write_binary(f"{gpu}/{name}.dylib", git_show(root, ref, f"{wrapper}/{name}.dylib"))

    prefix = f"Universal-Binaries/{src}/GPUCompiler.framework/Versions/32023/Libraries/lib"
    archive = subprocess.run(["git", "-C", root, "archive", ref, prefix], check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            if member.isfile() or member.issym():
                member.name = os.path.relpath(member.name, prefix)
                tar.extract(member, f"{gpu}/lib")

    for path in [f"{mtl}/MTLCompiler"] + [f"{gpu}/{f}" for f in os.listdir(gpu) if f.endswith(".dylib")]:
        # Outside the framework layout: inside it, codesign signs MTLCompiler as a bundle and adds _CodeSignature.
        with tempfile.TemporaryDirectory() as temp:
            signed = f"{temp}/{os.path.basename(path)}"
            shutil.copyfile(path, signed)
            subprocess.run(["codesign", "-f", "-s", "-", signed], check=True, stderr=subprocess.DEVNULL)
            shutil.copyfile(signed, path)


if __name__ == "__main__":
    main()
