#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Keeps captured detail where a generated live frame has nothing to add.
/// The picture is split into 16x16 tiles; a tile whose previous and current
/// source pixels are bit-identical is copied from the current source, every
/// other tile keeps the generated pixels. All three buffers must be BGRA with
/// identical dimensions.
@interface SPStaticTileRestorer : NSObject

@property (class, nonatomic, readonly) int tileSize;

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError *_Nullable *_Nullable)error;

/// Returns a new +1 buffer, or NULL when the inputs do not qualify, no tile is
/// static, or GPU work fails; the caller then keeps `generated`. Tile counts
/// are written whenever the GPU pass ran.
- (nullable CVPixelBufferRef)copyRestoringGenerated:(CVPixelBufferRef)generated
                                           previous:(CVPixelBufferRef)previous
                                            current:(CVPixelBufferRef)current
                                        staticTiles:(uint32_t *_Nullable)staticTiles
                                         totalTiles:(uint32_t *_Nullable)totalTiles CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
