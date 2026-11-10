// fuzzrun <kernel.metal> <gpu substring> [input seed]: compiles k() from the file on that GPU, runs 256 threads (64 per
// threadgroup) on 1024 seeded random uints, prints "HASH <fnv1a of the 2048 output words>" and then the words in hex
// (8 per thread). "COMPILE <error>" or "RUN <status>" if it doesn't get that far, "RUN untouched" if the command buffer
// completed without writing the output (a dropped dispatch: every kernel writes all 8 words of every thread). If the file
// also has a vertex function vfull, k is a fragment function instead, run once per pixel of a 256x1 target (t = pixel x).
// The GPU name substring is matched case-insensitively ("default": the system default GPU). Built by gpu.sh.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(int argc, char **argv) { @autoreleasepool {
  if (argc < 3) { fprintf(stderr, "usage: fuzzrun kernel.metal gpu [seed]\n"); return 2; }
  NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
  id<MTLDevice> dev = nil;
  for (id<MTLDevice> d in MTLCopyAllDevices()) if ([d.name rangeOfString:@(argv[2]) options:NSCaseInsensitiveSearch].location != NSNotFound) dev = d;
  if (!dev && !strcmp(argv[2], "default")) dev = MTLCreateSystemDefaultDevice();
  if (!dev) { printf("NODEVICE\n"); return 3; }
  unsigned seed = argc > 3 ? (unsigned)atoi(argv[3]) : 1;
  NSError *err = nil;
  MTLCompileOptions *opt = [MTLCompileOptions new];
  opt.fastMathEnabled = NO;
  id<MTLLibrary> lib = [dev newLibraryWithSource:src options:opt error:&err];
  id<MTLFunction> fn = [lib newFunctionWithName:@"k"];
  id<MTLFunction> vfull = [lib newFunctionWithName:@"vfull"];
  // Fragment mode (the file has a vertex function vfull): k is the fragment function, one pixel per thread on a 256x1 target.
  id<MTLComputePipelineState> ps = fn && !vfull ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
  id<MTLRenderPipelineState> rps = nil;
  if (fn && vfull) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = vfull; pd.fragmentFunction = fn; pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
    rps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
  }
  if (!ps && !rps) { printf("COMPILE %s\n", [[err.localizedDescription stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]); return 4; }
  enum { T = 256 };
  id<MTLBuffer> in = [dev newBufferWithLength:T * 4 * 4 options:MTLResourceStorageModeShared];
  id<MTLBuffer> out = [dev newBufferWithLength:T * 8 * 4 options:MTLResourceStorageModeShared];
  uint32_t x = seed * 2654435761u + 12345u;
  for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; ((uint32_t *)in.contents)[i] = (i % 7 == 0) ? (x & 0xff) : x; }
  memset(out.contents, 0xcd, T * 8 * 4);
  id<MTLCommandQueue> q = [dev newCommandQueue];
  id<MTLCommandBuffer> cb = [q commandBuffer];
  if (ps) {
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:in offset:0 atIndex:0]; [ce setBuffer:out offset:0 atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake(T / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce endEncoding];
  } else {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:T height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
    rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:rps]; [re setFragmentBuffer:in offset:0 atIndex:0]; [re setFragmentBuffer:out offset:0 atIndex:1];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
  }
  [cb commit]; [cb waitUntilCompleted];
  if (cb.status != MTLCommandBufferStatusCompleted) { printf("RUN %ld %s\n", (long)cb.status, cb.error.localizedDescription.UTF8String); return 5; }
  const uint32_t *o = out.contents;
  int written = 0;
  for (int i = 0; i < T * 8; i++) written |= o[i] != 0xcdcdcdcdu;
  if (!written) { printf("RUN untouched\n"); return 5; }
  uint32_t h = 2166136261u;
  for (int i = 0; i < T * 8; i++) for (int b = 0; b < 4; b++) { h ^= (o[i] >> (8 * b)) & 0xff; h *= 16777619u; }
  printf("HASH %08x\n", h);
  for (int t = 0; t < T; t++) { for (int w = 0; w < 8; w++) printf("%08x ", o[t * 8 + w]); printf("\n"); }
  return 0;
}}
