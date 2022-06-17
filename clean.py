from pathlib import Path
import subprocess

folders_to_delete = [
    # Mojave and Catalina non-Metal Patches
    # No longer used by us, but nice for reference
    "10.13.6-18",
    "10.13.6-19",
    "10.14.4-18",
    "10.14.4-19",
    "10.14.6-19",

    # Nvidia Web Driver Patches
    # Remove .pkg, unused by patcher
    "WebDriver-387.10.10.10.40.140/WebDriver-387.10.10.10.40.140.pkg",
    "WebDriver-387.10.10.10.40.140/WebDriver-387.10.10.15.15.108.pkg",
]

def delete_folders():

    root_path = "./Universal-Binaries"
    for folder in folders_to_delete:
        path = root_path + "/" + folder
        if Path(path).exists():
            print("  - Removing: " + path)
            subprocess.run(["rm", "-rf", path])


if __name__ == "__main__":
    print("- Starting clean up")
    delete_folders()
