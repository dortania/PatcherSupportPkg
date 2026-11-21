// n38-kepler-subtracted-not (Kepler adapter, NVAIR_SUB_NOT_FIX): x - ~v0, with ~v0 also feeding a 64-bit shift amount.
// tc[((uint)(int)(char)mulhi(c, x) - ~v0) & 63] read the slot 2 below the right one on 255 of 256 threads, in a kernel
// that also shifted a 64-bit value by an amount computed from the same ~v0 (mslfuzz2.py VEC=1 ASTYPE=1 LONG=1 seed 1170,
// reduced to this kernel). The back end folds the not into the subtraction and computes x + v0 - 1 instead of x + v0 + 1;
// the fix gives it x + (v0 + 1). The kernel on the fuzzer's inputs (seed 1, 256 threads in groups of 64, compiled without
// fast math, as the fuzzer does): each thread's 8 output words against the CPU reference (cpuref.py), as one FNV-1a hash
// per thread.
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
    "    uint dbg0 = 0xdeadu, dbg1 = 0xdeadu;\n"
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
    "    v2 = (uint)((long)((((ulong)(vf((((short2((short)(1u), (short)(1u)) & short2((short)(1u), (short)(1u))) & as_type<short2>(char4((char)(1u), (char)(1u), (char)(1u), (char)(1u))))))) << 32) | (ulong)((uint)((long)((((ulong)((uint)(max((int)(v1), (int)(v4)))) << 32) | (ulong)((uint)(max((int)(v3), (int)(65536u)))))) >> (rotate((v1 ^ t), in[(t * 4u + 0u)]) & 63u))))) >> ((uint)((bool)((~v0) & (uint)((int)(1906362748u) >> (int)(in[(t * 4u + 0u)] & 31u)))) & 63u));\n"
    "    { tc[l] = (uchar)(vf((((short2((short)(in[(t * 4u + 3u)]), (short)(1u)) % short2((short)(979), (short)(1u)))).yx))); threadgroup_barrier(mem_flags::mem_threadgroup); v3 += (uint)(tc[(((uint)((int)((char)(mulhi(4203593411u, in[(t * 4u + 1u)])))) - (~v0))) & 63u]) * 46u; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    dbg0 = v0 ^ (v1 * 0x9e3779b1u) ^ (v2 * 0x85ebca6bu); dbg1 = v3 ^ (v4 * 0x9e3779b1u) ^ (v5 * 0x85ebca6bu);\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = dbg0;\n"
    "    out[t * 8u + 6u] = dbg1;\n"
    "    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);\n"
    "}\n";

// FNV-1a of each thread's 8 words (bytes in little-endian order), from cpuref.py's output for this kernel and input seed 1
static const uint32_t want[256] = {
    0x644382dau, 0xdd3fc87bu, 0xdd65ad0bu, 0xf175613du, 0x5e7b44e4u, 0xe9cdbc9fu, 0xe31d38d3u, 0xf9b982cau,
    0x5af2c6f5u, 0x652e1e36u, 0xf5fad9e9u, 0xbd0db03cu, 0x03e2dc94u, 0x94a82d16u, 0x40be1f91u, 0x819ef3f9u,
    0x95bd09eeu, 0x1d3b4044u, 0xe2ab0437u, 0x7b6e832cu, 0x594b8d80u, 0x6c950ff1u, 0xb8f9e710u, 0xac378213u,
    0x01c6f519u, 0xd21b781au, 0xdf458ae6u, 0x6f3b4bbeu, 0xc0a73649u, 0xf98a32afu, 0x5382aa68u, 0x5a8dcd69u,
    0x6ee1ff02u, 0x2452e7f7u, 0x6980f450u, 0x5e498cd4u, 0x2a8f5cbdu, 0x436bc6a5u, 0xe47ae86au, 0xff3a1852u,
    0x5e37b980u, 0x7eb3e25au, 0x464efdc7u, 0xb0833dfbu, 0x9a5c9273u, 0x2357f616u, 0xb36f23b8u, 0x46e64468u,
    0x6fd3a3ffu, 0x0e33814bu, 0x4b27e423u, 0xda9481feu, 0x1d3b768cu, 0x1a7d2bcbu, 0x7daec2b3u, 0x6872dce7u,
    0xd2d8d299u, 0x0677263au, 0x0276060fu, 0xf549f851u, 0x22c93fddu, 0x267a0ef6u, 0x272a81acu, 0xee35ff81u,
    0x5e78a9d4u, 0xb9ff791du, 0x3f74ef76u, 0x3d587062u, 0x0cdd1433u, 0x41122ca4u, 0xc09e9a25u, 0x0afcfa16u,
    0x92b104e9u, 0xc232ef3du, 0x4c0f94aau, 0x11791f18u, 0x472a5144u, 0x125219b4u, 0xf68ba491u, 0x32554a2bu,
    0x0f0f9917u, 0x5c36890bu, 0x3388fd47u, 0x297158f3u, 0x6aa0e8e7u, 0xad8de998u, 0x3943e34bu, 0xd11299dau,
    0x6cc6e3dau, 0xae0922f9u, 0xee062d5cu, 0xc2a6b509u, 0x21a289fbu, 0x0bfd2280u, 0x1629b97cu, 0xb6ffdf5bu,
    0x633ae3bfu, 0x7077f11au, 0x24409524u, 0xa8d7f53bu, 0xb346f5c2u, 0x0d453c94u, 0x0cdca164u, 0x277665a4u,
    0xd16e782eu, 0x68100850u, 0x7150f21fu, 0x8e188947u, 0x812dc4eeu, 0xdd628294u, 0xf5d8cd78u, 0x7df53b41u,
    0x9d94b4e7u, 0xc675411du, 0x02f9c6aau, 0x2d759ffdu, 0x83a45e30u, 0xdfeae90cu, 0x9de21429u, 0xa417367fu,
    0x28549174u, 0xf33dcf31u, 0xa493ef4cu, 0xdd25921bu, 0xeff25390u, 0x74056d9fu, 0xa2df9db3u, 0xf4c972e0u,
    0xb3b13eecu, 0xa9a8b49cu, 0x2aafcec3u, 0x66649862u, 0x3368544cu, 0x3c043c06u, 0xe9af5188u, 0x440e5d28u,
    0xc93912a1u, 0x2cf61382u, 0x5e5ed975u, 0x4b2f12d7u, 0xa22d3af0u, 0xde7e0dd5u, 0x4ced9629u, 0x2b859812u,
    0x421b52a8u, 0x259368e4u, 0x65881948u, 0xf94ca3fbu, 0xcfecbdb8u, 0xe84b72cdu, 0x6f2ca424u, 0xadaad9cbu,
    0x3b6fd76fu, 0x74d6ae8au, 0x44c96da2u, 0x7f2f7281u, 0x7760a817u, 0x9b1770dfu, 0xb33ac827u, 0xe1773939u,
    0xfefe2b08u, 0x50002618u, 0xe1f6ac46u, 0xb3222367u, 0x9a96c02cu, 0x7703410eu, 0x1b2972dcu, 0xbfd434a3u,
    0x75c380c9u, 0x59b7a4c2u, 0x913d6732u, 0x422637abu, 0xaae89ad9u, 0xe552c1d1u, 0xe3b1ff73u, 0xd996a282u,
    0x28957402u, 0x1db338c5u, 0x86e5ac77u, 0xf66f729eu, 0xbdfd069au, 0xf053e953u, 0x5b68a2b8u, 0x326059e6u,
    0xf644f660u, 0x769097d1u, 0x53f8decdu, 0xc18be477u, 0xc8da70abu, 0x5616fc5fu, 0xedd85663u, 0x9c5a9c38u,
    0x8ece4954u, 0x8d1af90au, 0x7bf71137u, 0xdf3d5851u, 0xc643988fu, 0x196d527fu, 0xa3f1c6b1u, 0x58d89974u,
    0xe22a1d37u, 0x97115627u, 0xad8eb88bu, 0x974e54f1u, 0xc1c3433fu, 0xedec06ecu, 0xf20686efu, 0x2763b09au,
    0xd52493d2u, 0x9bb5f658u, 0x2e37d4c2u, 0xb09ba925u, 0xceac3f37u, 0xe31ca6c5u, 0x98583bddu, 0x68f5a2eau,
    0x6c535fb8u, 0xc99c2037u, 0x6b4cd0e5u, 0x9d493fc6u, 0x985ee5fau, 0x7cb043e1u, 0xd73c7459u, 0x7f33091cu,
    0xd0bc296fu, 0xe2ba9644u, 0x55ce14b5u, 0x4e741a49u, 0x315d1a3bu, 0x102fe968u, 0x91bf4469u, 0xd143645bu,
    0xc231e8f7u, 0xb6d2f7e1u, 0xc904c0a6u, 0x4e100a62u, 0x351aeebau, 0xe12305a8u, 0x9be73495u, 0x50800ac1u,
    0xa098e8e0u, 0x52541d23u, 0xea363bbdu, 0x36d41132u, 0xf1d1ce7fu, 0xc9eb39ddu, 0x2ab90b7au, 0x88a47d4bu,
    0xc09fb706u, 0x7d271b64u, 0xfe3f6872u, 0x6fe59244u, 0xcaac51ffu, 0xe5306188u, 0xb80d1a02u, 0x69f5ddb5u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n38-kepler-subtracted-not";
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
    return PASS(bug, "%s: x - ~v0 is right next to a 64-bit shift by an amount from the same ~v0", name);
}}
