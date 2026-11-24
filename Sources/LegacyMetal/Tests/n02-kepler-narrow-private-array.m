// n02-kepler-narrow-private-array: a load from a private uchar array must give the stored byte; the back end forwarded
// a stored 32-bit value without its mask (fuzz seed 575). Fix: GeForceAIRCompat NVAIR_NARROW_PRIVATE_ARRAY_FIX. Checks:
// the reduced fuzz kernel against the CPU reference (cpuref.py), 256 threads. Argument: GPU name (default: NVIDIA).
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
    "    v0 += (uint)(select((int)(insert_bits(((v1 ^ t) >> (254u & 31u)), (uint)(select((int)(in[(t * 4u + 2u)]), (int)(v1), (v2 & 2u) != 0u)), (uint)((uint)((uchar)(2u)) & 15u), (uint)(((int)(v4) > (int)(46u) ? 4294967295u : (v3 ^ t)) & 15u))), (int)(rotate((uint)((char)(v4)), (uint)(pc[(v5) & 7u]))), ((((0u & 1u) != 0u ? 255u : in[(t * 4u + 3u)]) - 2147483647u) & 2u) != 0u));\n"
    "    atomic_fetch_add_explicit(&ta, ((uint)((bool)((uint)(pc[(in[(t * 4u + 0u)]) & 7u]) & (uint)((bool)(v0 & 32u))))) & 255u, memory_order_relaxed);\n"
    "    if ((uint)(-(int)(((v5 ^ t) | (v5 ^ t)) & 0x7fffffffu)) < (uint)(min((int)((uint)(select((int)(65535u), (int)(v2), (in[(t * 4u + 1u)] & 2u) != 0u))), (int)(popcount(v3))))) {\n"
    "    } else {\n"
    "        v4 = absdiff((uint)((bool)((uint)(pc[(v3) & 7u]) & (v4 >> (v3 & 31u)))), (uint)(((long)((((ulong)((in[(t * 4u + 2u)] / (in[(t * 4u + 1u)] | 1u))) << 32) | (ulong)((uint)1u))) > (long)((((ulong)(mulhi(3888442553u, 735166297u)) << 32) | (ulong)((uint)((short)(87u)))))) ? ((((ulong)((in[(t * 4u + 2u)] / (in[(t * 4u + 1u)] | 1u))) << 32) | (ulong)((uint)1u))) >> 7 : ((((ulong)1u << 32) | (ulong)((uint)((short)(87u))))) >> 11));\n"
    "        v3 ^= (uint)(min((((ulong)((uint)((((((ulong)((uint)(pc[(v3) & 7u])) << 32) | (ulong)((uint)((uchar)(in[(t * 4u + 3u)]))))) * ((((ulong)(addsat(v3, in[(t * 4u + 3u)])) << 32) | (ulong)((v2 * v3))))) >> 22)) << 32) | (ulong)((uint)((ushort)(((int)(2u) >= (int)((v5 ^ t)) ? v0 : (v0 ^ t))) - (ushort)(insert_bits(v3, v5, (uint)(v2 & 15u), (uint)(in[(t * 4u + 1u)] & 15u)))))), (((ulong)(((uint)((bool)(205u & 655208222u)) <= (((v0 ^ t) & 1u) != 0u ? in[(t * 4u + 1u)] : in[(t * 4u + 2u)]) ? ((uint)((ushort)((v4 ^ t))) * (uint)((ushort)(in[(t * 4u + 0u)]))) : (uint)1u)) << 32) | (ulong)(popcount(v3)))) >> 16);\n"
    "    }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = v5;\n"
    "    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^ (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);\n"
    "    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);\n"
    "}\n";

// out[t * 8 + 3] for each thread t, from the CPU reference (cpuref.py) on the same input
static const uint32_t kExpected[256] = {
    0x12941a4bu, 0x70b000f6u, 0xd3523e78u, 0x1e4e64c5u, 0x4fb7c336u, 0x49727572u, 0xbeb1b427u, 0xd41fa8f5u,
    0x52040437u, 0x07dfabbfu, 0x7a98b3c0u, 0x24eff509u, 0xf3365604u, 0xa6a85894u, 0x85856652u, 0xe2730579u,
    0xb5677dcau, 0x2c80394du, 0xa6b1cb5au, 0x2828dee1u, 0xaade3a85u, 0x4a348b69u, 0x669203dcu, 0x917b0159u,
    0x41891c70u, 0xde794e4au, 0x7c4a4010u, 0x0622afb7u, 0x77843ee4u, 0x43c50047u, 0x20b2b69cu, 0x8a4d942bu,
    0xc17f96fdu, 0xa63da88cu, 0xf6b6fb6eu, 0x8886962eu, 0x696d024du, 0xb960e7acu, 0x4fbaacf7u, 0xf55e283cu,
    0x5ba3e91cu, 0x9dd8a6bbu, 0x8e174255u, 0x03d302a8u, 0x9262db17u, 0xac6dcfd4u, 0xeebccf54u, 0x8d55ce69u,
    0x7dbee5a1u, 0x366104e8u, 0x859f0675u, 0x32684a8eu, 0x35594ccbu, 0xa07db66au, 0x15583bd0u, 0xffcf9f84u,
    0x4b5337a9u, 0x82d40701u, 0xb6a51131u, 0xcf052a79u, 0xd920785cu, 0x7da90330u, 0xe3c375d1u, 0x0bc114edu,
    0xe8dbf959u, 0xd0e72ca6u, 0x835f6389u, 0x3fa88b30u, 0x1ef73498u, 0xa90cf791u, 0x8c4b7b92u, 0x3f0ff8f0u,
    0xd3623878u, 0x4e91c562u, 0xa65e101bu, 0xf35a1bfcu, 0x93e5820fu, 0x9662ea93u, 0x260a0437u, 0xe8a58669u,
    0xf1348c4bu, 0xa3ba9ad9u, 0xacf1ac72u, 0x2fb9ae84u, 0x975eaba7u, 0x8f000406u, 0x8cc97434u, 0xb24a08e9u,
    0xcf7a9c82u, 0x1f9150feu, 0x6d8427bfu, 0xaf28f92eu, 0xceb30621u, 0x6979919cu, 0xfd3fbc2fu, 0x129c9cdeu,
    0x6c254097u, 0x15874a8bu, 0xd7bc90b8u, 0x0cfc0747u, 0x32ea6537u, 0x59b2c361u, 0x9d05c4eeu, 0x4d4a014du,
    0x46f2c9c4u, 0x4598443au, 0x817b02d9u, 0x23cfbab5u, 0xaefdadbcu, 0x54693c32u, 0xd9060d37u, 0xa851eb7bu,
    0xc7093715u, 0x97d6035eu, 0xbe2cae4bu, 0x5166d017u, 0x54f9db18u, 0xc8aeec61u, 0x03ca4fbfu, 0xb6690a90u,
    0x74f000dau, 0xad64a244u, 0x6b13fee0u, 0x7e3a5400u, 0x9ff8234au, 0x4a64240eu, 0xba7b720au, 0x0000063du,
    0x64a2e5bbu, 0x7e9d4f5bu, 0xac37a81eu, 0xd72dd422u, 0xdd5b434eu, 0x9815ad41u, 0xfafd016du, 0x2a122dd6u,
    0x50669be0u, 0xd1b5c4fcu, 0xc366a17du, 0x41d92125u, 0xe47aaf0bu, 0x76dc013cu, 0x4726d2d2u, 0x7ed4a339u,
    0xadfc5c75u, 0xe5a143a9u, 0xb66191ccu, 0x9619ff74u, 0x4d520510u, 0xc1cd163du, 0x62290f1du, 0xf27ea548u,
    0xd77031c3u, 0x4788096eu, 0x04ebf893u, 0x46d805dbu, 0x2005a36du, 0xcfde6379u, 0xf6e84ec8u, 0x4aa3d630u,
    0xdc0089edu, 0xfb286f5du, 0x7948036cu, 0x917c5493u, 0x05e3030bu, 0x43ae3ca3u, 0x8162a5a2u, 0x16956ddeu,
    0xe5b4fe53u, 0xa8680701u, 0x4aa8b3a5u, 0xbd168eaau, 0x58594c2au, 0x323ef498u, 0xf6e90709u, 0x542e8891u,
    0x02c003c7u, 0xf3b81638u, 0x84ca9d6fu, 0xc61c1434u, 0x4aa691b1u, 0x0105fff1u, 0xa85cb381u, 0x0000046fu,
    0x1d3bc06au, 0x30273802u, 0x8ce80ffcu, 0x0b73e7f1u, 0x62bfed51u, 0xd1fad66du, 0x0ac906ecu, 0x59c3afb4u,
    0x00b5a0d7u, 0x902fab2bu, 0x06358b4fu, 0xd078dde8u, 0xc3390ba5u, 0xcc79074eu, 0x11857cc3u, 0xd7c0d5ecu,
    0xe8e70bddu, 0x6e6f21c4u, 0x46d0406du, 0x473b3d7du, 0xceee06fau, 0x37a928f1u, 0xda15291au, 0x5747b4cfu,
    0x23f5402cu, 0x037f41ecu, 0x0e7132cau, 0xa35b0303u, 0xa08ce4fbu, 0x6508280bu, 0xd0821110u, 0x649b7150u,
    0x132dfed1u, 0x9a267c1eu, 0x175801cfu, 0x0ab83089u, 0xc72f3caeu, 0x85c3f51bu, 0xe43d7cbbu, 0xcdeb3579u,
    0xff98e2f2u, 0x7454f8f7u, 0x38da45cfu, 0xbef7537bu, 0x9a4ca363u, 0xd255dec3u, 0xec32c396u, 0x16400d73u,
    0x75f80445u, 0xa8fa3c48u, 0x62f16692u, 0xb72ca413u, 0x954d4d0du, 0xeb090a7cu, 0x40f7426au, 0x47100350u,
    0x05432fc4u, 0x6b5b2f58u, 0x0b1b95c0u, 0xca4d0dc7u, 0x555b6096u, 0x1f17fc14u, 0x8cb6070fu, 0xea8e5d30u,
    0xe68c997cu, 0xcc7a721du, 0x18e71894u, 0xee6daa42u, 0x22d24fb9u, 0xb8550628u, 0x75ada2fdu, 0x94f3ff76u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n02-kepler-narrow-private-array";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
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
    const uint32_t *got = out.contents;
    int wrong = 0, first = -1;
    for (int t = 0; t < T; t++)
        if (got[t * 8 + 3] != kExpected[t] && !wrong++) first = t;
    if (wrong)
        return FAIL(bug, "%s: %d of 256 threads wrong (thread %d: %08x, want %08x)", name, wrong, first, got[first * 8 + 3], kExpected[first]);
    return PASS(bug, "%s: every result of the 256 threads matches the CPU reference", name);
}}
