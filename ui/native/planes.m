#import "planes.h"
#import <CoreMedia/CoreMedia.h>
#import <IOSurface/IOSurface.h>

static void retainFrame(void *p) { CFRetain(p); }
static void releaseFrame(void *p, uint32_t state) {
  (void)state;
  CFRelease(p);
}

static bool matches(CVPixelBufferRef buffer, CFStringRef key,
                    CFStringRef expected) {
  CFTypeRef v = CVBufferCopyAttachment(buffer, key, NULL);
  bool match = v && CFEqual(v, expected);
  if (v)
    CFRelease(v);
  return match;
}

@implementation SVFrame {
  CVPixelBufferRef _buffer;
  CVMetalTextureRef _maps[2];
}
- (instancetype)initWithBuffer:(CVPixelBufferRef)buffer
                         cache:(CVMetalTextureCacheRef)cache
                        device:(id<MTLDevice>)device {
  self = [super init];
  if (!self)
    return nil;
  IOSurfaceRef source = CVPixelBufferGetIOSurface(buffer);
  if (!source ||
      CVPixelBufferGetPixelFormatType(buffer) !=
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      CVPixelBufferGetPlaneCount(buffer) != 2 ||
      !matches(buffer, kCVImageBufferYCbCrMatrixKey,
               kCVImageBufferYCbCrMatrix_ITU_R_709_2) ||
      !matches(buffer, kCVImageBufferColorPrimariesKey,
               kCVImageBufferColorPrimaries_ITU_R_709_2) ||
      !matches(buffer, kCVImageBufferTransferFunctionKey,
               kCVImageBufferTransferFunction_ITU_R_709_2))
    return nil;
  _buffer = CVPixelBufferRetain(buffer);
  _surfaceID = IOSurfaceGetID(source);
  MTLPixelFormat formats[] = {MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm};
  SVPlane views[2];
  uint64_t ids[2];
  for (size_t p = 0; p < 2; ++p) {
    size_t w = CVPixelBufferGetWidthOfPlane(buffer, p);
    size_t h = CVPixelBufferGetHeightOfPlane(buffer, p);
    if (CVMetalTextureCacheCreateTextureFromImage(
            NULL, cache, buffer, NULL, formats[p], w, h, p, &_maps[p]) !=
        kCVReturnSuccess)
      return nil;
    id<MTLTexture> t = CVMetalTextureGetTexture(_maps[p]);
    if (!t || t.device != device || t.iosurface != source ||
        t.iosurfacePlane != p || t.pixelFormat != formats[p] || t.width != w ||
        t.height != h)
      return nil;
    t.label = p ? @"AVPlayer UV / plane 1" : @"AVPlayer Y / plane 0";
    views[p] = (SVPlane){(__bridge const void *)t, (int32_t)w, (int32_t)h,
                         t.pixelFormat};
    ids[p] = t.gpuResourceID._impl;
  }
  _yID = ids[0];
  _uvID = ids[1];
  // Offset in UV texel coordinates for progressive, center- or left-sited
  // 4:2:0.
  CFStringRef site = CVBufferCopyAttachment(
      buffer, kCVImageBufferChromaLocationTopFieldKey, NULL);
  bool left = !site || CFEqual(site, kCVImageBufferChromaLocation_Left);
  bool center = site && CFEqual(site, kCVImageBufferChromaLocation_Center);
  if (site)
    CFRelease(site);
  if (!left && !center)
    return nil;
  _planes = (SVPlanes){views[0],
                       views[1],
                       {(__bridge void *)self, retainFrame, releaseFrame},
                       left ? 0.25f : 0.0f,
                       0.0f};
  return self;
}
- (void)dealloc {
  for (size_t i = 0; i < 2; ++i)
    if (_maps[i])
      CFRelease(_maps[i]);
  if (_buffer)
    CVPixelBufferRelease(_buffer);
}
@end
