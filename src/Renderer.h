#pragma once

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "include/core/SkColorSpace.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/ports/SkCFObject.h"

#include <cstdint>

struct FrameEvidence {
  uint32_t sourceSurface;
  uint32_t drawableSurface;
  uint64_t yTexture;
  uint64_t uvTexture;
  uint64_t targetTexture;
};

class Renderer {
public:
  explicit Renderer(CAMetalLayer *layer);
  FrameEvidence draw(CVPixelBufferRef buffer, id<CAMetalDrawable> drawable);
  void drain();
  id<MTLCommandQueue> queue() const { return queue_; }

private:
  id<MTLCommandQueue> queue_;
  sk_sp<GrDirectContext> context_;
  sk_cfp<CVMetalTextureCacheRef> cache_;
  sk_sp<SkColorSpace> rec709_;
};
