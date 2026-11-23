// s88-intel-32-vertex-inputs (MetalOldCompat item 85, MTLSHIM_IVB_VERTEX_INPUTS): a vertex function with 32 inputs on the
// Ivy Bridge driver. -[MTLIGRenderPipelineState generate3DStateVF:] walks the inputs while their bit is set in a 32-bit
// mask, testing bit (i mod 32), so with all 32 set it never stopped, asked for vertex attribute 7680 and Metal aborted
// (WebKit's WebGPU offers 30 attributes: with vertex_index and instance_index that is 32, CTS vertex_state
// max_buffers_and_attribs). Checked, in a child process (so that the abort is a result): 30 float attributes with
// [[vertex_id]] and [[instance_id]] after them and before them (WebKit's order), and 31 with [[vertex_id]], each drawn
// as points over 2 vertices (and 3 instances);
// every point's value (the sum of its attributes, plus 1000 x vertex_id and 10000 x instance_id) must be right.
// Stock: FAIL (the child aborts). Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;

// returns NULL when right, or what was wrong
static const char *draw(id<MTLDevice> dev, int attributes, BOOL instanceID, BOOL idsFirst, char *what, size_t whatSize) {
    NSMutableString *s = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\nstruct In {\n"];
    for (int i = 0; i < attributes; i++) [s appendFormat:@"  float a%d [[attribute(%d)]];\n", i, i];
    NSString *ids = instanceID ? @"uint vid [[vertex_id]], uint iid [[instance_id]]" : @"uint vid [[vertex_id]]";
    [s appendFormat:@"};\nstruct V { float4 p [[position]]; float value [[flat]]; float size [[point_size]]; };\n"
                     "vertex V vs(%@) {\n  float sum = 0;\n",
                     idsFirst ? [ids stringByAppendingString:@", In in [[stage_in]]"] : [@"In in [[stage_in]], " stringByAppendingString:ids]];
    for (int i = 0; i < attributes; i++) [s appendFormat:@"  sum += in.a%d;\n", i];
    [s appendFormat:@"  uint id = %@;\n  V o;\n  o.p = float4((float(id * 2 + vid) + 0.5) / 3.0 - 1.0, 0.0, 0.0, 1.0);\n"
                     "  o.value = sum + 1000.0 * vid + 10000.0 * id;\n  o.size = 1;\n  return o;\n}\n"
                     "fragment float4 fs(V in [[stage_in]]) { return float4(in.value, 0, 0, 1); }\n",
                     instanceID ? @"iid" : @"0"];
    NSError *error = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:s] options:nil error:&error];
    if (!lib) return snprintf(what, whatSize, "compile: %s", error.localizedDescription.UTF8String), what;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    for (int i = 0; i < attributes; i++) {
        vd.attributes[i].format = MTLVertexFormatFloat;
        vd.attributes[i].offset = 4 * i;
        vd.attributes[i].bufferIndex = 0;
    }
    vd.layouts[0].stride = 4 * 32;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.vertexDescriptor = vd;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
    pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!ps) return snprintf(what, whatSize, "pipeline: %s", error.localizedDescription.UTF8String), what;
    float vertices[2][32];
    for (int v = 0; v < 2; v++)
        for (int i = 0; i < 32; i++) vertices[v][i] = i + 1 + v * 100;
    id<MTLBuffer> vb = [dev newBufferWithBytes:vertices length:sizeof vertices options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:6 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
    [re setRenderPipelineState:ps];
    [re setVertexBuffer:vb offset:0 atIndex:0];
    int instances = instanceID ? 3 : 1;
    [re drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:2 instanceCount:instances];
    [re endEncoding];
    id<MTLBuffer> out = [dev newBufferWithLength:24 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:pass.colorAttachments[0].texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(6, 1, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:24 destinationBytesPerImage:24];
    [be endEncoding];
    if (!reproRun(cb)) return snprintf(what, whatSize, "command buffer failed"), what;
    const float *o = out.contents;
    for (int slot = 0; slot < instances * 2; slot++) {
        int vid = slot % 2, iid = slot / 2;
        float want = 1000.0f * vid + 10000.0f * iid;
        for (int i = 0; i < attributes; i++) want += i + 1 + vid * 100;
        if (o[slot] != want)
            return snprintf(what, whatSize, "%d attributes + vertex_id%s%s: vertex %d instance %d drew %.0f, want %.0f", attributes,
                            instanceID ? " + instance_id" : "", idsFirst ? " (IDs first)" : "", vid, iid, o[slot], want), what;
    }
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s88-intel-32-vertex-inputs";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        if (getenv("S88_CHILD")) {
            char what[256];
            const char *wrong = draw(dev, 30, YES, NO, what, sizeof what);
            if (!wrong) wrong = draw(dev, 30, YES, YES, what, sizeof what);
            if (!wrong) wrong = draw(dev, 31, NO, NO, what, sizeof what);
            printf("s88 child: %s\n", wrong ? wrong : "right");
            return 0;
        }
        setenv("S88_CHILD", "1", 1);
        int out[2];
        if (pipe(out)) return FAIL(bug, "pipe failed");
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, out[1], 1);
        posix_spawn_file_actions_addclose(&actions, out[0]);
        pid_t pid;
        if (posix_spawn(&pid, argv[0], &actions, NULL, argv, environ)) return FAIL(bug, "could not run itself again");
        close(out[1]);
        char text[512] = {0};
        size_t used = 0;
        ssize_t n;
        while (used < sizeof text - 1 && (n = read(out[0], text + used, sizeof text - 1 - used)) > 0) used += (size_t)n;
        close(out[0]);
        int status = 0;
        waitpid(pid, &status, 0);
        if (WIFSIGNALED(status))
            return FAIL(bug, "%s: the child died (signal %d) making a render pipeline whose vertex function has 32 inputs", name,
                        WTERMSIG(status));
        char *line = strstr(text, "s88 child: ");
        if (!WIFEXITED(status) || WEXITSTATUS(status) || !line) return FAIL(bug, "%s: the child failed (status %d): %s", name, status, text);
        line += strlen("s88 child: ");
        line[strcspn(line, "\n")] = 0;
        if (strcmp(line, "right")) return FAIL(bug, "%s: %s", name, line);
        return PASS(bug, "%s: vertex functions with 32 inputs (30 attributes + vertex_id + instance_id, before or after them; 31 + vertex_id) draw right", name);
    }
}
