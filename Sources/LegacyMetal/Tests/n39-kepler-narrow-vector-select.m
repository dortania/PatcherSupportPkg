// n39-kepler-narrow-vector-select (Kepler adapter, NVAIR_NARROW_VECTOR_FIX): a select of 4-lane vectors of 8-bit
// integers counting a loop. A loop that ends when vf(select(uchar4(...), uchar4(...), uchar4(...) > uchar4(...))) & 3 is 0,
// in a loop the optimizer unrolls, with its count added to a value used after it, came out wrong on about half the threads
// (mslfuzz2.py VEC=1 ASTYPE=1 seed 13302, reduced to this kernel). With every other operation on the narrow vectors done
// lane by lane, only the <4 x i8> select was left, and done lane by lane too it is right. The kernel on the fuzzer's inputs
// (seed 1, 256 threads in groups of 64, compiled without fast math, as the fuzzer does): each thread's 8 output words
// against the CPU reference (cpuref.py), as one FNV-1a hash per thread.
// Since the fix for 8-bit compares (n41, NVAIR_NARROW_COMPARE_FIX) the kernel is right with either fix alone: the run
// without the fix turns both off.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "static uint vf(uchar2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 1u); }\n"
    "static uint vf(uchar3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 1u) ^ (uint(v.z) * 1u); }\n"
    "static uint vf(uchar4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 1u) ^ (uint(v.z) * 1u) ^ (uint(v.w) * 1u); }\n"
    "static uint vf(char2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 1u); }\n"
    "static uint vf(char3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 1u) ^ (uint(v.z) * 1u); }\n"
    "static uint vf(char4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 1u) ^ (uint(v.z) * 1u) ^ (uint(v.w) * 1u); }\n"
    "static uint vf(ushort2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 1u); }\n"
    "static uint vf(ushort3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 1u) ^ (uint(v.z) * 65599u); }\n"
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
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            if (((vf(((select(uchar4((uchar)(1u), (uchar)(1u), (uchar)(1u), (uchar)(1u)), uchar4((uchar)(1u), (uchar)(1u), (uchar)((~(v3 ^ t))), (uchar)(1u)), uchar4((uchar)(1u), (uchar)(1u), (uchar)((uint)((int)(in[(t * 4u + 1u)]) / (int)((in[(t * 4u + 0u)] | 1u) & 0x7fffffffu))), (uchar)(1u)) > uchar4((uchar)(1u), (uchar)(1u), (uchar)(1u), (uchar)(((in[(t * 4u + 0u)] & 1u) != 0u ? in[(t * 4u + 3u)] : (v0 ^ t))))) & uchar4((uchar)(1u), (uchar)(1u), (uchar)(1u), (uchar)(1u)))))) & 3u) == 0u) break; } v0 += n1; }\n"
    "        { uint4 w = uint4(((65u >= (v4 ^ t) ? 1668322756u : v5) << (((37u % (in[(t * 4u + 3u)] | 1u))) & 31u)), v0, min3(v1, ((v0 ^ t) | 112u), (uint)((ushort)(1u) >> (2762721722u & 7u))), v5); uint wi = ((((v1 & 1u) != 0u ? v2 : v2) <= ((uint)((int)((short)(1u))) - 277754759u) ? (in[(t * 4u + 2u)] / (in[(t * 4u + 3u)] | 1u)) : (uint)(-(int)((v0 ^ t) & 0x7fffffffu)))) & 3u; uint wm = median3(mulhi(1u, 1u), (1u >> (42949835u & 31u)), rhadd((v4 ^ t), v2)); w = uint4(wi == 0u ? wm : w.x, wi == 1u ? wm : w.y, wi == 2u ? wm : w.z, wi == 3u ? wm : w.w); uint wj = ((uint)(-(int)((1u >> ((v2 ^ t) & 31u)) & 0x7fffffffu))) & 3u; v4 += (wj == 0u ? w.x : (wj == 1u ? w.y : (wj == 2u ? w.z : w.w))) ^ (w.y << 1u) ^ w.w; }\n"
    "    }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = v5;\n"
    "    out[t * 8u + 6u] = 0u;\n"
    "    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);\n"
    "}\n";

// FNV-1a of each thread's 8 words (bytes in little-endian order), from cpuref.py's output for this kernel and input seed 1
static const uint32_t want[256] = {
    0xb8654ebeu, 0xa38e5774u, 0x739312d1u, 0x97cf5073u, 0x5bc1ea26u, 0x1935c4dfu, 0xcc27168du, 0xca40636au,
    0x25134d6au, 0x41c2f325u, 0x2e20e4b7u, 0x413c854cu, 0x9a8917bau, 0xf0506b71u, 0x41c7d9f0u, 0xebfc738bu,
    0x6f8fa454u, 0xf91542f5u, 0x683d48edu, 0xc1e39751u, 0xcaefb00fu, 0x10f3c1b1u, 0x91ea5200u, 0xfe82c2f7u,
    0x3888e888u, 0x38c3bde1u, 0xdbeb42a9u, 0x1da5cd01u, 0xbbb43b36u, 0x6f2c3e40u, 0xf85bca6du, 0x8608fb3du,
    0x685f16c7u, 0xa6893fd7u, 0x10e227eeu, 0x579df639u, 0xef988948u, 0x3391e569u, 0x2540462eu, 0xa7986a9du,
    0x0bf5847eu, 0x9889790fu, 0x91926155u, 0x85bdf668u, 0x81790b4eu, 0x2281ce8cu, 0x443e490eu, 0xe102dc83u,
    0x1785998du, 0x72ef94cbu, 0x76f208bbu, 0xbe770a93u, 0x2843eeadu, 0x1aee6507u, 0xe219ddc0u, 0x7553d1f3u,
    0x7a417c8du, 0xeef8f33au, 0x9b49b9eeu, 0xf77c43d5u, 0x78e13e8du, 0x002a757eu, 0x74c7ce3fu, 0x549ffabau,
    0x86ea98d2u, 0x6abb6702u, 0x35648de8u, 0x958fc305u, 0xece17d3cu, 0xdf098c89u, 0xa14b1e92u, 0xe69db0c5u,
    0xac86b838u, 0xa7701497u, 0xc79be093u, 0x7b94299eu, 0x80e3c03au, 0xa414b9fau, 0xb99a4896u, 0x6b8e6e9bu,
    0xe1d66485u, 0x43516596u, 0xee574b03u, 0xc17944b0u, 0x559b4998u, 0xe133f908u, 0x5cebd639u, 0x64fc0a55u,
    0xee393accu, 0xbc25d79bu, 0xa691fa75u, 0xfabacf5au, 0x2ec33f27u, 0xa635b1f1u, 0xb58a2743u, 0x9038a821u,
    0x20bd8fbbu, 0xd1593c2bu, 0x8740ef4bu, 0x1f48e57bu, 0xd8fbe731u, 0x208d8405u, 0x11e41315u, 0xf1298515u,
    0x086974deu, 0x45653972u, 0xfef3d7bcu, 0x770b9eb2u, 0x87373e94u, 0x478053dau, 0x4e7d2abbu, 0xec1da171u,
    0x42cf94e0u, 0x94e9b793u, 0x3c3a30d0u, 0x7f80d716u, 0xfdc5df41u, 0x903d73e6u, 0x5bdcee46u, 0x44b4843cu,
    0x3fe0e5dbu, 0xa852a7c5u, 0xe7ea44a7u, 0x3c9acbeau, 0x14d77a1du, 0xbe1beb8fu, 0xbebff17au, 0x5457f088u,
    0x510ea50fu, 0x76405fe6u, 0xc903f847u, 0x5eb41f57u, 0xd2986cf7u, 0xad51e681u, 0xb1ffd801u, 0x85218f5du,
    0xfb3b0582u, 0x1d1075d3u, 0x8b917350u, 0x126e11b1u, 0xdaaa9b15u, 0x60edac23u, 0x1e64e0dfu, 0x6ea6a311u,
    0x982e96d0u, 0x33c97b18u, 0x46f7decfu, 0x5f26cdc4u, 0xafbe8091u, 0xe743f42du, 0x1b6fdf41u, 0x8d66210du,
    0xf001879bu, 0x01b6c699u, 0xda16adf4u, 0x3c379940u, 0x1996537bu, 0x57727fb3u, 0xb8436794u, 0x25bb8095u,
    0xf7e113feu, 0x8a63e551u, 0x622e252cu, 0x87dbaa99u, 0x71beaf53u, 0x49ec07d3u, 0x57492f83u, 0xe415d699u,
    0xf0363cf2u, 0x4e73ab09u, 0x51a1fbf9u, 0x7240701du, 0xae8ad29au, 0xb3aed5b4u, 0x0485b8aeu, 0x9587af71u,
    0x881d2e68u, 0x49cd2b81u, 0xaa055fc1u, 0x68fcd23au, 0xc09ce0f4u, 0x5fbefd3fu, 0xc9a82f2du, 0xa7611ccau,
    0x01f3271au, 0x31084f5fu, 0x16c63627u, 0xfc78c96bu, 0x76543484u, 0x8f666ff0u, 0xea162cafu, 0x8ee7f9e9u,
    0x60daf8d5u, 0x3012e23bu, 0x8ca157dbu, 0xe13ad373u, 0xcae1a687u, 0x5eaf5528u, 0x0bb6fffbu, 0xc7e6e8f7u,
    0x8c6b7f93u, 0x29db7e5bu, 0xd659fb47u, 0xf0e4d0f8u, 0xf2e55023u, 0x4b13357eu, 0xf2c857e6u, 0xba646c16u,
    0x68363663u, 0x0e9217cfu, 0xef49696au, 0xb5f5e9f3u, 0x8d6c8af0u, 0x01d736dcu, 0x765053c5u, 0xaacd0526u,
    0xa694032cu, 0x1067d780u, 0xdf47f0ecu, 0x4be3b696u, 0x8a6effb0u, 0x4a63488eu, 0x70194f56u, 0x4baf2fd2u,
    0x29af378eu, 0xa04dcf78u, 0x513644a7u, 0xd5ddcf58u, 0x0ba584b5u, 0xbbacedb4u, 0x02efe89eu, 0xead02c38u,
    0xf3742591u, 0xa7476903u, 0x8339a864u, 0x8285e0c8u, 0x37d15a37u, 0x7dabf31cu, 0x1b8c149bu, 0x4a7fa32cu,
    0x7b5b77a7u, 0xeb084f7bu, 0x9df26212u, 0xe0c30769u, 0xc707c4d8u, 0x92923bd3u, 0xc0fa5a40u, 0xa73659ebu,
    0xb32be8f9u, 0x86363fd4u, 0xcc869b50u, 0xf3444aadu, 0x9debcf31u, 0x7862783du, 0xbf46fa41u, 0x30469686u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n39-kepler-narrow-vector-select";
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
    return PASS(bug, "%s: a loop counted by a select of narrow vectors runs the right number of times", name);
}}
