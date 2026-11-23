// n50-kepler-managed-upload-race (MetalOldCompat item 82): managed buffers written (didModifyRange:) and managed
// textures written (replaceRegion:), freed on some threads while others commit, as Safari's WebGPU does in its GPU
// process. Kepler's driver queues such CPU writes on a device-wide list that the next commit, on any queue, walks to
// upload them, and a resource freed before it was uploaded, while another thread committed, was freed under that
// commit: it read a nil _res (-[NVMTLCommandBuffer commit], EXC_BAD_ACCESS at 0x2f0) or over-released it (objc_release
// in MTLResourceListChunkFreeEntries); WebKit's GPU process crashed that way in the WebGPU CTS. The test runs itself
// again as a child for each kind (so that a crash is a result): two threads make, write and free managed buffers of
// 256 B to 32 KB (with initial bytes), or managed RGBA8 textures of 16 to 256 texels square, while two threads commit
// small blits on queues of their own, for 5 s each. Stock OCLP on Kepler: FAIL (the child crashed, within half a second
// for buffers). Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"
#include <spawn.h>
#include <stdatomic.h>
#include <sys/wait.h>

extern char **environ;

static int child(id<MTLDevice> dev, int textures) {
    __block atomic_int stop = 0, made = 0, commits = 0;
    static uint8_t bytes[32768], texels[256 * 256 * 4];  // newBufferWithBytes: (not item 60's zero-filled newBufferWithLength:, whose wait slows the race down)
    dispatch_group_t group = dispatch_group_create();
    for (int t = 0; t < 2; t++)
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            while (!atomic_load(&stop)) @autoreleasepool {
                if (textures) {
                    NSUInteger side = 16u << arc4random_uniform(5);
                    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                  width:side height:side mipmapped:NO];
                    td.storageMode = MTLStorageModeManaged;
                    td.usage = MTLTextureUsageShaderRead;
                    id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
                    [texture replaceRegion:MTLRegionMake2D(0, 0, side, side) mipmapLevel:0 withBytes:texels bytesPerRow:side * 4];
                } else {
                    NSUInteger length = 256u << arc4random_uniform(8);
                    id<MTLBuffer> buffer = [dev newBufferWithBytes:bytes length:length options:MTLResourceStorageModeManaged];
                    memset(buffer.contents, 0x5a, length / 2);
                    [buffer didModifyRange:NSMakeRange(0, length)];
                }
                atomic_fetch_add(&made, 1);
            }
        });
    for (int t = 0; t < 2; t++)
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            id<MTLCommandQueue> queue = [dev newCommandQueue];
            id<MTLBuffer> scratch = [dev newBufferWithLength:256 options:MTLResourceStorageModePrivate];
            while (!atomic_load(&stop)) @autoreleasepool {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                [blit fillBuffer:scratch range:NSMakeRange(0, 256) value:0];
                [blit endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                atomic_fetch_add(&commits, 1);
            }
        });
    [NSThread sleepForTimeInterval:5];
    atomic_store(&stop, 1);
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    printf("n50 child: %d managed %s written and freed, %d commits\n", atomic_load(&made), textures ? "textures" : "buffers",
           atomic_load(&commits));
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "n50-kepler-managed-upload-race";
        id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
        if (!dev) return SKIP(bug, "no such GPU");
        if (getenv("N50_CHILD")) return child(dev, !strcmp(getenv("N50_CHILD"), "textures"));
        const char *name = dev.name.UTF8String;
        char lines[2][256] = {{0}};
        const char *kinds[2] = {"buffers", "textures"};
        for (int k = 0; k < 2; k++) {
            setenv("N50_CHILD", kinds[k], 1);
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
                return FAIL(bug, "%s: the child crashed (signal %d) making, writing and freeing managed %s while two threads committed",
                            name, WTERMSIG(status), kinds[k]);
            if (!WIFEXITED(status) || WEXITSTATUS(status) || !strstr(text, "n50 child:"))
                return FAIL(bug, "%s: the %s child failed (status %d): %s", name, kinds[k], status, text);
            char *line = strstr(text, "n50 child: ") + strlen("n50 child: ");
            line[strcspn(line, "\n")] = 0;
            snprintf(lines[k], sizeof lines[k], "%s", line);
        }
        return PASS(bug, "%s: no crash in 5 s each (%s; %s)", name, lines[0], lines[1]);
    }
}
