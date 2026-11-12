// i30-intel-narrow-udiv (Intel adapter, IntelTextureAtomics.dylib): division of uchar lanes built from selects of 32-bit
// values. The back end writes it as UBDIV, and iCBE drops the AND 0xFF that truncates each lane (it takes the divide to
// read only the low byte) while the divide uses the whole register, so lanes were divided with their upper bits in
// place (the MacBookPro11,5 session's narrow-vector fuzzing, seed 31). The adapter writes UBDIV / USDIV as a 32-bit UDIV
// of masked copies. On the differential fuzzer's 256-thread input, against the CPU reference.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "static uint vf(uchar3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    uint v0 = in[t * 4u] + t, v1 = in[t * 4u + 1u] * 3u + t, v3 = in[t * 4u + 3u] * 7u + t, v4 = in[t * 4u] * 9u + t, v5 = in[t * 4u + 1u] * 11u + t;\n"
    "    v4 ^= vf((((uchar3((uchar)(((int)((v1 ^ t)) > (int)((v0 ^ t)) ? v5 : 2944262880u)), (uchar)((uint)(-(int)(18u & 0x7fffffffu))), (uchar)(((int)(in[(t * 4u + 3u)]) > (int)(v4) ? (v3 ^ t) : v5)))).zxy / uchar3((uchar)(65), (uchar)(32), (uchar)(125)))));\n"
    "    out[t * 8u + 0u] = v4;\n"
    "}\n";

// out[t * 8 + w] for each thread t and w in kWords, from the CPU reference (cpuref.py) on the same input
static const int kWords[] = {0};
enum { kNumWords = sizeof kWords / sizeof *kWords };
static const uint32_t kExpected[256 * kNumWords] = {
    0x0001023eu, 0x066b83d2u, 0x9b2b771fu, 0xa56ae6bfu, 0x8a0ddba9u, 0x3b98b72bu, 0xb1c4a6a8u, 0x000104f9u,
    0x4aabaa3du, 0x68fc9e3bu, 0x56916030u, 0xe74db737u, 0x793d73e7u, 0x7b1ea00bu, 0x000103beu, 0x0174e96fu,
    0x4361c8ceu, 0xaca81501u, 0x0684f2ecu, 0x1db0a367u, 0x0b5f3830u, 0x0001053eu, 0xcdef79d3u, 0xcdf64bddu,
    0x928412e9u, 0xf5af3fc4u, 0x80826bb9u, 0xe32fdd16u, 0x00010622u, 0x027b970au, 0x4d621ae1u, 0x4baf0706u,
    0x9d004716u, 0xe8a07d58u, 0x0f52550au, 0x000106cdu, 0x3434a970u, 0xb1346492u, 0x870be3e3u, 0x0c842735u,
    0x05153ee3u, 0xf2a39ae8u, 0x00010709u, 0xb44201d6u, 0xcfa4f998u, 0xe940afdau, 0x6690ff35u, 0xd31cd484u,
    0x12aa1d28u, 0x000103feu, 0x50689e2au, 0xc15d8137u, 0xf1c9abbeu, 0x1ef0d36cu, 0x0a2b39ffu, 0xaaa8fb7bu,
    0x000103f1u, 0xc0ff2e8fu, 0x2fcbc1beu, 0x7d407ec9u, 0x259e7131u, 0x0bbf0b31u, 0x9a61ce46u, 0x000107a7u,
    0xa927f4dbu, 0x15170a93u, 0x425da674u, 0x30de1daeu, 0x43051d27u, 0x263388c2u, 0x000107d3u, 0x7458f826u,
    0xdd237c41u, 0xf15c2b50u, 0x678254bau, 0x9ba54c44u, 0xf314e60bu, 0x000100f9u, 0xa75e7ce1u, 0x5d0a5c1du,
    0x7b2db498u, 0x5114b3e3u, 0x37d6d6ebu, 0x2e438917u, 0x00010096u, 0x9fedb3edu, 0x8ff2bd0eu, 0x2ebfbf59u,
    0x96c00077u, 0x3243f2adu, 0x9577b40bu, 0x00010691u, 0x5d8c0295u, 0xba1f10eeu, 0x960af984u, 0x8ec66038u,
    0xb4bc386cu, 0x2240b9a5u, 0x000102c7u, 0x1392caaeu, 0xd6217a89u, 0x0e335ba4u, 0x1e50f9f7u, 0x2a404349u,
    0x2d1d176au, 0x0001069fu, 0xe6b5ab3bu, 0x9a5a7c72u, 0xb3026d43u, 0x0bb6e2a5u, 0xdc95910bu, 0x8d8c936eu,
    0x000102a1u, 0x47b796e7u, 0x31362481u, 0x9952ec55u, 0xbc15b02au, 0x56a4cec4u, 0xeec43459u, 0x00010609u,
    0xbc5cb9b0u, 0x67e0c91au, 0xe21783d6u, 0xc198e6c8u, 0x967e4f46u, 0xc581e0c7u, 0x000106c1u, 0x117b16c3u,
    0xe62d0047u, 0x4c097c6bu, 0x4d1c54ddu, 0xbf1050e7u, 0x7abfbeaeu, 0x000102e6u, 0xd4b87f68u, 0xd795af08u,
    0xefc3cd58u, 0xd0edb784u, 0xe8cd95abu, 0xdb30b723u, 0x000107d6u, 0x29deca03u, 0xb892eedcu, 0xf1f5f6c2u,
    0x0f56b386u, 0x96c1e89eu, 0x26b23555u, 0x00010353u, 0xdab6e885u, 0x3e898611u, 0x33c2fd08u, 0x349749a9u,
    0x8d96dd52u, 0xbaca9284u, 0x00010015u, 0xb19a444bu, 0x2031bdc6u, 0x1ecd6f6au, 0x817dfa1cu, 0xd913b1f8u,
    0x50ecb0feu, 0x000107c0u, 0x75d2c2aau, 0xf3b17597u, 0xf0fd2effu, 0x477eaa4du, 0x6353cd93u, 0x154aa823u,
    0x00010333u, 0x9642d72bu, 0x8f64942fu, 0xbf3a8eadu, 0x99ae6b9eu, 0x3d195b27u, 0xe7ef8deeu, 0x00010f84u,
    0x4e8737ecu, 0xbe2b9e55u, 0xa0d45e30u, 0x165d90f0u, 0xfa6b4410u, 0xb5fd4485u, 0x000107b9u, 0x83060dd8u,
    0xf56cdd11u, 0x648d18e8u, 0x091b3bfeu, 0x0d9ec6b5u, 0x006804bfu, 0x00010609u, 0xeac1beb1u, 0xb9c1ea7bu,
    0x347468a1u, 0x26dabb8au, 0x192608f3u, 0xf9df44dbu, 0x0001036au, 0xcd5612beu, 0x8e10d404u, 0x2a51fa50u,
    0xf9f40e2fu, 0x13777d7eu, 0x0bac1e60u, 0x000102c9u, 0xe54eedddu, 0xc6a101d7u, 0x96e00c0du, 0xa0dd71b6u,
    0x163338b0u, 0x95b816c1u, 0x00010642u, 0x42923564u, 0x7edb7146u, 0xe8b1701bu, 0x60721034u, 0x2aa8087eu,
    0xa906d244u, 0x000105a9u, 0xe6ddd9aeu, 0xeaf5889au, 0x984e52a9u, 0x523f1579u, 0x6d80259du, 0xcc8ea8e9u,
    0x000104a1u, 0xe609686fu, 0x9d5b7043u, 0xa83458dau, 0xc82e1abau, 0x7dece9d0u, 0x1fd8a99du, 0x00010eacu,
    0x695f5cc9u, 0x5d739950u, 0x42540641u, 0xca5e329fu, 0xaca5ffc0u, 0xf1f5a460u, 0x000106dbu, 0x01907640u,
    0x9ea8e934u, 0xefa91cd5u, 0xd8d54e81u, 0x5fd9c4feu, 0x7a98b251u, 0x000100fau, 0x1bbb78a1u, 0x1ee37afeu,
    0x315449adu, 0xcd598072u, 0x3ef3b1dau, 0xfdbe7a07u, 0x00010212u, 0xd75d85c5u, 0x0d221ffbu, 0xcb4b7b25u
};

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i30-intel-narrow-udiv";
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
