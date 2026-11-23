#import "Renderer.h"
#import <IOSurface/IOSurface.h>

#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkImage.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrYUVABackendTextures.h"
#include "include/gpu/ganesh/SkImageGanesh.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendSurface.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"

#include <memory>
#include <stdexcept>

namespace {
struct FrameOwner {
  sk_cfp<CVPixelBufferRef> buffer;
  sk_cfp<CVMetalTextureRef> planes[2];
};

GrMtlTextureInfo textureInfo(id<MTLTexture> texture) {
  GrMtlTextureInfo info;
  info.fTexture = sk_ret_cfp((__bridge const void *)texture);
  return info;
}

bool attachmentIs(CVPixelBufferRef buffer, CFStringRef key,
                  CFStringRef expected) {
  sk_cfp<CFTypeRef> value(CVBufferCopyAttachment(buffer, key, nullptr));
  return value.get() && CFEqual(value.get(), expected);
}
} // namespace

Renderer::Renderer(CAMetalLayer *layer) {
  id<MTLDevice> device = layer.device;
  queue_ = [device newCommandQueue];
  queue_.label = @"NV12 probe / Skia and present";
  GrMtlBackendContext backend;
  backend.fDevice = sk_ret_cfp((__bridge const void *)device);
  backend.fQueue = sk_ret_cfp((__bridge const void *)queue_);
  context_ = GrDirectContexts::MakeMetal(backend);
  CVMetalTextureCacheRef cache = nullptr;
  CVReturn status =
      CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &cache);
  cache_.reset(cache);
  if (!context_ || status != kCVReturnSuccess)
    throw std::runtime_error(
        "Could not create the Ganesh context or Core Video texture cache");
  rec709_ = SkColorSpace::MakeCICP(SkNamedPrimaries::CicpId::kRec709,
                                   SkNamedTransferFn::CicpId::kRec709);
}

FrameEvidence Renderer::draw(CVPixelBufferRef buffer,
                             id<CAMetalDrawable> drawable) {
  IOSurfaceRef source = CVPixelBufferGetIOSurface(buffer);
  if (!source ||
      CVPixelBufferGetPixelFormatType(buffer) !=
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      CVPixelBufferGetPlaneCount(buffer) != 2 ||
      CVPixelBufferGetWidth(buffer) != 3840 ||
      CVPixelBufferGetHeight(buffer) != 2160)
    throw std::runtime_error(
        "Expected an IOSurface-backed 3840x2160 video-range NV12 frame");
  if (!attachmentIs(buffer, kCVImageBufferYCbCrMatrixKey,
                    kCVImageBufferYCbCrMatrix_ITU_R_709_2) ||
      !attachmentIs(buffer, kCVImageBufferColorPrimariesKey,
                    kCVImageBufferColorPrimaries_ITU_R_709_2) ||
      !attachmentIs(buffer, kCVImageBufferTransferFunctionKey,
                    kCVImageBufferTransferFunction_ITU_R_709_2))
    throw std::runtime_error(
        "Expected the Rec.709 matrix, primaries and transfer function");

  auto owner = std::make_unique<FrameOwner>();
  owner->buffer.retain(buffer);
  GrBackendTexture planes[SkYUVAInfo::kMaxPlanes];
  uint64_t textureIDs[2];
  const MTLPixelFormat formats[] = {MTLPixelFormatR8Unorm,
                                    MTLPixelFormatRG8Unorm};
  for (size_t p = 0; p < 2; ++p) {
    size_t w = CVPixelBufferGetWidthOfPlane(buffer, p);
    size_t h = CVPixelBufferGetHeightOfPlane(buffer, p);
    CVMetalTextureRef view = nullptr;
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(
        nullptr, cache_.get(), buffer, nullptr, formats[p], w, h, p, &view);
    owner->planes[p].reset(view);
    if (status != kCVReturnSuccess || !view)
      throw std::runtime_error("CVMetalTextureCache could not map the plane");
    id<MTLTexture> texture = CVMetalTextureGetTexture(view);
    if (!texture || texture.device != queue_.device ||
        texture.iosurface != source || texture.iosurfacePlane != p ||
        texture.pixelFormat != formats[p] || texture.width != w ||
        texture.height != h || w != (3840u >> p) || h != (2160u >> p))
      throw std::runtime_error(
          "Metal plane is not a matching view of the original IOSurface");
    texture.label = p == 0 ? @"AVPlayer Y / plane 0" : @"AVPlayer UV / plane 1";
    textureIDs[p] = texture.gpuResourceID._impl;
    planes[p] = GrBackendTextures::MakeMtl(
        (int)w, (int)h, skgpu::Mipmapped::kNo, textureInfo(texture));
  }
  SkYUVAInfo info({3840, 2160}, SkYUVAInfo::PlaneConfig::kY_UV,
                  SkYUVAInfo::Subsampling::k420,
                  kRec709_Limited_SkYUVColorSpace);
  GrYUVABackendTextures textures(info, planes, kTopLeft_GrSurfaceOrigin);
  auto image = SkImages::TextureFromYUVATextures(
      context_.get(), textures, rec709_,
      [](void *p) { delete static_cast<FrameOwner *>(p); }, owner.release());
  if (!image)
    throw std::runtime_error("Ganesh failed to borrow the two video planes");

  id<MTLTexture> target = drawable.texture;
  if (target.width != 3840 || target.height != 2160 ||
      target.pixelFormat != MTLPixelFormatBGRA8Unorm)
    throw std::runtime_error("Expected a 3840x2160 BGRA8 drawable");
  target.label = @"Final BGRA / CAMetalLayer drawable";
  auto backend =
      GrBackendRenderTargets::MakeMtl(3840, 2160, textureInfo(target));
  auto surface = SkSurfaces::WrapBackendRenderTarget(
      context_.get(), backend, kTopLeft_GrSurfaceOrigin, kBGRA_8888_SkColorType,
      SkColorSpace::MakeSRGB(), nullptr);
  if (!surface)
    throw std::runtime_error("Ganesh rejected the drawable");
  surface->getCanvas()->drawImage(
      image, 0, 0, SkSamplingOptions(SkFilterMode::kLinear), nullptr);
  if (!context_->flushAndSubmit(GrSyncCpu::kNo).fSuccess)
    throw std::runtime_error("Ganesh failed to submit");
  id<MTLCommandBuffer> present = [queue_ commandBuffer];
  if (!present)
    throw std::runtime_error(
        "Could not create the presentation command buffer");
  present.label = @"Present only";
  [present presentDrawable:drawable];
  [present commit];
  return {IOSurfaceGetID(source),
          target.iosurface ? IOSurfaceGetID(target.iosurface) : 0,
          textureIDs[0], textureIDs[1], target.gpuResourceID._impl};
}

void Renderer::drain() {
  if (!context_->flushAndSubmit(GrSyncCpu::kYes).fSuccess)
    throw std::runtime_error("Ganesh drain failed");
}
