// i34-intel-private-array-variable-only (Intel adapter, IntelTextureAtomics.dylib, i07's rewrite): a private array only
// ever indexed with variables. i07 was found with arrays written at constant offsets and read in a loop, but an array
// that is read and updated through variable indices alone in a loop (a[(i + t) & 7] += i; m ^= a[(i * 3) & 7]) comes
// out wrong as well (250 of 256 threads), so i07 has to take every small array with a variable index, not only those
// accessed both ways (narrowing it that way was tried and broke this). A fill-and-read pair of loops, and the
// read-modify-write loop, on the differential fuzzer's 256-thread input, against the CPU reference.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    int a[8];\n"
    "    for (uint j = 0; j < 8u; j++) a[j] = (int)(in[t * 4u + (j & 3u)] * (j + 1u));\n"
    "    int sv[8];\n"
    "    for (uint j = 0; j < 8u; j++) sv[(j * 3u + in[t * 4u]) & 7u] = (int)(j * 7u + t);\n"
    "    uint n = (in[t * 4u + 1u] & 7u) + 1u, acc = 0u;\n"
    "    for (uint i = 0; i < n; i++) acc += (uint)a[(i * 5u + in[t * 4u + 2u]) & 7u] ^ (uint)sv[(i + in[t * 4u + 3u]) & 7u];\n"
    "    out[t * 8u + 0u] = acc;\n"
    "    uint m = 0u;\n"
    "    for (uint i = 0; i < 8u; i++) { a[(i + t) & 7u] += (int)i; m ^= (uint)a[(i * 3u) & 7u]; }\n"
    "    out[t * 8u + 1u] = m;\n"
    "}\n";

// out[t * 8 + w] for each thread t and w in kWords, from the CPU reference (cpuref.py) on the same input
static const int kWords[] = {0, 1};
enum { kNumWords = sizeof kWords / sizeof *kWords };
static const uint32_t kExpected[256 * kNumWords] = {
    0x57ddcf92u, 0x2a01b25eu, 0x493d1e4du, 0x1fa609c2u, 0x49bc16b7u, 0xb7f80e75u, 0x1135c588u, 0xca53c2fdu,
    0xabf58c32u, 0xeee6d19au, 0x5586704cu, 0x6a759d52u, 0x482049b4u, 0xce3d1a51u, 0x32f38ee8u, 0x6ad63d35u,
    0xe7a9db60u, 0x04539186u, 0x837510d7u, 0xe9877d80u, 0x5c082c59u, 0xf4020acdu, 0xd0eb795eu, 0x959d21f7u,
    0x3ea25898u, 0x54bc2d0au, 0x21e9acf7u, 0xaa7e66eeu, 0x1c4a05aeu, 0xd28b0e99u, 0xd39219fcu, 0x38ad386du,
    0xacfcd348u, 0x17a38a4au, 0x839247acu, 0xf67f092cu, 0xccb08bdbu, 0xc35ff899u, 0x6716992bu, 0x19bbd019u,
    0x31850646u, 0xfa6c47f6u, 0x0b41eca6u, 0xc037d956u, 0xec422acfu, 0xb7726519u, 0x7ca54486u, 0xf3b1ccf7u,
    0x172b592du, 0xb6e5f4eau, 0x5c78c8c4u, 0x203143acu, 0xf29e58e4u, 0xadd49485u, 0x8da1715au, 0x5ef004e3u,
    0xbcfc1460u, 0xf61dcc5eu, 0x810bf3c8u, 0x3ff6065au, 0x3ed314dbu, 0xdf23ba9du, 0x7aaab7eau, 0xd88c6f9bu,
    0xff0713eau, 0x45ea216eu, 0x3ee8637eu, 0x3e99a5ecu, 0xe77eee7cu, 0xe970b29du, 0x2fce437cu, 0xabbf02d3u,
    0xc982415cu, 0x94cabe32u, 0xfe332db8u, 0xf6b6ee96u, 0x444a8d0au, 0xc6fb9f85u, 0xa7b79a9cu, 0x8b9c2c49u,
    0x5fa5f38eu, 0x745dd08au, 0x965f40bau, 0xd92151b4u, 0x7a7e319cu, 0xc0711e51u, 0x494b0018u, 0xc8fc1a6du,
    0x80e5e4a1u, 0x49398342u, 0x0619a8acu, 0x911a0406u, 0xef93f432u, 0x74d9dde5u, 0xe9355fd1u, 0x2e2ca917u,
    0x9ffb9a81u, 0x9522b3b6u, 0x0fe41cebu, 0xc995605eu, 0xc29216d7u, 0x89fb4295u, 0x52ffafa2u, 0xc56ff5f9u,
    0x3ab66d44u, 0x4c4908eau, 0x9ec6ada3u, 0x2832f762u, 0x52253addu, 0x570c5d29u, 0x3d2c715eu, 0xe3e50029u,
    0x89bc0da4u, 0x0e2ca2eau, 0xf44b35c1u, 0x98394682u, 0x98e55d4fu, 0x62d54221u, 0x00000186u, 0x70ef2789u,
    0x2005a8b7u, 0x9a50d39au, 0xf5ec3392u, 0x403210f6u, 0x3a2fd0d6u, 0x420d5689u, 0xba9c7d07u, 0x5b051dd9u,
    0x9c101a5cu, 0x18adb87au, 0x679c2135u, 0xcb306282u, 0xf0300162u, 0x23e37315u, 0x400c1ab1u, 0x3f57385du,
    0xe18839deu, 0x69d63526u, 0xecdae742u, 0x44db836eu, 0x00ced6e7u, 0x762829d1u, 0x0ae4d65au, 0x49d93129u,
    0xc87f926au, 0x073ad47eu, 0xbea614f3u, 0xa62eac3eu, 0xac57ee2bu, 0xc3064dc1u, 0xaac35ccbu, 0xaa6ae5b1u,
    0x5ed312c9u, 0xe049c962u, 0x7217cf87u, 0x904afcbeu, 0xc04a8ceau, 0x526e9bf5u, 0x15d363fcu, 0x9defe3a9u,
    0xc413846eu, 0x8ec0e836u, 0x93de9a5fu, 0xc587d3e8u, 0xc6c4f1ebu, 0xf6f165fdu, 0xe24a26dcu, 0xf1850461u,
    0x509d0693u, 0x486faf42u, 0x00000440u, 0xc4a7ef6eu, 0x47ef2154u, 0x1cf6a505u, 0x29219c73u, 0x9ad37a29u,
    0x59340482u, 0xd4570de6u, 0x9d9e86d2u, 0xcf9abce8u, 0x6b2598d6u, 0xa66fec29u, 0x5e8f38bcu, 0xcd3b19dbu,
    0x84b2a2c0u, 0x147786f2u, 0x22d7cafbu, 0xb43348b2u, 0x3666eb66u, 0x056af171u, 0x41877ceeu, 0x30f47f67u,
    0xa61d55ceu, 0x2978dc4eu, 0xc110e416u, 0x1f9be9c2u, 0x5b965cdeu, 0x8c195635u, 0x53f9371cu, 0xd73d791du,
    0xed96660du, 0xc68b17a6u, 0x70cf7822u, 0xa945fcd2u, 0x5b51dbcbu, 0xb6491181u, 0x24fa9d74u, 0xcc4c9e1bu,
    0xa7072ec9u, 0xd4a0e64eu, 0x3203bbbdu, 0xc67ca256u, 0xbf9151dau, 0xc869a909u, 0xbfd18056u, 0x2f861525u,
    0x2638ac00u, 0x701d315au, 0x2d8b7ae1u, 0xf0cb93d2u, 0x6fcfa437u, 0xaaf2a9cdu, 0x13a600c8u, 0xa080001du,
    0xd2626c6eu, 0x392c9c3au, 0xf59bb0a0u, 0xa70c0a64u, 0xf9eb55a7u, 0x5a705fd9u, 0xa7f8caceu, 0x5b9001ddu,
    0x516ce5a4u, 0x3907570au, 0xe518864fu, 0xd0a84c62u, 0x77545a8cu, 0x115dd29du, 0x699b874cu, 0xa290294fu,
    0x2c8703c1u, 0xc9d9d19au, 0x10c4a0c9u, 0x507002b8u, 0x86724aa3u, 0x74d6bbddu, 0xa3bbc418u, 0x278d9721u,
    0x79bcfc83u, 0x3623e62eu, 0x5f57b60fu, 0xfe2d220eu, 0xd55ab8cbu, 0x2d4eb99du, 0xa6a8437eu, 0xd44890e9u,
    0x068582f4u, 0x91b11d2au, 0x5f778085u, 0xbbcbca06u, 0xe29823c4u, 0x422e9715u, 0xdc633656u, 0x6994c92fu,
    0xc9603c67u, 0xf3ced422u, 0x3f0fb093u, 0xa11528feu, 0xaf13239cu, 0x66032965u, 0xb6b74700u, 0x66b1ae4fu,
    0x7d8d329eu, 0x2790010au, 0x7154631au, 0xc304be56u, 0x9eec2513u, 0x3c3f5addu, 0xf7d63f4du, 0x2f7e13a7u,
    0xe967d543u, 0xd5feff4au, 0x000000dau, 0xa9cb9b46u, 0xddcb2057u, 0xd26f9f59u, 0xd36ae6f0u, 0xedf69a4fu,
    0xd16a2cf5u, 0x59e85262u, 0x30b1d8bau, 0x1cdfa318u, 0xe3dd80bau, 0xb6c34d29u, 0x511883e5u, 0x4bc73625u,
    0x1e6681ebu, 0x36cf552au, 0x4b2f2b9cu, 0xa3a4e582u, 0x60d97332u, 0x3093106du, 0x6eb94e8bu, 0x774ac353u,
    0x9fb10830u, 0xfcea7622u, 0x15fab004u, 0xd63c39e8u, 0x0a2e8e52u, 0xe74f67f5u, 0x7e46ad8bu, 0x7f118727u,
    0xb89d7a7bu, 0x86b0ac16u, 0x39b55cf1u, 0x0c606cc2u, 0xfd88e084u, 0x3a32c66du, 0xff15aed7u, 0xd8e14167u,
    0xb987eec5u, 0x1358be26u, 0xc59fa605u, 0xf2a015acu, 0x2897e0d0u, 0x78193f61u, 0x61555e1au, 0xed0224dfu,
    0x79a0fd8au, 0xde4dbc16u, 0x664f3fa1u, 0xc89e3532u, 0xa7863954u, 0xf584b329u, 0x0222b01bu, 0xbf7804ffu,
    0x9f5e87e4u, 0x7ffc8d46u, 0x0c7017ebu, 0xb34cbbeeu, 0x2954536fu, 0x1afc9789u, 0x0bcfef5au, 0x4dd587c7u,
    0x575e0743u, 0xe115395eu, 0xdf435f5cu, 0xe9fadd6eu, 0xd627e935u, 0xc67d6e99u, 0x71fb5628u, 0x42e82979u,
    0xb52811ffu, 0xc3844aa6u, 0xe10ad5e7u, 0x840e9ee2u, 0xb421c130u, 0x06eb9431u, 0x38e6ae3fu, 0xdc49504du,
    0xa8c8058cu, 0xa8b67dbau, 0x70010fabu, 0xfc310972u, 0x4a122146u, 0xf90e7a81u, 0x476d365bu, 0x79682b13u,
    0x3748885cu, 0x9cedb476u, 0x52d4284cu, 0x75f72714u, 0xf71e4675u, 0xe9c14249u, 0xc0104b6cu, 0x3a99521fu,
    0x1f505238u, 0x691edb3eu, 0x24af335fu, 0x9ffe537eu, 0x9d9686e9u, 0xc9f92ec1u, 0x71d96944u, 0x5504dd51u,
    0xe3fee1d6u, 0x54419516u, 0x344bccbcu, 0xa932dae6u, 0xb963e8b9u, 0x54de7ec9u, 0x7f7d7ec3u, 0x6864052bu,
    0xf626edadu, 0xb4db759au, 0x02852fcdu, 0x42c37d3au, 0x53cb1731u, 0x8e2935cdu, 0xfe522f0au, 0x7d16da0fu,
    0x9182322bu, 0xc2774adau, 0xccbc85b6u, 0x5a98f7e2u, 0x25a0956eu, 0x4c676bc1u, 0x12435560u, 0x86c9e8adu,
    0x23b791f6u, 0x49d8af16u, 0x1cf02d1eu, 0x0b9f8bbeu, 0xb0f22fddu, 0xb3f76c05u, 0x2630882eu, 0x2fd6ff4fu,
    0xf403b6dau, 0x4d46c1eeu, 0xbb4d7337u, 0xd1ee060eu, 0xafa8960eu, 0x939c258du, 0x91857474u, 0xfd08fc75u,
    0x67f3ef0au, 0x7332ca22u, 0x6cb06a5du, 0x419d0ceeu, 0x7fa019a0u, 0xa0996d85u, 0x1ee4e41bu, 0x1afcb83bu,
    0xae0ca318u, 0x116c2092u, 0xf81fae8fu, 0xe3715684u, 0x2e117cb6u, 0xfbd17965u, 0x0085056bu, 0x08c325e7u,
    0xd6203a0fu, 0x05d2bccau, 0x72b3f9b1u, 0xebf510bau, 0xd87f4becu, 0xf2d358a5u, 0xe90f89e5u, 0xa1b4bc39u,
    0x9ee03cf2u, 0x198fe4b2u, 0x4f21403fu, 0xf2705d8au, 0xa945410cu, 0x9b5639a1u, 0x4db11f78u, 0x16afa9adu,
    0xfd6f80b9u, 0xda0641f2u, 0xbd19a030u, 0x1c27e0a2u, 0xde8f97d9u, 0x68380739u, 0x32f86b70u, 0xf3f429edu,
    0x6d2cdc5fu, 0x4ac7b526u, 0x8343ddf6u, 0x8f18b86au, 0x51dc2a80u, 0xbc536695u, 0xcd30ba30u, 0x941c0335u,
    0xd9513388u, 0xcc73610au, 0x3ea3b4a5u, 0xd22a70aau, 0x000002c0u, 0x351f670du, 0xb7e50e7bu, 0xafe62aebu,
    0xf52f53ccu, 0x95d9f0dau, 0xf99abba4u, 0x920d2b5eu, 0x26b66a39u, 0x73c5b441u, 0x92205de5u, 0x061f3af3u,
    0x45c4706fu, 0x944c46dau, 0x8b69f4d7u, 0xc996997au, 0x798da9e6u, 0x1572e4edu, 0xe5772204u, 0x4c058b81u,
    0x6b211bf8u, 0xd252e0aau, 0xf21b1284u, 0x46e6060eu, 0xce36f550u, 0xfdeb4f09u, 0x948c5d18u, 0x21d15697u,
    0xc99767eau, 0x6eb20de6u, 0xf3a7fc96u, 0x468ddc1eu, 0xb91c855au, 0xd1601845u, 0x2fe6c023u, 0xbfd0b3b3u
};

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i34-intel-private-array-variable-only";
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
