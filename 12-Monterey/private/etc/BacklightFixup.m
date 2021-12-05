// clang -fmodules BacklightFixup.m -dynamiclib -o BacklightFixup.dylib && codesign -f -s - BacklightFixup.dylib && cp ./BackLightFixup.dylib /etc/SkyLightPlugins

@import Foundation;

@interface Load:NSObject
@end

@implementation Load

+(void)load
{
	int pid = [[NSProcessInfo processInfo] processIdentifier];
	// Fix backlight on Penryn Macs (Terrifying, as this shouldn't be running at all)
	// Kill TouchBarServer, to prevent multiple instances
	NSLog(@"HedgeLog: Killing TouchBarServer...");
	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/usr/bin/killall";
	task.arguments = @[@"TouchBarServer"];
	// Start an instance of TouchBarServer
	task.terminationHandler = ^(NSTask *task){
		NSLog(@"HedgeLog: Starting TouchBarServer...");
		
		NSTask *starttask = [[NSTask alloc] init];
		starttask.launchPath = @"/usr/libexec/TouchBarServer";
		
		[starttask launch];
		
		NSLog(@"HedgeLog: Started TouchBarServer");
	};
	[task launch];
	[task waitUntilExit];
}

@end