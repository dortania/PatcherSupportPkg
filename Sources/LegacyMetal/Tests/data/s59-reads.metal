// s59's kernels, built by build.sh as a Metal 4.0 library (Xcode 26), where every texture read goes through
// air.get_read_sampler. Each reads one texel of a known texture into out[0]; the ushort-coordinate forms are the ones
// that crashed Tahoe's compiler (SceneKit's temporal_aa reads a depth texture that way).
#include <metal_stdlib>
using namespace metal;

kernel void read1d(texture1d<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint(2)).r; }
kernel void read1dShort(texture1d<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(ushort(3)).r; }
kernel void read2dLevel(texture2d<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint2(1, 2), 1).r; }
kernel void read2dShort(texture2d<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(ushort2(3, 1)).r; }
kernel void read2dArray(texture2d_array<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint2(1, 2), 1).r; }
kernel void read3d(texture3d<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint3(1, 2, 3)).r; }
kernel void read3dShort(texture3d<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(ushort3(2, 1, 1)).r; }
kernel void readCube(texturecube<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint2(1, 2), 4).r; }
kernel void readCubeShort(texturecube<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(ushort2(2, 3), ushort(5)).r; }
kernel void readCubeArray(texturecube_array<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint2(1, 2), 4, 1).r; }
kernel void readDepth(depth2d<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint2(1, 2)); }
kernel void readDepthShort(depth2d<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(ushort2(3, 1)); }
kernel void readDepthArray(depth2d_array<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint2(1, 2), 1); }
kernel void readDepthCube(depthcube<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint2(1, 2), 4); }
kernel void readBuffer(texture_buffer<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint(5)).r; }
