#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

typedef struct {
  void *payload;
  void (*retain)(void *);
  void (*release)(void *, uint32_t);
} SVImageOwner;

typedef struct {
  const void *texture;
  int32_t width, height;
  uint64_t format;
} SVPlane;

typedef struct {
  SVPlane y, uv;
  SVImageOwner owner;
  float chromaX, chromaY;
} SVPlanes;

@interface SVFrame : NSObject
- (instancetype)initWithBuffer:(CVPixelBufferRef)buffer
                         cache:(CVMetalTextureCacheRef)cache
                        device:(id<MTLDevice>)device;
@property(nonatomic, readonly) SVPlanes planes;
@property(nonatomic, readonly) uint32_t surfaceID;
@property(nonatomic, readonly) uint64_t yID, uvID;
@property(nonatomic) CMTime pts;
@end
