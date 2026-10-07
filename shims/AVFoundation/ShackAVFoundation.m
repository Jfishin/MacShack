// The two macOS-only capture presets Unity's webcam code references. Re-exports AVFoundation (and through it
// AVFAudio, which has the AVFormatIDKey/AVLinearPCM* settings keys on iOS).
#import <Foundation/Foundation.h>
NSString *const AVCaptureSessionPreset320x240 = @"AVCaptureSessionPreset320x240";
NSString *const AVCaptureSessionPreset960x540 = @"AVCaptureSessionPreset960x540";
