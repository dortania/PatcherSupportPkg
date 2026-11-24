// n42-kepler-wide-constant-product: a product of a 16-bit value and a wider constant must be exact; the back end
// misjudged its range. Fix: GeForceAIRCompat NVAIR_WIDE_CONSTANT_PRODUCT_FIX. Checks: the reduced fuzz kernel (seed
// 8322) against the CPU reference (cpuref.py), 256 threads. Argument: GPU name (default: NVIDIA).
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
    "    uint dbg0 = 0xdeadu, dbg1 = 0xdeadu;\n"
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
    "    v1 = vf((((short4((short)(-29565), (short)(-12825), (short)(31798), (short)(31966)) | short4((short)(-15912), (short)(-17978), (short)(24154), (short)(-8185))) & (short4((short)((uint)(select((int)(184u), (int)((v1 ^ t)), (v1 & 2u) != 0u))), (short)(158u), (short)((v5 ^ 183u)), (short)(((v0 ^ t) << ((v2 ^ t) & 31u)))) & short4((short)(31507), (short)(22660), (short)(-32066), (short)(27082))))));\n"
    "    for (uint i0 = 0; i0 < 2u; i0++) {\n"
    "        v3 += i0 * 3u;\n"
    "        if ((uint)(any((uchar3((uchar)((uint)((int)((v1 ^ t)) >> (int)(in[(t * 4u + 3u)] & 31u))), (uchar)((uint)((int)(in[(t * 4u + 3u)]) % (int)(((v1 ^ t) | 1u) & 0x7fffffffu))), (uchar)((uint)(pc[(v1) & 7u]))) & uchar3((uchar)((uint)(max((int)(in[(t * 4u + 1u)]), (int)((v1 ^ t))))), (uchar)(rhadd((v1 ^ t), (v5 ^ t))), (uchar)(mulhi(83u, v0)))) > uchar3((uchar)(104), (uchar)(223), (uchar)(106)))) < (uint)(-(int)((uint)((int)(v2) >> (int)((v4 ^ t) & 31u)) & 0x7fffffffu))) {\n"
    "            v0 ^= p[((uint)((int)(((v4 ^ t) << (in[(t * 4u + 0u)] & 31u))) / (int)(((uint)((int)(v4) / (int)((v3 | 1u) & 0x7fffffffu)) | 1u) & 0x7fffffffu))) & 7u];\n"
    "        } else {\n"
    "            v0 = (uint)((bool)(vf((((char4((char)(-17), (char)(-49), (char)(-19), (char)(-95)) & char4((char)(-98), (char)(67), (char)(121), (char)(-9))) >> char4((char)(5), (char)(1), (char)(0), (char)(4))))) & (uint)(all((char2((char)(66), (char)(-87)) >> char2((char)(3), (char)(2))) != max(char2((char)(((uint)((ushort)(2147483647u)) * (uint)((ushort)((v4 ^ t))))), (char)((uint)((int)(in[(t * 4u + 0u)]) % (int)((v0 | 1u) & 0x7fffffffu)))), char2((char)((uint)((int)((v3 ^ t)) >> (int)(in[(t * 4u + 1u)] & 31u))), (char)((uint)(!(v1 > in[(t * 4u + 1u)])))))))));\n"
    "        }\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            v4 ^= p[(((uint)(select((int)(4294967295u), (int)(v5), (v3 & 2u) != 0u)) / ((uint)((int)(v1) >> (int)(104490231u & 31u)) | 1u))) & 7u];\n"
    "            v4 += ((char)((uint)(max((int)((~256u)), (int)((uint)((int)(93u) >> (int)(in[(t * 4u + 3u)] & 31u)))))) == (char)((uint)(pc[((v2 ^ t)) & 7u])) ? (v1 ^ t) : (((uint)((uchar)((v4 ^ t))) & 1u) != 0u ? min3((v0 ^ t), 2u, 1u) : insert_bits((v2 ^ t), 870818439u, (uint)(in[(t * 4u + 3u)] & 15u), (uint)(65536u & 15u))));\n"
    "            if ((((uint)((bool)(((uint)((int)((short)(in[(t * 4u + 2u)]))) ^ v0) & ((uint)((int)((short)(82u))) * (v0 ^ t))))) & 3u) == 0u) break; } v0 += n1; }\n"
    "    }\n"
    "    dbg0 = v0 ^ (v1 * 0x9e3779b1u) ^ (v2 * 0x85ebca6bu); dbg1 = v3 ^ (v4 * 0x9e3779b1u) ^ (v5 * 0x85ebca6bu);\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = dbg0;\n"
    "    out[t * 8u + 6u] = dbg1;\n"
    "    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);\n"
    "}\n";

// FNV-1a of each thread's 8 words (bytes in little-endian order), from cpuref.py's output for this kernel and input seed 1
static const uint32_t want[256] = {
    0x1df1de53u, 0xdd086f6bu, 0xc39c4e52u, 0x3e824964u, 0x86a912e1u, 0xb6884dbeu, 0xc8b83df8u, 0xf1600f60u,
    0xe5b3ef19u, 0xb987b327u, 0x261772f1u, 0xa22bcdf8u, 0x7dec545au, 0x70e567acu, 0x6f25b0d7u, 0x521e8147u,
    0x103e0dc0u, 0x3111d504u, 0x8110cd3bu, 0x23283db5u, 0xf2a579deu, 0xc0c6f387u, 0x6e24b0c3u, 0xef45ee7au,
    0xd1419723u, 0x32bdc62bu, 0xe588d5a3u, 0x6e82103bu, 0xdcc869f1u, 0x2c21670fu, 0x8a957687u, 0x481e6a2fu,
    0x3ee4866fu, 0x04de69d4u, 0xa26cf04cu, 0xd29be956u, 0x93935f6du, 0xd98870cfu, 0xad569ae0u, 0x09f45157u,
    0xc4d9912cu, 0x6b1ff752u, 0xb386cf84u, 0x4a980aa2u, 0x2acd6238u, 0x4979df9du, 0xd9947859u, 0xe9978eb8u,
    0x32297575u, 0x0d6140d8u, 0xdf79511bu, 0x742b30ddu, 0xaa65ec80u, 0x08291929u, 0x72ed71f0u, 0x0c0cbef6u,
    0x494aaae0u, 0x7d7c2e1au, 0xa0735400u, 0xe3aa8c79u, 0xc5f149efu, 0x40a22accu, 0x09cf27aau, 0x174b12a4u,
    0xe595e6c2u, 0x76cd42bdu, 0x08915c1bu, 0x74444779u, 0xb6900bc7u, 0xed12653fu, 0x7282cfa6u, 0xe49dadc9u,
    0x5e302c4du, 0xe15ce5dbu, 0x1e14ab4bu, 0x1e14bd78u, 0x78c3fac4u, 0x3d540e74u, 0xe88258edu, 0xe0f028b2u,
    0xfb880246u, 0x4f0a3aa0u, 0x4384bc1eu, 0x8425a4c2u, 0x7193b917u, 0xf93bb964u, 0xb075cb8du, 0x9b084db8u,
    0x15d65378u, 0xd56312beu, 0x436698e2u, 0x9b97b9a5u, 0x440d1e2au, 0x55b3fafdu, 0x42c0d9d3u, 0x1c7b9752u,
    0x5a664082u, 0xf2cb1c85u, 0xdfd1183fu, 0x47f30b47u, 0xb358bf8au, 0x49eba017u, 0xb22d782cu, 0x2d70516cu,
    0x4a6e0e9eu, 0x68320c8bu, 0x4b32610du, 0xbaf5bca8u, 0x87171ba4u, 0xffdaf3bau, 0x81bac22au, 0xdd8e0d58u,
    0x7993d2b8u, 0xc2ca3f39u, 0x0acd1dc4u, 0x4240fe33u, 0xd923fba5u, 0x0ae4fc82u, 0x157ae82bu, 0xad7b45d1u,
    0x1dd86e27u, 0xbd41fe09u, 0x34ca2397u, 0x253bf7d5u, 0xe6f98997u, 0x8551f618u, 0x11863c26u, 0x5af13351u,
    0xcef55370u, 0xf070be38u, 0x7af24607u, 0x5454f9acu, 0x3b4a0fd8u, 0xf294e366u, 0x8d9c2a03u, 0xc196b81bu,
    0x782b42cau, 0xa342e846u, 0x91cefb2au, 0x03ae2c34u, 0x110c29b4u, 0x9ad395bdu, 0xd2a2ae75u, 0x7099584au,
    0x7abca4ffu, 0xabb60998u, 0x527fb266u, 0xdc898666u, 0xdd231c38u, 0x8f139c9du, 0xc8865e69u, 0xab706e3du,
    0xcb16a742u, 0x0c2b7a7fu, 0x994978b5u, 0x621c2bb6u, 0x6bf5bbd1u, 0xb875f60eu, 0x67157be2u, 0x87bd8413u,
    0xa4e23a94u, 0xff0e0426u, 0x09b96f11u, 0x3321b4ceu, 0x6fd7195bu, 0x708f08c2u, 0x9a978accu, 0x7e42d122u,
    0x641aa8a1u, 0x89f3ac0bu, 0x1e87b333u, 0x8ddf5fc1u, 0xd3d848b9u, 0x4393e036u, 0x40dbc48cu, 0x99bb23a9u,
    0x77610d4fu, 0xbbdb18b8u, 0xc3739aa3u, 0x851a21a0u, 0xa55b9ddau, 0x389eb680u, 0x4852e7d7u, 0x6700cafau,
    0x503c8954u, 0x0bfcd680u, 0x38140b61u, 0x9d48f0c7u, 0x3731818eu, 0xe9a37fdeu, 0x5de54649u, 0x30a91678u,
    0x92625d2du, 0x010b9b52u, 0x2b6fba04u, 0x3496de76u, 0xb52b3f2du, 0xfdfea709u, 0xe73c7c55u, 0x3644b8f1u,
    0x8c2fab4au, 0x9e701b36u, 0x436b1424u, 0x7dcddbf1u, 0x75348fa9u, 0xbab597c4u, 0x28faa235u, 0xc557085fu,
    0xfb576684u, 0x9b3153d6u, 0x6ae19908u, 0x93b157c8u, 0x594cd1d2u, 0xc8194befu, 0x97b1cd86u, 0x096c5ff8u,
    0xeade4c70u, 0x7e49fbffu, 0x16a06cbfu, 0xd77d31ccu, 0xb19f0862u, 0x50cffe89u, 0x5aef3d9au, 0x2c37ff08u,
    0x73bc4425u, 0xff9ed32fu, 0x1b4552d6u, 0x78fd6ad1u, 0xe1fa4490u, 0x5f98b8f6u, 0xf9706c8au, 0x4798008cu,
    0xed0b376fu, 0xe7cb4823u, 0xee564744u, 0x2ac0b587u, 0xad92b91bu, 0x4761f3e1u, 0x9bbad91eu, 0x1556043cu,
    0x971ed690u, 0x6f854a15u, 0xc6756497u, 0x0466f99eu, 0x5ac21573u, 0xa8ed59c1u, 0xf3be2fc6u, 0x942bf276u,
    0x5ab7c724u, 0xe401969cu, 0x4995dca3u, 0x49cbb27du, 0x8912269cu, 0x971e2c86u, 0xd56dea8eu, 0xc980eb29u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n42-kepler-wide-constant-product";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    return reproFuzzKernel(bug, dev, src, want, "products of narrow values and wide constants keep the kernel right");
}}
