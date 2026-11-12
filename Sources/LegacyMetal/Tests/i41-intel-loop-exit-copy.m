// i41-intel-loop-exit-copy (Intel adapter, INTEL_LOOP_EXIT_COPY_FIX): a loop-carried value read after the loop. The
// back end ends a loop body with the copies into the next iteration's registers and then the exit test, and iCBE reads
// the register that took the previous value at the top of the body as if it held the new one: in
// `p[...] = pc[addsat(0x7fffffff, v4 ^ t) & 7]; v4 = 0;` in a loop, with the store sunk out of it (after i07's private
// array rewrite), threads that left in the first iteration read pc at the index for v4 = 0, so out[0] and out[5] came
// out wrong in 8 of 256 threads. The adapter moves those copies after the exit test. Found by differential fuzzing
// (mslfuzz2 plain seed 565, reduced). Expected values from the CPU reference (cpuref.py) on the fuzzer's input.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
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
    "    switch (0u) {\n"
    "    default: {\n"
    "        v5 ^= p[((((uint)((int)((v2 ^ t)) % (int)((v1 | 1u) & 0x7fffffffu)) & 1u) != 0u ? (0u) : (uint)(1u))) & 7u];\n"
    "        break; }\n"
    "    }\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        p[(insert_bits((uint)(select((int)(v5), (int)(in[(t * 4u + 1u)]), ((v0 ^ t) & 2u) != 0u)), (uint)((int)(2147483647u) >> (int)((v3 ^ t) & 31u)), (uint)(0u), (uint)((uint)(pc[(49u) & 7u]) & 15u))) & 7u] = (uint)(pc[(addsat(2147483647u, (v4 ^ t))) & 7u]);\n"
    "        v4 = (uint)(0u);\n"
    "        if ((((mulhi(v3, in[(t * 4u + 0u)]) / (1u))) & 3u) == 0u) break; } v2 += n0; }\n"
    "    v2 = (uint)(!(v1 > (uint)(pc[((in[(t * 4u + 2u)] | v5)) & 7u])));\n"
    "    if (1u) {\n"
    "        v3 -= (uint)(max((int)((uint)((int)((uint)((int)((v3 ^ t)) % (int)(((v5 ^ t) | 1u) & 0x7fffffffu))) / (int)(1u))), (int)(0u)));\n"
    "    }\n"
    "    v0 ^= p[((uint)(-(int)(((v1 ^ t) == 1269682982u ? in[(t * 4u + 0u)] : in[(t * 4u + 1u)]) & 0x7fffffffu))) & 7u];\n"
    "    { tg[l] = addsat(min3(156u, in[(t * 4u + 3u)], v4), (uint)((ushort)(in[(t * 4u + 3u)]) | (ushort)(v5))); threadgroup_barrier(mem_flags::mem_threadgroup); v5 += tg[(insert_bits((65535u == (v0 ^ t) ? in[(t * 4u + 1u)] : 1u), (in[(t * 4u + 1u)] << (0u)), (uint)(0u), (uint)(0u))) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    switch (((uint)((short)(((0u) != 0u ? 32u : v3)))) & 3u) {\n"
    "    case 0u: {\n"
    "        break; }\n"
    "    default: {\n"
    "        v5 = (uint)((bool)((uint)(select((int)(0u), (int)(rotate((v0 ^ t), v2)), (1u) != 0u)) & clz((36u & in[(t * 4u + 0u)]))));\n"
    "        break; }\n"
    "    }\n"
    "    v5 -= insert_bits(((v3 % ((uint)((ushort)(in[(t * 4u + 3u)]) >> (v0 & 7u)) | 1u))), (0u), (uint)(0u), (uint)(0u));\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 5u] = v5;\n"
    "}\n";

// out[t * 8 + w] for each thread t and w in kWords, from the CPU reference (cpuref.py) on the same input
static const int kWords[] = {0, 5};
enum { kNumWords = sizeof kWords / sizeof *kWords };
static const uint32_t kExpected[256 * kNumWords] = {
    0x2c7496efu, 0xc5777be0u, 0x776be7cfu, 0x00000001u, 0x139e145bu, 0xfffffe87u, 0x00000001u, 0xfffff48du,
    0xf8e5017bu, 0x80994f2eu, 0x3f82da99u, 0xffffb2c1u, 0x2518b34eu, 0x357bc3cfu, 0x6a10f128u, 0xfffffdf8u,
    0x39f06c86u, 0xea8b9dd6u, 0x6874777fu, 0xffffffe1u, 0xace44317u, 0xfffffef3u, 0x8e003985u, 0x8e758abbu,
    0xb823297eu, 0xffffffdcu, 0xda141a07u, 0x1a87c8ddu, 0xd410682du, 0xffffffe1u, 0x1c9b53a5u, 0xfffffffeu,
    0x703f41f4u, 0x915d4721u, 0x4c12c974u, 0xfffffa1au, 0x0eb36160u, 0xffff7175u, 0xca691268u, 0xffff7c7eu,
    0xa6e5b89bu, 0xfffff726u, 0x60bc5dd5u, 0xfffffd4cu, 0x4e2d448au, 0xffffffeeu, 0x00000037u, 0xfffffea4u,
    0xf2995cfbu, 0x5a1f240cu, 0x542fcd19u, 0xffffa001u, 0x0000006eu, 0xfffffe27u, 0x7212496du, 0xfffffc25u,
    0x000000f8u, 0x0a8fc01cu, 0x00000029u, 0x00000001u, 0x5b1d29d5u, 0xffffff35u, 0x4d0bfb36u, 0xfffffc8fu,
    0x7c3d98d2u, 0xfffff423u, 0xe0f5809cu, 0x0000a085u, 0xbde188e3u, 0xfffff69bu, 0x8597903fu, 0xffffff66u,
    0x71086dd8u, 0x95212606u, 0x0b4390e6u, 0x14a8fd17u, 0xd61da6c8u, 0xffffe16cu, 0xb6aa1754u, 0x6d399e7au,
    0x009078f8u, 0x0000550du, 0xe7b20624u, 0xfffffdb6u, 0xe03f4413u, 0xfffffd34u, 0x85ce8f5fu, 0x00000001u,
    0xbe19fdb8u, 0xfffff083u, 0x8bb1f692u, 0x9e007269u, 0x9c99036du, 0x7eaeb48eu, 0x0000006fu, 0xffffffe8u,
    0x00000054u, 0xffffff78u, 0x00000051u, 0xfffffff2u, 0x99815f52u, 0xffffffd2u, 0x53e045bfu, 0xa298af1cu,
    0x43ea413fu, 0xfffffffcu, 0x24a7c587u, 0xfffffff6u, 0xc3a4add6u, 0xffffffe4u, 0x167b8636u, 0x35fc3476u,
    0x00000054u, 0xfffffaf9u, 0x00000055u, 0xfffffffcu, 0xfe203b56u, 0xfffffe8eu, 0x000000c5u, 0xfffffd02u,
    0xe0f58e4fu, 0xbbc6e992u, 0x8f86e5b8u, 0xffff7586u, 0xbc899a03u, 0xfffffd26u, 0x69ee3d07u, 0xffffffe6u,
    0x5a533402u, 0xc87ebe02u, 0x00000041u, 0xffffffbfu, 0x5cb4f5fcu, 0xfffffe59u, 0x00000041u, 0xffffe864u,
    0x95ab203bu, 0xfffffabfu, 0x3080a734u, 0xfffffe97u, 0xb6441f54u, 0xfffffa6au, 0xa8130c1fu, 0x00000001u,
    0x00000048u, 0x51702ffdu, 0xfe5faf27u, 0xffffffcau, 0xb62b0945u, 0xfffffe87u, 0x000000f9u, 0x000063c0u,
    0x8dde6eeau, 0xed2f8c6fu, 0x4f1ccaf1u, 0xffffde5eu, 0xf8f913ecu, 0x00000000u, 0x5fabedccu, 0xffffffbeu,
    0x2a2169a0u, 0xffff4778u, 0x257430d3u, 0xfffff91au, 0x00000052u, 0xfffffc04u, 0x9d7bc98au, 0x009feb8du,
    0x4084599du, 0xc5b02d9eu, 0x00000055u, 0xfffffffcu, 0x48e231dcu, 0x7328c092u, 0x5b139666u, 0xffffff7bu,
    0xa6c711b5u, 0xffffffaeu, 0x28108498u, 0xffffffa9u, 0x9d000cc3u, 0x1da8e017u, 0x25ef7bdfu, 0xfffffef8u,
    0x43488ff6u, 0x4bcd88d8u, 0x00000063u, 0xaec993d9u, 0x5cd06aefu, 0xffffff90u, 0x1646aca0u, 0xffffdfc9u,
    0x000000ecu, 0x696ab01cu, 0x0000006fu, 0xfffffea2u, 0x000001a2u, 0x95fe38b9u, 0x98a47499u, 0xffffffdeu,
    0x112d43ffu, 0xffffff07u, 0xbd558b99u, 0xfffff302u, 0x000001bau, 0xaef25241u, 0xaf5c957fu, 0xffffff52u,
    0xafadc970u, 0x86994f9cu, 0x000000afu, 0xffffffacu, 0x0000006au, 0xfffffff1u, 0x0391cfffu, 0x144e16efu,
    0x693945afu, 0x972e3c59u, 0x000003bbu, 0xfffff56cu, 0x0000007au, 0xffffefa8u, 0xaf12679eu, 0xffffffcdu,
    0x000000ecu, 0xffffff0fu, 0xe8c22b7cu, 0xfffffffcu, 0x0000079eu, 0xffffff90u, 0xd825c564u, 0xfffffbf1u,
    0x1714511fu, 0x62b88694u, 0x00000795u, 0xffffff14u, 0x536b3ff5u, 0xffffffabu, 0x000001f3u, 0x3efaa4eau,
    0x98141067u, 0xc2e306f8u, 0x00000095u, 0xfffffffau, 0xfcad2bfeu, 0x14caa550u, 0x000000bdu, 0x9a2ac857u,
    0x5bfe8722u, 0xffffe989u, 0x0000018bu, 0xfffffc29u, 0x621ec7bfu, 0xfffffe80u, 0x19a75ba1u, 0xffffffd8u,
    0xd0368983u, 0xffffeb5cu, 0x999e96feu, 0xffffff74u, 0xeb7dd1dfu, 0xffffffcbu, 0xdc574279u, 0xffff9bd3u,
    0x707d9493u, 0xfffff567u, 0x00000185u, 0xfffffec5u, 0x00000182u, 0xfffffffcu, 0x714f70ebu, 0xffffff7cu,
    0xa4866d2du, 0xfffffe3du, 0x5dae6d8du, 0x2d59be1du, 0x0000039au, 0xffffe2f2u, 0x8a21f72cu, 0xfffffba5u,
    0x17f3cec4u, 0xfffffbcbu, 0x00000095u, 0x00000001u, 0x0644b72eu, 0xffffff8bu, 0x57ecb2f3u, 0xfffff833u,
    0xd89db7eau, 0xfffff859u, 0x0c553610u, 0xfffff80fu, 0x63cefa0cu, 0x7f56b5c3u, 0xa099f998u, 0x4604d3c0u,
    0xd41b402bu, 0xef210939u, 0x00000091u, 0x070bc366u, 0x56ba9df0u, 0xffff53e2u, 0x7e48f7dcu, 0xffffffb3u,
    0x10a8f84bu, 0xfffff367u, 0x5dd84b45u, 0xfffffffbu, 0x59cc4957u, 0xffffff77u, 0xf74a248eu, 0xffffffffu,
    0x0139d69cu, 0x751fb85fu, 0x5ee6e064u, 0xfffffdbeu, 0x4edad1f5u, 0xf4bcf0d0u, 0xb7e458bbu, 0xfbad34dbu,
    0x000000e4u, 0x7dca6207u, 0xfe5118c3u, 0xfffffd4fu, 0xf0a5c123u, 0xfffffffeu, 0x96c27255u, 0xfffffeecu,
    0x1ac6b037u, 0xffffff31u, 0x79b8da50u, 0xfffffbebu, 0x0000016eu, 0xffffffe9u, 0xfc7b695du, 0xffffffbau,
    0xddb6e0a0u, 0xffffdbdfu, 0x000000fdu, 0xfffffffcu, 0x39db9168u, 0xfffff64au, 0x3f43c4edu, 0xfffff8e9u,
    0xe1db4182u, 0xffffefeeu, 0x0000016du, 0x00008997u, 0xccc0025eu, 0xffffff7eu, 0x0000017du, 0xfffffe23u,
    0x000000bcu, 0xa308d313u, 0x874dbfc1u, 0xc477cacau, 0xd8fb43d3u, 0xffffff93u, 0xfa551391u, 0x0cba83c0u,
    0xf66aa794u, 0xffffffbau, 0x5bfd0036u, 0xffffff72u, 0x5625751fu, 0xfffffff9u, 0x599a1d90u, 0xffffffbfu,
    0x1b4518f0u, 0xfffff7d6u, 0xb5d6ae2cu, 0xfffffbc6u, 0x03266caeu, 0xffffffffu, 0x80e820dau, 0xffffffd5u,
    0x807521b9u, 0xffffcfe6u, 0xe072615au, 0xffffe3c1u, 0x19e2d43au, 0xffffffd8u, 0x2a8ba776u, 0x9228621au,
    0x940d0dc4u, 0xffffffceu, 0x000001c7u, 0xffffff6eu, 0x44d90da0u, 0xad7705b4u, 0x33726a4du, 0x7dd41d45u,
    0xad1b92b8u, 0xffffa6b7u, 0x441592d3u, 0xfffffff4u, 0x5172a10du, 0xfffffe0bu, 0x4e3f72a6u, 0xa9051de9u,
    0x43583c68u, 0xffffcde6u, 0x431711eeu, 0x1e9c59ddu, 0x000000c6u, 0xffffff0eu, 0xe8b92da9u, 0x3d820b58u,
    0xd000ce8du, 0x5c29dbeeu, 0x00000153u, 0xffffffa6u, 0x66190131u, 0xfffff85cu, 0xac9c4f8au, 0xfffff01au,
    0x00000750u, 0xffffe4bdu, 0x00000751u, 0xfffff5cfu, 0xad01b659u, 0xffffff4fu, 0x813d9671u, 0xffffffdcu,
    0x24a9458fu, 0xffffffa2u, 0x00000171u, 0x1969fde4u, 0xb347314bu, 0xfffffd41u, 0xf18a220cu, 0x0000f238u,
    0xebe9e935u, 0xfffffeb4u, 0xabf47e5cu, 0xfffffd0eu, 0xca05a601u, 0xfffffff1u, 0x00001f2bu, 0xfffffcb5u,
    0x433399d1u, 0x5647ba67u, 0x00000725u, 0xfffffdabu, 0x81b4a06eu, 0xfffffe3cu, 0x00000327u, 0x456d7f0au,
    0x0000015bu, 0xfffffce7u, 0x000003e3u, 0xffffffe9u, 0x7e17df3au, 0xfffffcfeu, 0xd4611ab4u, 0xffffffe4u,
    0x0000011cu, 0xfffffea8u, 0x5bc8b7b6u, 0xffffffb3u, 0xb794059au, 0xfffffdfeu, 0x00000112u, 0xffffee91u,
    0x00000178u, 0xda16a8dfu, 0x4345a01bu, 0xfffff19au, 0xeb55d793u, 0xffffffe7u, 0x00000729u, 0xbb869c4cu,
    0x5f2e4c54u, 0xfffffeb5u, 0x00000317u, 0x17f847e6u, 0x0000012eu, 0xfffffeeeu, 0xc7490d2au, 0xffffffedu,
    0x00000710u, 0x63c78bc4u, 0x6ff63c43u, 0xffffed25u, 0x181797d1u, 0xfffffce7u, 0x2c0ea2b3u, 0x438ac601u,
    0x0000017cu, 0x4c893cbau, 0x30b99779u, 0xffffa8cbu, 0x914d9c75u, 0x00000000u, 0xf3d8c44eu, 0x257d6f9bu,
    0xd422cc1du, 0xfffffe6fu, 0xe515a1f1u, 0xfffffb82u, 0x95376a40u, 0xffffffdbu, 0xac07b060u, 0xffffd6aau,
    0x000001f0u, 0xffff9cdau, 0x2d09a7f6u, 0xffffffffu, 0x64b84f33u, 0xfffff9acu, 0xc1412a13u, 0xfffff950u
};

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i41-intel-loop-exit-copy";
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
