// i31-intel-narrow-div (Intel adapter, IntelTextureAtomics.dylib): 8- and 16-bit division and remainder done in narrow
// lanes. The back end's narrow divides take operands extended the wrong way (narrow constants arrive sign-extended,
// lanes zero-extended), so char4 shift amounts computed with char4(-90, -126, 70, 75) % d came out wrong (the
// MacBookPro11,5 session's narrow-vector fuzzing, seed 44; the expression is the reduced one from that kernel). The
// adapter does udiv / urem / sdiv / srem on i8 and i16 in 32-bit lanes. On the differential fuzzer's 256-thread input,
// against the CPU reference.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "static uint vf(char4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    uchar pc[8];\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[(t * 4u + (j & 3u))] >> j);\n"
    "    uint v0 = in[t * 4u] + t, v1 = in[t * 4u + 1u] * 3u + t, v2 = in[t * 4u + 2u] * 5u + t, v3 = in[t * 4u + 3u] * 7u + t, v4 = in[t * 4u] * 9u + t;\n"
    "    out[t * 8u + 0u] = vf((((char4((char)((uint)(pc[(196u) & 7u])), (char)((v3 ^ t)), (char)(mulhi(4u, v3)), (char)(((v0 % (v4 | 1u))))) >> ((char4((char)((uint)(-(int)(in[(t * 4u + 0u)] & 0x7fffffffu))), (char)(v2), (char)((v0 ^ t)), (char)((2065034790u / (31u | 1u))))) & char4((char)(7), (char)(7), (char)(7), (char)(7)))) >> (((char4((char)(-90), (char)(-126), (char)(70), (char)(75)) % ((char4((char)((uint)((int)(in[(t * 4u + 1u)]) % (int)((v1 | 1u) & 0x7fffffffu))), (char)(insert_bits(44u, 255u, (uint)(v0 & 15u), (uint)(32u & 15u))), (char)((((v0 ^ t) % (in[(t * 4u + 2u)] | 1u)))), (char)((uint)((bool)((v4 ^ t) & 4099727130u))))) & char4((char)(127), (char)(127), (char)(127), (char)(127)) | char4((char)(1), (char)(1), (char)(1), (char)(1))))) & char4((char)(7), (char)(7), (char)(7), (char)(7))))));\n"
    "}\n";

// out[t * 8 + w] for each thread t and w in kWords, from the CPU reference (cpuref.py) on the same input
static const int kWords[] = {0};
enum { kNumWords = sizeof kWords / sizeof *kWords };
static const uint32_t kExpected[256 * kNumWords] = {
    0xc6ffa241u, 0xfdfffdd8u, 0x030004b9u, 0xe4ffd47eu, 0x340051dcu, 0xcfffb570u, 0x3500526fu, 0xe3ffd2ebu,
    0x0d001774u, 0x2b0042bau, 0x06000d71u, 0x1000192cu, 0x09000e2au, 0x28003afbu, 0xc5ffa4b2u, 0x0e00160cu,
    0x06000872u, 0xe6ffdaa6u, 0xd5ffbde2u, 0xecffe316u, 0x37005698u, 0xecffe217u, 0xebffe184u, 0x33005149u,
    0x1f0031cdu, 0x0400066au, 0xdeffcd0au, 0x0e00170au, 0x390058bau, 0xf1ffe8b2u, 0xc3ffa58fu, 0xfcfffb47u,
    0xe5ffd612u, 0x06000a70u, 0xdbffc754u, 0x2b0043b1u, 0x33005048u, 0x2d0042d5u, 0x09000f2bu, 0xe2ffd258u,
    0xd3ffbabbu, 0xfafffc22u, 0x15012233u, 0x12001d56u, 0xffffffffu, 0x27003c64u, 0xe9ffdd5au, 0x1a0028e8u,
    0x02000226u, 0xdfffcc9eu, 0x0a000f9du, 0xf2ffea88u, 0xe4ffd46eu, 0xfffffdfcu, 0xfcfffb41u, 0x1d002feeu,
    0xcdffb54au, 0x23003719u, 0xcbffaf23u, 0x3500516cu, 0xfdfffcdbu, 0x02000327u, 0xddffcb71u, 0x31004e20u,
    0x37005795u, 0x13001de9u, 0xcbffaf23u, 0xd9ffc42eu, 0xf5fff142u, 0xf9fff78cu, 0xd3ffbbbbu, 0xfcfffa47u,
    0xedffe3aau, 0xd7ffc107u, 0xfbfffc80u, 0x13001ce9u, 0x27003d79u, 0xefffe7cfu, 0x20003163u, 0x180027c1u,
    0x37005795u, 0x25003b3eu, 0x2c004444u, 0x1500200fu, 0xedffe2a9u, 0xfffffafbu, 0x37005695u, 0x3b005ee0u,
    0x0e001709u, 0x2900418bu, 0x2900418au, 0x07000b05u, 0xe9ffde5eu, 0xfbfff8b4u, 0xc1ff9e66u, 0x1b002b81u,
    0x26003bd2u, 0x050006ddu, 0xf0ffe962u, 0xf1ffe9f6u, 0xd7ffc305u, 0xfefffe6du, 0x2300362fu, 0x0d001461u,
    0x2b0042b1u, 0xc5ffa4b2u, 0xc3ffa08bu, 0xf6fff0d4u, 0xf3ffef1au, 0xf0ffe863u, 0xfafff921u, 0xc2fe9fc7u,
    0xd6ffbf75u, 0x1f0030cfu, 0xcaffac9fu, 0x030004b9u, 0x180026cbu, 0xe8ffdbcbu, 0x01000093u, 0xe4ffd472u,
    0x0400054fu, 0x3d006007u, 0x3f006227u, 0xeeffe53du, 0xf6fff1d5u, 0xd6ffbf74u, 0xd3ffbbbdu, 0x02000326u,
    0xf0ffe962u, 0x13001fe8u, 0x0c0013e4u, 0x180027c6u, 0x13001de8u, 0xf1ffe8f5u, 0xeaffdff0u, 0x17002434u,
    0xc3ffa08bu, 0x0e00160au, 0xd6ffbe77u, 0xccffafb7u, 0xfbfffdb0u, 0x06000871u, 0x13001da0u, 0x33005048u,
    0xe7ffdb37u, 0x13001ce9u, 0xe5ffd510u, 0xfffffeffu, 0xfafff920u, 0x180024c7u, 0xd6ffbe75u, 0x0a000fbdu,
    0x240038abu, 0x07000a05u, 0x2a00421eu, 0xe7ffda3fu, 0xfdfefce6u, 0x3e006099u, 0xdeffcc17u, 0xefffe5d2u,
    0xdfffc9b8u, 0x2b0042b0u, 0xedffe2a9u, 0xd8ffc29au, 0xc4ffa11eu, 0x400064bfu, 0x37005695u, 0xd1ffb796u,
    0xfbfff8b3u, 0xdfffccbdu, 0xddffcb78u, 0xe1ffd1c6u, 0xf1ffe1f3u, 0x27003e67u, 0x12001c56u, 0xc9ffaafeu,
    0xeeffe23au, 0xf0ffe963u, 0x3c005e74u, 0xc7ffafd1u, 0xfcfffb47u, 0xfafff921u, 0xf3ffed1cu, 0xebffe285u,
    0x1000182eu, 0x2b0040b3u, 0x09000e2bu, 0x09000c2bu, 0x1f0031ccu, 0x1b002b80u, 0x2300351bu, 0x2e00486au,
    0x11001ac2u, 0x0b001050u, 0xc9ffa8ffu, 0xf0ffe867u, 0x31004e20u, 0xd9ffc52du, 0x340051dbu, 0xfafff821u,
    0xe7ffdb27u, 0x2b0043b0u, 0xe1ffd1c6u, 0x0a000ebdu, 0xd1ffb496u, 0x260038d2u, 0x050006ccu, 0x0d001476u,
    0x2900418au, 0x20003041u, 0x00000000u, 0x33005148u, 0x0d001476u, 0xd1ffb682u, 0xcaffae91u, 0x00010131u,
    0x2e00486au, 0xfafff920u, 0xdaffc5c1u, 0xdcffcae4u, 0xf7fff368u, 0xd7ffc007u, 0xd7ffc007u, 0x2000335eu,
    0x33005049u, 0xecffe316u, 0x240038acu, 0xd4ffba49u, 0x3000438eu, 0x1d002fa5u, 0x22003585u, 0x11001dc3u,
    0x28003df5u, 0x2f004cf9u, 0x07000806u, 0x0e00170au, 0x210032f6u, 0x20003559u, 0xd0ffb403u, 0x340050dcu,
    0x0f00149fu, 0x160023a2u, 0x20003260u, 0xd9ffc52eu, 0xe2ffd05du, 0xddffcb79u, 0x3e00609au, 0x23003619u,
    0xe0ffcb30u, 0x1c002d12u, 0x12001c30u, 0xf0ffed66u, 0x390058bau, 0xe4ffd47eu, 0x1e002f3au, 0xe3ffd2ecu
};

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i31-intel-narrow-div";
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
