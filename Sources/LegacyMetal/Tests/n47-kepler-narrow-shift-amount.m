// n47-kepler-narrow-shift-amount (Kepler adapter, NVAIR_NARROW_SHIFT_FIX): right shifts of 8-bit vector lanes by a masked
// variable amount, v >> (uchar(x) & 7) with x large. The adapter does arithmetic on 2- to 4-lane vectors of 8- and 16-bit
// integers lane by lane (NVAIR_NARROW_VECTOR_FIX, NVAIR_ODD_VECTOR_FIX), which left lshr/ashr i8 v, (and (trunc i32 x), 7):
// the back end drops the mask as redundant for an 8-bit shift and shifts by the whole 32-bit register instead, so every
// lane whose amount came from a value with upper bits set came out wrong (mslfuzz2.py ANGLE=1 FRAG=1 VEC=1 ASTYPE=1 seed
// 29, reduced: a char3 >> (char3(v0) & 7) inside all(...)). The same lanes in vector form (those passes off) or written as
// scalar shifts in the source (C promotes them to 32 bits) are right. Right shifts of i8 and i16 scalars are now done in
// 32 bits on the extended value with the amount through llvm.nvvm.min.u.i32. Here: a char3 and a char4 arithmetic shift
// under all(... < 1) and a uchar4 logical shift, by (char)v0 & 7 where v0 is 1055511043 in half the threads and 0 in the
// rest; each thread's 8 words against the CPU reference (cpuref.py) as FNV-1a hashes. Without the fix 117 of the 120
// threads with a nonzero amount are wrong in the uchar4 word, 56 and 59 in the char ones. Argument: GPU name substring
// (default: NVIDIA).
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
    "    uint v0 = (in[(t * 4u + 1u)] & 1u) != 0u ? 1055511043u : 0u;\n"
    "    uint v1 = (uint)(all((char3((char)(1u), (char)(in[(t * 4u + 2u)] ^ v0), (char)(1u)) >> ((char3((char)(1u), (char)(v0), (char)(1u))) & char3((char)(1u), (char)(7), (char)(1u)))) < char3((char)(1u), (char)(1u), (char)(1u))));\n"
    "    uint v2 = (uint)(all((char4((char)(1u), (char)(in[(t * 4u + 3u)] ^ v0), (char)(1u), (char)(1u)) >> ((char4((char)(1u), (char)(v0), (char)(1u), (char)(1u))) & char4((char)(1u), (char)(7), (char)(1u), (char)(1u)))) < char4((char)(1u), (char)(1u), (char)(1u), (char)(1u))));\n"
    "    uint v3 = vf(uchar4((uchar)(in[(t * 4u + 2u)] ^ v0), (uchar)(in[(t * 4u + 1u)]), (uchar)(1u), (uchar)(1u)) >> (uchar4((uchar)(v0), (uchar)(v0 >> 8), (uchar)(1u), (uchar)(1u)) & uchar4((uchar)(7), (uchar)(7), (uchar)(1u), (uchar)(1u))));\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = 0u;\n"
    "    out[t * 8u + 5u] = 0u;\n"
    "    out[t * 8u + 6u] = 0u;\n"
    "    out[t * 8u + 7u] = 0u;\n"
    "}\n";

// FNV-1a of each thread's 8 words (bytes in little-endian order), from cpuref.py's output for this kernel and input seed 1
static const uint32_t want[256] = {
    0x994ce3a5u, 0xbfc8f2f1u, 0x35e45812u, 0xdb64f753u, 0x6d32cdc0u, 0x82dae93eu, 0x2711579fu, 0x55de278eu,
    0x45b3b575u, 0x15a7bfdeu, 0x60d5ba98u, 0x6a93c97cu, 0x47d36dbeu, 0xc0705758u, 0x96895d2au, 0x06a94027u,
    0x97d94958u, 0x39c52040u, 0x7185d6e6u, 0x30223728u, 0x38a794ceu, 0x2cc8b8fdu, 0x07f7efa4u, 0xd57f4422u,
    0x3837d8fdu, 0x0b030e21u, 0xd2041a3bu, 0x4161b6b2u, 0xaf92b595u, 0x17bfd14du, 0xaa4f49d6u, 0x1d0950e0u,
    0x6a17c8c4u, 0x51dce852u, 0xc2b1a4d6u, 0xbe23aa08u, 0x125ea105u, 0xd6304151u, 0xd3bc0d76u, 0x047f6d67u,
    0x0c031431u, 0xa1f0a318u, 0x0c221269u, 0x5afa44fbu, 0xd0f7bc59u, 0xddafeb76u, 0x415beeceu, 0x0ac2e124u,
    0xb67319ebu, 0x770fabd3u, 0x6f9e58c3u, 0x1ee0bf4au, 0x78363781u, 0x433a0a31u, 0x4b9a88f6u, 0xd3439b6bu,
    0x7dc9ab10u, 0x6bd47980u, 0xd72f624cu, 0x60e3e383u, 0x0bef1a43u, 0xe36c4ff0u, 0x1bdfcfddu, 0xbc7f7194u,
    0xb040e9abu, 0x7eb7e3d3u, 0x49349e53u, 0xb80f8ed4u, 0xa1fc0bd7u, 0x9b994736u, 0xf07a8f5bu, 0xa3d47fa3u,
    0xf431f12fu, 0x2861a463u, 0x58a37f22u, 0x093bc449u, 0x3f64ef80u, 0xe6aded3du, 0x7e0842d6u, 0xe0afe6cfu,
    0xc3b442b5u, 0xb85dacc6u, 0x063b8c93u, 0x631d9c8au, 0x7ebf1ba0u, 0xccf0a182u, 0xcec1688du, 0xd527721cu,
    0x7a334872u, 0x62128067u, 0xa149844cu, 0x73905bd5u, 0xa4e18bb9u, 0xc096f3cdu, 0x3669d5fdu, 0x17128819u,
    0xe75d7196u, 0x9243bc13u, 0x5fd7216fu, 0x651a8d2eu, 0xc939d718u, 0xa46e8ee6u, 0x19359e15u, 0x5a151af8u,
    0x6ca486b0u, 0xcd8e8f0bu, 0xbe9c42b5u, 0xae94e012u, 0x828b919du, 0x0a3c1418u, 0x1137bcd1u, 0xc0c4ed5du,
    0x201ec5b6u, 0xd33d157bu, 0x280e95b8u, 0x0efd8cadu, 0x286156b8u, 0x9e24ca5fu, 0xafa7198fu, 0xab82a43bu,
    0xc82b9654u, 0x3698deedu, 0xbf463cfdu, 0x051c90f5u, 0x4ad011c6u, 0x50f949cdu, 0x21d125f3u, 0xa1441eacu,
    0xbc7a11ceu, 0x2efbc7dbu, 0x5b0a9e73u, 0x30033504u, 0xf4c6f546u, 0xd17f33bau, 0x0aa5fdc4u, 0x00b2f269u,
    0x74f45075u, 0x523c946au, 0x4a631aeau, 0x9db89b4du, 0xe44a5c99u, 0xaba36007u, 0x53f17015u, 0x48e98393u,
    0x21bea4dbu, 0xbda8057fu, 0xa968692du, 0xad12a105u, 0x0007d1f7u, 0x9c1795feu, 0x68c62204u, 0x166e8313u,
    0x867c823cu, 0x853ec3a1u, 0x9fc1df9fu, 0x77173339u, 0xcec1688du, 0x8de8d9b8u, 0x1a5839b4u, 0xe49bb38au,
    0x279431ccu, 0x03b8aa32u, 0xc87ae31au, 0xe79ada88u, 0xf20c859bu, 0x7895e399u, 0xac2a0cc6u, 0x35288e8fu,
    0x9fd03aa0u, 0x83e1e36eu, 0x4d470f86u, 0xe75eea6cu, 0x3b3a3551u, 0xddc5e93au, 0xbdc8eabdu, 0x73e829efu,
    0x932399d5u, 0x20e17f35u, 0x4c04b3b7u, 0x8a64ba70u, 0x7e06e6a4u, 0x1bea4c98u, 0x455610b0u, 0xa7a90aedu,
    0xe69f923cu, 0x47ce0df8u, 0x983fc90bu, 0x6e0da442u, 0xf9807532u, 0x679f9656u, 0x6b94194bu, 0x18a191f1u,
    0xf899f133u, 0xaab22c15u, 0xa1c27f3du, 0x5fb43c04u, 0xd558a7adu, 0x850ba284u, 0xb0f52bc8u, 0xa6b4ee7fu,
    0xe373238bu, 0x9c17a7c7u, 0xd25972d2u, 0xc00cd2d4u, 0xb4744e68u, 0xffb8cd02u, 0x5051c9d1u, 0x164f3730u,
    0x932c9febu, 0xeb60c6ecu, 0xe3108030u, 0xff719932u, 0x6142317bu, 0x55decd7cu, 0xe78e47f6u, 0xcb117a68u,
    0xfb280d3fu, 0xf3a7f0feu, 0x088eed31u, 0xc8941d5au, 0x0ca74695u, 0x1130e936u, 0xfc5250d4u, 0x9128bf4bu,
    0x4ebd8e2bu, 0xb288cb9du, 0xd0f07eb2u, 0x09ccc065u, 0x6c443551u, 0x0a64bc66u, 0xf4788d95u, 0xc3401134u,
    0xd17e2e58u, 0x6cbfe85eu, 0x198a4aa1u, 0xbe8b5a7du, 0x186be39du, 0xd4d9542au, 0x4a7d3079u, 0x181dd19au,
    0x1cbc552cu, 0x90fabfe1u, 0xa78f5208u, 0xb9cc3f90u, 0x7f3e46d3u, 0x0575407bu, 0x68852a65u, 0x31bbbfa9u,
    0xaf6621f0u, 0x3fb666beu, 0xbfcf69e2u, 0x88ef0df5u, 0xf956e98au, 0xfa72b7abu, 0x8fe8e1ecu, 0xe4255568u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n47-kepler-narrow-shift-amount";
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
    return PASS(bug, "%s: right shifts of 8-bit vector lanes by a masked variable amount are right", name);
}}
