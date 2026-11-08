// a15-amd-branch-conditions (AMD adapter, AMDTextureAtomics.dylib): branches the 12.5 AMD compiler gets wrong once
// threads diverge. All found by differential fuzzing against a CPU reference:
//   bittest:  r += (x & 1) != 0 ? 49 : ((b & 1) != 0 ? in[2] : d)  in an unrolled loop. libAMDIL902 treats booleans as
//             0 / 1 when it simplifies but branches on the whole register: the load of in[2], guarded by "x even and
//             b odd", becomes "x == 0 and b odd", so most threads add d instead
//   loopexit: while (n < 8) { n++; v ^= ...; if (even(v ^ t) && (in[2] & 3) == 0) break; }  after a barrier. SC's code
//             for the loop's two exits sends the threads that stay to the wrong branch whenever some threads leave, and
//             they run once more
//   bitphi:   r = (a & 1) != 0 ? 0 : b; if (r < d) a ^= in[..]; s = ((a & 1) != 0 ? d : 1) & 1 ? .. : ..  The front end
//             tests a phi of the two a & 1 values after the if; once bittest's fix had made the first test an extract,
//             that phi was the and's only user and libAMDIL902 dropped its & 1 (right with stock files: a regression
//             of the fix, seed 2245), so the fix takes the phi's ands through extract_bits too
//   bitshort: while (n < 8) { n++; v = ...; s = select(short2(1, 1), short2(..) & short2(-12131, -9348), ..); if
//             ((uint(s.x) ^ uint(s.y) * 257) & 3) == 0) break; }  Bit 1 of s is known zero, so the front end tests
//             (s.x ^ s.y) & 1 on 16 bits, and the exit tested the whole 16 bits (seed 1932): the fix takes 8- and
//             16-bit single-bit ands through extract_bits too
//   maskfirst: if ((min(150u, K) > b) != bool(min(1u, 104u) & (c / 1522195843u))) ..  The min/max fix folds min(1u, 104u)
//             to 1 in place, leaving `1 & y` with the constant first, which the bit-test fix didn't look at: y = 2 took
//             the wrong branch (seed 2286). The mask is now found in either operand
// 256 threads each, checked against the same code on the CPU. Stock OCLP: FAIL. Fixed: PASS.
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void bittest(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 4u], b = in[t * 4u + 1u], d = in[t * 4u + 3u], r = 0u;\n"
    "    for (uint n = 0u; n < 4u; n++) { uint x = (a + n) ^ t; r += (x & 1u) != 0u ? 49u : ((b & 1u) != 0u ? in[t * 4u + 2u] : d); }\n"
    "    out[t * 2u] = r; out[t * 2u + 1u] = 0u;\n"
    "}\n"
    "kernel void loopexit(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint p0 = in[t * 4u], p1 = in[t * 4u + 1u] + 1u, v = in[t * 4u] + t, n = 0u;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    while (n < 8u) { n++; v ^= in[t * 4u + 3u] > (v ^ t) ? p0 : p1; if (((v ^ t) & 1u) == 0u && (in[t * 4u + 2u] & 3u) == 0u) break; }\n"
    "    out[t * 2u] = v; out[t * 2u + 1u] = n;\n"
    "}\n"
    "kernel void bitphi(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 4u] * 9u + t, b = in[t * 4u + 1u] * 3u + t, c = in[t * 4u + 2u] * 5u + t, d = in[t * 4u + 3u] * 7u + t;\n"
    "    uint e = in[t * 4u + 1u] * 11u + t, r = (a & 1u) != 0u ? 0u : b;\n"
    "    if (r < d) a ^= in[b & 1023u];\n"
    "    out[t * 2u] = r ^ a; out[t * 2u + 1u] = b + ((((a & 1u) != 0u ? d : 1u) & 1u) != 0u ? max(c, e) : e >> 3u);\n"
    "}\n"
    "kernel void bitshort(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 4u], b = in[t * 4u + 1u], c = in[t * 4u + 2u], d = in[t * 4u + 3u], v = 0u, n = 0u;\n"
    "    while (n < 8u) { n++; v = n ^ ((b & 255u) >> (n & 7u));\n"
    "        short2 s = select(short2(1, 1), short2(short(c - a), short(~a)) & short2(-12131, -9348),\n"
    "                          short2(1857, -32256) >= short2(short(d), short((v & 255u) * (v & 255u))));\n"
    "        if (((uint(s.x) ^ uint(s.y) * 257u) & 3u) == 0u) break; }\n"
    "    out[t * 2u] = v; out[t * 2u + 1u] = n;\n"
    "}\n"
    "kernel void maskfirst(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 4u], b = in[t * 4u + 1u], c = in[t * 4u + 2u], r;\n"
    "    if ((min(150u, 2153091561u) > b) != bool(min(1u, 104u) & (c / 1522195843u))) r = a; else r = b + 1u;\n"
    "    out[t * 2u] = r; out[t * 2u + 1u] = 0u;\n"
    "}\n";

static void reference(int kernel, const uint32_t *in, uint32_t t, uint32_t out[2]) {
    if (kernel == 0) {
        uint32_t a = in[t * 4], b = in[t * 4 + 1], d = in[t * 4 + 3], r = 0;
        for (uint32_t n = 0; n < 4; n++) {
            uint32_t x = (a + n) ^ t;
            r += (x & 1) ? 49 : ((b & 1) ? in[t * 4 + 2] : d);
        }
        out[0] = r;
        out[1] = 0;
    } else if (kernel == 2) {
        uint32_t a = in[t * 4] * 9 + t, b = in[t * 4 + 1] * 3 + t, c = in[t * 4 + 2] * 5 + t, d = in[t * 4 + 3] * 7 + t;
        uint32_t e = in[t * 4 + 1] * 11 + t, r = (a & 1) ? 0 : b;
        if (r < d) a ^= in[b & 1023];
        out[0] = r ^ a;
        out[1] = b + ((((a & 1) ? d : 1) & 1) ? (c > e ? c : e) : e >> 3);
    } else if (kernel == 3) {
        uint32_t a = in[t * 4], b = in[t * 4 + 1], c = in[t * 4 + 2], d = in[t * 4 + 3], v = 0, n = 0;
        while (n < 8) {
            n++;
            v = n ^ ((b & 255) >> (n & 7));
            int16_t sx = (int16_t)d <= 1857 ? (int16_t)((int16_t)(c - a) & (int16_t)-12131) : 1;
            int16_t sy = (int16_t)((v & 255) * (v & 255)) <= -32256 ? (int16_t)((int16_t)~a & (int16_t)-9348) : 1;
            if ((((uint32_t)(int32_t)sx ^ (uint32_t)(int32_t)sy * 257) & 3) == 0) break;
        }
        out[0] = v;
        out[1] = n;
    } else if (kernel == 4) {
        uint32_t a = in[t * 4], b = in[t * 4 + 1], c = in[t * 4 + 2];
        out[0] = ((150u > b) != (bool)(1u & (c / 1522195843u))) ? a : b + 1;
        out[1] = 0;
    } else {
        uint32_t p0 = in[t * 4], p1 = in[t * 4 + 1] + 1, v = in[t * 4] + t, n = 0;
        while (n < 8) {
            n++;
            v ^= in[t * 4 + 3] > (v ^ t) ? p0 : p1;
            if (((v ^ t) & 1) == 0 && (in[t * 4 + 2] & 3) == 0) break;
        }
        out[0] = v;
        out[1] = n;
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a15-amd-branch-conditions";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[src stringByAppendingString:reproUniqueComment()] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        enum { T = 256 };
        id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
        uint32_t x = 2654435761u + 12345u, *words = in.contents;
        for (int i = 0; i < T * 4; i++) {  // the fuzzer's input: xorshift, every 7th word small
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            words[i] = i % 7 == 0 ? (x & 0xff) : x;
        }
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        static const char *const kernels[] = {"bittest", "loopexit", "bitphi", "bitshort", "maskfirst"};
        char report[300] = "";
        for (int k = 0; k < 5; k++) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(kernels[k])] error:&err];
            if (!ps) return FAIL(bug, "%s: %s: %s", dev.name.UTF8String, kernels[k], err.localizedDescription.UTF8String);
            id<MTLBuffer> out = [dev newBufferWithLength:T * 8 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setBuffer:in offset:0 atIndex:0];
            [ce setBuffer:out offset:0 atIndex:1];
            [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [ce endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", dev.name.UTF8String, kernels[k]);
            int wrong = 0, first = -1;
            for (uint32_t t = 0; t < T; t++) {
                uint32_t want[2];
                reference(k, words, t, want);
                if (memcmp(want, (uint32_t *)out.contents + t * 2, sizeof want) && wrong++ == 0) first = (int)t;
            }
            if (wrong) {
                char line[120];
                snprintf(line, sizeof line, "%s%s: %d of %d threads wrong (first %d)", report[0] ? "; " : "", kernels[k], wrong, T, first);
                strlcat(report, line, sizeof report);
            }
        }
        if (report[0]) return FAIL(bug, "%s: %s", dev.name.UTF8String, report);
        return PASS(bug, "%s: bit tests or'ed with other conditions, of phis and of shorts, and loops with two exits branch right", dev.name.UTF8String);
    }
}
