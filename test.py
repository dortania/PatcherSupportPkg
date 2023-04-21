import datetime
import enum
import shutil
import subprocess
import time
from functools import wraps
from pathlib import Path
from typing import Optional

VERBOSE = False
if VERBOSE:
    verbose_flags = {"ditto": "-V", "tar": "-v", "zip": None, "hdiutil": None}
else:
    verbose_flags = {"ditto": None, "tar": None, "zip": "-q", "hdiutil": "-quiet"}

TARGET_DIR = Path("Universal-Binaries")
# TARGET_DIR = Path("Universal-Binaries/WebDriver-387.10.10.10.40.140")
if not TARGET_DIR.exists():
    raise ValueError(f"Target directory {TARGET_DIR} does not exist")
RESULT_DIR = Path("results")
LOGFILE = Path("results.log")
FD = LOGFILE.open("w", encoding="utf-8", newline="\n")

RESULTS = ""


class CLIFlag(enum.Enum):
    def __str__(self) -> str:
        return self.value


class ZipCompressionMethod(CLIFlag):
    DEFLATE = "deflate"
    BZIP2 = "bzip2"  # Not available on macOS


class DittoCompressionMethod(CLIFlag):
    CPIO = ""
    CPIO_WITH_GZIP = "-z"
    CPIO_WITH_BZIP2 = "-j"
    ZIP = "-k"


class TarCompressionMethod(CLIFlag):
    GZIP = "--gzip"
    BZIP2 = "--bzip2"
    LRZIP = "--lrzip"  # Not available on macOS
    LZOP = "--lzop"  # Not available on macOS
    LZ4 = "--lz4"  # Compression level not supported on macOS
    XZ = "--xz"
    ZSTD = "--zstd"
    COMPRESS = "--compress"


class SevenZipCompressionMethod(CLIFlag):
    LZ = "LZMA"
    LZMA = "LZMA2"
    BZIP2 = "BZip2"
    DEFLATE = "Deflate"


class DMGFormat(CLIFlag):
    ReadWrite = "UDRW"
    ReadOnly = "UDRO"
    ADC = "UDCO"
    ZLIB = "UDZO"
    LZFSE = "ULFO"  # OS X 10.11+ only
    LZMA = "ULMO"  # macOS 10.15+ only
    BZIP2 = "UDBZ"  # deprecated
    ISO = "UDTO"
    SPARSE = "UDSP"
    SPARSEBUNDLE = "UDSB"
    EntireImageWithMD5 = "UFBI"


def get_file_size(path: Path) -> int:
    return Path(path).stat().st_size


def log(*values):
    print(*values)
    global RESULTS
    string = datetime.datetime.now().isoformat() + ": " + " ".join([str(i) for i in values]) + "\n"
    RESULTS += string
    FD.write(string)
    FD.flush()


def log_time(func):
    @wraps(func)
    def wrapper(*args, **kwargs):
        start = time.perf_counter_ns()
        result = func(*args, **kwargs)
        end = time.perf_counter_ns()
        log(f"Took {(end - start) / 1e9:.3f} seconds")
        return result

    return wrapper


def log_file_size(func):
    @wraps(func)
    def wrapper(target_file, *args, **kwargs):
        result = func(target_file, *args, **kwargs)
        log(f"File size: {get_file_size(target_file)}")
        return result

    return wrapper


def call_process(args):
    args = [str(i) for i in args if i]
    log(" ".join(args))
    subprocess.run(args, check=True)


@log_time
@log_file_size
def call_zip(target_file, compression_method: Optional[ZipCompressionMethod] = None, compression_level: Optional[int] = None):
    base_args = ["zip", verbose_flags["zip"], "-r", "--symlinks", target_file, TARGET_DIR, "-x", "**/.DS_Store", "-x", "**/__MACOSX"]
    if compression_method:
        base_args += ["--compression-method", compression_method]
    if compression_level:
        base_args += [f"-{compression_level}"]
    call_process(base_args)


@log_time
@log_file_size
def call_ditto(
    target_file, compression_method: Optional[DittoCompressionMethod] = DittoCompressionMethod.CPIO, compression_level: Optional[int] = None
):
    base_args = ["ditto", verbose_flags["ditto"], "-c", "--norsrc", "--noqtn", "--keepParent"]
    if compression_method:
        base_args += [compression_method]
    if compression_level is not None:
        if compression_method != DittoCompressionMethod.ZIP:
            raise ValueError("compression_level only supported for ZIP")
        base_args += ["--zlibCompressionLevel", compression_level]
    base_args += [TARGET_DIR, target_file]
    call_process(base_args)


@log_time
@log_file_size
def call_tar(target_file, compression_method: Optional[TarCompressionMethod] = None, compression_level: Optional[int] = None):
    base_args = ["tar", verbose_flags["tar"], "--uid", "0", "--gid", "0", "--no-mac-metadata", "-c"]
    if compression_method:
        base_args += [compression_method]
    if compression_level is not None:
        base_args += ["--options", f"compression-level={compression_level}"]
    base_args += ["-f", target_file, TARGET_DIR]
    call_process(base_args)


def call_7z_internal(
    bin,
    target_file,
    compression_method: Optional[SevenZipCompressionMethod] = SevenZipCompressionMethod.DEFLATE,
    compression_level: Optional[int] = None,
):
    base_args = [bin, "a", "-t7z", f"-m0={compression_method}"]
    if compression_level is not None:
        base_args += [f"-mx={compression_level}"]
    base_args += [target_file, TARGET_DIR]
    call_process(base_args)


@log_time
@log_file_size
def call_7z(
    target_file,
    compression_method: Optional[SevenZipCompressionMethod] = SevenZipCompressionMethod.DEFLATE,
    compression_level: Optional[int] = None,
):
    call_7z_internal("7z", target_file, compression_method, compression_level)


@log_time
@log_file_size
def call_7zz(
    target_file,
    compression_method: Optional[SevenZipCompressionMethod] = SevenZipCompressionMethod.DEFLATE,
    compression_level: Optional[int] = None,
):
    call_7z_internal("7zz", target_file, compression_method, compression_level)


def call_hdiutil_internal(
    target_file,
    dmg_format: Optional[DMGFormat] = None,
    fs="HFS+",
    compression_level: Optional[int] = None,
    use_password=True,
):
    base_args = [
        "hdiutil",
        "create",
        "-srcfolder",
        TARGET_DIR,
        target_file,
        verbose_flags["hdiutil"],
        "-volname",
        "payloads",
        "-fs",
        fs,
        "-ov",
    ]
    if use_password:
        base_args += [
            "-passphrase",
            "password",
            "-encryption",
        ]
    if dmg_format:
        base_args += ["-format", dmg_format]
    if compression_level is not None:
        if dmg_format != DMGFormat.ZLIB:
            raise ValueError("compression_level only supported for ZLIB")
        base_args += ["-imagekey", f"zlib-level={compression_level}"]
    call_process(base_args)


@log_time
@log_file_size
def call_hdiutil(
    target_file,
    dmg_format: Optional[DMGFormat] = None,
    fs="HFS+",
    compression_level: Optional[int] = None,
    use_password=True,
):
    call_hdiutil_internal(target_file, dmg_format, fs, compression_level, use_password)


@log_time
@log_file_size
def call_hdiutil_and_convert(
    target_file,
    dmg_format: Optional[DMGFormat] = None,
    internal_dmg_format: Optional[DMGFormat] = DMGFormat.ReadOnly,
    fs="HFS+",
    compression_level: Optional[int] = None,
    tasks=None,
):
    target_file = Path(target_file)

    FILE_EXT = {
        DMGFormat.SPARSE: "sparseimage",
        DMGFormat.SPARSEBUNDLE: "sparsebundle",
        None: "dmg",
    }

    temporary_file_name = target_file.with_stem(target_file.stem + "-temp").with_suffix("." + FILE_EXT.get(internal_dmg_format, "dmg"))

    call_hdiutil_internal(temporary_file_name, internal_dmg_format, fs, use_password=False)
    base_args = [
        "hdiutil",
        "convert",
        "-format",
        dmg_format,
        temporary_file_name,
        "-o",
        target_file,
        verbose_flags["hdiutil"],
        "-passphrase",
        "password",
        "-encryption",
        "-ov",
    ]
    if tasks is not None:
        base_args += ["-tasks", tasks]
    if compression_level is not None:
        if dmg_format != DMGFormat.ZLIB:
            raise ValueError("compression_level only supported for ZLIB")
        base_args += ["-imagekey", f"zlib-level={compression_level}"]
    call_process(base_args)
    if temporary_file_name.exists():
        if temporary_file_name.is_file():
            temporary_file_name.unlink()
        else:
            shutil.rmtree(temporary_file_name, ignore_errors=True)


def main():
    shutil.rmtree(RESULT_DIR, ignore_errors=True)
    Path(RESULT_DIR).mkdir(exist_ok=True)

    # Known good
    # call_hdiutil(f"{RESULT_DIR}/dmg.dmg", dmg_format=DMGFormat.ReadOnly)
    # call_hdiutil(f"{RESULT_DIR}/dmg-rw.dmg", dmg_format=DMGFormat.ReadWrite)
    # call_hdiutil(f"{RESULT_DIR}/dmg-sparse.sparseimage", dmg_format=DMGFormat.SPARSE)
    # call_hdiutil(f"{RESULT_DIR}/dmg-sparsebundle.sparsebundle", dmg_format=DMGFormat.SPARSEBUNDLE)
    # call_hdiutil(f"{RESULT_DIR}/dmg-lzma.dmg", dmg_format=DMGFormat.LZMA)
    call_hdiutil_and_convert(f"{RESULT_DIR}/dmg-lzma-conv.dmg", dmg_format=DMGFormat.LZMA)
    log()
    call_hdiutil_and_convert(f"{RESULT_DIR}/dmg-lzma-conv2.dmg", dmg_format=DMGFormat.LZMA, internal_dmg_format=DMGFormat.SPARSEBUNDLE)
    log()
    call_hdiutil_and_convert(f"{RESULT_DIR}/dmg-lzma-apfs-conv.dmg", dmg_format=DMGFormat.LZMA, fs="APFS")
    log()
    call_hdiutil_and_convert(
        f"{RESULT_DIR}/dmg-lzma-apfs-conv2.dmg", dmg_format=DMGFormat.LZMA, fs="APFS", internal_dmg_format=DMGFormat.SPARSEBUNDLE
    )
    log()
    # call_hdiutil_and_convert(f"{RESULT_DIR}/dmg-lzma-conv-tasks7.dmg", dmg_format=DMGFormat.LZMA, tasks=7)
    # log()
    # call_hdiutil_and_convert(
    #     f"{RESULT_DIR}/dmg-lzma-conv2-tasks7.dmg", dmg_format=DMGFormat.LZMA, internal_dmg_format=DMGFormat.SPARSEBUNDLE, tasks=7
    # )
    # call_hdiutil(f"{RESULT_DIR}/dmg-zlib.dmg", dmg_format=DMGFormat.ZLIB)
    # call_hdiutil(f"{RESULT_DIR}/dmg-zlib9.dmg", dmg_format=DMGFormat.ZLIB, compression_level=9)
    # call_hdiutil(f"{RESULT_DIR}/dmg-lzfse.dmg", dmg_format=DMGFormat.LZFSE)
    # call_hdiutil(f"{RESULT_DIR}/dmg-bzip2.dmg", dmg_format=DMGFormat.BZIP2)


if __name__ == "__main__":
    main()
    FD.close()
