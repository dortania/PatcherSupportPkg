// n34-kepler-sign-extended-dividend: an unsigned division of a sign-extended 8- or 16-bit value must be exact; the back
// end divided it in floating point as a 16-bit value. Fix: GeForceAIRCompat NVAIR_SEXT_DIVIDEND_FIX (without:
// NVAIR_NARROW_DIVISION_FIX off too). Checks: six shapes, 256 threads against the CPU. Argument: GPU name (default:
// NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint4 *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint4 v = in[t];\n"
    "    out[t * 8 + 0] = (uint)((int)((short)(v.x)) % 28781) / ((v.y & 255u) | 1u);\n"
    "    out[t * 8 + 1] = (uint)((int)((short)(v.z)) % 7) / ((v.w & 255u) | 1u);\n"
    "    out[t * 8 + 2] = (uint)((int)((short)(v.x)) % 28781) % ((v.w & 255u) | 1u);\n"
    "    out[t * 8 + 3] = (uint)((int)((char)(v.y)) % 101) / ((v.z & 255u) | 1u);\n"
    "    out[t * 8 + 4] = (uint)((int)((short)(v.w)) / 1234) / ((v.x & 255u) | 1u);\n"
    "    uint3 r = uint3(int3(short3(short(v.y), short(v.z), short(v.w))) % int3(28781)) / uint3((v.x & 255u) | 1u, (v.y & 15u) | 1u, (v.z & 3u) | 1u);\n"
    "    out[t * 8 + 5] = r.x; out[t * 8 + 6] = r.y; out[t * 8 + 7] = r.z;\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n34-kepler-sign-extended-dividend";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:T * 8 * 4 options:MTLResourceStorageModeShared];
    uint32_t *p = in.contents, x = 5221u * 2654435761u + 12345u;
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
    static const char *what[8] = {"(int)(short)x % 28781 / d", "(int)(short)x % 7 / d", "(int)(short)x % 28781 % d", "(int)(char)x % 101 / d",
                                  "(int)(short)x / 1234 / d", "lane x of int3(short3) % 28781 / d", "lane y of the same", "lane z of the same"};
    for (int t = 0; t < T; t++) {
        uint32_t vx = p[t * 4], vy = p[t * 4 + 1], vz = p[t * 4 + 2], vw = p[t * 4 + 3];
        uint32_t want[8] = {
            (uint32_t)((int32_t)(int16_t)vx % 28781) / ((vy & 255u) | 1u),
            (uint32_t)((int32_t)(int16_t)vz % 7) / ((vw & 255u) | 1u),
            (uint32_t)((int32_t)(int16_t)vx % 28781) % ((vw & 255u) | 1u),
            (uint32_t)((int32_t)(int8_t)vy % 101) / ((vz & 255u) | 1u),
            (uint32_t)((int32_t)(int16_t)vw / 1234) / ((vx & 255u) | 1u),
            (uint32_t)((int32_t)(int16_t)vy % 28781) / ((vx & 255u) | 1u),
            (uint32_t)((int32_t)(int16_t)vz % 28781) / ((vy & 15u) | 1u),
            (uint32_t)((int32_t)(int16_t)vw % 28781) / ((vz & 3u) | 1u)};
        for (int k = 0; k < 8; k++)
            if (r[t * 8 + k] != want[k])
                return FAIL(bug, "%s: %s, thread %d: %#x, want %#x", name, what[k], t, r[t * 8 + k], want[k]);
    }
    return PASS(bug, "%s: unsigned divisions of sign-extended 8- and 16-bit values are right", name);
}}
