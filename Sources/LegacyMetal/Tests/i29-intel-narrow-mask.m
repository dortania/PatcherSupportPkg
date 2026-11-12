// i29-intel-narrow-mask (Intel adapter, IntelTextureAtomics.dylib): a uchar lane widened into a ushort2. The IGIL text
// truncates it with AND 255 and re-truncates the 16-bit result with AND 0xFFFF; iCBE took the second AND for a
// zero-extension of the first AND's source and dropped the 255, so ushort2(...) & ushort2((uchar)x, ...) kept bits 8-15
// of x (the disassembly folds 255, 0xFFFF and 0x9a4b into one AND with 0x9a4b; the MacBookPro11,5 session's
// narrow-vector fuzzing, seed 53). The adapter makes such a redundant second AND a MOV. On the differential fuzzer's
// 256-thread input, against the CPU reference.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    uint v0 = in[t * 4u] * 1u + t, v2 = in[t * 4u + 2u] * 5u + t, v5 = in[t * 4u + 1u] * 11u + t;\n"
    "    ushort2 a = ushort2((ushort)(35069), (ushort)(25597)) / ((ushort2((ushort)65535u, (ushort)((uint)((int)(v2) % 3))) | ushort2(1, 1)));\n"
    "    ushort2 c = ushort2((ushort)(39499), (ushort)(58089)) & ushort2((ushort)((uint)((uchar)((v5 ^ t)) >> 0u)), (ushort)((uint)((int)(v2) / (int)((v0 | 1u) & 0x7fffffffu))));\n"
    "    ushort2 o = a | c;\n"
    "    out[t * 8u + 5u] = o.x | (uint(o.y) << 16);\n"
    "}\n";

// out[t * 8 + w] for each thread t and w in kWords, from the CPU reference (cpuref.py) on the same input
static const int kWords[] = {5};
enum { kNumWords = sizeof kWords / sizeof *kWords };
static const uint32_t kExpected[256 * kNumWords] = {
    0x63fd0001u, 0x63fd0042u, 0xe2e90003u, 0x63fd0000u, 0x63fd004au, 0xe2e90003u, 0xe2e90043u, 0x60c8000bu,
    0xe2e90002u, 0x00000049u, 0x21540043u, 0x21540042u, 0x63fd0009u, 0x21540001u, 0xe0c90049u, 0xe2e80049u,
    0x21550003u, 0x63fd004au, 0x00000002u, 0x63fd0049u, 0xe2e90041u, 0x40000041u, 0xe2e90042u, 0x63fd0008u,
    0x2154004bu, 0x21540041u, 0x63fd0008u, 0x63fd004bu, 0xa2010040u, 0x00000008u, 0xe3fd004au, 0x63fd000bu,
    0x63fd000au, 0x00000043u, 0x63fd0049u, 0x20090003u, 0xe2e8000au, 0x63fd0042u, 0x63fd000au, 0x00000043u,
    0xe2e80049u, 0x2154004au, 0x63fd0009u, 0xe3fd0009u, 0x63fd0041u, 0x21540002u, 0xe3fd000au, 0x63fd0040u,
    0x00000000u, 0xe3fd0041u, 0x63fd0009u, 0x63fd0042u, 0x63fd004bu, 0x2155000au, 0xe2e9004bu, 0xe2e90042u,
    0x63fd0048u, 0x21550048u, 0x21540002u, 0x63fd0008u, 0xe3fd004au, 0xe2e90003u, 0x0000004au, 0xa0c0000bu,
    0x63fd0041u, 0xe3fd0048u, 0x63fd000au, 0x63fd0048u, 0x63fd0001u, 0x63fd000bu, 0xe2a90002u, 0x63fd004au,
    0xe3fd0008u, 0x63fd004au, 0x00000003u, 0x63fd0000u, 0x00000043u, 0x20e9004bu, 0xe2e9000au, 0x00000049u,
    0x21540042u, 0xe3fd0041u, 0xe2e90040u, 0x63fd0002u, 0x20890041u, 0x00000008u, 0x63fd004bu, 0x21540009u,
    0xe2e90041u, 0xe2e80042u, 0x63fd0002u, 0xe3fd004bu, 0xe3fd0003u, 0xe2e10008u, 0x63fd004bu, 0x63fd0003u,
    0x00000008u, 0xe2e90000u, 0xc2290048u, 0x63fd0042u, 0x63fd004au, 0x2154000bu, 0x63fd0048u, 0x63fd0043u,
    0x00000003u, 0xc0c00008u, 0x63fd0048u, 0x63fd0049u, 0x63fd0002u, 0x63fd0000u, 0x63fd0000u, 0xe2e90003u,
    0x63dd0040u, 0x00000042u, 0x63fd0040u, 0x63fd004au, 0x63fd0042u, 0xe2e90008u, 0x63fd0003u, 0x63fd0040u,
    0x63fd0042u, 0x00000048u, 0x21540043u, 0x63fd0048u, 0x63fd000au, 0xe3fd0000u, 0xe3fd0003u, 0x00000003u,
    0x0000004bu, 0x63fd0049u, 0x63fd0041u, 0xe2e9004bu, 0x63fd0041u, 0x63fd0048u, 0x21550048u, 0x00000043u,
    0x63fd000bu, 0x0000000bu, 0x21550000u, 0x63fd0009u, 0x63fd004bu, 0x21550040u, 0x00000001u, 0x63fd0043u,
    0x0000000bu, 0x21540042u, 0x21540043u, 0xe3fd0043u, 0x2155004au, 0x00000008u, 0x21540009u, 0x63fd0043u,
    0x0000000au, 0x63fd0009u, 0x63fd0043u, 0x00000001u, 0x00000009u, 0x21540009u, 0x63fd0002u, 0x63fd004au,
    0xe2e90000u, 0x63fd0043u, 0x63fd000bu, 0x63fd004au, 0x63fd0002u, 0x63fd0009u, 0xe2e80040u, 0x21540001u,
    0x00890049u, 0x63fd0048u, 0x63fd0002u, 0x63fd0003u, 0xe3fd0042u, 0x63fd0008u, 0x63fd000au, 0xe2e10000u,
    0x00000008u, 0x63fd0042u, 0x63fd000bu, 0x63fd0042u, 0x63fd0002u, 0x2154004bu, 0xe3fd000au, 0x0000000bu,
    0x63fd0043u, 0x21540001u, 0x63fd0001u, 0xe3fd0002u, 0x63fd004au, 0x63fd000bu, 0x0000000au, 0xe3fd0001u,
    0x63fd0002u, 0x00000040u, 0x21550003u, 0x63fd004au, 0x63fd004bu, 0x63fd000au, 0x00000043u, 0x63fd004bu,
    0x21550001u, 0xe3fd0049u, 0x21550008u, 0x63fd0009u, 0x63fd0049u, 0x21550008u, 0x63fd000au, 0x63fd0003u,
    0x63fd0048u, 0x63fd0040u, 0x63fd0049u, 0x63fd0042u, 0xe2e80001u, 0x63fd0000u, 0xe3fd004au, 0x63fd0049u,
    0xe2e90042u, 0xe3fd0001u, 0x63fd004au, 0xe3fd0000u, 0x63fd004bu, 0x00000048u, 0x63fd0003u, 0xe3fd0048u,
    0x62810043u, 0x21540000u, 0xe2c9004bu, 0x63fd0049u, 0xe3fd0000u, 0x63fd0002u, 0x0000004au, 0xe0090009u,
    0xe3fd0048u, 0x00000040u, 0x2154000bu, 0x63fd0000u, 0x63fd004au, 0x63fd0040u, 0xc0e10000u, 0x63fd0041u,
    0x63fd0008u, 0x21540002u, 0xe2e80000u, 0x63fd0002u, 0x21540008u, 0x4089000au, 0x21540043u, 0x63fd004bu,
    0x21540049u, 0x0000000au, 0xe2e90003u, 0xe3fd0042u, 0x23d50040u, 0xe2e90002u, 0xe2e90001u, 0x63fd000au
};

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i29-intel-narrow-mask";
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
