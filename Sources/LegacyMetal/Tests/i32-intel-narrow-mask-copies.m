// i32-intel-narrow-mask-copies (Intel adapter, IntelTextureAtomics.dylib): the iCBE fold of i29 reached through copies.
// A uchar read from a private array is truncated (AND r45, r388, 255), copied into the register a switch's shared case
// takes (MOV r420, r45; CALL 9), and truncated to 16 bits there (AND r389, r46, 65535); iCBE dropped the 255 and the
// value kept bits 8-15 (mslfuzz2 seed 330, one case falling through into the next; seed 88 of the narrow-vector mode
// too). That register is also set from a full 32-bit value on another path, so the 16-bit AND has to stay: it becomes
// SHL 16 / SHR 16. The kernel is the reduced seed 330, on the differential fuzzer's 256-thread input, against the CPU
// reference.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    threadgroup uint tg[64];\n"
    "    threadgroup uchar tc[64];\n"
    "    threadgroup atomic_uint ta;\n"
    "    if (l == 0) atomic_store_explicit(&ta, 0u, memory_order_relaxed);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    uint p[8];\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;\n"
    "    uchar pc[8];\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[(t * 4u + (j & 3u))] >> j);\n"
    "    uint v0 = in[(t * 4u + 0u)] * 1u + t;\n"
    "    uint v1 = in[(t * 4u + 1u)] * 3u + t;\n"
    "    uint v2 = in[(t * 4u + 2u)] * 5u + t;\n"
    "    uint v3 = in[(t * 4u + 3u)] * 7u + t;\n"
    "    uint v4 = in[(t * 4u + 0u)] * 9u + t;\n"
    "    uint v5 = in[(t * 4u + 1u)] * 11u + t;\n"
    "    { uint4 w = uint4(insert_bits((~147u), madsat((v2 ^ t), in[(t * 4u + 2u)], (v4 ^ t)), (uint)((uint)((ushort)(v0) >> ((v0 ^ t) & 7u)) & 15u), (uint)((uint)(pc[(v1) & 7u]) & 15u)), v2, ((uint)((int)((char)(9u))) - (uint)(pc[(in[(t * 4u + 2u)]) & 7u])), v2); w[((median3(v1, 65536u, (v2 ^ t)) | rotate(210u, in[(t * 4u + 1u)]))) & 3u] = ((uint)((ushort)(in[(t * 4u + 2u)]) >> (in[(t * 4u + 0u)] & 7u)) & rotate(in[(t * 4u + 1u)], (v5 ^ t))); v2 += w[((uint)((int)((in[(t * 4u + 1u)] >> ((v2 ^ t) & 31u))) % (int)(((uint)((ushort)(1u) >> (in[(t * 4u + 3u)] & 7u)) | 1u) & 0x7fffffffu))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        if ((((uint)(pc[((uint)((int)(v3) % (int)(((v4 ^ t) | 1u) & 0x7fffffffu))) & 7u])) & 3u) == 0u) break; } v5 += n0; }\n"
    "    { tg[l] = min3(max((v5 ^ t), (v0 ^ t)), (uint)((short)(v4)), (uint)(select((int)(v4), (int)(v3), (in[(t * 4u + 1u)] & 2u) != 0u))); threadgroup_barrier(mem_flags::mem_threadgroup); v0 += tg[(v4) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    if (255u > (uint)((uchar)((uint)((ushort)(in[(t * 4u + 3u)]))))) {\n"
    "    }\n"
    "    { tg[l] = (uint)((int)((in[(t * 4u + 1u)] >> (v1 & 31u))) % (int)((in[(t * 4u + 1u)] | 1u) & 0x7fffffffu)); threadgroup_barrier(mem_flags::mem_threadgroup); v2 += tg[((uint)(pc[((v3 ^ t)) & 7u])) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    switch ((insert_bits(((uint)((int)((char)(in[(t * 4u + 2u)]))) * in[(t * 4u + 1u)]), (v1 / (v4 | 1u)), (uint)(((197u & 1u) != 0u ? (v1 ^ t) : (v5 ^ t)) & 15u), (uint)((uint)(min((int)((v5 ^ t)), (int)(v0))) & 15u))) & 3u) {\n"
    "    case 0u: {\n"
    "        break; }\n"
    "    case 1u: {\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            v1 = (uint)(pc[(((uint)((uchar)(in[(t * 4u + 2u)]) * (uchar)(in[(t * 4u + 2u)])) << ((in[(t * 4u + 0u)] >> (255u & 31u)) & 31u))) & 7u]);\n"
    "            if ((((290058566u >> ((uint)((uchar)((v2 ^ t))) & 31u))) & 3u) == 0u) break; } v3 += n1; }\n"
    "        }\n"
    "    case 2u: {\n"
    "        v3 = (uint)((ushort)(v1) >> ((uint)(max((int)((uint)((ushort)((v0 ^ t)) >> (in[(t * 4u + 3u)] & 7u))), (int)((uint)((uchar)(v2))))) & 7u));\n"
    "        break; }\n"
    "    default: {\n"
    "        break; }\n"
    "    }\n"
    "    { tc[l] = (uchar)((uint)((int)(((v2 & 1u) != 0u ? in[(t * 4u + 0u)] : 31u)) >> (int)(in[(t * 4u + 2u)] & 31u))); threadgroup_barrier(mem_flags::mem_threadgroup); v5 += (uint)(tc[(231u) & 63u]) * 280u; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    { tg[l] = popcount((uint)(select((int)((v3 ^ t)), (int)(1420832813u), (255u & 2u) != 0u))); threadgroup_barrier(mem_flags::mem_threadgroup); v5 += tg[(extract_bits(rotate(in[(t * 4u + 2u)], 2u), (uint)(mulhi(220u, 145u) & 15u), (uint)(((v4 ^ t) / (v5 | 1u)) & 15u))) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    switch ((extract_bits(min3(v4, v3, (v4 ^ t)), (uint)((uint)((int)((v4 ^ t)) % (int)((2096784434u | 1u) & 0x7fffffffu)) & 15u), (uint)((uint)(select((int)(v5), (int)(v4), (4073427928u & 2u) != 0u)) & 15u))) & 3u) {\n"
    "    case 0u: {\n"
    "        break; }\n"
    "    case 1u: {\n"
    "        break; }\n"
    "    default: {\n"
    "        break; }\n"
    "    }\n"
    "    for (uint i0 = 0; i0 < 3u; i0++) {\n"
    "    }\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        if ((((uint)((ushort)((uint)(min((int)((v1 ^ t)), (int)(in[(t * 4u + 2u)])))) + (ushort)(v4))) & 3u) == 0u) break; } v3 += n0; }\n"
    "    switch ((insert_bits(mulhi(v0, (v5 ^ t)), ((uint)((int)((short)(v4))) ^ (v2 ^ t)), (uint)((v1 & (v4 ^ t)) & 15u), (uint)(((int)(in[(t * 4u + 0u)]) >= (int)((v3 ^ t)) ? v4 : (v3 ^ t)) & 15u))) & 3u) {\n"
    "    case 0u: {\n"
    "        }\n"
    "    case 1u: {\n"
    "        break; }\n"
    "    default: {\n"
    "        break; }\n"
    "    }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 8u + 3u] = v3;\n"
    "}\n";

// out[t * 8 + w] for each thread t and w in kWords, from the CPU reference (cpuref.py) on the same input
static const int kWords[] = {3};
enum { kNumWords = sizeof kWords / sizeof *kWords };
static const uint32_t kExpected[256 * kNumWords] = {
    0x12941a4cu, 0x000000feu, 0x335a3e80u, 0xef5264c6u, 0x0a23c33eu, 0xe2d18a95u, 0xe4284be0u, 0x0000000au,
    0x00000438u, 0x000001e1u, 0x000001f7u, 0x31bff511u, 0x6d2c560cu, 0xb019589cu, 0x000003a6u, 0x00000581u,
    0x0000000du, 0x77b13955u, 0x00000459u, 0x0000016eu, 0x00000fb2u, 0x00004c6fu, 0x000003ddu, 0x8e48feaeu,
    0x0000014fu, 0x00000008u, 0x180bbff7u, 0xe1eaafb8u, 0x84923eecu, 0x0000004fu, 0x00003c62u, 0x00002357u,
    0x94ff9705u, 0xa4f7a894u, 0x9d33fb6fu, 0x00001633u, 0x0000024eu, 0xb960e7b4u, 0x1b0bacffu, 0x7bd52844u,
    0x9c23e924u, 0x7c34a6bcu, 0x00000001u, 0x000002b0u, 0x000000e1u, 0x00001829u, 0xeebccf5cu, 0x5257ce71u,
    0xf7fae5a9u, 0x0000148du, 0x00000009u, 0x00003270u, 0x00000672u, 0x0bd6b672u, 0x00000031u, 0x0000002fu,
    0x428b37b1u, 0x00000709u, 0x00007b24u, 0x73022a7au, 0x0000535au, 0x7aa90338u, 0xe3c375d9u, 0x0bc114f5u,
    0x00000d8au, 0x1be5d361u, 0x00001ce7u, 0x15848b31u, 0x0000004cu, 0x00000475u, 0x88a77b9au, 0x00000234u,
    0xcfae3879u, 0x1299c56au, 0x00000812u, 0x77a61c04u, 0x00000013u, 0xa9a6ea94u, 0x0000e7b5u, 0x00000009u,
    0x432a8c4cu, 0x0000f13du, 0x2dec5395u, 0xfbbdae85u, 0x000000aeu, 0x0000040eu, 0x00000012u, 0xe9b608f1u,
    0x00000550u, 0x0eba5106u, 0x00007dc4u, 0x90d4f936u, 0x00000008u, 0xaa6f919du, 0x9bb8bc30u, 0x0000cb2cu,
    0xf0a1bf69u, 0xdcf24a93u, 0x904490c0u, 0x00004d60u, 0x00001c0au, 0x00005f3cu, 0x65c3c4f6u, 0x61ba0155u,
    0x00000bebu, 0x4bc34442u, 0x000002dau, 0x4243babdu, 0x00000110u, 0xcf7f3c3au, 0xc5510d3fu, 0x00000008u,
    0xdc29371du, 0x000001fdu, 0x00000ab8u, 0x2febd01fu, 0x00002c3au, 0x90eaec69u, 0x00000080u, 0xef290a98u,
    0x00001999u, 0x2488a24cu, 0x000002b0u, 0x82225408u, 0xabae234bu, 0x96c32416u, 0xaed77212u, 0x00000017u,
    0x3ba71a4cu, 0xfd754f63u, 0x574da81fu, 0x00000004u, 0xa152bcb9u, 0x2865ad49u, 0x0000016eu, 0x2a122ddeu,
    0x7aef6420u, 0x000001b5u, 0x4b0ea185u, 0xbc86dedbu, 0x00000008u, 0x00007fafu, 0x00000008u, 0xf8925cceu,
    0xb34b5c76u, 0x3d95bc5eu, 0x9c9291cdu, 0x0000075au, 0x0000024du, 0x37f11645u, 0x0000000bu, 0x0000152bu,
    0xcb8a31cbu, 0x00000007u, 0x00000008u, 0x000005e3u, 0x000000b5u, 0x000021beu, 0x00009cd4u, 0xe9dfd638u,
    0x6dbb89eeu, 0xfd626f65u, 0x00000374u, 0x70ac549bu, 0xa5fe0313u, 0x0000055eu, 0xdac0a5aau, 0xb27b6de6u,
    0x0000029eu, 0x00000709u, 0xe0294c62u, 0xf061715du, 0x58594c32u, 0xc35af4a0u, 0xde93f8feu, 0xc8a58892u,
    0x000003c8u, 0x000002d8u, 0x13776298u, 0x00001735u, 0xc42491b9u, 0xd1300016u, 0x73d7b389u, 0x00000109u,
    0x00000052u, 0xc8d9380au, 0x54101004u, 0x0000000eu, 0xe7b7ed59u, 0x00002566u, 0x00001976u, 0x00000009u,
    0x000057a3u, 0x63c1ab33u, 0x63c98b57u, 0x7e18ddf0u, 0x00000009u, 0x00000352u, 0xac277ccbu, 0x00000157u,
    0x0000001eu, 0x00000012u, 0x032e4075u, 0x0000000fu, 0x00000702u, 0x595228f9u, 0x0000017eu, 0xecd7b4d7u,
    0x35834034u, 0xfaecbe1bu, 0x00000275u, 0x000001c1u, 0xbfbde503u, 0x63c22813u, 0x00003e80u, 0xb12e7158u,
    0x00000869u, 0xb3af7c26u, 0x000015d7u, 0xb5883091u, 0x061f3cb6u, 0xc8baf523u, 0x00000016u, 0x5ce1ca87u,
    0x89b8e2fau, 0x00000710u, 0x00000008u, 0x00000058u, 0x6a6ba364u, 0x00000012u, 0x78acc397u, 0x0000004cu,
    0x0000044du, 0x00000017u, 0x0111669au, 0x59f8a414u, 0x00000050u, 0x86df0a7du, 0xd6764272u, 0x00000358u,
    0xa1c72fc5u, 0x00000f3au, 0x581895c8u, 0xd785f240u, 0x4a5e9f6au, 0x1f17fc1cu, 0x000007cau, 0xb3365d38u,
    0x00000009u, 0x3f3a7225u, 0x00000009u, 0x0000382du, 0x57f64fc1u, 0x00000629u, 0x00009db4u, 0xa2f3ff7eu
};

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i32-intel-narrow-mask-copies";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        enum { T = 256 };
        id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
        uint32_t x = 2654435761u + 12345u, *w = in.contents;  // the differential fuzzer's input, seed 1
        for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; w[i] = (i % 7 == 0) ? (x & 0xff) : x; }
        memset(out.contents, 0xcd, T * 32);
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:in offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreadgroups:MTLSizeMake(T / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint32_t *o = out.contents;
        int wrong = 0, first = -1;
        int firstWord = 0;
        for (int t = 0; t < T; t++)
            for (int k = 0; k < kNumWords; k++)
                if (o[t * 8 + kWords[k]] != kExpected[t * kNumWords + k]) { wrong++; if (first < 0) first = t, firstWord = k; }
        if (wrong)
            return FAIL(bug, "%s: %d results wrong (thread %d, out[%d]: %08x, want %08x)", name, wrong, first, kWords[firstWord],
                        o[first * 8 + kWords[firstWord]], kExpected[first * kNumWords + firstWord]);
        return PASS(bug, "%s: every result of the 256 threads matches the CPU reference", name);
    }
}
