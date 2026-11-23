#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <os/signpost.h>

#include "Renderer.h"
#include "include/core/SkColorSpace.h"
#include <cstdio>
#include <memory>
#include <stdexcept>

@interface Playback : NSObject
- (instancetype)initWithSource:(NSURL *)source
                        frames:(FILE *)frames
                       capture:(NSURL *)capture;
- (void)start;
@property(readonly) int result;
@end

@implementation Playback {
  std::unique_ptr<Renderer> _renderer;
  NSWindow *_window;
  CAMetalLayer *_layer;
  AVPlayer *_player;
  AVPlayerItemVideoOutput *_output;
  CADisplayLink *_link;
  FILE *_frames;
  NSURL *_capture;
  os_log_t _log;
  double _start;
  NSUInteger _count;
  bool _playing;
  bool _stopped;
  bool _captured;
  int _result;
}

- (instancetype)initWithSource:(NSURL *)source
                        frames:(FILE *)frames
                       capture:(NSURL *)capture {
  self = [super init];
  if (self) {
    _frames = frames;
    _capture = capture;
    _log = os_log_create("org.scoop.video.probe", "playback");
    _result = 1;
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 450)
                                          styleMask:NSWindowStyleMaskTitled
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"4K60 AVPlayer → Skia / NV12";
    [_window center];
    _layer = [CAMetalLayer layer];
    _layer.device = MTLCreateSystemDefaultDevice();
    if (!_layer.device)
      throw std::runtime_error("No Metal device");
    _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _layer.framebufferOnly = YES;
    _layer.opaque = YES;
    sk_cfp<CGColorSpaceRef> srgb(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    _layer.colorspace = srgb.get();
    _window.contentView.wantsLayer = YES;
    _window.contentView.layer = _layer;
    [_window orderFrontRegardless];
    _layer.drawableSize = CGSizeMake(3840, 2160);
    _renderer = std::make_unique<Renderer>(_layer);

    NSDictionary *settings = @{
      (NSString *)kCVPixelBufferPixelFormatTypeKey :
          @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES
    };
    _output = [[AVPlayerItemVideoOutput alloc] initWithOutputSettings:settings];
    _output.suppressesPlayerRendering = YES;
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:source];
    [item addOutput:_output];
    _player = [AVPlayer playerWithPlayerItem:item];
    _player.muted = YES;
    _player.automaticallyWaitsToMinimizeStalling = NO;
    fprintf(_frames, "pts_value,pts_scale,host_s,iosurface,drawable_iosurface,"
                     "y_gpu_id,uv_gpu_id,"
                     "drawable_gpu_id\n");
  }
  return self;
}

- (void)start {
  _start = CACurrentMediaTime();
  _link = [_window.contentView displayLinkWithTarget:self
                                            selector:@selector(tick:)];
  [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  // Also end a run if the display link stops issuing callbacks.
  [NSTimer
      scheduledTimerWithTimeInterval:25
                             repeats:NO
                               block:^(NSTimer *) {
                                 if (!self->_stopped)
                                   [self finish:NO
                                        message:"Playback watchdog expired"];
                               }];
}

- (void)finish:(BOOL)success message:(const char *)message {
  if (_stopped)
    return;
  _stopped = true;
  [_link invalidate];
  _link = nil;
  [_player pause];
  _renderer->drain();
  fprintf(stderr, "%s; frames=%lu elapsed=%.3f device=%s\n", message,
          (unsigned long)_count, CACurrentMediaTime() - _start,
          _layer.device.name.UTF8String);
  fflush(_frames);
  _result = success ? 0 : 1;
  [NSApp stop:nil];
  // Wake AppKit's event wait when stop: was called from a display-link
  // callback.
  [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                       subtype:0
                                         data1:0
                                         data2:0]
           atStart:NO];
}

- (void)tick:(CADisplayLink *)link {
  @autoreleasepool {
    try {
      if (_player.currentItem.status == AVPlayerItemStatusFailed) {
        [self finish:NO
             message:_player.currentItem.error.description.UTF8String];
        return;
      }
      if (!_playing) {
        if (_player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
          [_player playImmediatelyAtRate:1.0f];
          _playing = true;
        }
        return;
      }
      CMTime requested = [_output itemTimeForHostTime:link.targetTimestamp];
      if (!CMTIME_IS_NUMERIC(requested))
        return;
      if (CMTimeCompare(requested, CMTimeMake(9, 1)) >= 0) {
        [self finish:(_count > 0 && (!_capture || _captured))
             message:"Playback ended"];
        return;
      }
      if (![_output hasNewPixelBufferForItemTime:requested])
        return;
      CMTime pts = kCMTimeInvalid;
      sk_cfp<CVPixelBufferRef> frame([_output
          copyPixelBufferForItemTime:requested
                  itemTimeForDisplay:&pts]);
      if (!frame.get())
        return;
      if (!CMTIME_IS_NUMERIC(pts))
        throw std::runtime_error("Frame has no presentation time");

      const bool capture =
          _capture && !_captured && CMTimeCompare(pts, CMTimeMake(3, 1)) >= 0;
      if (capture) {
        MTLCaptureDescriptor *descriptor = [MTLCaptureDescriptor new];
        descriptor.captureObject = _renderer->queue();
        descriptor.destination = MTLCaptureDestinationGPUTraceDocument;
        descriptor.outputURL = _capture;
        NSError *error = nil;
        if (![MTLCaptureManager.sharedCaptureManager
                startCaptureWithDescriptor:descriptor
                                     error:&error]) {
          [self finish:NO message:error.localizedDescription.UTF8String];
          return;
        }
      }
      id<CAMetalDrawable> drawable = [_layer nextDrawable];
      if (!drawable)
        throw std::runtime_error("No drawable");
      const double host = CACurrentMediaTime();
      auto signpost = os_signpost_id_generate(_log);
      os_signpost_interval_begin(_log, signpost, "Draw NV12", "pts=%lld/%d",
                                 pts.value, pts.timescale);
      FrameEvidence e = _renderer->draw(frame.get(), drawable);
      os_signpost_interval_end(_log, signpost, "Draw NV12", "IOSurface=%u",
                               e.sourceSurface);
      fprintf(_frames, "%lld,%d,%.9f,%u,%u,%llu,%llu,%llu\n", pts.value,
              pts.timescale, host, e.sourceSurface, e.drawableSurface,
              e.yTexture, e.uvTexture, e.targetTexture);
      ++_count;
      if (capture) {
        [MTLCaptureManager.sharedCaptureManager stopCapture];
        _captured = true;
        fprintf(stderr, "GPU capture PTS=%lld/%d IOSurface=%u\n", pts.value,
                pts.timescale, e.sourceSurface);
      }
    } catch (const std::exception &error) {
      [self finish:NO message:error.what()];
    }
  }
}
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 3 && argc != 4) {
      fprintf(stderr, "Usage: %s source.mp4 frames.csv [frame.gputrace]\n",
              argv[0]);
      return 2;
    }
    std::unique_ptr<FILE, decltype(&fclose)> frames(fopen(argv[2], "wx"),
                                                    fclose);
    if (!frames) {
      perror(argv[2]);
      return 1;
    }
    try {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      NSURL *source = [NSURL fileURLWithPath:@(argv[1])];
      NSURL *capture = argc == 4 ? [NSURL fileURLWithPath:@(argv[3])] : nil;
      Playback *playback = [[Playback alloc] initWithSource:source
                                                     frames:frames.get()
                                                    capture:capture];
      [playback start];
      [NSApp run];
      return playback.result;
    } catch (const std::exception &error) {
      fprintf(stderr, "%s\n", error.what());
      return 1;
    }
  }
}
