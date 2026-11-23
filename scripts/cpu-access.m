#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
#include <dlfcn.h>
#include <execinfo.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdio.h>

// Loaded only for the separate CPU-access measurement. The system trace runs
// without this library.
static atomic_uint cvLock, cvBase, cvPlane, ioLock, ioBase, ioPlane;
static atomic_uint textureViews, getBytes, replaceRegion, otherTextureClass;
static atomic_uint vtTransfers;
static Class observedClass;
static NSMutableDictionary<NSData *, NSNumber *> *planeStacks;

// Some framework paths request a plane pointer without locking or copying
// pixels. Group actual return addresses so each distinct path can be examined
// separately.
static void recordPlaneStack(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (getenv("NV12_CPU_STACKS"))
      planeStacks = [NSMutableDictionary new];
  });
  if (!planeStacks)
    return;
  @autoreleasepool {
    void *frames[9];
    int count = backtrace(frames, 9);
    NSData *key = [NSData dataWithBytes:frames
                                 length:sizeof(frames[0]) * count];
    @synchronized(planeStacks) {
      planeStacks[key] = @([planeStacks[key] unsignedIntValue] + 1);
    }
  }
}

static bool videoSize(size_t w, size_t h) { return w >= 1920 && h >= 1080; }
static bool videoBuffer(CVPixelBufferRef b) {
  return videoSize(CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(b));
}
static bool videoSurface(IOSurfaceRef s) {
  return videoSize(IOSurfaceGetWidth(s), IOSurfaceGetHeight(s));
}

static CVReturn observeCVLock(CVPixelBufferRef b,
                              CVPixelBufferLockFlags flags) {
  if (videoBuffer(b))
    atomic_fetch_add(&cvLock, 1);
  return CVPixelBufferLockBaseAddress(b, flags);
}
static void *observeCVBase(CVPixelBufferRef b) {
  if (videoBuffer(b))
    atomic_fetch_add(&cvBase, 1);
  return CVPixelBufferGetBaseAddress(b);
}
static void *observeCVPlane(CVPixelBufferRef b, size_t plane) {
  if (videoBuffer(b))
    atomic_fetch_add(&cvPlane, 1);
  return CVPixelBufferGetBaseAddressOfPlane(b, plane);
}
static kern_return_t observeIOLock(IOSurfaceRef s, IOSurfaceLockOptions options,
                                   uint32_t *seed) {
  if (videoSurface(s))
    atomic_fetch_add(&ioLock, 1);
  return IOSurfaceLock(s, options, seed);
}
static void *observeIOBase(IOSurfaceRef s) {
  if (videoSurface(s)) {
    atomic_fetch_add(&ioBase, 1);
    if (getenv("NV12_CPU_STACKS")) {
      void *frames[10];
      int count = backtrace(frames, 10);
      fprintf(stderr, "whole-base surface=%u format=0x%08x\n",
              IOSurfaceGetID(s), IOSurfaceGetPixelFormat(s));
      backtrace_symbols_fd(frames, count, fileno(stderr));
    }
  }
  return IOSurfaceGetBaseAddress(s);
}
static void *observeIOPlane(IOSurfaceRef s, size_t plane) {
  if (videoSurface(s)) {
    atomic_fetch_add(&ioPlane, 1);
    recordPlaneStack();
  }
  return IOSurfaceGetBaseAddressOfPlane(s, plane);
}

static CVReturn observeWrap(CFAllocatorRef allocator, IOSurfaceRef surface,
                            CFDictionaryRef attrs, CVPixelBufferRef *buffer) {
  CVReturn result =
      CVPixelBufferCreateWithIOSurface(allocator, surface, attrs, buffer);
  if (result == kCVReturnSuccess && videoSurface(surface)) {
    Dl_info caller = {0};
    dladdr(__builtin_return_address(0), &caller);
    fprintf(stderr, "wrap surface=%u format=0x%08x caller=%s\n",
            IOSurfaceGetID(surface), CVPixelBufferGetPixelFormatType(*buffer),
            caller.dli_sname ? caller.dli_sname : "unknown");
  }
  return result;
}

static OSStatus observeTransfer(VTPixelTransferSessionRef session,
                                CVPixelBufferRef source,
                                CVPixelBufferRef dest) {
  if (videoBuffer(source) || videoBuffer(dest))
    atomic_fetch_add(&vtTransfers, 1);
  return VTPixelTransferSessionTransferImage(session, source, dest);
}

// Override the CPU pixel operations on the actual input texture class,
// including inherited methods.
static IMP get2D, getSlice, put2D, putSlice;
static IMP observeMethod(Class cls, SEL sel, IMP hook) {
  Method method = class_getInstanceMethod(cls, sel);
  IMP original = method_getImplementation(method);
  class_replaceMethod(cls, sel, hook, method_getTypeEncoding(method));
  return original;
}
static void observeGet2D(id<MTLTexture> t, SEL s, void *p, NSUInteger row,
                         MTLRegion r, NSUInteger level) {
  if (videoSize(t.width, t.height))
    atomic_fetch_add(&getBytes, 1);
  ((void (*)(id, SEL, void *, NSUInteger, MTLRegion, NSUInteger))get2D)(
      t, s, p, row, r, level);
}
static void observeGetSlice(id<MTLTexture> t, SEL s, void *p, NSUInteger row,
                            NSUInteger image, MTLRegion r, NSUInteger level,
                            NSUInteger slice) {
  if (videoSize(t.width, t.height))
    atomic_fetch_add(&getBytes, 1);
  ((void (*)(id, SEL, void *, NSUInteger, NSUInteger, MTLRegion, NSUInteger,
             NSUInteger))getSlice)(t, s, p, row, image, r, level, slice);
}
static void observePut2D(id<MTLTexture> t, SEL s, MTLRegion r, NSUInteger level,
                         const void *p, NSUInteger row) {
  if (videoSize(t.width, t.height))
    atomic_fetch_add(&replaceRegion, 1);
  ((void (*)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger))put2D)(
      t, s, r, level, p, row);
}
static void observePutSlice(id<MTLTexture> t, SEL s, MTLRegion r,
                            NSUInteger level, NSUInteger slice, const void *p,
                            NSUInteger row, NSUInteger image) {
  if (videoSize(t.width, t.height))
    atomic_fetch_add(&replaceRegion, 1);
  ((void (*)(id, SEL, MTLRegion, NSUInteger, NSUInteger, const void *,
             NSUInteger, NSUInteger))putSlice)(t, s, r, level, slice, p, row,
                                               image);
}
static id<MTLTexture> observeView(CVMetalTextureRef view) {
  id<MTLTexture> texture = CVMetalTextureGetTexture(view);
  if (!texture || !videoSize(texture.width, texture.height))
    return texture;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    observedClass = object_getClass(texture);
    get2D = observeMethod(
        observedClass, @selector(getBytes:bytesPerRow:fromRegion:mipmapLevel:),
        (IMP)observeGet2D);
    getSlice = observeMethod(
        observedClass,
        @selector(
            getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:),
        (IMP)observeGetSlice);
    put2D = observeMethod(
        observedClass,
        @selector(replaceRegion:mipmapLevel:withBytes:bytesPerRow:),
        (IMP)observePut2D);
    putSlice = observeMethod(observedClass,
                             @selector(replaceRegion:mipmapLevel:slice:
                                       withBytes:bytesPerRow:bytesPerImage:),
                             (IMP)observePutSlice);
  });
  atomic_fetch_add(&textureViews, 1);
  if (object_getClass(texture) != observedClass)
    atomic_fetch_add(&otherTextureClass, 1);
  return texture;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
  const void *replacement, *original;
} hooks[] = {{observeCVLock, CVPixelBufferLockBaseAddress},
             {observeCVBase, CVPixelBufferGetBaseAddress},
             {observeCVPlane, CVPixelBufferGetBaseAddressOfPlane},
             {observeIOLock, IOSurfaceLock},
             {observeIOBase, IOSurfaceGetBaseAddress},
             {observeIOPlane, IOSurfaceGetBaseAddressOfPlane},
             {observeWrap, CVPixelBufferCreateWithIOSurface},
             {observeTransfer, VTPixelTransferSessionTransferImage},
             {observeView, CVMetalTextureGetTexture}};

__attribute__((destructor)) static void report(void) {
  @autoreleasepool {
    @synchronized(planeStacks) {
      for (NSData *key in planeStacks) {
        fprintf(stderr, "IOSurfaceGetBaseAddressOfPlane stack count=%u\n",
                [planeStacks[key] unsignedIntValue]);
        backtrace_symbols_fd((void *const *)key.bytes,
                             (int)(key.length / sizeof(void *)),
                             fileno(stderr));
      }
    }
  }
  fprintf(stderr,
          "cpu_access views=%u other_texture_class=%u cv_lock=%u cv_base=%u "
          "cv_plane_base=%u "
          "io_lock=%u io_base=%u io_plane_base=%u metal_get_bytes=%u "
          "metal_replace_region=%u vt_transfer=%u\n",
          atomic_load(&textureViews), atomic_load(&otherTextureClass),
          atomic_load(&cvLock), atomic_load(&cvBase), atomic_load(&cvPlane),
          atomic_load(&ioLock), atomic_load(&ioBase), atomic_load(&ioPlane),
          atomic_load(&getBytes), atomic_load(&replaceRegion),
          atomic_load(&vtTransfers));
}
