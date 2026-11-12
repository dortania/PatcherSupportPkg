"""Add an LC_LOAD_WEAK_DYLIB command to a 64-bit Mach-O (into the free space after its load commands).

usage: python3 add_weak_dylib.py <in> <out> <dylib path>
The input must be unsigned (codesign --remove-signature first); sign the output afterwards. A weak dylib that is
missing at load time is skipped by dyld, so deleting it later can't break the binary.
"""

import struct
import sys

LC_LOAD_WEAK_DYLIB = 0x80000018
LC_SEGMENT_64 = 0x19

src, dst, path = sys.argv[1], sys.argv[2], sys.argv[3].encode()
data = bytearray(open(src, "rb").read())
magic, cputype, subtype, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IiiIIIII", data, 0)
assert magic == 0xFEEDFACF, "not a 64-bit Mach-O"

# Walk the load commands: refuse duplicates and find the first section's file offset (end of the free space).
offset, first_section = 32, len(data)
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, offset)
    if cmd in (0xC, 0x80000018, 0x8000001F):  # LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB
        name_off = struct.unpack_from("<I", data, offset + 8)[0]
        assert data[offset + name_off :].split(b"\0")[0] != path, "already present"
    if cmd == 0x1D:
        raise SystemExit("binary is signed; remove the signature first")
    if cmd == LC_SEGMENT_64:
        nsects = struct.unpack_from("<I", data, offset + 64)[0]
        for s in range(nsects):
            sect = offset + 72 + s * 80
            sect_offset = struct.unpack_from("<I", data, sect + 48)[0]
            if sect_offset:
                first_section = min(first_section, sect_offset)
    offset += size
end = 32 + sizeofcmds
assert offset == end

name = path + b"\0"
cmdsize = (24 + len(name) + 7) & ~7
assert end + cmdsize <= first_section, f"no room: {first_section - end} bytes free, need {cmdsize}"
assert data[end : end + cmdsize] == bytes(cmdsize), "padding after the load commands is not empty"
command = struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000) + name
data[end : end + cmdsize] = command.ljust(cmdsize, b"\0")
struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
open(dst, "wb").write(data)
print(f"added LC_LOAD_WEAK_DYLIB {path.decode()} ({cmdsize} bytes; {first_section - end - cmdsize} bytes still free)")
