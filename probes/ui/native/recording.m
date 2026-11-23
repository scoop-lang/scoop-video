#import "../../../scoop.ui.video/native/recording.h"

@interface SVProbeRecording : NSObject <SVRecording>
- (instancetype)initWithCSV:(NSString *)path capture:(NSString *)capture;
@end

@implementation SVProbeRecording {
  FILE *_csv;
  NSURL *_capture;
  id<MTLCommandQueue> _queue;
  BOOL _capturing;
}
- (instancetype)initWithCSV:(NSString *)path capture:(NSString *)capture {
  self = [super init];
  if (!self)
    return nil;
  _csv = fopen(path.fileSystemRepresentation, "wx");
  if (!_csv) {
    perror(path.fileSystemRepresentation);
    return nil;
  }
  fprintf(_csv, "pts_value,pts_scale,host_s,iosurface,y_gpu_id,uv_gpu_id,"
                "accepted,playing,new_sample\n");
  if (capture)
    _capture = [NSURL fileURLWithPath:capture];
  return self;
}
- (void)attach:(AVPlayer *)player queue:(id<MTLCommandQueue>)queue {
  player.muted = YES;
  player.currentItem.forwardPlaybackEndTime = CMTimeMake(9, 1);
  _queue = queue;
}
- (NSString *)sample:(SVFrame *)frame {
  if (!_capture || CMTimeCompare(frame.pts, CMTimeMake(3, 1)) < 0)
    return nil;
  MTLCaptureDescriptor *d = [MTLCaptureDescriptor new];
  d.captureObject = _queue;
  d.destination = MTLCaptureDestinationGPUTraceDocument;
  d.outputURL = _capture;
  _capture = nil;
  NSError *error = nil;
  _capturing = [MTLCaptureManager.sharedCaptureManager
      startCaptureWithDescriptor:d
                           error:&error];
  return _capturing ? nil
                    : (error.localizedDescription ?: @"Metal capture failed");
}
- (void)complete:(SVFrame *)f
        hostTime:(CFTimeInterval)time
        accepted:(BOOL)accepted
         playing:(BOOL)playing
       newSample:(BOOL)newSample {
  fprintf(_csv, "%lld,%d,%.9f,%u,%llu,%llu,%d,%d,%d\n", f ? f.pts.value : -1,
          f ? f.pts.timescale : 1, time, f.surfaceID, f.yID, f.uvID, accepted,
          playing, newSample);
  if (_capturing) {
    [MTLCaptureManager.sharedCaptureManager stopCapture];
    _capturing = NO;
    fprintf(stderr, "UI capture PTS=%lld/%d IOSurface=%u\n", f.pts.value,
            f.pts.timescale, f.surfaceID);
  }
}
- (void)close {
  if (_capturing)
    [MTLCaptureManager.sharedCaptureManager stopCapture];
  _capturing = NO;
  if (_csv)
    fclose(_csv);
  _csv = NULL;
}
- (void)dealloc {
  [self close];
}
@end

bool sv_enable_ui_recording(void) {
  NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
  SVProbeRecording *recording =
      [[SVProbeRecording alloc] initWithCSV:args[2]
                                    capture:args.count == 4 ? args[3] : nil];
  if (!recording)
    return false;
  sv_record_next_player(recording);
  return true;
}
