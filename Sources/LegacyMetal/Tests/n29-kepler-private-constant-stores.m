// n29-kepler-private-constant-stores (Kepler adapter, NVAIR_PRIVATE_CONSTANT_STORE_FIX): stores to a private array at a
// constant index, when the array is also written at a variable index later. A byte array filled by a loop the compiler
// unrolls (eight stores at constant indexes), then written at a variable index inside a loop and read at the end, read
// back slots' old values (mslfuzz2.py VEC=1 seed 2603, reduced: right with the constant-index stores at an opaque index,
// and with the array left in bytes, NVAIR_NARROW_PRIVATE_ARRAY_FIX=0; small kernels of the same shape were right). The
// reduced kernel on the fuzzer's inputs (seed 1, 256 threads in groups of 64, compiled without fast math, as the fuzzer
// does): each thread's 8 output words against the CPU reference (cpuref.py), as one FNV-1a hash per thread.
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
    "    for (uint i0 = 0; i0 < 4u; i0++) {\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            pc[((uint)((uchar)((in[(t * 4u + 3u)] / (219u | 1u))) % (uchar)(32u | 1u))) & 7u] = (uchar)(vf((min((ushort3((ushort)((uint)((int)(in[(t * 4u + 3u)]) / (int)((v2 | 1u) & 0x7fffffffu))), (ushort)((uint)(pc[((v5 ^ t)) & 7u])), (ushort)(max3(in[(t * 4u + 1u)], v5, v4))) % ((ushort3((ushort)((((v0 ^ t) % (735865967u | 1u)))), (ushort)(popcount((v0 ^ t))), (ushort)((uint)(pc[((v4 ^ t)) & 7u])))) | ushort3((ushort)(1), (ushort)(1), (ushort)(1)))), max(ushort3((ushort)(hadd(84714012u, v3)), (ushort)(extract_bits((v5 ^ t), (uint)(in[(t * 4u + 1u)] & 15u), (uint)((v0 ^ t) & 15u))), (ushort)(insert_bits(v5, v0, (uint)(v1 & 15u), (uint)((v5 ^ t) & 15u)))), ushort3((ushort)((uint)(-(int)(32u & 0x7fffffffu))), (ushort)((in[(t * 4u + 0u)] / ((v0 ^ t) | 1u))), (ushort)((uint)((bool)((v2 ^ t) & in[(t * 4u + 1u)])))))))));\n"
    "            if ((((uint)((uchar)((uint)((bool)(v5 & 60u))) >> ((uint)(!(v4 > v0)) & 7u))) & 3u) == 0u) break; } v5 += n1; }\n"
    "    }\n"
    "    { uint4 w = uint4(mulhi(v4, ((1726677284u & 1u) != 0u ? v1 : (v2 ^ t))), v1, 234u, v2); w[((reverse_bits(in[(t * 4u + 0u)]) << (((uint)((ushort)((v3 ^ t))) * (uint)((ushort)(595927600u))) & 31u))) & 3u] = (uint)(select((int)(((v0 % (85u | 1u)))), (int)(min3(31u, (v2 ^ t), 1521424794u)), (((uint)((int)((char)((v1 ^ t)))) ^ v3) & 2u) != 0u)); v3 += w[((uint)((int)((ushort)((uint)(min((int)((v5 ^ t)), (int)(in[(t * 4u + 1u)])))) >> ((uint)(pc[(in[(t * 4u + 3u)]) & 7u]) & 15u)))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    v0 = (reverse_bits(((v3 ^ t) ^ 1u)) < (uint)(min((int)(in[(t * 4u + 1u)]), (int)((uint)(max((int)((v3 ^ t)), (int)(4294967295u)))))) ? vf((char2((char)((uint)((uchar)(in[(t * 4u + 2u)]) >> (in[(t * 4u + 1u)] & 7u))), (char)((in[(t * 4u + 3u)] >> (2640230338u & 31u)))))) : vf((min((char4((char)(26), (char)(79), (char)(84), (char)(120)) >> char4((char)(4), (char)(5), (char)(4), (char)(0))), (char4((char)((uint)((int)(in[(t * 4u + 3u)]) % (int)(((v3 ^ t) | 1u) & 0x7fffffffu))), (char)(rotate(v1, in[(t * 4u + 3u)])), (char)(mulhi(in[(t * 4u + 1u)], v5)), (char)((3048814845u / (in[(t * 4u + 2u)] | 1u)))) & char4((char)(-83), (char)(22), (char)(-33), (char)(91)))))));\n"
    "    { uint4 w = uint4((uint)((int)(hadd(0u, 65535u)) / (int)(((v1 << 1u) | 1u) & 0x7fffffffu)), v3, vf((ushort3((ushort)(49428), (ushort)(40570), (ushort)(49437)))), v5); w[((~(~(v1 ^ t)))) & 3u] = (uint)(all((char2((char)((uint)((int)((v2 ^ t)) % (int)((v2 | 1u) & 0x7fffffffu))), (char)(((uint)((ushort)((v4 ^ t))) * (uint)((ushort)(3701298002u))))) & char2((char)(((v3 ^ t) * v3)), (char)(((uint)((int)((short)(in[(t * 4u + 2u)]))) ^ in[(t * 4u + 2u)])))) < char2((char)(12), (char)(10)))); v0 += w[(((((int)((v5 ^ t)) <= (int)((v3 ^ t)) ? v2 : 2731521293u) & 1u) != 0u ? rotate(v1, in[(t * 4u + 0u)]) : (uint)(pc[(in[(t * 4u + 0u)]) & 7u]))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    v1 = (uint)((ushort)((uint)(max((int)((v1 ^ t)), (int)((uint)((short)(2474321163u)))))) - (ushort)((uint)((uchar)(mulhi(v3, v5)) >> (((v4 ^ t) ^ in[(t * 4u + 2u)]) & 7u))));\n"
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
    0xa23fddccu, 0x3a7c50d2u, 0x2dea2f65u, 0x427a2e40u, 0x7bf69729u, 0x3eb39375u, 0x340a86c3u, 0x35c5db26u,
    0xc8b90879u, 0x4b436381u, 0x4d3d4bc5u, 0x9fe6b31au, 0x5e53350cu, 0x938ac630u, 0xf89c4fadu, 0xeb9eac86u,
    0x78002e84u, 0x91725af3u, 0x4e9b2404u, 0x7f05453eu, 0xde038bdau, 0xffaf031cu, 0xc89df75du, 0x1228939au,
    0x7c446d25u, 0x27975888u, 0x6b570e34u, 0xd700a43au, 0x7add43d4u, 0xe7a547cfu, 0x2add793fu, 0xf4be5f09u,
    0x70eb9362u, 0xbcdfc7eau, 0x5346ab5cu, 0x42af30f5u, 0x0921f5f8u, 0x38529750u, 0xb8143f27u, 0x0fa63764u,
    0x7ed5a232u, 0xfe584b7au, 0xa91e2a6eu, 0x8bcc34feu, 0xaf2fbe98u, 0xe6b5dd13u, 0xff17bc1fu, 0x1b7a4a11u,
    0x939d848eu, 0xdb413b49u, 0xcb2efb05u, 0x524cc8d4u, 0x1adf61ccu, 0x7ed875c6u, 0x83ff70ddu, 0xbecd54f9u,
    0xd25d2082u, 0x2f953c47u, 0x3c1b9af2u, 0x1caa6077u, 0xb4155ff0u, 0x43777806u, 0x496a7dcfu, 0x35baa854u,
    0x50dc04f6u, 0x2b8165a0u, 0xee6c5e25u, 0x9ff48a2fu, 0x17fc592fu, 0x6d9bbea2u, 0x0eb3a32eu, 0x52ec74afu,
    0x23aa41f0u, 0x0e67ce89u, 0xa4562cbbu, 0xbb7a5d24u, 0xc4394d19u, 0xe9ef701cu, 0x781f7168u, 0x6d7469abu,
    0x14bb07e4u, 0xa03977c1u, 0xe6eedae3u, 0xc5571f1cu, 0x4a3f81e1u, 0x573cfc56u, 0xa813115du, 0x2fc2eda5u,
    0xe70cbedeu, 0xbc5294ddu, 0x0b30a237u, 0x5157ea2fu, 0x1efa73e9u, 0x261ab931u, 0x77202b49u, 0x6a97a898u,
    0x0b08198eu, 0x0f55b9b5u, 0x29461639u, 0x40c9d668u, 0xbfba7211u, 0xded8e27eu, 0x91c70cd4u, 0x8c0225ceu,
    0x33aa0330u, 0x8e76d116u, 0x9ffcaebeu, 0xbe784f37u, 0x5d289f18u, 0x012a3366u, 0x0f9aa848u, 0x34f24eefu,
    0x70c25906u, 0xdfdeb1dbu, 0x59fdf7e2u, 0xa2ec2ea3u, 0xf5042f12u, 0x91a15c57u, 0x231999b5u, 0x92e38f74u,
    0xf1876c42u, 0xc896e025u, 0x7c0c5d77u, 0x337346a6u, 0xdd2e3868u, 0xe7b04dd9u, 0xa4d7eaefu, 0x121281dfu,
    0x7cb51366u, 0xa3778158u, 0x4f4f8ce0u, 0xa5df0717u, 0x2517c440u, 0xa9def2a2u, 0xeea8c647u, 0x0ab6d37cu,
    0x704169ccu, 0x172585f4u, 0x7dc957b3u, 0x91edc155u, 0xb047afa1u, 0x400b2654u, 0x2181dfaau, 0x97d4e6ceu,
    0x4f0b17bfu, 0x168f2d29u, 0xb6058c0au, 0x78502452u, 0x1d4c5351u, 0x6a2b4864u, 0x80861335u, 0x375dd848u,
    0xa3feaf4eu, 0xd8eb53d2u, 0x7e5681fau, 0x59c8787cu, 0x500ab01fu, 0x71b6015fu, 0xc6facaaau, 0xcf22557bu,
    0xa881fe9cu, 0xd9ff86cdu, 0x0668e2e6u, 0x4f7e782au, 0xf78acae4u, 0x357715e4u, 0xf4a68b23u, 0x21df9ee1u,
    0xaeed1f48u, 0x7237d732u, 0x73202701u, 0x4df4e29fu, 0x3e46e7d8u, 0xb04efe5fu, 0xeaf0bfa0u, 0xc77a66cau,
    0xdd455764u, 0xc8232497u, 0x0e55d832u, 0xf505c2d0u, 0x67dcd311u, 0xb4861a6fu, 0x2e3a3b23u, 0xe2fc5b5fu,
    0xf482d68au, 0xce472d1bu, 0x2491864bu, 0xe9d4de14u, 0xf2f9f795u, 0x69357ed6u, 0xd1e7bd7du, 0x6f304e08u,
    0xb1e11752u, 0x7fbad226u, 0x058bec84u, 0xfdb57147u, 0xe50d3409u, 0x05473321u, 0x5f3cca24u, 0x4565c25du,
    0xb0a35805u, 0xbe2a18ccu, 0xf30e32a3u, 0xd3af535fu, 0x38516510u, 0x47e33919u, 0x5fa7efd0u, 0x8f8927bfu,
    0xa7697150u, 0x18750769u, 0x8577d94fu, 0x8929e67du, 0x952e2166u, 0xb054207bu, 0x43729dfdu, 0x8214a6aau,
    0xa4c624eau, 0x1a380c99u, 0xc911514au, 0x3bd4385cu, 0xf4c80c9bu, 0x77850237u, 0xce342de5u, 0xdbd98c9eu,
    0xde5f90d4u, 0xfcaa497eu, 0x48f01cbcu, 0x309a91d7u, 0x00409534u, 0xcf5e358cu, 0x7b66b17bu, 0x69da0d62u,
    0x65fe7882u, 0x3db5a117u, 0x2df23ba4u, 0x1c91c2f1u, 0xc813cb92u, 0x079c602eu, 0x3e230d5fu, 0xb7e86940u,
    0x4524dcf2u, 0xc96f0967u, 0x1510644cu, 0x4977454au, 0x587ea45cu, 0x033f22c2u, 0x88af1cb0u, 0x19dd3d0cu,
    0xf067559cu, 0x928c53f2u, 0xc43fffe5u, 0x038cc90bu, 0x18886c0bu, 0x05cb3f47u, 0x0e75ff0bu, 0x624f38f9u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n29-kepler-private-constant-stores";
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
    return PASS(bug, "%s: stores to a private array at a constant index are seen by the reads after its variable-index stores", name);
}}
