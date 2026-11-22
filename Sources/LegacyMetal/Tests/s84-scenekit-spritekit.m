// s84-scenekit-spritekit (sweep): SceneKit and SpriteKit render offscreen on the GPU under test with SCNRenderer and
// SKRenderer, in this process. Both generate their Metal shaders at runtime from the scene (lights, materials, shadows,
// textures, blend modes), a third shader generator on these stacks after ANGLE (browsers, Electron) and SPIRV-Cross
// (MoltenVK), which games, Chess.app and Quick Look's 3D previews use. Checked, for every MSAA sample count the GPU has of
// 1, 2 and 4: a red lit sphere with a shadow on a white floor under a directional light, a textured box, and a SpriteKit
// scene of blended sprites and a shape node render, and sampled pixels have the colors the scene implies (lit red on the
// sphere, white floor brighter than its shadow, the box's texture colors, the sprites over the background).
// Argument: GPU name substring (default: the system default GPU).
#import "repro.h"
#import <SceneKit/SceneKit.h>
#import <SpriteKit/SpriteKit.h>

enum { W = 128, H = 128 };

static id<MTLTexture> target(id<MTLDevice> dev, NSUInteger samples, MTLPixelFormat format, id<MTLTexture> *resolve) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> single = [dev newTextureWithDescriptor:td];
    if (resolve) *resolve = single;
    if (samples == 1) return single;
    td.textureType = MTLTextureType2DMultisample;
    td.sampleCount = samples;
    td.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:td];
}

// BGRA8 pixel at (x, y) as r, g, b in 0..255
static void pixel(id<MTLTexture> t, int x, int y, int rgb[3]) {
    uint8_t p[4];
    [t getBytes:p bytesPerRow:4 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
    rgb[0] = p[2]; rgb[1] = p[1]; rgb[2] = p[0];
}

static NSString *renderPass(id<MTLCommandQueue> q, NSUInteger samples, void (^draw)(id<MTLCommandBuffer>, MTLRenderPassDescriptor *),
                            id<MTLTexture> *out) {
    id<MTLDevice> dev = q.device;
    id<MTLTexture> resolved;
    id<MTLTexture> color = target(dev, samples, MTLPixelFormatBGRA8Unorm, &resolved);
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:W height:H mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget;
    dd.storageMode = MTLStorageModePrivate;
    if (samples > 1) { dd.textureType = MTLTextureType2DMultisample; dd.sampleCount = samples; }
    id<MTLTexture> depth = [dev newTextureWithDescriptor:dd];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = color;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.4, 1);
    if (samples > 1) {
        rp.colorAttachments[0].resolveTexture = resolved;
        rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    } else {
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    rp.depthAttachment.texture = depth;
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.clearDepth = 1.0;
    rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    draw(cb, rp);
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be synchronizeResource:resolved];
    [be endEncoding];
    if (!reproRun(cb)) return [NSString stringWithFormat:@"command buffer failed: %@", cb.error.localizedDescription];
    *out = resolved;
    return nil;
}

static SCNScene *scene3D(void) {
    SCNScene *s = [SCNScene scene];
    SCNNode *cam = [SCNNode node];
    cam.camera = [SCNCamera camera];
    cam.position = SCNVector3Make(0, 2.5, 6);
    cam.eulerAngles = SCNVector3Make(-0.38, 0, 0);
    [s.rootNode addChildNode:cam];
    SCNNode *sun = [SCNNode node];
    sun.light = [SCNLight light];
    sun.light.type = SCNLightTypeDirectional;
    sun.light.castsShadow = YES;
    sun.light.shadowMapSize = CGSizeMake(1024, 1024);
    sun.eulerAngles = SCNVector3Make(-1.2, 0.4, 0);
    [s.rootNode addChildNode:sun];
    SCNNode *amb = [SCNNode node];
    amb.light = [SCNLight light];
    amb.light.type = SCNLightTypeAmbient;
    amb.light.color = [NSColor colorWithWhite:0.25 alpha:1];
    [s.rootNode addChildNode:amb];
    SCNFloor *floor = [SCNFloor floor];
    floor.reflectivity = 0;
    floor.firstMaterial.diffuse.contents = NSColor.whiteColor;
    [s.rootNode addChildNode:[SCNNode nodeWithGeometry:floor]];
    SCNSphere *ball = [SCNSphere sphereWithRadius:0.8];
    ball.firstMaterial.diffuse.contents = NSColor.redColor;
    ball.firstMaterial.lightingModelName = SCNLightingModelBlinn;
    SCNNode *ballNode = [SCNNode nodeWithGeometry:ball];
    ballNode.position = SCNVector3Make(-0.9, 0.8, 0);
    [s.rootNode addChildNode:ballNode];
    // a box with a 2x2 checker texture of green and blue
    NSImage *checker = [NSImage imageWithSize:NSMakeSize(64, 64) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.greenColor setFill]; NSRectFill(NSMakeRect(0, 0, 32, 32)); NSRectFill(NSMakeRect(32, 32, 32, 32));
        [NSColor.blueColor setFill]; NSRectFill(NSMakeRect(32, 0, 32, 32)); NSRectFill(NSMakeRect(0, 32, 32, 32));
        return YES;
    }];
    SCNBox *box = [SCNBox boxWithWidth:1.2 height:1.2 length:1.2 chamferRadius:0];
    box.firstMaterial.diffuse.contents = checker;
    box.firstMaterial.lightingModelName = SCNLightingModelConstant;  // unlit: the texture's own colors
    SCNNode *boxNode = [SCNNode nodeWithGeometry:box];
    boxNode.position = SCNVector3Make(1.1, 0.6, 0);
    [s.rootNode addChildNode:boxNode];
    return s;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s84-scenekit-spritekit";
        id<MTLDevice> dev = argc > 1 ? reproDevice(argc, argv, "") : MTLCreateSystemDefaultDevice();
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        id<MTLCommandQueue> q = [dev newCommandQueue];
        NSMutableArray *checked = [NSMutableArray array];
        for (NSUInteger samples = 1; samples <= 4; samples *= 2) {
            if (![dev supportsTextureSampleCount:samples]) continue;
            // SceneKit
            SCNRenderer *r = [SCNRenderer rendererWithDevice:dev options:nil];
            r.scene = scene3D();
            r.autoenablesDefaultLighting = NO;
            r.pointOfView = [r.scene.rootNode childNodesPassingTest:^BOOL(SCNNode *n, BOOL *stop) { return n.camera != nil; }].firstObject;
            id<MTLTexture> img = nil;
            NSString *err = renderPass(q, samples, ^(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor *rp) {
                [r renderAtTime:0 viewport:CGRectMake(0, 0, W, H) commandBuffer:cb passDescriptor:rp];
            }, &img);
            if (err) return FAIL(bug, "%s: SceneKit at %lu samples: %s", name, (unsigned long)samples, err.UTF8String);
            if (getenv("S84_DUMP")) {  // debugging: the rendered image as a PNG
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H bitsPerSample:8
                    samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:W * 4 bitsPerPixel:32];
                for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { int c[3]; pixel(img, x, y, c); uint8_t *q = rep.bitmapData + y * W * 4 + x * 4; q[0] = c[0]; q[1] = c[1]; q[2] = c[2]; q[3] = 255; }
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithFormat:@"%s/s84-scenekit-%lux.png", getenv("S84_DUMP"), (unsigned long)samples] atomically:YES];
            }
            // find the sphere (reddest pixel), the box (a green and a blue pixel), and floor brightness spread (shadow)
            int best = -1, green = 0, blue = 0, floorMax = 0, floorMin = 255;
            for (int y = 0; y < H; y += 2)
                for (int x = 0; x < W; x += 2) {
                    int c[3];
                    pixel(img, x, y, c);
                    int redness = c[0] - (c[1] + c[2]) / 2;
                    if (redness > best) best = redness;
                    if (c[1] > 180 && c[0] < 80 && c[2] < 80) green++;
                    if (c[2] > 180 && c[0] < 80 && c[1] < 80) blue++;
                    if (y > H / 3 && abs(c[0] - c[1]) < 12 && abs(c[1] - c[2]) < 12) {  // grey/white floor pixels
                        if (c[0] > floorMax) floorMax = c[0];
                        if (c[0] < floorMin) floorMin = c[0];
                    }
                }
            if (best < 100) return FAIL(bug, "%s: SceneKit at %lu samples: no lit red sphere (best redness %d)", name, (unsigned long)samples, best);
            if (green < 10 || blue < 10)
                return FAIL(bug, "%s: SceneKit at %lu samples: the box's texture is missing (%d green, %d blue pixels)", name, (unsigned long)samples, green, blue);
            if (floorMax < 150 || floorMax - floorMin < 40)
                return FAIL(bug, "%s: SceneKit at %lu samples: no lit floor with a shadow (floor %d..%d)", name, (unsigned long)samples, floorMin, floorMax);
            // SpriteKit: a white square sprite, a half-transparent red one over it and the background, a yellow circle
            SKScene *sk = [SKScene sceneWithSize:CGSizeMake(W, H)];
            sk.backgroundColor = [NSColor colorWithRed:0 green:0 blue:0.5 alpha:1];
            SKSpriteNode *a = [SKSpriteNode spriteNodeWithColor:NSColor.whiteColor size:CGSizeMake(60, 60)];
            a.position = CGPointMake(40, 40);
            SKSpriteNode *b = [SKSpriteNode spriteNodeWithColor:[NSColor colorWithRed:1 green:0 blue:0 alpha:0.5] size:CGSizeMake(60, 60)];
            b.position = CGPointMake(60, 60);
            SKShapeNode *c = [SKShapeNode shapeNodeWithCircleOfRadius:15];
            c.fillColor = NSColor.yellowColor;
            c.strokeColor = NSColor.clearColor;
            c.position = CGPointMake(100, 100);
            [sk addChild:a]; [sk addChild:b]; [sk addChild:c];
            SKRenderer *sr = [SKRenderer rendererWithDevice:dev];
            sr.scene = sk;
            [sr updateAtTime:0];
            err = renderPass(q, samples, ^(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor *rp) {
                [sr renderWithViewport:CGRectMake(0, 0, W, H) commandBuffer:cb renderPassDescriptor:rp];
            }, &img);
            if (err) return FAIL(bug, "%s: SpriteKit at %lu samples: %s", name, (unsigned long)samples, err.UTF8String);
            int px[3];
            // SpriteKit's origin is bottom-left, the texture's top-left: scene (x, y) -> texture (x, H - 1 - y)
            struct { int x, y; int want[3]; const char *what; } probes[] = {
                {5, 5, {25, 25, 102}, "background (the pass's clear color: SKRenderer draws no scene background)"},
                {20, 20, {255, 255, 255}, "white sprite"},
                {50, 50, {255, 128, 128}, "red sprite over white (blended)"}, {80, 80, {140, 13, 51}, "red sprite over the background (blended)"},
                {100, 100, {255, 255, 0}, "yellow circle"}};
            for (unsigned i = 0; i < sizeof probes / sizeof probes[0]; i++) {
                pixel(img, probes[i].x, H - 1 - probes[i].y, px);
                for (int k = 0; k < 3; k++)
                    if (abs(px[k] - probes[i].want[k]) > 24)
                        return FAIL(bug, "%s: SpriteKit at %lu samples: %s at (%d,%d) is %d,%d,%d, want about %d,%d,%d", name, (unsigned long)samples,
                                    probes[i].what, probes[i].x, probes[i].y, px[0], px[1], px[2], probes[i].want[0], probes[i].want[1], probes[i].want[2]);
            }
            [checked addObject:[NSString stringWithFormat:@"%lux", (unsigned long)samples]];
        }
        return PASS(bug, "%s: SceneKit (lit sphere, shadowed floor, textured box) and SpriteKit (blended sprites, a shape) render right at %s",
                    name, [checked componentsJoinedByString:@", "].UTF8String);
    }
}
