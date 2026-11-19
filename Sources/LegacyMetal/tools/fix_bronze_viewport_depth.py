"""fix_bronze_viewport_depth.py <AMDMTLBronzeDriver>: orders the viewport depth clamp range in the 12.5 Bronze driver, in place.

amdMtlBronzeSetViewports (BronzeRenderCmdEncoderMembersRec *, const MTLViewport *, unsigned) sets the depth scale to
zfar - znear and the offset to znear, which also works for a reversed range (znear > zfar, which Metal allows), but on
Metal's path it stores the depth clamp range as ZMIN = znear, ZMAX = zfar unordered (encoder members 0x3f0 + 8i and
0x3f4 + 8i, written to PA_SC_VPORT_ZMIN/ZMAX in the same call). With a reversed range ZMIN > ZMAX, and the clamp
min(max(z, ZMIN), ZMAX) returns zfar for every fragment: viewport depth 1..0 stored 0 instead of 0.75 for z = 0.25, and
0.75..0.25 stored 0.25 instead of 0.625 (OpenGL's path, the other branch, orders them with minss / maxss). The two stores
become the ordered pair, from znear already in xmm3 and zfar:

    before                                         after
    xorps    %xmm4, %xmm4                          movaps   %xmm3, %xmm4
    cvtsd2ss 0x20(%rsi,%rax), %xmm4                cvtsd2ss 0x28(%rsi,%rax), %xmm1
    movss    %xmm4, 0x3f0(%rbx,%r12,8)             minss    %xmm1, %xmm4
    xorps    %xmm1, %xmm1                          maxss    %xmm3, %xmm1
    cvtsd2ss 0x28(%rsi,%rax), %xmm1                movss    %xmm4, 0x3f0(%rbx,%r12,8)
    movss    %xmm1, 0x3f4(%rbx,%r12,8)             movss    %xmm1, 0x3f4(%rbx,%r12,8); nop

The driver's change check right after compares xmm4 / xmm1 with the old members, so it sees what was stored. The function
is found through the symbol table and the 38 bytes must appear exactly once inside it; a file that already has the new
bytes is refused. Run before signing (build.sh signs the driver afterwards).
"""
import struct
import sys

SYMBOL = b"__ZL24amdMtlBronzeSetViewportsP32BronzeRenderCmdEncoderMembersRecPK11MTLViewportj"
OLD = bytes.fromhex("0f57e4" "f20f5a640620" "f3420f11a4e3f0030000" "0f57c9" "f20f5a4c0628" "f3420f118ce3f4030000")
NEW = bytes.fromhex("0f28e3" "f20f5a4c0628" "f30f5de1" "f30f5fcb" "f3420f11a4e3f0030000" "f3420f118ce3f4030000" "90")
assert len(OLD) == len(NEW) == 38
LC_SEGMENT_64, LC_SYMTAB, MH_MAGIC_64, CPU_TYPE_X86_64 = 0x19, 0x2, 0xFEEDFACF, 0x01000007


def main():
    path = sys.argv[1]
    data = bytearray(open(path, "rb").read())
    magic, cputype, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_X86_64:
        sys.exit("not a thin x86_64 Mach-O")
    pos, text, symtab = 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, pos)
        if cmd == LC_SEGMENT_64 and data[pos + 8:pos + 24].rstrip(b"\0") == b"__TEXT":
            text = struct.unpack_from("<QQQQ", data, pos + 24)  # vmaddr, vmsize, fileoff, filesize
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", data, pos + 8)
        pos += size
    if not text or not symtab:
        sys.exit("no __TEXT segment or symbol table")
    symoff, nsyms, stroff, _ = symtab
    starts = sorted(struct.unpack_from("<IBBHQ", data, symoff + 16 * i)[4] for i in range(nsyms)
                    if struct.unpack_from("<IBBHQ", data, symoff + 16 * i)[1] & 0x0E == 0x0E)
    func = None
    for i in range(nsyms):
        strx, ntype, _, _, value = struct.unpack_from("<IBBHQ", data, symoff + 16 * i)
        if ntype & 0x0E == 0x0E and data[stroff + strx:data.index(b"\0", stroff + strx)] == SYMBOL:
            func = value
    if func is None:
        sys.exit("amdMtlBronzeSetViewports not in the symbol table")
    end = next((s for s in starts if s > func), func + 0x1000)
    lo, hi = func - text[0] + text[2], end - text[0] + text[2]
    body = bytes(data[lo:hi])
    if body.count(NEW) and not body.count(OLD):
        sys.exit("already patched")
    if body.count(OLD) != 1:
        sys.exit("expected the ZMIN/ZMAX stores once in amdMtlBronzeSetViewports, found %d" % body.count(OLD))
    at = lo + body.index(OLD)
    data[at:at + 38] = NEW
    open(path, "wb").write(data)
    print("AMDMTLBronzeDriver: viewport depth clamp range ordered at %#x" % (text[0] + at - text[2]))


if __name__ == "__main__":
    main()
