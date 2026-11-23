#import "planes.h"
#import <AVFoundation/AVFoundation.h>

// The Instruments executable attaches a recorder to its next player on the UI
// thread.
@protocol SVRecording <NSObject>
- (void)attach:(AVPlayer *)player queue:(id<MTLCommandQueue>)queue;
- (NSString *)sample:(SVFrame *)frame;
- (void)complete:(SVFrame *)frame
        hostTime:(CFTimeInterval)time
        accepted:(BOOL)accepted
         playing:(BOOL)playing
       newSample:(BOOL)newSample;
- (void)close;
@end
void sv_record_next_player(id<SVRecording> recording);
