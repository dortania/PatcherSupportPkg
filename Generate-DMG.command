"""
Build and sign PatcherSupportPkg Disk Image.
Note password encryption required to pass Apple's notarization.
"""

import os
import subprocess

UB_DIRECTORY:     str = "Universal-Binaries"
DMG_NAME:         str = "Universal-Binaries.dmg"
DMG_VOLNAME:      str = "OpenCore Patcher Resources (Root Patching)"
DMG_SIZE:         str = "4096"
DMG_FORMAT:       str = "UDRO"
DMG_PASSPHRASE:   str = "password"
SIGNING_IDENTITY: str = "OpenCore Legacy Patcher Software Signing"


class GenerateDiskImage:

    def __init__(self) -> None:
        print("Generating DMG")
        self._set_working_directory()
        self._strip_extended_attributes()
        self._remove_ds_store()
        self._create_dmg()
        self._convert_dmg()
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
        subprocess.run(["killall", "hdiutil"], capture_output=True)


    def _strip_extended_attributes(self) -> None:
        print("  - Stripping extended attributes")
        subprocess.run(["/usr/bin/xattr", "-rc", UB_DIRECTORY], capture_output=True)


    def _remove_ds_store(self) -> None:
        print("  - Removing .DS_Store files")
        subprocess.run(["find", UB_DIRECTORY, "-name", ".DS_Store", "-delete"], capture_output=True)


    def _create_dmg(self, raise_on_error: bool = False) -> None:
        """
        raise_on_error: If false, attempts to reset hdiutil and try again
        """
        print("  - Creating DMG")
        result = subprocess.run([
            "hdiutil", "create",
            "-srcfolder", UB_DIRECTORY, "tmp.dmg",
            "-volname", DMG_VOLNAME,
            "-fs", "HFS+", "-ov",
            "-format", DMG_FORMAT,
            "-megabytes", DMG_SIZE
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
            "hdiutil", "convert",
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
            "codesign", "-s", SIGNING_IDENTITY, DMG_NAME
        ], capture_output=True)
        if result.returncode != 0:
            print("    - Failed to sign DMG")
            print(f"STDOUT:\n{result.stdout.decode('utf-8')}")
            print(f"STDERR:\n{result.stderr.decode('utf-8')}")
            raise Exception("Failed to sign DMG")


    def _remove_tmp_dmg(self) -> None:
        subprocess.run(["rm", "tmp.dmg"], capture_output=True)


if __name__ == "__main__":
    GenerateDiskImage()