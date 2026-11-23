#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <execinfo.h>
#import <objc/runtime.h>
#include <stdio.h>

// Observe the startup blit in a separate run. Getting the concrete encoder
// class needs no submitted GPU work. The player creates its texture cache
// before the UI controls are drawn for the first time.
static IMP copyBuffer, fillBuffer, upload, uploadOptions;

static void showStack(void) {
  void *frames[15];
  int count = backtrace(frames, 15);
  backtrace_symbols_fd(frames, count, fileno(stderr));
}

static void copy(id encoder, SEL sel, id<MTLBuffer> src, NSUInteger srcOffset,
                 id<MTLBuffer> dst, NSUInteger dstOffset, NSUInteger size) {
  fprintf(stderr,
          "blit buffer-to-buffer bytes=%zu source_length=%zu "
          "destination_length=%zu destination_label=%s\n",
          size, src.length, dst.length, dst.label.UTF8String ?: "(none)");
  showStack();
  ((void (*)(id, SEL, id, NSUInteger, id, NSUInteger, NSUInteger))copyBuffer)(
      encoder, sel, src, srcOffset, dst, dstOffset, size);
}
static void fill(id encoder, SEL sel, id<MTLBuffer> dst, NSRange range,
                 uint8_t value) {
  fprintf(stderr, "blit fill-buffer bytes=%zu destination_length=%zu\n",
          range.length, dst.length);
  showStack();
  ((void (*)(id, SEL, id, NSRange, uint8_t))fillBuffer)(encoder, sel, dst,
                                                        range, value);
}
static void showUpload(MTLSize size, id<MTLTexture> dst) {
  fprintf(
      stderr,
      "blit buffer-to-texture size=%zux%zu destination=%zux%zu format=%lu\n",
      size.width, size.height, dst.width, dst.height,
      (unsigned long)dst.pixelFormat);
  showStack();
}
static void toTexture(id encoder, SEL sel, id src, NSUInteger offset,
                      NSUInteger row, NSUInteger image, MTLSize size,
                      id<MTLTexture> dst, NSUInteger slice, NSUInteger level,
                      MTLOrigin origin) {
  showUpload(size, dst);
  ((void (*)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id,
             NSUInteger, NSUInteger, MTLOrigin))upload)(
      encoder, sel, src, offset, row, image, size, dst, slice, level, origin);
}
static void toTextureOptions(id encoder, SEL sel, id src, NSUInteger offset,
                             NSUInteger row, NSUInteger image, MTLSize size,
                             id<MTLTexture> dst, NSUInteger slice,
                             NSUInteger level, MTLOrigin origin,
                             MTLBlitOption options) {
  showUpload(size, dst);
  ((void (*)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id,
             NSUInteger, NSUInteger, MTLOrigin, MTLBlitOption))uploadOptions)(
      encoder, sel, src, offset, row, image, size, dst, slice, level, origin,
      options);
}
static IMP observe(Class cls, SEL sel, IMP replacement) {
  Method method = class_getInstanceMethod(cls, sel);
  IMP original = method_getImplementation(method);
  class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
  return original;
}
static CVReturn observeCache(CFAllocatorRef allocator, CFDictionaryRef attrs,
                             id<MTLDevice> device, CFDictionaryRef texAttrs,
                             CVMetalTextureCacheRef *result) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
    Class cls = object_getClass(encoder);
    [encoder endEncoding];
    copyBuffer = observe(
        cls,
        @selector(copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:),
        (IMP)copy);
    fillBuffer = observe(cls, @selector(fillBuffer:range:value:), (IMP)fill);
    upload =
        observe(cls,
                @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:
                          sourceBytesPerImage:sourceSize:toTexture:
                          destinationSlice:destinationLevel:destinationOrigin:),
                (IMP)toTexture);
    uploadOptions = observe(
        cls,
        @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:
                  sourceBytesPerImage:sourceSize:toTexture:destinationSlice:
                  destinationLevel:destinationOrigin:options:),
        (IMP)toTextureOptions);
  });
  return CVMetalTextureCacheCreate(allocator, attrs, device, texAttrs, result);
}
__attribute__((used, section("__DATA,__interpose"))) static const struct {
  const void *replacement, *original;
} hook = {observeCache, CVMetalTextureCacheCreate};
