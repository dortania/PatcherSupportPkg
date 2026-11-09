// i43-intel-narrow-mask-shift (Intel adapter, INTEL_NARROW_MASK_FIX): i32's rewrite of a narrow mask. i32 turns an AND
// 0xFF / 0xFFFF over a narrower AND into a 32-bit form; it used to be SHL 24 / SHR 24, and where the source was itself a
// narrow AND (AND 0xFF over x & 3, from `vf(uchar3(...) % uchar3(3)) & 3` in a loop's exit test), iCBE kept that source
// in a byte register, the SHL lost it, and the exit test compared against 0: the loop count came out wrong in 171 of
// 256 threads (mslfuzz2 VEC=1 seed 1111, reduced). Now it is (x | bit 31) & (mask | bit 31), then bit 31 XORed away.
// Expected values from the CPU reference (cpuref.py) on the fuzzer's input. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU
// name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "static uint vf(uchar2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "static uint vf(uchar3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }\n"
    "static uint vf(uchar4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
    "static uint vf(char2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "static uint vf(char3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }\n"
    "static uint vf(char4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
    "static uint vf(ushort2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "static uint vf(ushort3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }\n"
    "static uint vf(ushort4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
    "static uint vf(short2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "static uint vf(short3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }\n"
    "static uint vf(short4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
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
    "    uint v4 = in[(t * 4u + 0u)] * 9u + t;\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        if (((vf((((uchar3((uchar)(123), (uchar)(162), (uchar)(188)) & uchar3((uchar)(min(32u, (v4 ^ t))), (uchar)(absdiff(v0, 3828903791u)), (uchar)(hadd(24u, 4294967295u)))) % (((uchar3((uchar)(48), (uchar)(242), (uchar)(167)) / uchar3((uchar)(21), (uchar)(90), (uchar)(80)))) | uchar3((uchar)(1), (uchar)(1), (uchar)(1))))))) & 3u) == 0u) break; } v1 += n0; }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 8u + 1u] = v1;\n"
    "}\n";

// out[t * 8 + 1] for each thread t, from the CPU reference (cpuref.py) on the same input
static const uint32_t kExpected[256] = {
    0x855dc325u, 0x0b5eb09bu, 0x809fb1d1u, 0xc0f21e38u, 0xc25af916u, 0x0000007bu, 0xad6112dau, 0x3e32d33cu,
    0x7adb18f2u, 0xb0d3766du, 0xdb6cf7e9u, 0x93c8ccb1u, 0x00000221u, 0x693df45cu, 0x7c3139ecu, 0xfabd65a6u,
    0xf8684d17u, 0x1bbfbf07u, 0x46b18a31u, 0x0000016eu, 0x27233eaau, 0x3b5198e4u, 0x3cf2fd2cu, 0x8158d180u,
    0xe697a3e7u, 0x5fa2fa3cu, 0x0000011eu, 0xb6da4a70u, 0x1cbc0dc0u, 0xee9c07a2u, 0x9a2778b5u, 0x24d746b4u,
    0xfa03c29bu, 0x000001d6u, 0xeb4cb13fu, 0x90c6b159u, 0x86763d56u, 0x862da32fu, 0xbf792469u, 0xf708eb70u,
    0x00000201u, 0xa622e5afu, 0xa0bdccd7u, 0x826350a6u, 0xd5cff94du, 0x4be6c117u, 0x2facb888u, 0x0000003cu,
    0x7304bb3cu, 0x57e1a434u, 0xdca0a9e4u, 0xaf38c9a9u, 0x46e7cd4bu, 0x90a995a3u, 0x000000adu, 0xb43a09e9u,
    0x0333402cu, 0xeeb2385du, 0xbec0f640u, 0xab3784c4u, 0xf7e45353u, 0x00000287u, 0x064d7f3cu, 0x3dcab900u,
    0x041fd82eu, 0xbb8ef6f1u, 0x83cd737du, 0x23124717u, 0x0000008au, 0xe8e746dau, 0xf960fc8cu, 0xc13d8cfau,
    0xb7ed1308u, 0x78d4be94u, 0xa3d68116u, 0x00000227u, 0xee1cfb5bu, 0xed5663b6u, 0x6a4ae7bcu, 0x25e9fcf2u,
    0xb285566au, 0x6522f144u, 0x0000029au, 0x80280746u, 0xc18d0a75u, 0xefda7b95u, 0x84ab8c62u, 0x3f80529au,
    0x42772a4du, 0x000002dcu, 0x6e3a7dc4u, 0x71ce70c4u, 0x0252fe8fu, 0xb443b03du, 0x8847f9deu, 0x0643cb2cu,
    0x0000024du, 0xb86885edu, 0x11a25dcbu, 0x42fa9ab9u, 0xfd807012u, 0x97cbbe7eu, 0x88fac9f6u, 0x00000204u,
    0x41a8be3bu, 0x3ad70532u, 0x1f59faf3u, 0x491c8f8fu, 0x5c914222u, 0x4b17604au, 0x000001d2u, 0x40666628u,
    0x20ca832cu, 0x8199faf4u, 0x7cf5ab0au, 0x67e98321u, 0x9d2f2c3au, 0x0000008eu, 0xebcabd51u, 0x6fc15d0bu,
    0x3942cc92u, 0x676cacedu, 0x36bb55f6u, 0x396ce56bu, 0x000001dau, 0xd520194au, 0xbc25f3fdu, 0xf688249cu,
    0x831f016fu, 0x1b0621a1u, 0x7926ade7u, 0x000002f8u, 0x799cfb55u, 0x65e27b35u, 0x1389406bu, 0x1b756834u,
    0x6be04937u, 0x93676d32u, 0x0000023bu, 0x86220a86u, 0x33ee54d3u, 0x696bff65u, 0xe1645698u, 0x779152ccu,
    0x7287853fu, 0x00000314u, 0xc4cee77eu, 0xe1cdea54u, 0x3bf024d2u, 0x021b2e61u, 0x384c26cbu, 0x72dda920u,
    0x000000eeu, 0x80583784u, 0x421b4619u, 0x7ebdf7eeu, 0x5d2a3cb5u, 0x202d436du, 0xfdea9cd4u, 0x000001cdu,
    0x5f847da5u, 0xfaf349d2u, 0x1bf9111du, 0xc54ef8e5u, 0x797d765au, 0xb60eaac8u, 0x0000014au, 0xaaa36936u,
    0x9924a5a5u, 0x9ae0095du, 0x98d17970u, 0x2cd7a515u, 0xa66b0556u, 0x0000036du, 0xbf808a68u, 0xcbf0f393u,
    0xf5826cfdu, 0x6f42b42bu, 0xed93409du, 0x4bd15cbdu, 0x000000feu, 0x81fdc32eu, 0x23d0e0a4u, 0x57d08088u,
    0x10e6b03bu, 0x4e7ebdf5u, 0x55c54404u, 0x00000195u, 0xc5710abau, 0xa1572566u, 0x536bcb7cu, 0x0589680au,
    0x9025af3eu, 0xe31d1ac6u, 0x0000020au, 0xa66611b5u, 0x17cfb404u, 0xe14ed297u, 0xa8247525u, 0x4d4e0abcu,
    0x724eb2e9u, 0x00000110u, 0x6e8bbaaeu, 0x6ddd6576u, 0x3c6d9341u, 0x7a23f3a6u, 0x85292fb8u, 0x5d20c9bcu,
    0x00000150u, 0x19be0722u, 0x070526dfu, 0x2eb5dcfdu, 0x2a69da11u, 0x17654eb9u, 0x75613e79u, 0x0000029eu,
    0x8b328626u, 0x9398aff8u, 0x9a91aebcu, 0x5ba0c9f3u, 0xd9e1b963u, 0xf51cc5cdu, 0x000000e9u, 0x099dcad4u,
    0x6e50576cu, 0x5ec11a86u, 0x5d90958du, 0x7489a8aeu, 0x0468956cu, 0x0000028bu, 0x1077a8a4u, 0x89acca8au,
    0x36966f41u, 0xb4beb491u, 0x4edb37aau, 0xbb1587a7u, 0x0000012au, 0x4a01d89au, 0x18f6804fu, 0xb9d7e7d7u,
    0xe2f9efc0u, 0x2d63f32bu, 0x135b365au, 0x00000292u, 0x63bdaf44u, 0x3ec59f63u, 0x2f26f855u, 0x6ea062bcu,
    0xea21b9c1u, 0xbe1be874u, 0x0000029du, 0x769f705au, 0xd3735324u, 0x8434b827u, 0xc1449dbbu, 0x427230a2u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i43-intel-narrow-mask-shift";
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
    for (int t = 0; t < T; t++) if (o[t * 8 + 1] != kExpected[t] && !wrong++) first = t;
    if (wrong) return FAIL(bug, "%s: %d of 256 loop counts wrong (thread %d: %u, want %u)", name, wrong, first, o[first * 8 + 1], kExpected[first]);
    return PASS(bug, "%s: every result of the 256 threads matches the CPU reference", name);
}}
