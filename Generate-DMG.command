#!/usr/bin/env python3
"""
Build and sign PatcherSupportPkg Disk Image.
Note password encryption required to pass Apple's notarization.
"""

import os
import math
import argparse
import subprocess

UB_DIRECTORY:     str = "Universal-Binaries"
DMG_NAME:         str = "Universal-Binaries.dmg"
DMG_VOLNAME:      str = "BridgePatcher Resources (Root Patching)"
DMG_FORMAT:       str = "UDRO"
DMG_PASSPHRASE:   str = "password"
SIGNING_IDENTITY: str = "OpenCore Legacy Patcher Software Signing"

# Headroom added on top of the measured payload size so HFS+ metadata
# (catalog/extents B-trees, journal, etc.) always fits
DMG_HEADROOM_PERCENT: int = 10
DMG_HEADROOM_MB:      int = 256
HFS_BLOCK_SIZE:       int = 4096


class GenerateDiskImage:

    def __init__(self, sign_dmg: bool = False) -> None:
        print("Generating DMG")
        self._set_working_directory()
        self._strip_extended_attributes()
        self._remove_ds_store()
        self._create_dmg()
        self._convert_dmg()
        if sign_dmg:
            self._sign_dmg()
        self._remove_tmp_dmg()


    def _set_working_directory(self) -> None:
        print("  - Setting working directory")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))


    def _reset_hdiutil(self) -> None:
        """
        Attempt to reset hdiutil
        On some instances, "hdiutil: create failed - Resource busy" is thrown
        """
        print("  - Resetting hdiutil")
        subprocess.run(["/usr/bin/killall", "hdiutil"], capture_output=True)


    def _strip_extended_attributes(self) -> None:
        print("  - Stripping extended attributes")
        subprocess.run(["/usr/bin/xattr", "-rc", UB_DIRECTORY], capture_output=True)


    def _remove_ds_store(self) -> None:
        print("  - Removing .DS_Store files")
        subprocess.run(["/usr/bin/find", UB_DIRECTORY, "-name", ".DS_Store", "-delete"], capture_output=True)


    def _calculate_dmg_size(self) -> str:
        """
        Calculate the DMG size (in megabytes) from the contents of UB_DIRECTORY,
        instead of hardcoding it, so the image grows with the payloads.

        Each file is rounded up to the HFS+ allocation block size, then a
        percentage-based and fixed headroom is added for filesystem metadata.
        """
        total_bytes = 0
        for root, dirs, files in os.walk(UB_DIRECTORY):
            for name in dirs + files:
                st = os.lstat(os.path.join(root, name))
                # Every entry costs at least one block of catalog/metadata space
                total_bytes += max(math.ceil(st.st_size / HFS_BLOCK_SIZE), 1) * HFS_BLOCK_SIZE

        size_mb = math.ceil(total_bytes / (1024 * 1024))
        size_mb += math.ceil(size_mb * DMG_HEADROOM_PERCENT / 100) + DMG_HEADROOM_MB
        print(f"    - Payload size: {total_bytes / (1024 * 1024):.0f} MB, DMG size: {size_mb} MB")
        return str(size_mb)


    def _create_dmg(self, raise_on_error: bool = False) -> None:
        """
        raise_on_error: If false, attempts to reset hdiutil and try again
        """
        print("  - Creating DMG")
        dmg_size = self._calculate_dmg_size()
        result = subprocess.run([
            "/usr/bin/hdiutil", "create",
            "-srcfolder", UB_DIRECTORY, "tmp.dmg",
            "-volname", DMG_VOLNAME,
            "-fs", "HFS+", "-ov",
            "-format", DMG_FORMAT,
            "-megabytes", dmg_size
        ], capture_output=True)
        if result.returncode != 0:
            print("    - Failed to create DMG")
            print(f"STDOUT:\n{result.stdout.decode('utf-8')}")
            print(f"STDERR:\n{result.stderr.decode('utf-8')}")
            if raise_on_error:
                raise Exception("Failed to create DMG")
            if "Resource busy" in result.stderr.decode("utf-8"):
                self._reset_hdiutil()
                self._create_dmg(raise_on_error=True)
            else:
                raise Exception("Failed to create DMG")


    def _convert_dmg(self, raise_on_error: bool = False) -> None:
        """
        raise_on_error: If false, attempts to reset hdiutil and try again
        """
        print("  - Converting DMG")
        result = subprocess.run([
            "/usr/bin/hdiutil", "convert",
            "-format", "ULMO", "tmp.dmg",
            "-o", DMG_NAME,
            "-passphrase", DMG_PASSPHRASE,
            "-encryption", "-ov"
        ], capture_output=True)
        if result.returncode != 0:
            print("    - Failed to convert DMG")
            print(f"STDOUT:\n{result.stdout.decode('utf-8')}")
            print(f"STDERR:\n{result.stderr.decode('utf-8')}")
            if raise_on_error:
                raise Exception(f"Failed to convert DMG")
            if "Resource busy" in result.stderr.decode("utf-8"):
                self._reset_hdiutil()
                self._convert_dmg(raise_on_error=True)
            else:
                raise Exception("Failed to convert DMG")


    def _sign_dmg(self) -> None:
        print("  - Signing DMG")
        result = subprocess.run([
            "/usr/bin/codesign", "-s", SIGNING_IDENTITY, DMG_NAME
        ], capture_output=True)
        if result.returncode != 0:
            print("    - Failed to sign DMG")
            print(f"STDOUT:\n{result.stdout.decode('utf-8')}")
            print(f"STDERR:\n{result.stderr.decode('utf-8')}")
            raise Exception("Failed to sign DMG")


    def _remove_tmp_dmg(self) -> None:
        subprocess.run(["/bin/rm", "tmp.dmg"], capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate PatcherSupportPkg Disk Image")
    parser.add_argument("--sign", action="store_true", help="Sign the generated DMG")
    args = parser.parse_args()

    GenerateDiskImage(sign_dmg=args.sign)
