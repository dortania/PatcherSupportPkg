#!/usr/bin/env python3
# textpin.py <mach-o>...: the signing-independent identity the AMD adapter checks: LC_UUID and the SHA-256 of the
# __TEXT segment's file bytes after the load commands (code, constants and the header padding where
# make_parser_fix.py puts its code; the load commands themselves change when a file is re-signed).
import hashlib
import struct
import sys


def pin(path):
    d = open(path, "rb").read()
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IiiIIIII", d, 0)
    assert magic == 0xFEEDFACF, "not a thin 64-bit Mach-O"
    off, uuid, text = 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, off)
        if cmd == 0x1B:
            uuid = d[off + 8 : off + 24]
        if cmd == 0x19 and d[off + 8 : off + 24].rstrip(b"\0") == b"__TEXT":
            fileoff, filesize = struct.unpack_from("<QQ", d, off + 40)
            text = (fileoff, filesize)
        off += size
    start = 32 + sizeofcmds
    return uuid, hashlib.sha256(d[start : text[0] + text[1]]).digest(), start, text


for p in sys.argv[1:]:
    u, h, start, text = pin(p)
    print(f"{u.hex()} {h.hex()} text[{start:#x}:{text[0]+text[1]:#x}] {p}")
