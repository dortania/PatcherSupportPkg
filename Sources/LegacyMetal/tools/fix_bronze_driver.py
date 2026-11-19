"""fix_bronze_driver.py <AMDMTLBronzeDriver>: two fixes to the 12.5 Bronze driver's viewport state, in place.

1. Reversed viewport depth ranges (n21). amdMtlBronzeSetViewports (BronzeRenderCmdEncoderMembersRec *, const MTLViewport *,
unsigned) sets the depth scale to zfar - znear and the offset to znear, which also works for a reversed range (znear >
zfar, which Metal allows), but on Metal's path it stores the depth clamp range as ZMIN = znear, ZMAX = zfar unordered
(encoder members 0x3f0 + 8i and 0x3f4 + 8i, written to PA_SC_VPORT_ZMIN/ZMAX in the same call). With a reversed range
ZMIN > ZMAX, and the clamp min(max(z, ZMIN), ZMAX) returns zfar for every fragment: viewport depth 1..0 stored 0 instead of
0.75 for z = 0.25, and 0.75..0.25 stored 0.25 instead of 0.625 (OpenGL's path, the other branch, orders them with minss /
maxss). The two stores become the ordered pair, from znear already in xmm3 and zfar:

    before                                         after
    xorps    %xmm4, %xmm4                          movaps   %xmm3, %xmm4
    cvtsd2ss 0x20(%rsi,%rax), %xmm4                cvtsd2ss 0x28(%rsi,%rax), %xmm1
    movss    %xmm4, 0x3f0(%rbx,%r12,8)             minss    %xmm1, %xmm4
    xorps    %xmm1, %xmm1                          maxss    %xmm3, %xmm1
    cvtsd2ss 0x28(%rsi,%rax), %xmm1                movss    %xmm4, 0x3f0(%rbx,%r12,8)
    movss    %xmm1, 0x3f4(%rbx,%r12,8)             movss    %xmm1, 0x3f4(%rbx,%r12,8); nop

The driver's change check right after compares xmm4 / xmm1 with the old members, so it sees what was stored.

2. Wide points centered outside the viewport (n23). The driver sets the clipper's guard band (PA_CL_GB_VERT/HORZ_CLIP_ADJ)
from the viewport but leaves the discard band (PA_CL_GB_VERT/HORZ_DISC_ADJ) at 1.0, the viewport itself, so a point whose
center is outside the viewport is dropped whole, even the part of it that's inside (on Intel and Apple GPUs it draws).
The four registers are encoder members 0x620 VERT_CLIP, 0x624 VERT_DISC, 0x628 HORZ_CLIP, 0x62c HORZ_DISC (offsets
0x2fc..0x308 of the BronzeRenderEncoderHwCtxRegsRec inside them), set in two places, which now set the discard band to the
guard band (as radeonsi caps it); the viewport scissor still keeps the pixels inside the viewport.
amdMtlBronzeInitRenderEncoderHwCtxRegs, for the render target's default viewport (v in xmm6, h in xmm7):

    movss    %xmm7, 0x304(%rdi)                    unpcklps %xmm6, %xmm6; unpcklps %xmm7, %xmm7
    movss    %xmm6, 0x2fc(%rdi)                    movlhps  %xmm7, %xmm6; movups %xmm6, 0x2fc(%rdi)

and amdMtlBronzeSetViewports, which stores the new guard band (v, h in xmm0, h in xmm1) and emits the four registers:

    movaps   -0x70(%rbp), %xmm1                    movaps   -0x70(%rbp), %xmm1
    movss    %xmm1, 0x628(%rbx)                    movaps   -0x50(%rbp), %xmm0
    movaps   -0x50(%rbp), %xmm0                    unpcklps %xmm0, %xmm0
    movss    %xmm0, 0x620(%rbx)                    movups   %xmm0, 0x620(%rbx)
    movl     0x624(%rbx), %ecx                     movd     %xmm0, %ecx
    movl     0x62c(%rbx), %edx                     movd     %xmm1, %edx; nopw (10 bytes)

Each function is found through the symbol table and its old bytes must appear exactly once inside it; a file that already
has the new bytes is refused. Run before signing (build.sh signs the driver afterwards).
"""
import struct
import sys

SET_VIEWPORTS = b"__ZL24amdMtlBronzeSetViewportsP32BronzeRenderCmdEncoderMembersRecPK11MTLViewportj"
INIT_HW_CTX = b"__Z38amdMtlBronzeInitRenderEncoderHwCtxRegsP31BronzeRenderEncoderHwCtxRegsRecjjPK21Bronze_DeviceSettingsPK15BronzeHwInfoRec"
FIXES = [  # function, old bytes, new bytes, what
    (SET_VIEWPORTS,
     "0f57e4 f20f5a640620 f3420f11a4e3f0030000 0f57c9 f20f5a4c0628 f3420f118ce3f4030000",
     "0f28e3 f20f5a4c0628 f30f5de1 f30f5fcb f3420f11a4e3f0030000 f3420f118ce3f4030000 90",
     "viewport depth clamp range ordered"),
    (INIT_HW_CTX,
     "f30f11bf04030000 f30f11b7fc020000",
     "0f14f6 0f14ff 0f16f7 0f11b7fc020000",
     "default viewport's discard band = guard band"),
    (SET_VIEWPORTS,
     "0f284d90 f30f118b28060000 0f2845b0 f30f118320060000 8b8b24060000 8b932c060000",
     "0f284d90 0f2845b0 0f14c0 0f118320060000 660f7ec1 660f7eca 662e0f1f840000000000",
     "viewports' discard band = guard band"),
]
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
    syms = [struct.unpack_from("<IBBHQ", data, symoff + 16 * i) for i in range(nsyms)]
    syms = [(data[stroff + s[0]:data.index(b"\0", stroff + s[0])], s[4]) for s in syms if s[1] & 0x0E == 0x0E]
    starts = sorted(value for _, value in syms)
    for symbol, old, new, what in FIXES:
        old, new = bytes.fromhex(old.replace(" ", "")), bytes.fromhex(new.replace(" ", ""))
        assert len(old) == len(new)
        func = next((value for name, value in syms if name == symbol), None)
        if func is None:
            sys.exit("%s not in the symbol table" % symbol.decode())
        end = next((s for s in starts if s > func), func + 0x1000)
        lo, hi = func - text[0] + text[2], end - text[0] + text[2]
        body = bytes(data[lo:hi])
        if body.count(new) and not body.count(old):
            sys.exit("already patched (%s)" % what)
        if body.count(old) != 1:
            sys.exit("%s: expected the old bytes once in %s, found %d" % (what, symbol.decode(), body.count(old)))
        at = lo + body.index(old)
        data[at:at + len(old)] = new
        print("AMDMTLBronzeDriver: %s at %#x" % (what, text[0] + at - text[2]))
    open(path, "wb").write(data)


if __name__ == "__main__":
    main()
