"""
Postprocess binaries on CI
"""

# TODO: We need a proper way to identify and sign bundles. Unfortunately Apple does not make this easy.

import subprocess
import sys
from pathlib import Path

# Configurable options

IDENTITY = "OpenCore Legacy Patcher Software Signing"
TARGET_DIR = Path("Universal-Binaries")
UNUSED = [
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

# Constants

MACHO_MAGIC = {
    "MH_MAGIC": b"\xfe\xed\xfa\xce",
    "MH_CIGAM": b"\xce\xfa\xed\xfe",
    "MH_MAGIC_64": b"\xfe\xed\xfa\xcf",
    "MH_CIGAM_64": b"\xcf\xfa\xed\xfe",
    "FAT_MAGIC": b"\xbe\xba\xfe\xca",
    "FAT_CIGAM": b"\xca\xfe\xba\xbe",
}


def clean_unused():
    """
    Remove unused files and folders
    """

    for path in UNUSED:
        path = TARGET_DIR / path
        if path.exists():
            print(f"Removing: {path}")
            subprocess.check_output(["rm", "-rf", path])

    for path in TARGET_DIR.rglob(".DS_Store"):
        print(f"Removing: {path}")
        path.unlink()


def get_machos(directory=TARGET_DIR):
    """
    Get all machos in a directory
    """

    machos: dict[Path, bytes] = {}
    for file in directory.rglob("*"):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open("rb") as f:
            magic = f.read(4)
            if magic in MACHO_MAGIC.values():
                machos[file] = magic
    return dict(sorted(machos.items(), key=lambda item: item[0]))


def thin_macho(file: Path, magic: bytes):
    """
    Run lipo to thin a fat macho
    """

    if magic in (MACHO_MAGIC["FAT_MAGIC"], MACHO_MAGIC["FAT_CIGAM"]):
        subprocess.check_output(["lipo", "-thin", "x86_64", "-output", file, file])


def signing_sanity_checks(file: Path) -> tuple[bool, bool]:  # (valid, needs_signing)
    """
    Run codesign -dvvv and codesign --verify to check if a binary is signed correctly
    """

    with file.open("rb") as f:
        magic = f.read(4)
        if magic not in (MACHO_MAGIC["MH_CIGAM_64"], MACHO_MAGIC["FAT_CIGAM"]):
            print(f"ERROR: {file} is not a 64-bit Mach-O")
            print()
            return False, False

    result = subprocess.run(["codesign", "-dvvv", file], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    # stdout has the entitlements, stderr has the details
    if result.returncode != 0:
        if "not signed at all" not in result.stderr.decode():
            raise RuntimeError(f"codesign failed ({result.returncode}): {result.stderr.decode()}")

    entitlements = result.stdout.decode()
    binary_details = result.stderr.decode()

    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--verbose=4", "--deep", "--ignore-resources", file], capture_output=True, check=False
    )
    if result.returncode != 0:
        error_reason = result.stderr.decode().replace(f"{file}: ", "").splitlines()[0].strip()
        if result.returncode == 3:
            # We don't care about requirements
            pass
        elif "Signature=adhoc" in binary_details:
            # We will just resign it anyway
            pass
        # elif error_reason == "resource envelope is obsolete (custom omit rules)":
        #     # Known weird issue with Apple binaries
        #     pass
        elif error_reason == "invalid Info.plist (plist or signature have been modified)":
            # Usually from ramdisk binaries or bad copies, but they still work
            pass
        # elif error_reason == "unsealed contents present in the bundle root" and "Signature=adhoc" in binary_details:
        #     # Bundle was not properly deep signed, ignore
        #     pass
        # elif "is not signed at all" in error_reason:
        #     # This is fine, we will sign it
        #     return True, True
        else:
            # invalid signature (code or signature have been modified)
            print(f"ERROR: {file}: {error_reason}")
            print("If this file is patched or a new binary, please adhoc sign it.")
            print()
            return False, False

    if ": no signature" in binary_details:
        assert "{file}: no signature" in binary_details
        print(f"ERROR: {file} is not signed")
        print("It seems that this binary may have been signed by ldid. Please resign it with codesign, or pass -Cadhoc to ldid.")
        print()
        return False, False

    if "Authority=Dortania Root CA" in binary_details:
        # We have pushed a signed binary already to the repo.
        # This means that CI signing cannot handle this binary. Do not resign, use as is.
        return True, False

    if "Authority=Apple Root CA" in binary_details:
        # File is signed by Apple, and we have already checked that it is valid
        return True, False

    # Anything past here should be adhoc signed
    if "Signature=adhoc" not in binary_details:
        raise RuntimeError(f"Unknown signing authority: {binary_details}")

    if entitlements.strip():
        print(f"Warning: {file} has entitlements. We will preserve entitlements, but this is unusual.")

    return True, True


def sign_macho(file: Path):
    """
    Sign a macho
    """

    print(f"Signing: {file}")
    subprocess.check_output(["codesign", "-f", "-s", IDENTITY, "--preserve-metadata=entitlements", "--generate-entitlement-der", file])


if __name__ == "__main__":
    clean_unused()

    machos = get_machos()
    if not machos:
        print("No machos found!")
        sys.exit(1)
    machos_to_sign = []
    all_valid = True
    for macho, _ in machos.items():
        valid, needs_signing = signing_sanity_checks(macho)
        all_valid &= valid
        if needs_signing:
            machos_to_sign.append(macho)
    if not all_valid:
        sys.exit(1)

    for macho, magic in machos.items():
        thin_macho(macho, magic)

    for macho in machos_to_sign:
        sign_macho(macho)

    print("Done!")
