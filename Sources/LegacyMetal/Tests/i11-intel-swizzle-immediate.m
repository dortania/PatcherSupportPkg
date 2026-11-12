// i11-intel-swizzle-immediate (Intel adapter, IntelTextureAtomics.dylib): in a long fragment function, a vector built
// from immediates and per-pixel values (FragColor = vec4(1.0, a, b, 1.0)) gets the immediates right in only one pixel of
// eight on the 3802 Intel compiler (IGIL MOV_SWZ); the others read 0. dEQP's uniform-block cases with instance arrays
// end that way and failed in Chrome and Safari (uniformbuffers single_struct_array and single_nested_struct_array,
// *_instance_array_fragment / _both). Runs ANGLE's translation of one of them (data/i11-ubo-fragment.metal) with its
// buffer bytes (data/i11-ubo.bin, three blocks through an argument buffer): every pixel should be white.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i11-intel-swizzle-immediate";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *dir = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"data"];
        NSString *fsrc = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"i11-ubo-fragment.metal"] encoding:NSUTF8StringEncoding error:nil];
        NSData *blocks = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"i11-ubo.bin"]];
        if (!fsrc || blocks.length < 2 * 768 + 704) return SKIP(bug, "data/i11-ubo-fragment.metal or data/i11-ubo.bin missing (run build.sh)");
        NSString *vsrc = [@"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 pos [[position]]; float _uv_vtxResult; };\n"
            "vertex V vs(uint id [[vertex_id]]) { float2 t = float2(id & 1, id >> 1); V o; o.pos = float4(t * 2 - 1, 0, 1); o._uv_vtxResult = 1; return o; }\n"
            stringByAppendingString:reproUniqueComment()];
        NSError *error = nil;
        id<MTLLibrary> flib = [dev newLibraryWithSource:[fsrc stringByAppendingString:reproUniqueComment()] options:nil error:&error];
        id<MTLLibrary> vlib = flib ? [dev newLibraryWithSource:vsrc options:nil error:&error] : nil;
        MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
        bool no = false;
        for (NSUInteger i = 0; i < 6; i++) [constants setConstantValue:&no type:MTLDataTypeBool atIndex:i];  // ANGLE's function constants
        id<MTLFunction> fs = vlib ? [flib newFunctionWithName:@"main0" constantValues:constants error:&error] : nil;
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [vlib newFunctionWithName:@"vs"];
        pd.fragmentFunction = fs;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> ps = fs ? [dev newRenderPipelineStateWithDescriptor:pd error:&error] : nil;
        if (!ps) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLBuffer> ubo = [dev newBufferWithBytes:blocks.bytes length:blocks.length options:MTLResourceStorageModeShared];
        id<MTLArgumentEncoder> encoder = [fs newArgumentEncoderWithBufferIndex:25];
        id<MTLBuffer> arguments = [dev newBufferWithLength:encoder.encodedLength options:MTLResourceStorageModeShared];
        [encoder setArgumentBuffer:arguments offset:0];
        for (NSUInteger i = 0; i < 3; i++) [encoder setBuffer:ubo offset:768 * i atIndex:i];
        uint8_t angleUniforms[64] = {0};  // ANGLEUniformBlock: renderArea 32x32, flipXY (1, 1)
        uint32_t renderArea = 32 | (32 << 16), flipXY = 0x7f7f7f7f;
        memcpy(angleUniforms + 8, &renderArea, 4);
        memcpy(angleUniforms + 12, &flipXY, 4);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc setFragmentBuffer:arguments offset:0 atIndex:25];
        [enc useResource:ubo usage:MTLResourceUsageRead];
        [enc setFragmentBytes:angleUniforms length:sizeof angleUniforms atIndex:17];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        static uint8_t px[32 * 32 * 4];
        [target getBytes:px bytesPerRow:32 * 4 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
        int wrong = 0, first = -1;
        for (int i = 0; i < 32 * 32; i++)
            if (px[4 * i] != 255 || px[4 * i + 1] != 255 || px[4 * i + 2] != 255 || px[4 * i + 3] != 255) wrong += (first < 0 ? (first = i, 1) : 1);
        if (wrong)
            return FAIL(bug, "%s: %d of 1024 pixels not white (first: %d,%d,%d,%d; vec4(1.0, a, b, 1.0) with a = b = 1)", dev.name.UTF8String, wrong,
                        px[4 * first], px[4 * first + 1], px[4 * first + 2], px[4 * first + 3]);
        return PASS(bug, "%s: vec4(1.0, a, b, 1.0) right in every pixel of a long fragment function", dev.name.UTF8String);
    }
}
