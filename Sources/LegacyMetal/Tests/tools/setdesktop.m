// setdesktop <image file>: sets the desktop picture of every screen with NSWorkspace, as an app or System Settings'
// "Add Photo" does (a dynamic HEIC stays dynamic). Used by wallpaper-check.sh; built on first use.
#import <AppKit/AppKit.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: setdesktop <image file>\n"); return 2; }
        NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
        int failures = 0;
        for (NSScreen *screen in NSScreen.screens) {
            NSError *error = nil;
            if (![NSWorkspace.sharedWorkspace setDesktopImageURL:url forScreen:screen options:@{} error:&error]) {
                fprintf(stderr, "setdesktop: %s\n", error.localizedDescription.UTF8String);
                failures++;
            }
        }
        return failures ? 1 : 0;
    }
}
