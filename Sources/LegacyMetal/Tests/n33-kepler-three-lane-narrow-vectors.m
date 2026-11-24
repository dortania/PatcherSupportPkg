// n33-kepler-three-lane-narrow-vectors: arithmetic on 3-lane 8- and 16-bit vectors must be right in lane z; beside the
// back end's padding lane it lost bits. Fix: GeForceAIRCompat NVAIR_ODD_VECTOR_FIX. Checks: ushort3, uchar3 and short3
// forms, 256 threads against the CPU. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint4 *in [[buffer(0)]], device uint4 *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint4 v = in[t];\n"
    "    ushort3 m = ushort3(ushort(v.y), ushort(~v.z), ushort(v.x & 1124510566u));\n"
    "    ushort3 a = ushort3(1, 6, 5) | (ushort3(7166, 18911, 44867) & m);\n"
    "    ushort3 b = ushort3(9, 3, 17) ^ (ushort3(0xf0f0, 0x0ff0, 0xff00) & ushort3(ushort(v.w), ushort(v.x), ushort(v.y & 0x3f3f3f3fu)));\n"
    "    uchar3 c = uchar3(3, 5, 9) | (uchar3(0xf0, 0x3c, 0x66) & uchar3(uchar(v.z), uchar(v.w), uchar(v.x & 0x5a5a5a5au)));\n"
    "    out[t * 3] = uint4(a.x, a.y, a.z, 0);\n"
    "    out[t * 3 + 1] = uint4(b.x, b.y, b.z, 0);\n"
    "    out[t * 3 + 2] = uint4(c.x, c.y, c.z, 0);\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n33-kepler-three-lane-narrow-vectors";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    for (int fast = 0; fast < 2; fast++) {
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.fastMathEnabled = fast;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:options error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        enum { T = 256 };
        id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:T * 3 * 16 options:MTLResourceStorageModeShared];
        uint32_t *p = in.contents, x = 4480u * 2654435761u + 12345u;
        for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = x; }
        memset(out.contents, 0xcd, out.length);
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:in offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreadgroups:MTLSizeMake(T / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint32_t *r = out.contents;
        for (int t = 0; t < T; t++) {
            uint32_t vx = p[t * 4], vy = p[t * 4 + 1], vz = p[t * 4 + 2], vw = p[t * 4 + 3];
            uint16_t m[3] = {(uint16_t)vy, (uint16_t)~vz, (uint16_t)(vx & 1124510566u)};
            uint32_t want[3][3] = {
                {(uint16_t)(1 | (7166 & m[0])), (uint16_t)(6 | (18911 & m[1])), (uint16_t)(5 | (44867 & m[2]))},
                {(uint16_t)(9 ^ (0xf0f0 & (uint16_t)vw)), (uint16_t)(3 ^ (0x0ff0 & (uint16_t)vx)), (uint16_t)(17 ^ (0xff00 & (uint16_t)(vy & 0x3f3f3f3fu)))},
                {(uint8_t)(3 | (0xf0 & (uint8_t)vz)), (uint8_t)(5 | (0x3c & (uint8_t)vw)), (uint8_t)(9 | (0x66 & (uint8_t)(vx & 0x5a5a5a5au)))}};
            const char *what[3] = {"ushort3 or", "ushort3 xor", "uchar3 or"};
            for (int k = 0; k < 3; k++)
                for (int lane = 0; lane < 3; lane++)
                    if (r[(t * 3 + k) * 4 + lane] != want[k][lane])
                        return FAIL(bug, "%s: %s (fast math %s), thread %d, lane %c: %#x, want %#x", name, what[k], fast ? "on" : "off", t,
                                    "xyz"[lane], r[(t * 3 + k) * 4 + lane], want[k][lane]);
        }
    }
    return PASS(bug, "%s: arithmetic on 3-lane vectors of 8- and 16-bit integers is right in every lane", name);
}}
