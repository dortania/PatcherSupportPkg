#!/usr/bin/env python3

"""
Goal of this function is to create a Disk image holding only the files that are not committed to git
The purpose is to allow for internal developers to test their changes through the patcher more easily.

Resulting DMG will be placed in the root of the OpenCore-Legacy-Patcher repo for merging.
"""

import os
import subprocess

from pathlib import Path


OCLP_DIRECTORY:  str = "../OpenCore-Legacy-Patcher"
OVERLAY_FOLDER:  str = "DortaniaInternalResources"
OVERLAY_DMG:     str = OVERLAY_FOLDER + ".dmg"
ENCRYPTION_FILE: str = "" # Replace with path to file containing the encryption password


class GenerateInternalDiffDiskImage:

    def __init__(self) -> None:
        print("Generating internal diff disk image")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))

        files = self._find_binaries_to_add()
        if not files:
            print("  - No files to add")
            return
        self._prepare_workspace()
        self._generate_dmg(files)


    def _find_binaries_to_add(self) -> list:
        """
        Grab a list of all files that are not committed to git
        Exclude files that wouldn't be compatible with the patcher (ex. zip files)
        """
        uncommited_files = self._find_uncommited_files()
        uncommited_files = [file for file in uncommited_files if file.startswith("Universal-Binaries")]

        for extension in [".zip", ".dmg", ".pkg"]:
            uncommited_files = [file for file in uncommited_files if not file.endswith(extension)]

        return uncommited_files


    def _find_uncommited_files(self) -> list:
        """
        Grab a list of all files that are not committed to git

        Use git status to find uncommited files
        """
        uncommited_files = subprocess.run(
            ["/usr/bin/git", "status", "--porcelain"], capture_output=True, text=True)
        if uncommited_files.returncode != 0:
            print("  - Failed to find uncommited files")
            print(uncommited_files.stdout)
            print(uncommited_files.stderr)
            return []

        # Strip status flags
        return [file[3:] for file in uncommited_files.stdout.split("\n") if file]


    def _legacy_find_uncommited_files(self) -> list:
        """
        Grab a list of all files that are not committed to git

        Legacy variant using ls-files. This is less reliable than using git status
        """
        uncommited_files = subprocess.run(
            [
                "/usr/bin/git", "ls-files", "--others", "--exclude-standard"
            ], capture_output=True, text=True)
        if uncommited_files.returncode != 0:
            print("  - Failed to find uncommited files")
            print(uncommited_files.stdout)
            print(uncommited_files.stderr)
            return []

        return uncommited_files.stdout.split("\n")


    def _prepare_workspace(self) -> None:
        """
        Remove old files and create a new workspace
        """
        print("  - Preparing workspace")

        if Path(OVERLAY_DMG).exists():
            subprocess.run(["/bin/rm", OVERLAY_DMG])

        if Path(OVERLAY_FOLDER).exists():
            subprocess.run(["/bin/rm", "-rf", OVERLAY_FOLDER])

        subprocess.run(["/bin/mkdir", OVERLAY_FOLDER])


    def _fetch_encryption_password(self) -> str:
        """
        Return the encryption password for the DMG
        """
        password_file = Path(ENCRYPTION_FILE).expanduser()
        if not password_file.exists() or not password_file.is_file():
            return "password"
        return password_file.read_text().strip()


    def _generate_dmg(self, files: list) -> None:
        """
        Copy files to the workspace and generate the DMG
        """
        print("  - Copying files")
        for file in files:
            print(f"    - {file}")
            src_path = Path(file)
            dst_path = Path(OVERLAY_FOLDER) / str(src_path).split("Universal-Binaries/")[1]
            if not Path(dst_path.parent).exists():
                subprocess.run(["/bin/mkdir", "-p", dst_path.parent])
            subprocess.run(["/bin/cp", "-a", src_path, dst_path])

        print("  - Generating tmp DMG")
        subprocess.run([
            "/usr/bin/hdiutil", "create",
            "-srcfolder", OVERLAY_FOLDER, "tmp.dmg",
            "-volname", "Dortania Internal Resources",
            "-fs", "HFS+",
            "-ov",
            "-format", "UDRO"
        ], capture_output=True, text=True)
        print("  - Converting to encrypted DMG")
        subprocess.run(
            ["/usr/bin/hdiutil", "convert",
             "-format", "ULMO", "tmp.dmg",
             "-o", OVERLAY_DMG,
             "-passphrase", self._fetch_encryption_password(),
             "-encryption",
             "-ov"
        ], capture_output=True, text=True)
        subprocess.run(["/bin/rm", "tmp.dmg"])

        if Path(OCLP_DIRECTORY).exists():
            print("  - Moving DMG")
            if Path(OCLP_DIRECTORY, OVERLAY_DMG).exists():
                subprocess.run(["/bin/rm", f"{OCLP_DIRECTORY}/{OVERLAY_DMG}"])
            subprocess.run(["/bin/mv", OVERLAY_DMG, f"{OCLP_DIRECTORY}/{OVERLAY_DMG}"])

        print("  - Cleaning up")
        subprocess.run(["/bin/rm", "-rf", OVERLAY_FOLDER])


if __name__ == "__main__":
    GenerateInternalDiffDiskImage()