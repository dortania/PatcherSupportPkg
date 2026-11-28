// winid <pid>: prints the window number of the process's largest on-screen normal window (for screencapture -l), or nothing.
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    int pid = atoi(argv[1]); long best = -1; double bestArea = 0;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(list, i); int owner = 0, layer = -1; long num = 0; CGRect r;
        CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
        CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
        CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowNumber), kCFNumberLongType, &num);
        if (owner != pid || layer != 0 || !CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r)) continue;
        if (r.size.width * r.size.height > bestArea) bestArea = r.size.width * r.size.height, best = num;
    }
    if (best >= 0) printf("%ld\n", best);
    return best >= 0 ? 0 : 1;
}
