// n50-kepler-managed-upload-race (MetalOldCompat item 82): managed buffers written (didModifyRange:) and freed on some
// threads while others commit, as Safari's WebGPU does in its GPU process. Kepler's driver keeps the buffers given to
// didModifyRange: on a device-wide list that the next commit, on any queue, walks to upload them, and a buffer freed
// before it was uploaded, while another thread committed, was freed under that commit: the commit read a nil _res
// (-[NVMTLCommandBuffer commit], EXC_BAD_ACCESS at 0x2f0) or over-released it (objc_release in
// MTLResourceListChunkFreeEntries); WebKit's GPU process crashed that way in the WebGPU CTS. The test runs itself again
// as a child (so that a crash is a result): two threads make (with initial bytes), write and free managed buffers of
// 256 B to 32 KB while two threads commit small blits on queues of their own, for 6 s. Stock OCLP on Kepler: FAIL (the
// child crashed, within half a second). Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"
#include <spawn.h>
#include <stdatomic.h>
#include <sys/wait.h>

extern char **environ;

static int child(id<MTLDevice> dev) {
    __block atomic_int stop = 0, made = 0, commits = 0;
    static uint8_t bytes[32768];  // newBufferWithBytes: (not item 60's zero-filled newBufferWithLength:, whose wait slows the race down)
    dispatch_group_t group = dispatch_group_create();
    for (int t = 0; t < 2; t++)
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            while (!atomic_load(&stop)) @autoreleasepool {
                NSUInteger length = 256u << arc4random_uniform(8);
                id<MTLBuffer> buffer = [dev newBufferWithBytes:bytes length:length options:MTLResourceStorageModeManaged];
                memset(buffer.contents, 0x5a, length / 2);
                [buffer didModifyRange:NSMakeRange(0, length)];
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
    [NSThread sleepForTimeInterval:6];
    atomic_store(&stop, 1);
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    printf("n50 child: %d managed buffers written and freed, %d commits\n", atomic_load(&made), atomic_load(&commits));
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "n50-kepler-managed-upload-race";
        id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
        if (!dev) return SKIP(bug, "no such GPU");
        if (getenv("N50_CHILD")) return child(dev);
        const char *name = dev.name.UTF8String;
        setenv("N50_CHILD", "1", 1);
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
            return FAIL(bug, "%s: the child crashed (signal %d) making, writing and freeing managed buffers while two threads committed",
                        name, WTERMSIG(status));
        if (!WIFEXITED(status) || WEXITSTATUS(status) || !strstr(text, "n50 child:"))
            return FAIL(bug, "%s: the child failed (status %d): %s", name, status, text);
        char *line = strstr(text, "n50 child: ") + strlen("n50 child: ");
        line[strcspn(line, "\n")] = 0;
        return PASS(bug, "%s: no crash in 6 s (%s)", name, line);
    }
}
