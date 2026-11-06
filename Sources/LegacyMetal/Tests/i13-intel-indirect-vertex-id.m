// i13-intel-indirect-vertex-id (Intel adapter, IntelTextureAtomics.dylib): in indexed draws through an indirect buffer
// (drawIndexedPrimitives:...indirectBuffer:), [[vertex_id]] on the 12.x Intel driver leaves out the base vertex, unless the
// vertex function also reads [[base_vertex]]; direct draws are right. WebGPU's drawIndexedIndirect with a base vertex
// drew from the wrong vertices wherever Dawn's shader uses the vertex index (CTS draw:arguments, robust_access_vertex).
// A vertex function with rasterization off writes [[vertex_id]] and [[instance_id]] to a buffer, in indexed draws (base
// vertex 5 and 2, first index 0 and 1, base instance 7) and a non-indexed draw, each direct and indirect (arguments in a
// private buffer filled by a blit). Stock OCLP: FAIL. Fixed: PASS (Haswell). Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i13-intel-indirect-vertex-id";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *src = [@"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex void v(uint vid [[vertex_id]], uint iid [[instance_id]], device uint2 *out [[buffer(1)]], constant uint &slot [[buffer(2)]]) {\n"
            "  out[slot * 32 + (vid & 15) + 16 * (iid & 1)] = uint2(vid, iid); }\n" stringByAppendingString:reproUniqueComment()];
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: no library: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.rasterizationEnabled = NO;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!ps) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        // draws: {indexed, count, instances, first index or vertex, base vertex, base instance}
        static const int kDraws[3][6] = {{1, 3, 2, 0, 5, 7}, {1, 3, 2, 1, 2, 0}, {0, 3, 2, 4, 0, 3}};
        uint32_t args[3][5];
        for (int d = 0; d < 3; d++) {
            if (kDraws[d][0]) {
                MTLDrawIndexedPrimitivesIndirectArguments a = {(uint32_t)kDraws[d][1], (uint32_t)kDraws[d][2], (uint32_t)kDraws[d][3], kDraws[d][4], (uint32_t)kDraws[d][5]};
                memcpy(args[d], &a, sizeof a);
            } else {
                MTLDrawPrimitivesIndirectArguments a = {(uint32_t)kDraws[d][1], (uint32_t)kDraws[d][2], (uint32_t)kDraws[d][3], (uint32_t)kDraws[d][5]};
                memset(args[d], 0, sizeof args[d]);
                memcpy(args[d], &a, sizeof a);
            }
        }
        id<MTLBuffer> staging = [dev newBufferWithBytes:args length:sizeof args options:MTLResourceStorageModeShared];
        id<MTLBuffer> indirect = [dev newBufferWithLength:sizeof args options:MTLResourceStorageModePrivate];
        uint16_t indices[4] = {0, 1, 2, 3};
        id<MTLBuffer> ib = [dev newBufferWithBytes:indices length:sizeof indices options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:6 * 32 * 8 options:MTLResourceStorageModeShared];
        memset(out.contents, 0xff, out.length);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0 toBuffer:indirect destinationOffset:0 size:sizeof args];
        [blit endEncoding];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc setVertexBuffer:out offset:0 atIndex:1];
        for (uint32_t slot = 0; slot < 6; slot++) {
            int d = slot / 2;
            [enc setVertexBytes:&slot length:4 atIndex:2];
            if (slot & 1) {
                if (kDraws[d][0])
                    [enc drawIndexedPrimitives:MTLPrimitiveTypePoint indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0 indirectBuffer:indirect indirectBufferOffset:sizeof args[0] * d];
                else
                    [enc drawPrimitives:MTLPrimitiveTypePoint indirectBuffer:indirect indirectBufferOffset:sizeof args[0] * d];
            } else if (kDraws[d][0]) {
                [enc drawIndexedPrimitives:MTLPrimitiveTypePoint indexCount:kDraws[d][1] indexType:MTLIndexTypeUInt16 indexBuffer:ib
                         indexBufferOffset:2 * kDraws[d][3] instanceCount:kDraws[d][2] baseVertex:kDraws[d][4] baseInstance:kDraws[d][5]];
            } else {
                [enc drawPrimitives:MTLPrimitiveTypePoint vertexStart:kDraws[d][3] vertexCount:kDraws[d][1] instanceCount:kDraws[d][2] baseInstance:kDraws[d][5]];
            }
        }
        [enc endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        const uint32_t *o = (const uint32_t *)out.contents;
        for (int slot = 0; slot < 6; slot++) {
            const int *draw = kDraws[slot / 2];
            const char *how = slot & 1 ? "indirect" : "direct";
            for (int instance = 0; instance < draw[2]; instance++)
                for (int k = 0; k < draw[1]; k++) {
                    uint32_t vid = (uint32_t)(draw[3] + k + draw[4]), iid = (uint32_t)(draw[5] + instance);  // indices[i] == i
                    const uint32_t *got = o + 2 * (slot * 32 + (vid & 15) + 16 * (iid & 1));
                    if (got[0] != vid || got[1] != iid) {
                        if (draw[0])
                            return FAIL(bug, "%s: %s indexed draw, base vertex %d, first index %d: vertex %u of instance %u not written as itself "
                                        "(slot holds vertex_id %d, instance_id %d)", dev.name.UTF8String, how, draw[4], draw[3], vid, iid, (int)got[0], (int)got[1]);
                        return FAIL(bug, "%s: %s draw from vertex %d: vertex %u of instance %u not written as itself (slot holds vertex_id %d, instance_id %d)",
                                    dev.name.UTF8String, how, draw[3], vid, iid, (int)got[0], (int)got[1]);
                    }
                }
        }
        return PASS(bug, "%s: vertex_id and instance_id right in direct and indirect draws (indexed with base vertex, and non-indexed)", dev.name.UTF8String);
    }
}
