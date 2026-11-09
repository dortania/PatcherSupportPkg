// i44-intel-private-array-partial (Intel adapter, INTEL_PRIVATE_ARRAY_FIX): i07 rewriting only part of an array. i07
// decided GEP by GEP whether it could rewrite a variable-index access; the front end had stored `p[i] = in[3]` as a
// <2 x i16> through a bitcast of the element's address (in[3] was also used as a ushort2), so that store stayed as the
// front end wrote it while the array's other variable-index store was rewritten, and the back end then addressed the
// array both ways: its contents after the first store were wrong in all 256 threads (mslfuzz2 VEC=1 seed 1469,
// reduced; the stock compiler gets it right). Loads and stores through a same-size bitcast are now done in the
// element's own type, and an array is rewritten whole or not at all. Expected values from the CPU reference
// (cpuref.py) on the fuzzer's input. Fixed: PASS. Argument: GPU name substring (default: Intel).
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
    "    p[(vf((as_type<uchar4>((ushort2((ushort)((uint)((short)(v1))), (ushort)(v1)) & ushort2((ushort)((v3 << (v1 & 31u))), (ushort)(max(2655246051u, (v3 ^ t))))))))) & 7u] = (uint)((uchar)(in[(t * 4u + 3u)]) >> ((uint)((ushort)(in[(t * 4u + 0u)]) - (ushort)(in[(t * 4u + 3u)])) & 7u));\n"
    "    out[t * 8u + 5u] = p[0] ^ (p[1] << 1) ^ (p[2] << 2) ^ (p[3] << 3) ^ (p[4] << 4) ^ (p[5] << 5) ^ (p[6] << 6) ^ (p[7] << 7);\n"
    "    atomic_fetch_add_explicit(&ta, ((uint)((uchar)(min(2930715104u, (v0 ^ t))) >> ((uint)(pc[(v0) & 7u]) & 7u))) & 255u, memory_order_relaxed);\n"
    "    v0 = (uint)((int)((ushort)(vf(((max(uchar2((uchar)(237), (uchar)(33)), uchar2((uchar)(88), (uchar)(66))) & (uchar2((uchar)(183), (uchar)(17)) << uchar2((uchar)(4), (uchar)(7))))))) >> (vf((as_type<ushort2>(in[(t * 4u + 3u)]))) & 15u)));\n"
    "    p[(vf((((char2((char)((uint)(-(int)((v2 ^ t) & 0x7fffffffu))), (char)(in[(t * 4u + 2u)])) | char2((char)((uint)(select((int)(in[(t * 4u + 3u)]), (int)(in[(t * 4u + 3u)]), ((v0 ^ t) & 2u) != 0u))), (char)((uint)(select((int)((v0 ^ t)), (int)(in[(t * 4u + 0u)]), (114u & 2u) != 0u))))) & char2((char)(-72), (char)(-91)))))) & 7u] = in[(t * 4u + 3u)];\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^ (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);\n"
    "}\n";

// out[t * 8 + 5] and out[t * 8 + 6] for each thread t, from the CPU reference (cpuref.py) on the same input
static const uint32_t kExpected[256 * 2] = {
    0xd86827f9u, 0x74799cbcu, 0xaaa3796eu, 0xb7456474u, 0x48fb2108u, 0xedc50967u, 0x9353527fu, 0x139d4c4bu,
    0x2293be4bu, 0xa661a5d5u, 0xa059bbe3u, 0x69d3f1a2u, 0x2f63c941u, 0x3184d331u, 0x14b04efcu, 0x70156becu,
    0xfe141b3au, 0x2a981f63u, 0x32bc7225u, 0xd327f138u, 0xa05e2454u, 0x0fdd03d1u, 0x974d362au, 0x0f18a089u,
    0x71f078b6u, 0xf7497496u, 0xb9899100u, 0x12c565deu, 0xb20b9897u, 0xa2f62e86u, 0x0eacca0du, 0x0e722b49u,
    0x931accabu, 0x6dd92cceu, 0x8caa5157u, 0x0ffae6c3u, 0x9016aa91u, 0x667e5d48u, 0x2eec154du, 0x66915adbu,
    0xd6cbcfbfu, 0x1da8ff3du, 0xd1c38d81u, 0xa884084fu, 0x8d811706u, 0xf01dca2fu, 0x752e7b22u, 0x7a6d7f5au,
    0x6ae2a754u, 0xaed71414u, 0x4af24d08u, 0xebaa35f3u, 0xaf8c23f6u, 0x32136ca3u, 0x84025c46u, 0x6f991a3du,
    0x6fca2668u, 0xf168958au, 0x06ff9e26u, 0x00ec9175u, 0x14497678u, 0x3acde871u, 0x7f9780c7u, 0xbf1e2e1au,
    0xdd1e4bebu, 0x9d785cfeu, 0xcc82e893u, 0x0a46c5d1u, 0x40d9df6du, 0xcd12542eu, 0xc6859c61u, 0xbd76d0d4u,
    0x8d1019b8u, 0x78d8e6c9u, 0x7daa739du, 0x34ca3d2fu, 0x6d9aa072u, 0x76878e22u, 0xa84b8109u, 0x04ea99efu,
    0xdbd53730u, 0x4def3fd7u, 0x15dbc207u, 0x3d2c8bbau, 0x38844bb3u, 0x78c2c372u, 0xd90a0a45u, 0x874937dbu,
    0x86df61f8u, 0x6eb02c3au, 0xf9f49adcu, 0x01daef40u, 0x4d538e57u, 0x41aeebf2u, 0x57cddb14u, 0x7a2dc667u,
    0x31245a5bu, 0xc9344f78u, 0xa222ef94u, 0x4fb01772u, 0xc41cb864u, 0x859acdd4u, 0x674921d9u, 0x252daa0au,
    0xc87813abu, 0xd8186215u, 0x12af1006u, 0x5c0d2d28u, 0xbb13eb22u, 0x453bac16u, 0xb4229b3au, 0x9185bc4au,
    0xf7023895u, 0x158b8159u, 0x95bc2904u, 0x514e7d2bu, 0x95cfde49u, 0x8c39d107u, 0x973a1ae1u, 0x5383f330u,
    0x4b2fbb39u, 0xf427d536u, 0xd3c53726u, 0x35e815b2u, 0x9797fd51u, 0x35bf0497u, 0xd5b8357du, 0xa404252du,
    0x955cc6bau, 0xeb0e06deu, 0xd01ed910u, 0xc75ade8du, 0xf3ecd219u, 0x3d849fc8u, 0x7a0cef07u, 0x069eec29u,
    0x7ccf08c7u, 0x81d502b7u, 0xe2ce327fu, 0xac0f10ffu, 0x8195972cu, 0x6bfdc590u, 0xfe2ac16du, 0x8ab25ba3u,
    0x511a299fu, 0x9e50e6d8u, 0x6acea298u, 0xc57a108fu, 0xb509316bu, 0x5a0f1431u, 0xe771fae9u, 0x10f945f8u,
    0x0bb61b66u, 0x88ef94d0u, 0x77995d28u, 0x0b1963a6u, 0x36f317d5u, 0x81c2ab09u, 0x04ae7326u, 0xcc6e4273u,
    0xe86700d4u, 0xbfb0e236u, 0xad505f5du, 0x666be62eu, 0x4ce1a743u, 0x90a52985u, 0x9cb31ff3u, 0x51c6f788u,
    0x03f196bbu, 0xde4ade02u, 0xcbbeda92u, 0x10253e60u, 0x7803d1e9u, 0xec0c13afu, 0xad065874u, 0x9233e9d8u,
    0xf07de8a8u, 0xb41937dfu, 0xe1af6295u, 0xde78677eu, 0xc7f3fbe8u, 0xbc816b0fu, 0x646bb711u, 0xaed4da1eu,
    0x73823b98u, 0x1a2a0180u, 0xd71894d5u, 0x70c94accu, 0x624d947fu, 0x340f1c96u, 0xf3ff723bu, 0xe9003571u,
    0x5e8c4536u, 0x69d23dc8u, 0x1ee70b69u, 0xa85f7de1u, 0x550ee0feu, 0x81808caeu, 0x78b447abu, 0x1ff30500u,
    0x1daa27e6u, 0xdbf595c8u, 0xb0582184u, 0x2c77be27u, 0x407f4059u, 0x51ce2632u, 0x1ef58c31u, 0xb53e473eu,
    0xe593331du, 0x5858d642u, 0xf460ae75u, 0xfff6c1d3u, 0xff8a2277u, 0xa91c4932u, 0xb71bac73u, 0x8775285au,
    0x3cac6f81u, 0x94504ab5u, 0x8fd4681fu, 0x343cee84u, 0xd2806182u, 0x9faa532au, 0x7bf5221bu, 0x53d1d7f4u,
    0x42b9aea0u, 0x518588c2u, 0x4495a32eu, 0x8df7c550u, 0x75568d18u, 0x1dff9168u, 0x947abd91u, 0xa54234fcu,
    0xae39651eu, 0xb0e0bf09u, 0xda2734e4u, 0x369e035fu, 0x0df523c4u, 0x606ca874u, 0x0471840eu, 0x3835da60u,
    0x32b4597au, 0xbb4692bbu, 0x1ff2c36au, 0x94a6f5bdu, 0x6c04a3ecu, 0xe199b76eu, 0x381f806du, 0xbb72cfb7u,
    0x0a79093cu, 0x96798cbcu, 0x60413af7u, 0xa85c2360u, 0x9ee943ceu, 0x98da3bffu, 0x4c5442c6u, 0x03555c06u,
    0x639bffecu, 0xe55ef2b2u, 0xe4e072bau, 0x63904422u, 0x53262b4du, 0x53b1b8b5u, 0x4e634292u, 0x5e25593fu,
    0x465469d7u, 0xd84cd1b6u, 0x4adf4e4cu, 0x232ae859u, 0x007decc3u, 0xe3e3fa97u, 0x897159a7u, 0x73bd9449u,
    0xd5678199u, 0x0752ddcdu, 0xd2fc0c5cu, 0xdd61a073u, 0x39133b10u, 0x017e4e4fu, 0x2d238a50u, 0x7cf2dca2u,
    0x3c884a82u, 0xeeb1ce9eu, 0x10af20fau, 0x7b012988u, 0xfe96553cu, 0x18957ccdu, 0x38066682u, 0x34dfe84au,
    0x9e9e0578u, 0x45ce4f22u, 0x67d16dedu, 0x5ab66019u, 0x3f058c07u, 0xc245bbefu, 0x7bfb9389u, 0x5535663cu,
    0x9119534cu, 0x0f0b7bedu, 0x8952ae30u, 0xf9264a9du, 0x1d4c527eu, 0xd8096e2fu, 0xbf8656f7u, 0x67efe45au,
    0x26e597d7u, 0xa9e771e0u, 0xa45c987eu, 0xa8c0b01eu, 0x35ec095bu, 0xcdff1bd9u, 0x30ebf5e6u, 0x6d9a1ca4u,
    0xa66ba6c4u, 0x2fe4d137u, 0x712823b2u, 0xb6dfcffcu, 0x6e6b0463u, 0x7333b229u, 0x9fcecedau, 0x0f689e0cu,
    0x9e9c1942u, 0x94f6de70u, 0xf917e9d6u, 0x728a208au, 0xd2563f7du, 0x52e234e4u, 0x2af18142u, 0xf0f64324u,
    0x958dbbe4u, 0x71228220u, 0x27d0d46cu, 0xfb82015du, 0x97918b48u, 0x1d6a07bbu, 0x5c174806u, 0xfd3e111cu,
    0xec200f68u, 0x8769db1bu, 0x3790ee2au, 0xa64aa594u, 0xa6b08b5au, 0xe8867593u, 0x697e2912u, 0x419755b8u,
    0xa0e5585eu, 0x16c1ce3fu, 0xa8ecca91u, 0x8e4b04ccu, 0x508a2f3fu, 0xdd4bd8b6u, 0xac58d223u, 0x2184d5f6u,
    0xbd0a55c6u, 0x74dad5c4u, 0xab1de06fu, 0xf513ce16u, 0xd1ed2185u, 0xd29436a5u, 0xd2dfd37du, 0xdf157236u,
    0xe9c61c70u, 0x64bd1a97u, 0xa8cc0ab1u, 0x038dc1cbu, 0x1aef8b9eu, 0x23762959u, 0x265b6234u, 0x481cb943u,
    0x8fa91021u, 0xaf7379beu, 0xc7b69fdcu, 0xdece90b7u, 0x00e98840u, 0xd3b68be4u, 0x5bfd01ceu, 0x6acc2693u,
    0xfc500b36u, 0xd715a25au, 0xd7f32bddu, 0xe4211c76u, 0xa0b93693u, 0xf5816986u, 0x636bf635u, 0x028fa0ebu,
    0xc946c963u, 0xd5cdbe6bu, 0xb48381cdu, 0x6778bde6u, 0x8ea1ff90u, 0xd4b62e6au, 0xc72f0696u, 0xbf339804u,
    0x89755eb6u, 0xc880136fu, 0xfa8b374du, 0x56fdb3deu, 0xe56d44a9u, 0xd65a63ecu, 0xbbc9c1afu, 0x442fb96fu,
    0x7f0f452eu, 0xb4d70e9bu, 0xb5246025u, 0x0ee1110eu, 0xa2b7e6e3u, 0x92f8039fu, 0x5f590d21u, 0x2495afc1u,
    0xd1a9e7f3u, 0x1c096ee2u, 0xbd26f979u, 0x9f13847du, 0x01e05912u, 0xcb891b77u, 0x1b870fb0u, 0x0d339f32u,
    0xb64b5bedu, 0x78f64a67u, 0xd8f716cau, 0xa2d3aa5cu, 0xecdd85e7u, 0xa4b91041u, 0x85d1e9cbu, 0xb0b4c0b4u,
    0xac0242dbu, 0x8e438dfcu, 0xd7b6ec9au, 0x40de7ac3u, 0xe4ca7f16u, 0x30ee267fu, 0x6b1a0307u, 0xc851f7c0u,
    0xcabcea2eu, 0xb4b541d8u, 0xf14a0b15u, 0xc7337b05u, 0xbb12ef36u, 0x5a32a8dfu, 0xe7555bc6u, 0xde0bbc44u,
    0x019c0298u, 0xa8b96655u, 0x0b23fa38u, 0x5e345806u, 0x1a562b21u, 0x9d550657u, 0x400ee0bcu, 0x74681cdbu,
    0xb06a4af3u, 0x54bb7c00u, 0xb1b23d97u, 0x68ff4de6u, 0xfb8a99aeu, 0x448bd0afu, 0x6141994fu, 0x1b1b18ffu,
    0x508079c3u, 0x4a6ff468u, 0x7b69b444u, 0x17f5bea3u, 0x065fbad5u, 0x049e57deu, 0x6cb99e62u, 0x40cd43adu,
    0x60189af6u, 0x9ef7b48cu, 0xfaa77857u, 0x0e78d856u, 0xb32f2ef2u, 0xf160fff2u, 0xa44ec76fu, 0x0d9897acu,
    0x991f9c15u, 0x128404c0u, 0x983f2d2du, 0x1f20b237u, 0x73e1a0c3u, 0x13a1d7ddu, 0xcef69915u, 0xf09f8ea0u,
    0x07d5badeu, 0x898064d0u, 0x883af4c9u, 0x9aee5873u, 0xe2309b19u, 0x30be7347u, 0x00bc5b7au, 0xe5c951d2u,
    0xb5632a14u, 0x9048c87fu, 0x34663336u, 0xc58d19b5u, 0x81f4832du, 0x7e4e78acu, 0x01c0689bu, 0x6f616664u,
    0x6b2509d9u, 0xe855ed95u, 0x52a95096u, 0xb28ae465u, 0x7b3dfe36u, 0x4dc73a77u, 0x91b60ddeu, 0xe4412634u,
    0x0008d815u, 0x0dbcc5a1u, 0xb3d003e7u, 0x96c9394cu, 0x4d2760edu, 0xff29de67u, 0x204d786cu, 0x8377b643u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i44-intel-private-array-partial";
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
    int wrong = 0, first = -1, word = 0;
    for (int t = 0; t < T; t++)
        for (int k = 0; k < 2; k++)
            if (o[t * 8 + 5 + k] != kExpected[t * 2 + k] && !wrong++) first = t, word = k;
    if (wrong)
        return FAIL(bug, "%s: %d results wrong (thread %d, out[%d]: %08x, want %08x)", name, wrong, first, 5 + word,
                    o[first * 8 + 5 + word], kExpected[first * 2 + word]);
    return PASS(bug, "%s: every result of the 256 threads matches the CPU reference", name);
}}
