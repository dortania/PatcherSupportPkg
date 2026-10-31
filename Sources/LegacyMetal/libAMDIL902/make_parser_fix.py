"""Build libAMDIL902-parserfix.dylib: the stock 12.5 libAMDIL902 (Monterey AMD shader backend) taught two pieces of
the argument metadata that Sequoia's Metal compiler writes differently.

1. Argument buffers (replaces OCLP's Tahoe stub that disables initializeIABArgTypeSet):
The 2022 llvm::ArgType::ArgType(MDNode*, unsigned) parser matches keys strictly in sequence. Sequoia's compiler adds
"air.address_space", <i32> (and the flag "air.buffer_stride") to buffer arguments, ahead of "air.struct_type_info";
the old parser stalls on them, never records the argument buffer's struct layout (ArgType+0x80 stays null) and
ILMetadataPropagation::initializeIABArgTypeSet then dereferences that null pointer.

Patch: at the "air.struct_type_info" check (0x63b62), jump to code in the header padding that first skips any
number of those keys, then resumes the original check.

2. Colour (framebuffer) fragment inputs: Sequoia writes "air.render_target", <attachment> for inputs (no blending
index, which only outputs have). ILEntryFunc::initShaderArgType insists on two integers after every
"air.render_target" and otherwise aborts the compile with "Unsupported 'air.render_target' metadata configuration",
so any [[color(n)]] input, even an unused one, failed. The old argument parser does not read render_target on
inputs itself; AIRRenderTargetType(MDNode*, unsigned&) does, and it reads the operand after the attachment index as
the blending index without checking its type, so with the one-integer form it dereferences a key string (crash with
"air.raster_order_group", silent misparse with "air.arg_type_name"). Fix: the check accepts the one-integer form
(its four failure branches continue the scan), and AIRRenderTargetType only takes a blending index when the next
operand is a constant (otherwise 0, leaving that operand for the caller).

4. Private arrays read through a shared address (Tests/c03-amdil-gep-select): the IL GEP
Select pass (ILGEPSelect::runOnFunction) rewrites each load through a dynamically indexed GEP into a small private
array (<= 4 elements, alloca) as loads of every element + selects on the index. It positions its IRBuilder at the GEP
once and never moves it, so every expansion lands at the GEP: when one GEP serves several loads (LLVM computes
&w[i].field once and reuses it), loads after stores to that field read the values from before the stores. Fix: when
the pass picks up each load, the builder is moved to that load first (IRBuilderBase::SetInsertPoint(load)).
usage: python3 make_parser_fix.py <stock libAMDIL902.dylib> <out>
       PARSERFIX_SKIP_GEP_SELECT=1: patches 1-3 only (the tests' "without the fix" build for c03)
"""

import hashlib
import os
import struct
import sys

BASE = 0x4FFA0D370000  # __TEXT vmaddr (file offset 0)
SITE = 0x4FFA0D3D3B62  # movl -0x2c(%rbp),%eax ; movl (%r12),%ecx   (start of the struct_type_info check)
RESUME = 0x4FFA0D3D3B69  # cmpl %ecx,%eax
GET_STRING = 0x4FFA0DE4F410  # llvm::MDString::getString() const
CAVE = 0x4FFA0D372000  # zero padding between the load commands (end 0x8c8) and __text (0x3ac0)
# The stock 12.5 build, independent of its code signature (Dortania's release signing and PatcherSupportPkg's ad-hoc
# copies differ): LC_UUID + SHA-256 of the __TEXT bytes after the load commands (see AMDTextureAtomics' provider check).
STOCK_UUID = "d5cf000789353193b3f1d0b3dd0dcc91"
STOCK_TEXT_SHA = "e43893cb0b79ed8199ad298013b2e1ccc37ca55103469006406cbbb1a2769c49"


def text_pin(data):
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    off, uuid, text_end = 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x1B:
            uuid = data[off + 8 : off + 24].hex()
        if cmd == 0x19 and data[off + 8 : off + 24].rstrip(b"\0") == b"__TEXT":
            fileoff, filesize = struct.unpack_from("<QQ", data, off + 40)
            text_end = fileoff + filesize
        off += size
    return uuid, hashlib.sha256(data[32 + sizeofcmds : text_end]).hexdigest()


SITE_BYTES = bytes.fromhex("8b45d4418b0c24")


def q(s):
    return struct.pack("<Q", int.from_bytes(s.encode(), "little"))


code = bytearray()
labels, fixups = {}, []  # fixups: (position of rel8/rel32 field, label or absolute target, size)


def emit(b):
    code.extend(b)


def label(n):
    labels[n] = len(code)


def jcc8(op, target):
    emit(bytes([op, 0]))
    fixups.append((len(code) - 1, target, 1))


def rel32(op, target):
    emit(bytes([op]) + b"\0\0\0\0")
    fixups.append((len(code) - 4, target, 4))


label("loop")
emit(bytes.fromhex("8b45d4"))  # movl -0x2c(%rbp),%eax        index of the next metadata operand
emit(bytes.fromhex("418b0c24"))  # movl (%r12),%ecx             operand count
emit(bytes.fromhex("39c8"))  # cmpl %ecx,%eax
jcc8(0x73, "resume")  # jae resume
emit(bytes.fromhex("4829c8"))  # subq %rcx,%rax               operands are stored before the node
emit(bytes.fromhex("488b3cc3"))  # movq (%rbx,%rax,8),%rdi
emit(bytes.fromhex("4885ff"))  # testq %rdi,%rdi
jcc8(0x74, "resume")  # je resume
emit(bytes.fromhex("803f00"))  # cmpb $0,(%rdi)               MDString?
jcc8(0x75, "resume")
rel32(0xE8, GET_STRING)  # call MDString::getString     -> rax = data, rdx = length
emit(bytes.fromhex("4883fa11"))  # cmpq $17,%rdx                both keys are 17 characters
jcc8(0x75, "resume")
emit(bytes.fromhex("8078106 5".replace(" ", "")))  # cmpb $'e',0x10(%rax)  both end in 'e'
jcc8(0x75, "resume")
emit(b"\x48\xb9" + q("air.addr"))
emit(bytes.fromhex("483908"))  # cmpq "air.addr",(%rax)
jcc8(0x75, "stride")
emit(b"\x48\xb9" + q("ess_spac"))
emit(bytes.fromhex("48394808"))  # cmpq "ess_spac",8(%rax)
jcc8(0x75, "resume")
emit(bytes.fromhex("8345d402"))  # addl $2,-0x2c(%rbp)          "air.address_space", <value>
jcc8(0xEB, "loop")
label("stride")
emit(b"\x48\xb9" + q("air.buff"))
emit(bytes.fromhex("483908"))  # cmpq "air.buff",(%rax)
jcc8(0x75, "resume")
emit(b"\x48\xb9" + q("er_strid"))
emit(bytes.fromhex("48394808"))  # cmpq "er_strid",8(%rax)
jcc8(0x75, "resume")
emit(bytes.fromhex("8345d401"))  # addl $1,-0x2c(%rbp)          "air.buffer_stride" (flag, no value)
jcc8(0xEB, "loop")
label("resume")
emit(SITE_BYTES)  # the two instructions the jump at SITE replaced
rel32(0xE9, RESUME)  # jmp back to cmpl %ecx,%eax

for pos, target, size in fixups:
    addr = (CAVE + labels[target]) if isinstance(target, str) else target
    disp = addr - (CAVE + pos + size)
    if size == 1:
        assert -128 <= disp < 128, (target, disp)
        code[pos] = disp & 0xFF
    else:
        code[pos : pos + 4] = struct.pack("<i", disp)

data = bytearray(open(sys.argv[1], "rb").read())
assert text_pin(data) == (STOCK_UUID, STOCK_TEXT_SHA), "not the stock 12.5 libAMDIL902"
site, cave = SITE - BASE, CAVE - BASE
assert data[site : site + 7] == SITE_BYTES
assert data[cave : cave + len(code) + 16] == bytes(len(code) + 16), "cave is not free"
data[cave : cave + len(code)] = code
data[site : site + 7] = b"\xe9" + struct.pack("<i", CAVE - (SITE + 5)) + b"\x90\x90"

# Patch 3: AIRRenderTargetType::AIRRenderTargetType(MDNode const*, unsigned&). After the attachment index has been
# read (r9 = its operand index, r8d = r9 + 1, rdx = &index, rsi = node, rdi = this), continue in a second cave that
# reads the blending index only if operand r8 is a ConstantAsMetadata.
RT_SITE, RT_SITE_BYTES = 0x4FFA0D3D23FF, bytes.fromhex("418d41028902")  # lea 0x2(%r9),%eax ; mov %eax,(%rdx)
CAVE2 = CAVE + 0x100
rt = bytes.fromhex(
    "8b4608"  # movl 0x8(%rsi),%eax           operand count
    "4489c1"  # movl %r8d,%ecx
    "39c1"  # cmpl %eax,%ecx
    "7334"  # jae noblend
    "4829c1"  # subq %rax,%rcx
    "488b04ce"  # movq (%rsi,%rcx,8),%rax        operand r9 + 1
    "4885c0"  # testq %rax,%rax
    "7428"  # je noblend
    "803801"  # cmpb $1,(%rax)                 ConstantAsMetadata?
    "7523"  # jne noblend
    "488b8880000000"  # movq 0x80(%rax),%rcx           its ConstantInt
    "488d4118"  # leaq 0x18(%rcx),%rax           APInt value (inline when <= 64 bits)
    "83792040"  # cmpl $0x40,0x20(%rcx)
    "7603"  # jbe 1f
    "488b00"  # movq (%rax),%rax
    "488b00"  # 1: movq (%rax),%rax
    "48894708"  # movq %rax,0x8(%rdi)            blending index
    "418d4102"  # leal 0x2(%r9),%eax
    "8902"  # movl %eax,(%rdx)               consumed both integers
    "5d"
    "c3"  # popq %rbp ; retq
    "48c7470800000000"  # noblend: movq $0,0x8(%rdi)     index stays at r9 + 1
    "5d"
    "c3"
)  # popq %rbp ; retq
off = RT_SITE - BASE
assert data[off : off + 6] == RT_SITE_BYTES
assert data[CAVE2 - BASE : CAVE2 - BASE + len(rt)] == bytes(len(rt))
data[CAVE2 - BASE : CAVE2 - BASE + len(rt)] = rt
data[off : off + 6] = b"\xe9" + struct.pack("<i", CAVE2 - (RT_SITE + 5)) + b"\x90"

# Patch 2: in initShaderArgType, the branches to the render_target error (0x4FFA0D3DB491) continue the scan at
# 0x4FFA0D3DB43E instead. (address of the 2-byte jcc, its opcode)
CONTINUE = 0x4FFA0D3DB43E
for jcc, opcode in ((0x4FFA0D3DB41C, 0x73), (0x4FFA0D3DB42A, 0x75), (0x4FFA0D3DB42F, 0x74), (0x4FFA0D3DB43C, 0x75)):
    off = jcc - BASE
    assert data[off] == opcode and jcc + 2 + struct.unpack("b", data[off + 1 : off + 2])[0] == 0x4FFA0D3DB491
    data[off + 1] = CONTINUE - (jcc + 2)
# Patch 4: ILGEPSelect::runOnFunction, per use of the GEP: after it has found that the user is a load (rax = the load,
# rbx = the use), save both as before and also move the IRBuilder (at -0x178(%rbp)) to the load.
GS_SITE, GS_RESUME = 0x4FFA0D39B9BB, 0x4FFA0D39B9C9
GS_SITE_BYTES = bytes.fromhex("48899d40ffffff" "48898548ffffff")  # movq %rbx,-0xc0(%rbp) ; movq %rax,-0xb8(%rbp)
SET_INSERT_POINT = 0x4FFA0D396E0C  # llvm::IRBuilderBase::SetInsertPoint(llvm::Instruction*)
CAVE4 = CAVE + 0x200
gs = bytearray(GS_SITE_BYTES)  # the two stores the jump replaces
gs += bytes.fromhex("50" "50")  # pushq %rax (twice: keep the stack 16-byte aligned for the call)
gs += bytes.fromhex("488dbd88feffff")  # leaq -0x178(%rbp),%rdi   the IRBuilder
gs += bytes.fromhex("4889c6")  # movq %rax,%rsi              the load
gs += b"\xe8" + struct.pack("<i", SET_INSERT_POINT - (CAVE4 + len(gs) + 5))  # call SetInsertPoint
gs += bytes.fromhex("58" "58")  # popq %rax (twice)
gs += b"\xe9" + struct.pack("<i", GS_RESUME - (CAVE4 + len(gs) + 5))  # jmp back to movq (%rax),%rdi
if os.environ.get("PARSERFIX_SKIP_GEP_SELECT") != "1":
    off = GS_SITE - BASE
    assert data[off : off + 14] == GS_SITE_BYTES
    assert data[CAVE4 - BASE : CAVE4 - BASE + len(gs) + 16] == bytes(len(gs) + 16), "cave 4 is not free"
    data[CAVE4 - BASE : CAVE4 - BASE + len(gs)] = gs
    data[off : off + 14] = b"\xe9" + struct.pack("<i", CAVE4 - (GS_SITE + 5)) + b"\x90" * 9
open(sys.argv[2], "wb").write(data)
print(f"cave {len(code)} bytes at {hex(cave)}; text pin {text_pin(data)[1]} (re-sign the output: its signature is stale)")
