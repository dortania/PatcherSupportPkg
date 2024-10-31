#!/usr/bin/env python3

# Merge Moraea's generated binaries with PatcherSupportPkg format
# Usage: python merge.py --version <OS version> --input <input folder>

import os
import argparse
import subprocess

from pathlib import Path


class MoraeaBinaryMerging:

    def __init__(self, input_folder: str, version: str = None):
        """
        Merge Moraea's generated binaries with PatcherSupportPkg format

        Parameters:
            input_folder (str): Input folder, containing the binaries to merge
            version (str): OS version, defaults to folder name if not specified
        """

        self.input_folder: Path = Path(input_folder)
        if not self.input_folder.exists():
            print("Input folder does not exist")
            exit(1)

        if version is None:
            version = self.input_folder.name[:2]
            print(f"  - No OS version specified, using folder name: {version}")

        self.version = self._convert_os_to_kernel(version)
        self.file_map = self._generate_file_map(self.version)

        self._update_binaries()


    def _convert_os_to_kernel(self, version):
        try:
            version = int(version)
        except ValueError:
            print("Invalid OS version")
            exit(1)

        if version >= 11:
            version =  version + 9
            print(f"  - Adjusted Kernel version to {version}")
            return str(version)
        raise ValueError("Invalid OS version, only 11+ supported")


    def _generate_file_map(self, version: str):
        FILE_MAP = {
            "Cass2": {
                "IOAccelerator":          f"Universal-Binaries/10.13.6-{version}/System/Library/PrivateFrameworks/IOAccelerator.framework/Versions/A/IOAccelerator",
                "IOAcceleratorOld.dylib": f"Universal-Binaries/10.13.6-{version}/System/Library/PrivateFrameworks/IOAccelerator.framework/Versions/A/IOAcceleratorOld.dylib",
                "IOSurface":              f"Universal-Binaries/10.14.6-{version}/System/Library/Frameworks/IOSurface.framework/Versions/A/IOSurface",
                "IOSurfaceOld.dylib":     f"Universal-Binaries/10.14.6-{version}/System/Library/Frameworks/IOSurface.framework/Versions/A/IOSurfaceOld.dylib",
            },
            "Common": {
                "CoreDisplay":          f"Universal-Binaries/10.14.4-{version}/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay",
                "CoreDisplayOld.dylib": f"Universal-Binaries/10.14.4-{version}/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplayOld.dylib",
                "QuartzCore":           f"Universal-Binaries/10.15.7-{version}/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore",
                "QuartzCoreOld.dylib":  f"Universal-Binaries/10.15.7-{version}/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCoreOld.dylib",
                "SkyLight":             f"Universal-Binaries/10.14.6-{version}/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
                "SkyLightOld.dylib":    f"Universal-Binaries/10.14.6-{version}/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLightOld.dylib",
                **({ "FakeLibSystem.dylib": f"Universal-Binaries/10.14.6-{version}/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/FakeLibSystem.dylib"} if int(version) >= 23 else {}),
                **({ "LibSystemWrapper.dylib": f"Universal-Binaries/10.14.6-{version}/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/LibSystemWrapper.dylib"} if int(version) >= 23 else {}),
            },
            "Zoe": {
                "IOSurface":          f"Universal-Binaries/10.15.7-{version}/System/Library/Frameworks/IOSurface.framework/Versions/A/IOSurface",
                "IOSurfaceOld.dylib": f"Universal-Binaries/10.15.7-{version}/System/Library/Frameworks/IOSurface.framework/Versions/A/IOSurfaceOld.dylib",
            },
        }

        return FILE_MAP

    def _update_binaries(self):
        print(f"- Processing files against version: {self.version}")
        for folder in self.file_map:
            for binary in self.file_map[folder]:
                print(f"  - Processing binary: {binary} ({folder})")

                # Check if exists at source location
                if not Path(self.input_folder / f"{folder}/{binary}").exists():
                    print("    - Binary not found at source location, skipping")
                    continue

                # Check if exists at destination location
                if Path(self.file_map[folder][binary]).exists():
                    print("    - Binary found at destination location, removing")
                    subprocess.run(["/bin/rm", self.file_map[folder][binary]])

                # Copy binary to destination location
                print("    - Copying binary to destination location")
                if not Path(self.file_map[folder][binary]).parent.exists():
                    print("    - Creating parent folder")
                    subprocess.run(["/bin/mkdir", "-p", Path(self.file_map[folder][binary]).parent])
                subprocess.run(["/bin/mv", self.input_folder / f"{folder}/{binary}", self.file_map[folder][binary]])

        unused_files = []
        for folder in self.file_map:
            for file in Path(self.input_folder / folder).iterdir():
                if file.name == ".DS_Store":
                    continue
                if file.suffix == ".m":
                    continue
                unused_files.append(file)

        if len(unused_files) > 0:
            print("- Unused files found:")
            for file in unused_files:
                print(f"  - {file}")
            raise ValueError("Unused files found, check the output above")


if __name__ == "__main__":
    print("- Starting Moraea Merging Script")

    parser = argparse.ArgumentParser()
    # 2 arguments each with a value
    parser.add_argument("--version", type=str, help="OS version")
    parser.add_argument("--input", type=str, help="Input folder")
    args = parser.parse_args()

    if not args.input:
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        print("No arguments provided, merging binaries from ./Files-To-Merge")
        for folder in Path("./Files-To-Merge").iterdir():
            if folder.is_dir():
                print("#" * 80)
                print(f"# Merging binaries from {folder}")
                print("#" * 80)
                MoraeaBinaryMerging(input_folder=folder)
                print("- Removing input folder")
                subprocess.run(["/bin/rm", "-rf", folder])
    else:
        MoraeaBinaryMerging(input_folder=args.input, version=args.version)

    print("- Done")