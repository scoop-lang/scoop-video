#import "planes.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <os/signpost.h>

typedef int32_t (*SVNotify)(void *);
static char itemStatusKey;

@interface SVPlayer : NSObject {
@public
  AVPlayer *av;
  AVPlayerItemVideoOutput *output;
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  CVMetalTextureCacheRef cache;
  SVFrame *frame;
  FILE *csv;
  NSURL *captureURL;
  BOOL playing, ended, capturing, captured, newSample;
  NSString *error;
  CFTimeInterval began;
  os_log_t log;
  os_signpost_id_t signpost;
}
- (void)start:(SVNotify)notify context:(void *)context;
- (void)close;
@end

@implementation SVPlayer {
  id _periodic, _end, _failure;
  BOOL _observingStatus;
  SVNotify _notify;
  void *_context;
}
- (void)wake {
  if (_notify)
    _notify(_context);
}
- (void)finish {
  ended = YES;
  playing = NO;
  [av pause];
  [self wake];
}
- (void)tick {
  if (ended || !playing)
    return;
  CMTime t = [output itemTimeForHostTime:CACurrentMediaTime()];
  if (!CMTIME_IS_NUMERIC(t))
    return;
  if (csv && CMTimeCompare(t, CMTimeMake(9, 1)) >= 0) {
    [self finish];
  } else if ([output hasNewPixelBufferForItemTime:t]) {
    [self wake];
  }
}
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (context != &itemStatusKey) {
    [super observeValueForKeyPath:keyPath
                         ofObject:object
                           change:change
                          context:context];
    return;
  }
  AVPlayerItem *item = object;
  if (item.status == AVPlayerItemStatusFailed) {
    NSString *message =
        item.error.localizedDescription ?: @"Could not open the video";
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_notify) {
        self->error = message;
        [self finish];
      }
    });
  }
}
- (void)start:(SVNotify)notify context:(void *)context {
  _notify = notify;
  _context = context;
  [av.currentItem addObserver:self
                   forKeyPath:@"status"
                      options:NSKeyValueObservingOptionInitial |
                              NSKeyValueObservingOptionNew
                      context:&itemStatusKey];
  _observingStatus = YES;
  __weak SVPlayer *weak = self;
  _periodic = [av addPeriodicTimeObserverForInterval:CMTimeMake(1, 60)
                                               queue:dispatch_get_main_queue()
                                          usingBlock:^(CMTime time) {
                                            (void)time;
                                            [weak tick];
                                          }];
  _end = [NSNotificationCenter.defaultCenter
      addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                  object:av.currentItem
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *note) {
                (void)note;
                [weak finish];
              }];
  _failure = [NSNotificationCenter.defaultCenter
      addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                  object:av.currentItem
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *note) {
                SVPlayer *p = weak;
                if (p) {
                  p->error =
                      [note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                          localizedDescription]
                          ?: @"Playback failed";
                  [p finish];
                }
              }];
  [av playImmediatelyAtRate:1];
  playing = YES;
}
- (void)close {
  _notify = NULL;
  if (_observingStatus)
    [av.currentItem removeObserver:self
                        forKeyPath:@"status"
                           context:&itemStatusKey];
  [av pause];
  if (_periodic)
    [av removeTimeObserver:_periodic];
  if (_end)
    [NSNotificationCenter.defaultCenter removeObserver:_end];
  if (_failure)
    [NSNotificationCenter.defaultCenter removeObserver:_failure];
  if (capturing)
    [MTLCaptureManager.sharedCaptureManager stopCapture];
  if (csv)
    fclose(csv);
  if (cache)
    CFRelease(cache);
}
@end

void *sv_open(void *dev, void *cmd, SVNotify notify, void *context) {
  @autoreleasepool {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSString *path = args.count > 1 ? args[1] : @"artifacts/source-4k60.mp4";
    if (![NSFileManager.defaultManager isReadableFileAtPath:path] ||
        args.count > 4) {
      fprintf(
          stderr,
          "Usage: scoop-video-ui [video.mp4 [frames.csv [frame.gputrace]]]\n");
      return NULL;
    }
    SVPlayer *p = [SVPlayer new];
    p->device = (__bridge id<MTLDevice>)dev;
    p->queue = (__bridge id<MTLCommandQueue>)cmd;
    if (CVMetalTextureCacheCreate(NULL, NULL, p->device, NULL, &p->cache) !=
        kCVReturnSuccess)
      return NULL;
    if (args.count > 2) {
      p->csv = fopen(args[2].fileSystemRepresentation, "wx");
      if (!p->csv) {
        perror(args[2].fileSystemRepresentation);
        [p close];
        return NULL;
      }
      fprintf(p->csv, "pts_value,pts_scale,host_s,iosurface,y_gpu_id,uv_gpu_id,"
                      "accepted,playing,new_sample\n");
    }
    if (args.count > 3)
      p->captureURL = [NSURL fileURLWithPath:args[3]];
    p->log = os_log_create("org.scoop.video.ui", "playback");
    p->output = [[AVPlayerItemVideoOutput alloc] initWithOutputSettings:@{
      (id)kCVPixelBufferPixelFormatTypeKey :
          @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES
    }];
    p->output.suppressesPlayerRendering = YES;
    AVPlayerItem *item =
        [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    [item addOutput:p->output];
    p->av = [AVPlayer playerWithPlayerItem:item];
    p->av.muted = p->csv != NULL;
    p->av.automaticallyWaitsToMinimizeStalling = NO;
    [p start:notify context:context];
    return (__bridge_retained void *)p;
  }
}

void sv_close(void *ref) {
  SVPlayer *p = (__bridge_transfer SVPlayer *)ref;
  [p close];
}

void sv_toggle(void *ref) {
  SVPlayer *p = (__bridge SVPlayer *)ref;
  if (p->ended) {
    p->ended = NO;
    [p->av seekToTime:kCMTimeZero
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero];
  }
  p->playing = !p->playing;
  if (p->playing)
    [p->av playImmediatelyAtRate:1];
  else
    [p->av pause];
  [p wake];
}

int32_t sv_state(void *ref) {
  SVPlayer *p = (__bridge SVPlayer *)ref;
  if (p->error) {
    fprintf(stderr, "AVPlayer: %s\n", p->error.UTF8String);
    return -1;
  }
  return p->ended ? 2 : p->playing ? 1 : 0;
}

double sv_progress(void *ref) {
  SVPlayer *p = (__bridge SVPlayer *)ref;
  double duration = CMTimeGetSeconds(p->av.currentItem.duration);
  return duration > 0 && p->frame
             ? fmin(1, fmax(0, CMTimeGetSeconds(p->frame.pts) / duration))
             : 0;
}

// Returns a new pair only when the media clock advances. The player owns it
// until replacement; each imported Image independently retains the same owner.
int32_t sv_begin(void *ref) {
  SVPlayer *p = (__bridge SVPlayer *)ref;
  p->began = CACurrentMediaTime();
  p->newSample = NO;
  p->signpost = os_signpost_id_generate(p->log);
  os_signpost_interval_begin(p->log, p->signpost, "Scoop UI video");
  CMTime t = [p->output itemTimeForHostTime:p->began];
  if (!CMTIME_IS_NUMERIC(t) ||
      (p->csv && CMTimeCompare(t, CMTimeMake(9, 1)) >= 0) ||
      ![p->output hasNewPixelBufferForItemTime:t])
    return 0;
  CMTime pts = kCMTimeInvalid;
  CVPixelBufferRef b = [p->output copyPixelBufferForItemTime:t
                                          itemTimeForDisplay:&pts];
  if (!b)
    return 0;
  SVFrame *next = [[SVFrame alloc] initWithBuffer:b
                                            cache:p->cache
                                           device:p->device];
  CVPixelBufferRelease(b);
  if (!next || !CMTIME_IS_NUMERIC(pts)) {
    p->error = @"Expected progressive BT.709 video-range NV12 and two views of "
               @"its IOSurface";
    return -1;
  }
  next.pts = pts;
  p->frame = next;
  p->newSample = YES;
  if (p->captureURL && !p->captured &&
      CMTimeCompare(pts, CMTimeMake(3, 1)) >= 0) {
    MTLCaptureDescriptor *d = [MTLCaptureDescriptor new];
    d.captureObject = p->queue;
    d.destination = MTLCaptureDestinationGPUTraceDocument;
    d.outputURL = p->captureURL;
    NSError *e = nil;
    if (![MTLCaptureManager.sharedCaptureManager
            startCaptureWithDescriptor:d
                                 error:&e]) {
      p->error = e.localizedDescription;
      return -1;
    }
    p->capturing = YES;
  }
  return 1;
}

SVPlanes sv_planes(void *ref) {
  return ((__bridge SVPlayer *)ref)->frame.planes;
}

void sv_complete(void *ref, bool accepted) {
  SVPlayer *p = (__bridge SVPlayer *)ref;
  SVFrame *f = p->frame;
  if (p->csv) {
    fprintf(p->csv, "%lld,%d,%.9f,%u,%llu,%llu,%d,%d,%d\n",
            f ? f.pts.value : -1, f ? f.pts.timescale : 1, p->began,
            f.surfaceID, f.yID, f.uvID, accepted, p->playing, p->newSample);
  }
  os_signpost_interval_end(p->log, p->signpost, "Scoop UI video",
                           "IOSurface=%u accepted=%d", f.surfaceID, accepted);
  if (p->capturing) {
    [MTLCaptureManager.sharedCaptureManager stopCapture];
    p->capturing = NO;
    p->captured = YES;
    fprintf(stderr, "UI capture PTS=%lld/%d IOSurface=%u\n", f.pts.value,
            f.pts.timescale, f.surfaceID);
  }
}
