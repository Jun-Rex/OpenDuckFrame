#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import "SPStaticTileRestorer.h"
#include <cstdio>
#include <functional>

// Real GPU pass over synthetic BGRA buffers loaded from the built Debug app.
static CVPixelBufferRef makeBuffer(int width, int height, OSType format,
                                   const std::function<uint8_t(int, int)> &value) {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    if (CVPixelBufferCreate(NULL, width, height, format, (__bridge CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess) return NULL;
    if (format != kCVPixelFormatType_32BGRA) return buffer;
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        uint8_t *p = base + y * stride + x * 4, v = value(x, y);
        p[0] = v; p[1] = (uint8_t)(v ^ 0x5a); p[2] = (uint8_t)(255 - v); p[3] = 255;
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

static bool samePixel(CVPixelBufferRef a, CVPixelBufferRef b, int x, int y) {
    const uint8_t *pa = (const uint8_t *)CVPixelBufferGetBaseAddress(a) + y * CVPixelBufferGetBytesPerRow(a) + x * 4;
    const uint8_t *pb = (const uint8_t *)CVPixelBufferGetBaseAddress(b) + y * CVPixelBufferGetBytesPerRow(b) + x * 4;
    return memcmp(pa, pb, 4) == 0;
}

static int failures = 0;
static void expect(bool condition, const char *what) {
    printf("%s %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition) failures++;
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2 || !dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    Class restorerClass = NSClassFromString(@"SPStaticTileRestorer");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!restorerClass || !device) { fprintf(stderr, "restorer class or Metal device unavailable\n"); return 2; }
    NSError *error = nil;
    SPStaticTileRestorer *restorer = [[restorerClass alloc] initWithDevice:device error:&error];
    expect(restorer != nil, "restorer loads its kernel from the app library");
    if (!restorer) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    const int tile = [restorerClass tileSize];

    // Width/height are not tile multiples, so edge tiles are partial.
    const int W = 1001, H = 603;
    auto texture = [](int x, int y) { return (uint8_t)((x * 7 + y * 13) & 0xff); };
    // A moving block (the "video") changes only inside [300,420)x[200,290).
    auto inBlock = [](int x, int y) { return x >= 300 && x < 420 && y >= 200 && y < 290; };
    CVPixelBufferRef a = makeBuffer(W, H, kCVPixelFormatType_32BGRA, [&](int x, int y) { return inBlock(x, y) ? (uint8_t)40 : texture(x, y); });
    CVPixelBufferRef b = makeBuffer(W, H, kCVPixelFormatType_32BGRA, [&](int x, int y) { return inBlock(x, y) ? (uint8_t)200 : texture(x, y); });
    // A softened generated frame: every pixel differs from both sources.
    CVPixelBufferRef g = makeBuffer(W, H, kCVPixelFormatType_32BGRA, [&](int x, int y) { return (uint8_t)(texture(x, y) + 3); });

    uint32_t restored = 0, total = 0;
    CVPixelBufferRef out = [restorer copyRestoringGenerated:g previous:a current:b staticTiles:&restored totalTiles:&total];
    const uint32_t tilesX = (W + tile - 1) / tile, tilesY = (H + tile - 1) / tile;
    uint32_t changedTiles = 0;
    for (uint32_t ty = 0; ty < tilesY; ++ty) for (uint32_t tx = 0; tx < tilesX; ++tx) {
        bool changed = false;
        for (int y = ty * tile; y < (int)MIN((ty + 1) * tile, (uint32_t)H) && !changed; ++y)
            for (int x = tx * tile; x < (int)MIN((tx + 1) * tile, (uint32_t)W) && !changed; ++x) changed = inBlock(x, y);
        changedTiles += changed;
    }
    expect(out != NULL, "mixed frame returns a restored buffer");
    expect(total == tilesX * tilesY, "tile total covers partial edge tiles");
    expect(restored == total - changedTiles, "only tiles touched by the change keep generated pixels");
    if (out) {
        expect(CVPixelBufferGetWidth(out) == (size_t)W && CVPixelBufferGetHeight(out) == (size_t)H &&
               CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_32BGRA, "output keeps source geometry and format");
        CVPixelBufferLockBaseAddress(out, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(g, kCVPixelBufferLock_ReadOnly);
        bool staticExact = true, changedGenerated = true;
        for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
            const int tx = x / tile, ty = y / tile;
            bool tileChanged = false;
            for (int yy = ty * tile; yy < MIN((ty + 1) * tile, H) && !tileChanged; ++yy)
                for (int xx = tx * tile; xx < MIN((tx + 1) * tile, W) && !tileChanged; ++xx) tileChanged = inBlock(xx, yy);
            if (tileChanged) changedGenerated = changedGenerated && samePixel(out, g, x, y);
            else staticExact = staticExact && samePixel(out, b, x, y);
        }
        expect(staticExact, "static tiles are the current source, byte for byte (edge tiles included)");
        expect(changedGenerated, "changed tiles are the generated pixels, untouched");
        CVPixelBufferUnlockBaseAddress(g, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(out, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(out);
    }

    // Everything moved: nothing to restore, the generated frame stays.
    CVPixelBufferRef moved = makeBuffer(W, H, kCVPixelFormatType_32BGRA, [&](int x, int y) { return (uint8_t)(texture(x, y) + 1); });
    restored = 7; total = 0;
    CVPixelBufferRef none = [restorer copyRestoringGenerated:g previous:a current:moved staticTiles:&restored totalTiles:&total];
    expect(none == NULL && restored == 0 && total == tilesX * tilesY, "fully changed pair keeps the generated frame");
    if (none) CVPixelBufferRelease(none);

    // A size or format mismatch (reduced-size presentation paths) is not touched.
    CVPixelBufferRef small = makeBuffer(W / 2, H / 2, kCVPixelFormatType_32BGRA, texture);
    restored = 9; total = 9;
    CVPixelBufferRef mismatch = [restorer copyRestoringGenerated:small previous:a current:b staticTiles:&restored totalTiles:&total];
    expect(mismatch == NULL && restored == 9 && total == 9, "size mismatch is skipped without GPU work");
    CVPixelBufferRef nv12 = makeBuffer(W - 1, H - 1, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, texture);
    CVPixelBufferRef nonBGRA = [restorer copyRestoringGenerated:g previous:nv12 current:b staticTiles:NULL totalTiles:NULL];
    expect(nonBGRA == NULL, "non-BGRA input is skipped");

    for (CVPixelBufferRef buffer : {a, b, g, moved, small, nv12}) if (buffer) CVPixelBufferRelease(buffer);
    printf("%s\n", failures ? "static tile restore: FAILED" : "static tile restore: OK");
    return failures ? 1 : 0;
} }
