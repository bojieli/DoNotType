#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <stdio.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: record OUTPUT.wav SECONDS\n");
            return 2;
        }
        int seconds = [[NSString stringWithUTF8String:argv[2]] intValue];
        if (seconds < 1 || seconds > 120) {
            fprintf(stderr, "Recording duration must be between 1 and 120 seconds.\n");
            return 2;
        }
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusNotDetermined) {
            dispatch_semaphore_t answer = dispatch_semaphore_create(0);
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_semaphore_signal(answer);
            }];
            if (dispatch_semaphore_wait(answer, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC))) {
                fprintf(stderr, "Timed out waiting for microphone permission.\n");
                return 1;
            }
        }
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
            fprintf(stderr, "Allow microphone access for your terminal in System Preferences > Security & Privacy > Microphone.\n");
            return 1;
        }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @16000,
            AVNumberOfChannelsKey: @1, AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO
        };
        NSError *error = nil;
        AVAudioRecorder *recorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&error];
        if (![recorder record]) {
            fprintf(stderr, "Could not start the default microphone: %s\n",
                    error ? error.localizedDescription.UTF8String : "check the selected sound input");
            return 1;
        }
        fprintf(stderr, "Microphone active for %d seconds.\n", seconds);
        [NSThread sleepForTimeInterval:seconds];
        BOOL finished = recorder.isRecording;
        [recorder stop];
        if (!finished) {
            fprintf(stderr, "Microphone recording was interrupted.\n");
            return 1;
        }
        return 0;
    }
}
