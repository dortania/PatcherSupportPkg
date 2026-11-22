// n41-kepler-narrow-compares (Kepler adapter, NVAIR_NARROW_COMPARE_FIX): equality and unsigned compares of 8-bit values. A
// loop that exits when two lanes of a uchar4 select are equal (vf(select(...)) & 3 == 0), reduced from mslfuzz2.py VEC=1
// ASTYPE=1 seed 13302: with the narrow vectors done lane by lane, the back end got icmp eq i8 (trunc i32 y), 0 and the
// icmp ne/ugt i8 compares of the lanes, and 198 of 256 threads came out wrong. The same condition with its compares in 32
// bits is right, while the same added code with the compares left 8-bit is not; the adapter now makes each such compare
// 32-bit. The kernel on the fuzzer's inputs (seed 1, 256 threads in groups of 64, compiled without fast math, as the
// fuzzer does): each thread's 8 output words against the CPU reference (cpuref.py), as one FNV-1a hash per thread.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
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
    "    uint v2 = in[(t * 4u + 2u)] * 5u + t;\n"
    "    uint v3 = in[(t * 4u + 3u)] * 7u + t;\n"
    "    uint v4 = in[(t * 4u + 0u)] * 9u + t;\n"
    "    uint v5 = in[(t * 4u + 1u)] * 11u + t;\n"
    "    for (uint i0 = 0; i0 < 5u; i0++) {\n"
    "        v0 += i0 * 1u;\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            v1 = vf((((char4((char)(1u), (char)(1u), (char)(1u), (char)(1u)) >> char4((char)(1u), (char)(1u), (char)(1u), (char)(1u))) & as_type<char4>(ushort2((ushort)(1u), (ushort)(1u))))));\n"
    "            v0 ^= p[((uint)(-(int)(((uint)((ushort)(1u)) * (uint)((ushort)(1u))) & 0x7fffffffu))) & 7u];\n"
    "            if (((vf(((select(uchar4((uchar)(1u), (uchar)(1u), (uchar)(1u), (uchar)(1u)), uchar4((uchar)(1u), (uchar)(1u), (uchar)((~(v3 ^ t))), (uchar)(madsat((v5 ^ t), (v2 ^ t), 215u))), uchar4((uchar)(1u), (uchar)(1u), (uchar)((uint)((int)(in[(t * 4u + 1u)]) / (int)((in[(t * 4u + 0u)] | 1u) & 0x7fffffffu))), (uchar)(1u)) > uchar4((uchar)(1u), (uchar)(1u), (uchar)(1u), (uchar)(((in[(t * 4u + 0u)] & 1u) != 0u ? in[(t * 4u + 3u)] : (v0 ^ t))))) & uchar4((uchar)(1u), (uchar)(1u), (uchar)(1u), (uchar)(1u)))))) & 3u) == 0u) break; } v0 += n1; }\n"
    "        { uint4 w = uint4(((65u >= (v4 ^ t) ? 1668322756u : v5) << (((37u % (in[(t * 4u + 3u)] | 1u))) & 31u)), v0, min3(v1, ((v0 ^ t) | 112u), (uint)((ushort)(1u) >> (2762721722u & 7u))), v5); uint wi = ((((v1 & 1u) != 0u ? v2 : v2) <= ((uint)((int)((short)(1u))) - 277754759u) ? (in[(t * 4u + 2u)] / (in[(t * 4u + 3u)] | 1u)) : (uint)(-(int)((v0 ^ t) & 0x7fffffffu)))) & 3u; uint wm = median3(mulhi((v5 ^ t), (v1 ^ t)), ((v2 ^ t) >> (42949835u & 31u)), rhadd((v4 ^ t), v2)); w = uint4(wi == 0u ? wm : w.x, wi == 1u ? wm : w.y, wi == 2u ? wm : w.z, wi == 3u ? wm : w.w); uint wj = ((uint)(-(int)(((v3 ^ t) >> ((v2 ^ t) & 31u)) & 0x7fffffffu))) & 3u; v4 += (wj == 0u ? w.x : (wj == 1u ? w.y : (wj == 2u ? w.z : w.w))) ^ (w.y << 1u) ^ w.w; }\n"
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

// FNV-1a of each thread's 8 words (bytes in little-endian order), from cpuref.py's output for this kernel and input seed 1
static const uint32_t want[256] = {
    0xbec89e96u, 0xb1b3fe01u, 0x779a713du, 0x7f1c6abdu, 0x43cb6f08u, 0xedb4bda9u, 0x410e8f76u, 0x3bc77fccu,
    0x766e1b1cu, 0x34db94d6u, 0xfebc4397u, 0x2e01e50bu, 0x0b342ceeu, 0xe624eaaau, 0xf0503ba7u, 0xd560c7bcu,
    0x15fe54eau, 0xf0257d44u, 0xba6b9f48u, 0x9b760438u, 0xe837bcdbu, 0x338a8426u, 0x0c998575u, 0xcdfcec7bu,
    0xd4cc9dc6u, 0x2fd060a8u, 0x61c3856cu, 0xe97031e6u, 0x3ad1776fu, 0x994fad30u, 0x7d37bca3u, 0x4aaa1d9eu,
    0x223c4377u, 0xc6ddecf2u, 0x663ee077u, 0x1ac18c00u, 0xcdf21529u, 0xfe652303u, 0xd45e6420u, 0xeca6246fu,
    0xf4202175u, 0x68e2a889u, 0xaa86c3a7u, 0x6be94239u, 0x8b4f789du, 0x243247f1u, 0x0fe524f7u, 0x009552aau,
    0xb03a1856u, 0xf40fb88fu, 0x743251adu, 0x3a632bc6u, 0x5fbe5946u, 0xb9739277u, 0xa8d1d009u, 0xae7bb11eu,
    0x593c8fdeu, 0xc675d390u, 0xaa921523u, 0xc7765576u, 0x9e97aa94u, 0x5ac2f89au, 0x01463774u, 0x897cc399u,
    0x59c70f51u, 0x212f8cf2u, 0x39991f75u, 0x683f1746u, 0x4473a2cbu, 0x5664af8au, 0x6ffa20a9u, 0x8e0e67beu,
    0x214c9363u, 0xd1edbd63u, 0x2781dad5u, 0x8ff0dc5bu, 0xe7b5f3d7u, 0xd9e3636cu, 0xbcb6936bu, 0x8c7ce57eu,
    0x78de7651u, 0x8cd92b08u, 0x5bfee8a8u, 0x2e458835u, 0xd7fd5ca5u, 0xfc4d0ca1u, 0x5d71bd43u, 0x736d2008u,
    0xbd1a3f74u, 0x578fedd2u, 0xf7d99577u, 0x72b61c66u, 0x6ef276a3u, 0xd0813e77u, 0x89265886u, 0x17e33cedu,
    0x1237a9f1u, 0xfbfbdd7eu, 0xfc311a36u, 0xaf5dca27u, 0x8de991d4u, 0x8e850528u, 0x0a6f8426u, 0xef9aaa8bu,
    0xe7ccc456u, 0x91f74dd9u, 0xd0f60446u, 0xa8aae775u, 0x1a41fd34u, 0x2da90605u, 0x4f327031u, 0x8ec7961fu,
    0x3951d1d2u, 0x8a8e1e3eu, 0xcc3a886du, 0x99091e61u, 0xf2da65d9u, 0xf8ded390u, 0x3585eb99u, 0xa8017ee6u,
    0x376cf4c5u, 0xe6f89bf5u, 0x3009ecf8u, 0xdacb058au, 0x73fff98du, 0x70cd3cc1u, 0x9a7ec2d2u, 0x18d7d083u,
    0xde7447fbu, 0x170b12c2u, 0x42ae3c25u, 0xa58e081au, 0x1b461576u, 0x2d9832ccu, 0x5e0f5c39u, 0x900450ddu,
    0x533f7e9du, 0x819b18dau, 0x4e863622u, 0x2f6d7134u, 0x180362a2u, 0x075edfc4u, 0x44f1f5d8u, 0x6d437d49u,
    0x9c7a2685u, 0xdbfab0b1u, 0xa374d61eu, 0x556daf69u, 0xb21c98c8u, 0x74ee921eu, 0x47a1601fu, 0x2a1f849fu,
    0xa43a5793u, 0x43a99608u, 0xf341fc67u, 0x53fb0f58u, 0x0935ff37u, 0x37cbab8fu, 0x694c5920u, 0x1f3c8356u,
    0xdb7e8e3eu, 0x6a528755u, 0xc1ca6f27u, 0x0d7b9953u, 0x89654b0au, 0xf1613490u, 0xb2fbbfb9u, 0x721422ddu,
    0xabb4b61fu, 0xb4c25ca0u, 0xea3a3073u, 0xb9251f8cu, 0xa5f06cddu, 0x2ba2f7f4u, 0xfd4a8841u, 0x916bb42au,
    0x66cd3b33u, 0x3f848e47u, 0x26186c32u, 0x6db0ba4au, 0xd81e99f6u, 0xf2e20252u, 0x48e2cbc4u, 0x30420edfu,
    0xa4dd2f50u, 0x218e6930u, 0x0ac7dee4u, 0xc2d88c31u, 0x9ca13938u, 0x407cb8d2u, 0x6f06d78du, 0xbd8ee683u,
    0xeb2f11e9u, 0xd2b2c75au, 0xde0a166cu, 0x3b5f1c22u, 0x027562e1u, 0x92b0381au, 0x32e2c61fu, 0xf48f5d46u,
    0x806af3c1u, 0x4d8a739cu, 0x7737debbu, 0xbee722a1u, 0x6bd8c7eeu, 0x16e2f6dcu, 0x6ac628dbu, 0x313f7d2fu,
    0x97816cb1u, 0x4f402d1eu, 0x97aca550u, 0x3bd9018eu, 0xf0904de6u, 0x52ea07adu, 0x6268f6dcu, 0x56ae0923u,
    0xcf3c3365u, 0x778ca1bau, 0xda6c58a1u, 0x1c918223u, 0x71078df1u, 0x73391046u, 0x9550cb62u, 0xe92b091fu,
    0x4c8f086eu, 0xc92070a8u, 0xa7d9d1beu, 0x144b0172u, 0x4982d3a9u, 0xbe57ae04u, 0x99ba588eu, 0x48dba343u,
    0xd68b34a2u, 0xe223f9d7u, 0xb22b2150u, 0xa254b38bu, 0xb40ca179u, 0xea88f6afu, 0x8c78dfc9u, 0x82832045u,
    0xb20979e6u, 0x40a22774u, 0x4f6ddc14u, 0x9d1b4633u, 0x8a34257fu, 0xf208bc82u, 0x947c0f97u, 0x44493dabu,
    0x07cfc7e2u, 0x680b8d37u, 0x94090c3du, 0xb9475dbfu, 0x425115efu, 0x43db748au, 0x2d0f9414u, 0x22a17eb0u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n41-kepler-narrow-compares";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;  // as the fuzzer compiles
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:options error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> in = [dev newBufferWithLength:T * 4 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:T * 8 * 4 options:MTLResourceStorageModeShared];
    uint32_t x = 1u * 2654435761u + 12345u;  // the fuzzer's inputs, seed 1
    for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; ((uint32_t *)in.contents)[i] = (i % 7 == 0) ? (x & 0xff) : x; }
    memset(out.contents, 0xcd, out.length);
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
    for (int t = 0; t < T; t++) {
        uint32_t h = 2166136261u;
        for (int w = 0; w < 8; w++)
            for (int b = 0; b < 4; b++) { h ^= (o[t * 8 + w] >> (8 * b)) & 0xff; h *= 16777619u; }
        if (h != want[t]) { wrong++; if (first < 0) first = t; }
    }
    if (wrong) return FAIL(bug, "%s: %d of %d threads differ from the CPU reference (first: thread %d)", name, wrong, T, first);
    return PASS(bug, "%s: compares of 8-bit lanes end a loop at the right iteration", name);
}}
