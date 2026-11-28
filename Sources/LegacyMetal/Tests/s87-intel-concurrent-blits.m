// s87-intel-concurrent-blits: blits from two threads at once must work on Ivy Bridge; the driver's shared state crashed
// it (SIGFPE). Fix: MetalOldCompat item 83 MTLSHIM_IVB_BLIT_LOCK.
// Checks: two threads fill and copy on their own queues for 3 s, in a child; every copy right. Argument: GPU name.
#import "repro.h"
#include <spawn.h>
#include <stdatomic.h>
#include <sys/wait.h>
extern char **environ;

static int child(id<MTLDevice> dev) {
    __block atomic_int stop = 0, blits = 0, wrong = 0;
    dispatch_group_t group = dispatch_group_create();
    for (int t = 0; t < 2; t++)
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            id<MTLCommandQueue> queue = [dev newCommandQueue];
            id<MTLBuffer> a = [dev newBufferWithLength:1024 options:MTLResourceStorageModePrivate];
            id<MTLBuffer> b = [dev newBufferWithLength:1024 options:MTLResourceStorageModePrivate];
            id<MTLBuffer> back = [dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:16 height:16 mipmapped:NO];
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
            for (uint8_t value = 1; !atomic_load(&stop); value++) @autoreleasepool {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                [blit fillBuffer:a range:NSMakeRange(0, 1024) value:value];
                [blit copyFromBuffer:a sourceOffset:0 toBuffer:b destinationOffset:0 size:1024];
                [blit copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:64 sourceBytesPerImage:1024 sourceSize:MTLSizeMake(16, 16, 1)
                           toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(16, 16, 1)
                             toBuffer:back destinationOffset:0 destinationBytesPerRow:64 destinationBytesPerImage:1024];
                [blit endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                const uint8_t *p = back.contents;
                for (int i = 0; i < 1024; i++)
                    if (p[i] != value) { atomic_fetch_add(&wrong, 1); break; }
                atomic_fetch_add(&blits, 4);
            }
        });
    [NSThread sleepForTimeInterval:3];
    atomic_store(&stop, 1);
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    printf("s87 child: %d blits, %d wrong round trips\n", atomic_load(&blits), atomic_load(&wrong));
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s87-intel-concurrent-blits";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        if (getenv("S87_CHILD")) return child(dev);
        const char *name = dev.name.UTF8String;
        setenv("S87_CHILD", "1", 1);
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
            return FAIL(bug, "%s: the child crashed (signal %d) with two threads blitting at once", name, WTERMSIG(status));
        if (!WIFEXITED(status) || WEXITSTATUS(status) || !strstr(text, "s87 child:"))
            return FAIL(bug, "%s: the child failed (status %d): %s", name, status, text);
        unsigned count = 0, wrong = 0;
        sscanf(strstr(text, "s87 child: "), "s87 child: %u blits, %u wrong", &count, &wrong);
        if (wrong) return FAIL(bug, "%s: %u of the round trips (fill, copies, texture and back) came back wrong", name, wrong);
        return PASS(bug, "%s: two threads blitting at once for 3 s: %u blits, every round trip right", name, count);
    }
}
