// n44-kepler-metal-array-constant-loads (Kepler adapter, NVAIR_ARRAY_STRUCT_FIX): n26-kepler-private-constant-loads's kernel with its private arrays written as
// metal::array<T, N>, as ANGLE writes every GLSL array (Chrome, Safari, Firefox WebGL): a struct holding the array, which
// reaches the back end as alloca {[N x T]} with GEPs (s, 0, 0, i) and slipped past the private-array fixes made for C
// arrays; they now see it as the plain array. Without the fix the original's bug is back.
// The original test's description follows.
// n26-kepler-private-constant-loads (Kepler adapter, NVAIR_PRIVATE_CONSTANT_LOAD_FIX): two loads of the same element of
// a private array at a constant index, with the array written at a variable index between them. The back end took them for
// one value: v5 = pc[0] before a loop that loads pc[0] again and stores pc[i] came out as the loop's last pc[0], even with
// every access to the array volatile (mslfuzz2.py seed 2136 on the GTX 770; also the cause of seeds 1413, 1523 and 1896 of
// the VEC=1 runs, long listed as Kepler limitations). The fuzzer's reduced kernel runs as it is and again with both loads
// at indexes the back end can't fold, (thread position >> 31) and ((thread position + 1) >> 31), always 0 (one shared 0
// still left the two addresses alike to the back end); the two must give the same 8 words in
// every one of 256 threads (inputs: the fuzzer's for seed 2136; compiled without fast math, as the fuzzer does).
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    threadgroup metal::array<uint, 64> tg;\n"
    "    threadgroup metal::array<uchar, 64> tc;\n"
    "    threadgroup atomic_uint ta;\n"
    "    if (l == 0) atomic_store_explicit(&ta, 0u, memory_order_relaxed);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    metal::array<uint, 8> p;\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;\n"
    "    metal::array<uchar, 8> pc;\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[(t * 4u + (j & 3u))] >> j);\n"
    "    uint v0 = in[(t * 4u + 0u)] * 1u + t;\n"
    "    uint v1 = in[(t * 4u + 1u)] * 3u + t;\n"
    "    uint v2 = in[(t * 4u + 2u)] * 5u + t;\n"
    "    uint v3 = in[(t * 4u + 3u)] * 7u + t;\n"
    "    uint v4 = in[(t * 4u + 0u)] * 9u + t;\n"
    "    uint v5 = in[(t * 4u + 1u)] * 11u + t;\n"
    "    pc[(((uint)((ushort)(((v3 ^ t) ^ v0))) * (uint)((ushort)(rotate(v3, (v4 ^ t)))))) & 7u] = (uchar)(max((uint)((int)(in[(t * 4u + 1u)]) / (int)((v5 | 1u) & 0x7fffffffu)), v4));\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        v5 = (uint)(pc[(256u) & 7u]);\n"
    "        if (((((((uint)((ushort)(in[(t * 4u + 1u)])) * (uint)((ushort)(in[(t * 4u + 3u)]))) % (addsat(1859741407u, in[(t * 4u + 0u)]) | 1u)))) & 3u) == 0u) break; } v0 += n0; }\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        if (max((in[(t * 4u + 2u)] >> (v1 & 31u)), (v2 ^ t)) > (v0 ^ t)) {\n"
    "            v0 = (uint)(pc[0u]);\n"
    "            pc[((uint)(-(int)(((v5 ^ t) >= v4 ? 224u : v3) & 0x7fffffffu))) & 7u] = (uchar)(madhi(((int)1u <= (int)(181u) ? in[(t * 4u + 0u)] : 90u), (uint)((short)((v3 ^ t))), madsat(in[(t * 4u + 1u)], (v3 ^ t), v2)));\n"
    "        } else {\n"
    "        }\n"
    "        if ((((extract_bits((v5 ^ t), (uint)(1u & 15u), (uint)(in[(t * 4u + 1u)] & 15u)) / ((uint)(!(in[(t * 4u + 1u)] > (v3 ^ t))) | 1u))) & 3u) == 0u) break; } v0 += n0; }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = v5;\n"
    "    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^ (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);\n"
    "    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);\n"
    "}\n"
    "\n"
    ;
static NSString *const refSrc = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void kref(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    threadgroup metal::array<uint, 64> tg;\n"
    "    threadgroup metal::array<uchar, 64> tc;\n"
    "    threadgroup atomic_uint ta;\n"
    "    if (l == 0) atomic_store_explicit(&ta, 0u, memory_order_relaxed);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    metal::array<uint, 8> p;\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;\n"
    "    metal::array<uchar, 8> pc;\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[(t * 4u + (j & 3u))] >> j);\n"
    "    uint v0 = in[(t * 4u + 0u)] * 1u + t;\n"
    "    uint v1 = in[(t * 4u + 1u)] * 3u + t;\n"
    "    uint v2 = in[(t * 4u + 2u)] * 5u + t;\n"
    "    uint v3 = in[(t * 4u + 3u)] * 7u + t;\n"
    "    uint v4 = in[(t * 4u + 0u)] * 9u + t;\n"
    "    uint v5 = in[(t * 4u + 1u)] * 11u + t;\n"
    "    pc[(((uint)((ushort)(((v3 ^ t) ^ v0))) * (uint)((ushort)(rotate(v3, (v4 ^ t)))))) & 7u] = (uchar)(max((uint)((int)(in[(t * 4u + 1u)]) / (int)((v5 | 1u) & 0x7fffffffu)), v4));\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        v5 = (uint)(pc[(l >> 31u) & 7u]);\n"
    "        if (((((((uint)((ushort)(in[(t * 4u + 1u)])) * (uint)((ushort)(in[(t * 4u + 3u)]))) % (addsat(1859741407u, in[(t * 4u + 0u)]) | 1u)))) & 3u) == 0u) break; } v0 += n0; }\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        if (max((in[(t * 4u + 2u)] >> (v1 & 31u)), (v2 ^ t)) > (v0 ^ t)) {\n"
    "            v0 = (uint)(pc[((l + 1u) >> 31u) & 7u]);\n"
    "            pc[((uint)(-(int)(((v5 ^ t) >= v4 ? 224u : v3) & 0x7fffffffu))) & 7u] = (uchar)(madhi(((int)1u <= (int)(181u) ? in[(t * 4u + 0u)] : 90u), (uint)((short)((v3 ^ t))), madsat(in[(t * 4u + 1u)], (v3 ^ t), v2)));\n"
    "        } else {\n"
    "        }\n"
    "        if ((((extract_bits((v5 ^ t), (uint)(1u & 15u), (uint)(in[(t * 4u + 1u)] & 15u)) / ((uint)(!(in[(t * 4u + 1u)] > (v3 ^ t))) | 1u))) & 3u) == 0u) break; } v0 += n0; }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = v5;\n"
    "    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^ (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);\n"
    "    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);\n"
    "}\n"
    "\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n44-kepler-metal-array-constant-loads";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;  // as the fuzzer compiles
    // two libraries: the kernel alone, as the fuzzer compiles it (with the reference beside it, the bug didn't show)
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:options error:&err];
    id<MTLLibrary> refLib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:refSrc] options:options error:&err];
    if (!lib || !refLib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    id<MTLComputePipelineState> ref = [dev newComputePipelineStateWithFunction:[refLib newFunctionWithName:@"kref"] error:&err];
    if (!ps || !ref) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> in = [dev newBufferWithLength:T * 4 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:T * 8 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> want = [dev newBufferWithLength:T * 8 * 4 options:MTLResourceStorageModeShared];
    uint32_t x = 2136 * 2654435761u + 12345u;
    for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; ((uint32_t *)in.contents)[i] = (i % 7 == 0) ? (x & 0xff) : x; }
    memset(out.contents, 0xcd, out.length);
    memset(want.contents, 0xab, want.length);
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setBuffer:in offset:0 atIndex:0];
    [ce setComputePipelineState:ps];
    [ce setBuffer:out offset:0 atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake(T / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce setComputePipelineState:ref];
    [ce setBuffer:want offset:0 atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake(T / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    const uint32_t *got = out.contents, *ok = want.contents;
    int wrong = 0, first = -1;
    for (int i = 0; i < T * 8; i++)
        if (got[i] != ok[i]) { wrong++; if (first < 0) first = i; }
    if (wrong)
        return FAIL(bug, "%s: %d of %d words differ from the same kernel with an opaque index (thread %d word %d: %#x, want %#x)", name, wrong,
                    T * 8, first / 8, first % 8, got[first], ok[first]);
    return PASS(bug, "%s: loads of a private array's element at a constant index see the stores to it at a variable index", name);
}}
