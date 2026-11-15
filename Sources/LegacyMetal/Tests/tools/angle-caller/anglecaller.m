// Built as tools/angle-caller/libANGLE-shared.dylib for s63's S63_METALLIB mode: loads a metallib with
// -[MTLDevice newLibraryWithData:error:] from an image named like WebKit's ANGLE, which is how MetalOldCompat item 13
// recognises ANGLE's internal-shader library (by the caller's image name).
#import <Metal/Metal.h>
__attribute__((visibility("default"), noinline)) id s63LoadAngleLibrary(id<MTLDevice> device, NSData *bytes, NSError **error) {
    dispatch_data_t data = dispatch_data_create(bytes.bytes, bytes.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id library = [device newLibraryWithData:data error:error];
    __asm__ volatile("");  // keep the call a call (the shim reads its return address)
    return library;
}
