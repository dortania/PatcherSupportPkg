// webkithost <url> [seconds] (tools/webkit-cts.sh builds and runs it): one window with one WKWebView, as Safari draws
// (WebKit's GPU process, its WGSL compiler and argument buffers, ANGLE for WebGL), but an app of our own: WebKit's XPC
// services take __XPC_ variables from it, so a build can be injected into the GPU process (__XPC_DYLD_INSERT_LIBRARIES)
// and, one hop further, into the MTLCompilerService the GPU process starts (__XPC___XPC_DYLD_LIBRARY_PATH), which
// Safari, a platform binary, doesn't allow. Prints every console message of every frame (console.*, uncaught errors)
// as "<level>: <text>"; WEBKITHOST_SCRIPT=<file.js> is injected at document end in the main frame; quits when a
// message contains WEBKITHOST_DONE, or after [seconds] (default 7200).
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>

@interface Host : NSObject <NSApplicationDelegate, WKScriptMessageHandler>
@property(strong) NSWindow *window;
@property(strong) WKWebView *web;
@end

@implementation Host
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSArray *args = NSProcessInfo.processInfo.arguments;
    if (args.count < 2) {
        fprintf(stderr, "usage: webkithost <url> [seconds]\n");
        exit(2);
    }
    double limit = args.count > 2 ? [args[2] doubleValue] : 7200;
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    // WebKit before Safari 26 (Sequoia's 18.x) leaves WebGPU off for apps: switch on every feature flag named WebGPU*, as
    // Safari's Feature Flags menu does (WKPreferences' private feature API)
    if ([WKPreferences respondsToSelector:NSSelectorFromString(@"_features")]) {
        NSArray *features = ((NSArray *(*)(id, SEL))objc_msgSend)([WKPreferences class], NSSelectorFromString(@"_features"));
        SEL set = NSSelectorFromString(@"_setEnabled:forFeature:");
        for (id feature in features) {
            NSString *key = [feature valueForKey:@"key"];
            if ([key hasPrefix:@"WebGPU"] && [config.preferences respondsToSelector:set]) {
                ((void (*)(id, SEL, BOOL, id))objc_msgSend)(config.preferences, set, YES, feature);
                fprintf(stderr, "webkithost: feature %s on\n", key.UTF8String);
            }
        }
    }
    NSString *forward = @"(function(){var p=function(k,a){try{window.webkit.messageHandlers.log.postMessage(k+': '+"
                         "Array.prototype.map.call(a,String).join(' '));}catch(e){}};"
                         "['log','warn','error','info','debug'].forEach(function(k){var o=console[k];console[k]=function(){"
                         "p(k,arguments);if(o)o.apply(console,arguments);};});"
                         "window.addEventListener('error',function(e){p('uncaught',[e.message]);});})();";
    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:forward
                                                                         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                                      forMainFrameOnly:NO]];
    const char *script = getenv("WEBKITHOST_SCRIPT");
    NSString *extra = script ? [NSString stringWithContentsOfFile:@(script) encoding:NSUTF8StringEncoding error:nil] : nil;
    if (script && !extra) {
        fprintf(stderr, "webkithost: can't read %s\n", script);
        exit(2);
    }
    if (extra)
        [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:extra
                                                                             injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                                                          forMainFrameOnly:YES]];
    [config.userContentController addScriptMessageHandler:self name:@"log"];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 1100, 800)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"webkithost";
    self.web = [[WKWebView alloc] initWithFrame:self.window.contentView.bounds configuration:config];
    self.web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window.contentView addSubview:self.web];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:args[1]]]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        printf("webkithost: time limit (%.0f s)\n", limit);
        [NSApp terminate:nil];
    });
}
- (void)userContentController:(WKUserContentController *)c didReceiveScriptMessage:(WKScriptMessage *)m {
    NSString *body = [m.body description];
    printf("%s\n", body.UTF8String);
    fflush(stdout);
    if ([body containsString:@"WEBKITHOST_DONE"]) dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        Host *host = [Host new];
        app.delegate = host;
        [app run];
    }
    return 0;
}
