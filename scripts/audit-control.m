#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>

// Exercise the measurement on a separate synthetic frame before observing real
// playback.
int main(void) {
  @autoreleasepool {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attrs = @{
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES
    };
    if (CVPixelBufferCreate(
            NULL, 3840, 2160, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            (__bridge CFDictionaryRef)attrs, &buffer) != kCVReturnSuccess)
      return 1;
    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess)
      return 1;
    (void)CVPixelBufferGetBaseAddress(buffer);
    *(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0) = 32;
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    IOSurfaceRef io = CVPixelBufferGetIOSurface(buffer);
    if (IOSurfaceLock(io, 0, NULL) != KERN_SUCCESS)
      return 1;
    (void)IOSurfaceGetBaseAddress(io);
    *(uint8_t *)IOSurfaceGetBaseAddressOfPlane(io, 0) = 64;
    IOSurfaceUnlock(io, 0, NULL);
    CVMetalTextureCacheRef cache = NULL;
    CVMetalTextureRef view = NULL;
    if (CVMetalTextureCacheCreate(NULL, NULL, MTLCreateSystemDefaultDevice(),
                                  NULL, &cache) != kCVReturnSuccess ||
        CVMetalTextureCacheCreateTextureFromImage(
            NULL, cache, buffer, NULL, MTLPixelFormatR8Unorm, 3840, 2160, 0,
            &view) != kCVReturnSuccess)
      return 1;
    id<MTLTexture> texture = CVMetalTextureGetTexture(view);
    MTLRegion pixel = MTLRegionMake2D(0, 0, 1, 1);
    uint8_t written = 176, read = 0;
    [texture replaceRegion:pixel
               mipmapLevel:0
                 withBytes:&written
               bytesPerRow:1];
    [texture getBytes:&read bytesPerRow:1 fromRegion:pixel mipmapLevel:0];
    CVPixelBufferRef alias = NULL, destination = NULL;
    VTPixelTransferSessionRef transfer = NULL;
    if (CVPixelBufferCreateWithIOSurface(NULL, io, NULL, &alias) !=
            kCVReturnSuccess ||
        CVPixelBufferCreate(NULL, 3840, 2160,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attrs,
                            &destination) != kCVReturnSuccess ||
        VTPixelTransferSessionCreate(NULL, &transfer) != noErr ||
        VTPixelTransferSessionTransferImage(transfer, alias, destination) !=
            noErr)
      return 1;
    CFRelease(transfer);
    CFRelease(destination);
    CFRelease(alias);
    CFRelease(view);
    CFRelease(cache);
    CFRelease(buffer);
    return read == written ? 0 : 1;
  }
}
