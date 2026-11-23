#import "recording.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

typedef int32_t (*SVNotify)(void *);
static char itemStatusKey;
static id<SVRecording> nextRecording;
void sv_record_next_player(id<SVRecording> recording) {
  nextRecording = recording;
}

@interface SVPlayer : NSObject <AVPlayerItemOutputPullDelegate> {
@public
  AVPlayer *av;
  AVPlayerItemVideoOutput *output;
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  CVMetalTextureCacheRef cache;
  SVFrame *frame;
  id<SVRecording> recording;
  BOOL playing, ended, newSample;
  NSString *error;
  CFTimeInterval began;
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
- (void)outputMediaDataWillChange:(AVPlayerItemOutput *)sender {
  (void)sender;
  [self wake];
}
- (void)tick {
  if (ended || !playing)
    return;
  CMTime t = [output itemTimeForHostTime:CACurrentMediaTime()];
  if (!CMTIME_IS_NUMERIC(t))
    return;
  if ([output hasNewPixelBufferForItemTime:t]) {
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
  [output setDelegate:self queue:dispatch_get_main_queue()];
  [output requestNotificationOfMediaDataChangeWithAdvanceInterval:0.0];
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
  if (playing)
    [av playImmediatelyAtRate:1];
}
- (void)close {
  _notify = NULL;
  [output setDelegate:nil queue:NULL];
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
  [recording close];
  if (cache)
    CFRelease(cache);
}
@end

void *sv_open(void *dev, void *cmd, const char *path, bool playing,
              SVNotify notify, void *context) {
  @autoreleasepool {
    NSURL *url = [NSURL fileURLWithFileSystemRepresentation:path
                                                isDirectory:NO
                                              relativeToURL:nil];
    SVPlayer *p = [SVPlayer new];
    p->device = (__bridge id<MTLDevice>)dev;
    p->queue = (__bridge id<MTLCommandQueue>)cmd;
    if (CVMetalTextureCacheCreate(NULL, NULL, p->device, NULL, &p->cache) !=
        kCVReturnSuccess)
      return NULL;
    p->output = [[AVPlayerItemVideoOutput alloc] initWithOutputSettings:@{
      (id)kCVPixelBufferPixelFormatTypeKey :
          @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES
    }];
    p->output.suppressesPlayerRendering = YES;
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    [item addOutput:p->output];
    p->av = [AVPlayer playerWithPlayerItem:item];
    p->playing = playing;
    p->recording = nextRecording;
    nextRecording = nil;
    [p->recording attach:p->av queue:p->queue];
    p->av.automaticallyWaitsToMinimizeStalling = NO;
    [p start:notify context:context];
    return (__bridge_retained void *)p;
  }
}

void sv_close(void *ref) {
  SVPlayer *p = (__bridge_transfer SVPlayer *)ref;
  [p close];
}

void sv_set_playing(void *ref, bool playing) {
  SVPlayer *p = (__bridge SVPlayer *)ref;
  if (p->error || playing == p->playing)
    return;
  if (p->ended) {
    p->ended = NO;
    [p->av seekToTime:kCMTimeZero
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero];
  }
  p->playing = playing;
  if (p->playing)
    [p->av playImmediatelyAtRate:1];
  else
    [p->av pause];
  [p wake];
}

int32_t sv_state(void *ref) {
  SVPlayer *p = (__bridge SVPlayer *)ref;
  if (p->error)
    return -1;
  return p->ended ? 2 : p->playing ? 1 : 0;
}

const char *sv_error(void *ref) {
  return ((__bridge SVPlayer *)ref)->error.UTF8String;
}

double sv_progress(void *ref) {
  SVPlayer *p = (__bridge SVPlayer *)ref;
  double duration = CMTimeGetSeconds(p->av.currentItem.duration);
  if (p->ended && !p->error)
    return 1;
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
  if (p->error)
    return -1;
  if (p->ended)
    return 0;
  CMTime t = [p->output itemTimeForHostTime:p->began];
  if (!CMTIME_IS_NUMERIC(t) || ![p->output hasNewPixelBufferForItemTime:t])
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
    [p->av pause];
    return -1;
  }
  next.pts = pts;
  p->frame = next;
  p->newSample = YES;
  p->error = [p->recording sample:next];
  if (p->error) {
    [p->av pause];
    return -1;
  }
  return 1;
}

SVPlanes sv_planes(void *ref) {
  SVFrame *frame = ((__bridge SVPlayer *)ref)->frame;
  return frame ? frame.planes : (SVPlanes){0};
}

void sv_complete(void *ref, bool accepted) {
  SVPlayer *p = (__bridge SVPlayer *)ref;
  [p->recording complete:p->frame
                hostTime:p->began
                accepted:accepted
                 playing:p->playing
               newSample:p->newSample];
}
