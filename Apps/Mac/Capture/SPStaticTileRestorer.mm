#import "SPStaticTileRestorer.h"
#include <initializer_list>

static const int SPStaticTile = 16;

@implementation SPStaticTileRestorer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _pipeline;
    id<MTLBuffer> _counter;
    CVMetalTextureCacheRef _cache;
}

+ (int)tileSize { return SPStaticTile; }

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error {
    if (!(self = [super init])) return nil;
    NSError *failure = nil;
    // The kernel ships in the app's default library; resolve it through the
    // image that defines this class so test hosts load the same library.
    id<MTLLibrary> library = [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:SPStaticTileRestorer.class] error:&failure]
        ?: [device newDefaultLibrary];
    id<MTLFunction> function = [library newFunctionWithName:@"spRestoreStaticTiles"];
    _pipeline = function ? [device newComputePipelineStateWithFunction:function error:&failure] : nil;
    if (!_pipeline || _pipeline.maxTotalThreadsPerThreadgroup < (NSUInteger)(SPStaticTile * SPStaticTile)) {
        if (error) *error = failure ?: [NSError errorWithDomain:@"app.openduckframe.static-tiles" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"静态区域还原着色器不可用"}];
        return nil;
    }
    _device = device;
    _queue = [device newCommandQueue];
    _counter = [device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if (!_queue || !_counter || CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_cache) != kCVReturnSuccess) {
        if (error) *error = [NSError errorWithDomain:@"app.openduckframe.static-tiles" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"静态区域还原资源创建失败"}];
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_cache) CFRelease(_cache);
}

- (CVMetalTextureRef)textureFor:(CVPixelBufferRef)buffer {
    CVMetalTextureRef ref = NULL;
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, buffer, NULL, MTLPixelFormatBGRA8Unorm,
        CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &ref);
    return ref;
}

- (CVPixelBufferRef)copyRestoringGenerated:(CVPixelBufferRef)generated
                                  previous:(CVPixelBufferRef)previous
                                   current:(CVPixelBufferRef)current
                               staticTiles:(uint32_t *)staticTiles
                                totalTiles:(uint32_t *)totalTiles {
    if (!generated || !previous || !current) return NULL;
    const size_t width = CVPixelBufferGetWidth(generated), height = CVPixelBufferGetHeight(generated);
    for (CVPixelBufferRef buffer : {generated, previous, current}) {
        if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA ||
            CVPixelBufferGetWidth(buffer) != width || CVPixelBufferGetHeight(buffer) != height) return NULL;
    }
    if (width == 0 || height == 0) return NULL;
    CVPixelBufferRef output = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attributes, &output) != kCVReturnSuccess || !output) return NULL;
    CVMetalTextureRef refs[4] = {[self textureFor:previous], [self textureFor:current], [self textureFor:generated], [self textureFor:output]};
    BOOL ready = YES;
    for (CVMetalTextureRef ref : refs) ready = ready && ref && CVMetalTextureGetTexture(ref);
    BOOL completed = NO;
    const uint32_t tilesX = (uint32_t)((width + SPStaticTile - 1) / SPStaticTile);
    const uint32_t tilesY = (uint32_t)((height + SPStaticTile - 1) / SPStaticTile);
    uint32_t restored = 0;
    if (ready) {
        *(uint32_t *)_counter.contents = 0;
        id<MTLCommandBuffer> command = [_queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:_pipeline];
        for (NSUInteger i = 0; i < 4; ++i) [encoder setTexture:CVMetalTextureGetTexture(refs[i]) atIndex:i];
        [encoder setBuffer:_counter offset:0 atIndex:0];
        [encoder dispatchThreadgroups:MTLSizeMake(tilesX, tilesY, 1)
                threadsPerThreadgroup:MTLSizeMake(SPStaticTile, SPStaticTile, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        completed = command.status == MTLCommandBufferStatusCompleted;
        if (completed) restored = *(uint32_t *)_counter.contents;
    }
    for (CVMetalTextureRef ref : refs) if (ref) CFRelease(ref);
    CVMetalTextureCacheFlush(_cache, 0);
    if (completed) {
        if (staticTiles) *staticTiles = restored;
        if (totalTiles) *totalTiles = tilesX * tilesY;
    }
    if (!completed || restored == 0) { CVPixelBufferRelease(output); return NULL; }
    CVBufferPropagateAttachments(generated, output);
    return output;
}

@end
