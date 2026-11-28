"""make_coreimage_fix.py <stock CoreImageOld.dylib> <output>: repairs OCLP's CoreImageOld.dylib (the 14.0 beta 3 Core
Image of the 3802 payloads, Universal-Binaries/14.0 Beta 3-24), which apps get behind OCLP's small CoreImage wrapper.

1. CIKernelReflection::reflect: OCLP's copy has its first 11 bytes replaced with `movabs rax, 0; ret`, so reflection
   always fails. Core Image reflects every kernel it loads from a metallib through it, so +[CIKernel
   kernelWithFunctionName:fromMetalLibraryData:error:] returned nil, without an error, for every precompiled Core Image
   kernel an app makes (Microsoft Office's picture corrections). The stub kept stitchable kernels from reaching MetalOld's
   MTLStitchingReflectionReader, which aborted on the reflection replies of Sequoia's compiler service; MetalOldCompat
   item 52 makes those replies readable, and the two ship together: with reflect back and without item 52, Photos'
   portrait filters abort.
2. Its own data: CoreImageOld finds three of its __TEXT sections with getsectdatafromFramework("CoreImage", "__TEXT",
   ...), which matches images by leaf name, so it found OCLP's wrapper, which has none of them: __runtimeheader (the
   header for kernels written in Metal), __cikl2metal_pre (the preamble for kernels written in the Core Image kernel
   language) and __cruft (Core Image's table of fixed kernel strings for old apps). +[CIKernel kernelsWithMetalString:
   error:] then aborted the app (newLibraryWithSource: with a nil source). The three calls now pass the leaf of
   CoreImageOld's own install name, the LC_ID_DYLIB string in the mapped header: a new displacement in each `lea rdi`.
   OCLP's NOP of the `je` taken for an empty __cruft table (in +[CIKernel(CruftCompatability)
   modifiedKernelStringForFosl:], the crash fixed in PatcherSupportPkg 1cb56b28d) stays; with the table found it isn't
   reached.
3. +[CIKernel kernelsWithString:andCIKernelLibrary:messageLog:]: stubbed like reflect, so +[CIKernel kernelsWithString:]
   (several kernels in one string) returned nil. Its prologue goes back.

Functions are found through the symbol table, and each stub and the instructions after it are checked against what
OCLP's copy holds before the original prologue (push rbp; mov rbp, rsp; push r15; push r14; push r13; push r12's first
byte) is written back. The section lookups are found by their string operands, and there must be exactly the three.
That leaves the old signature invalid; build.sh signs the output again.
"""
import re
import struct
import sys

STUB = bytes.fromhex("48b80000000000000000c3")  # movabs rax, 0; ret
ORIGINAL = bytes.fromhex("554889e54157415641554154")[:11]
STUBBED = {  # symbol: the bytes after the stub (push r12's second byte, push rbx; sub rsp, n)
    b"__ZN18CIKernelReflection7reflectEP15CIKernelLibraryPKcPP7NSError": bytes.fromhex("5453" "4881ec28020000"),
    b"+[CIKernel kernelsWithString:andCIKernelLibrary:messageLog:]": bytes.fromhex("5453" "4881ec58030000"),
}
SECTIONS = (b"__runtimeheader", b"__cikl2metal_pre", b"__cruft")
LC_SEGMENT_64, LC_SYMTAB, LC_ID_DYLIB, MH_MAGIC_64, CPU_TYPE_X86_64 = 0x19, 0x2, 0xD, 0xFEEDFACF, 0x01000007


def load_commands(data):
    magic, cputype, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_X86_64:
        sys.exit("not a thin x86_64 Mach-O")
    pos = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, pos)
        yield cmd, pos
        pos += size


def layout(data):
    text, symtab, sects, install = None, None, {}, None
    for cmd, pos in load_commands(data):
        if cmd == LC_SEGMENT_64 and data[pos + 8:pos + 24].rstrip(b"\0") == b"__TEXT":
            text = struct.unpack_from("<QQQQ", data, pos + 24)  # vmaddr, vmsize, fileoff, filesize
            for j in range(struct.unpack_from("<I", data, pos + 64)[0]):
                sp = pos + 72 + 80 * j
                addr, size, off = struct.unpack_from("<QQI", data, sp + 32)
                sects[bytes(data[sp:sp + 16]).rstrip(b"\0")] = (addr, size, off)
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", data, pos + 8)  # symoff, nsyms, stroff, strsize
        elif cmd == LC_ID_DYLIB:
            name = pos + struct.unpack_from("<I", data, pos + 8)[0]
            install = (name, bytes(data[name:data.index(b"\0", name)]))
    if not text or not symtab or not install or b"__text" not in sects or b"__cstring" not in sects:
        sys.exit("no __TEXT segment, symbol table, install name or __text/__cstring")
    if text[0] != 0 or text[2] != 0:
        sys.exit("__TEXT doesn't start at address 0 / file offset 0")  # then file offsets = addresses below
    return symtab, sects, install


def symbol_offsets(data, symtab, names):
    symoff, nsyms, stroff, _ = symtab
    found = {}
    for i in range(nsyms):
        strx, ntype, _, _, value = struct.unpack_from("<IBBHQ", data, symoff + 16 * i)
        nm = bytes(data[stroff + strx:data.index(b"\0", stroff + strx)])
        if nm in names and ntype & 0x0E == 0x0E:  # N_SECT
            found[nm] = value
    missing = [n.decode() for n in names if n not in found]
    if missing:
        sys.exit("not in the symbol table: %s" % ", ".join(missing))
    return found


def restore_stubs(data, symtab):
    for name, off in symbol_offsets(data, symtab, list(STUBBED)).items():
        after = STUBBED[name]
        if data[off:off + 11] == ORIGINAL:
            sys.exit("%s at %#x is not stubbed: not OCLP's CoreImageOld" % (name.decode(), off))
        if data[off:off + 11] != STUB or data[off + 11:off + 11 + len(after)] != after:
            sys.exit("unexpected bytes at %s (%#x): %s" % (name.decode(), off, data[off:off + 20].hex()))
        data[off:off + 11] = ORIGINAL
        print("CoreImageOld: %s restored at %#x" % (name.decode(), off))


def redirect_section_lookups(data, sects, install):
    caddr, csize, coff = sects[b"__cstring"]
    taddr, tsize, toff = sects[b"__text"]
    strings = {}
    for s in (b"CoreImage", b"__TEXT") + SECTIONS:
        hits = [caddr + m.start() + 1 for m in re.finditer(b"\0" + re.escape(s) + b"\0", data[coff:coff + csize])]
        if len(hits) != 1:
            sys.exit("%d copies of the string %s" % (len(hits), s.decode()))
        strings[s] = hits[0]

    def lea_target(pos, reg):  # lea <reg>, [rip + disp32] at file offset pos (= address), its target or None
        if data[pos:pos + 3] != b"\x48\x8d" + bytes([reg]):
            return None
        return pos + 7 + struct.unpack_from("<i", data, pos + 3)[0]

    sites = {}
    for m in re.finditer(rb"\x48\x8d\x3d", data[toff:toff + tsize]):  # lea rdi, [rip + disp32]
        pos = toff + m.start()
        if lea_target(pos, 0x3D) != strings[b"CoreImage"]:
            continue
        if lea_target(pos + 7, 0x35) != strings[b"__TEXT"]:  # lea rsi, "__TEXT"
            sys.exit("lookup at %#x: second operand isn't __TEXT" % pos)
        sect = next((s for s in SECTIONS if lea_target(pos + 14, 0x15) == strings[s]), None)  # lea rdx, <section>
        if sect is None or sect in sites:
            sys.exit("lookup at %#x: unexpected section operand" % pos)
        sites[sect] = pos
    if len(sites) != len(SECTIONS):
        sys.exit("found %d of the %d section lookups" % (len(sites), len(SECTIONS)))
    name_off, name = install
    if not name.endswith(b"/CoreImageOld.dylib"):
        sys.exit("unexpected install name %s" % name.decode())
    leaf = name_off + len(name) - len(b"CoreImageOld.dylib")
    for sect, pos in sorted(sites.items(), key=lambda kv: kv[1]):
        struct.pack_into("<i", data, pos + 3, leaf - (pos + 7))
        print("CoreImageOld: %s looked up in CoreImageOld.dylib (%#x)" % (sect.decode(), pos))


def main():
    src, dst = sys.argv[1:3]
    data = bytearray(open(src, "rb").read())
    symtab, sects, install = layout(data)
    for s in SECTIONS:
        if s not in sects:
            sys.exit("no __TEXT,%s section" % s.decode())
    restore_stubs(data, symtab)
    redirect_section_lookups(data, sects, install)
    open(dst, "wb").write(data)


if __name__ == "__main__":
    main()
