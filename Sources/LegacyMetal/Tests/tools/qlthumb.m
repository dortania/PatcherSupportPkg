// qlthumb <file> <out.png> [size]: a thumbnail of the file through QLThumbnailGenerator, the API Finder uses (its thumbnail
// extensions run out of process: 3D models through SceneKit/RealityKit on Metal). Prints its size and how much of it is
// drawn; exit status 1 if none within 60 s, 3 if it's blank (under 0.5% of it drawn). Used by quicklook-check.sh; built on first use.
#import <AppKit/AppKit.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: qlthumb <file> <out.png> [size]\n"); return 2; }
        CGFloat size = argc > 3 ? atof(argv[3]) : 512;
        QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:[NSURL fileURLWithPath:@(argv[1])]
            size:CGSizeMake(size, size) scale:1.0 representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
        __block int status = 1;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [QLThumbnailGenerator.sharedGenerator generateBestRepresentationForRequest:req
                                                                completionHandler:^(QLThumbnailRepresentation *rep, NSError *error) {
            if (rep) {
                NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:rep.CGImage];
                if ([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[2]) atomically:YES]) {
                    long n = bitmap.pixelsWide * bitmap.pixelsHigh, opaque = 0;  // how much of it is drawn (a blank one is transparent)
                    for (long y = 0; y < bitmap.pixelsHigh; y++)
                        for (long x = 0; x < bitmap.pixelsWide; x++)
                            if ([bitmap colorAtX:x y:y].alphaComponent > 0.05) opaque++;
                    printf("%ldx%ld, %.1f%% drawn\n", (long)bitmap.pixelsWide, (long)bitmap.pixelsHigh, n ? 100.0 * opaque / n : 0.0);
                    status = n && opaque * 200 >= n ? 0 : 3;  // under 0.5% drawn: blank
                }
            } else {
                printf("no thumbnail: %s\n", error.localizedDescription.UTF8String ?: "?");
            }
            dispatch_semaphore_signal(done);
        }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC))) { printf("no thumbnail within 60 s\n"); return 1; }
        return status;
    }
}
