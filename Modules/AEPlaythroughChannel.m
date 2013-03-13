//
//  AEPlaythroughChannel.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEPlaythroughChannel.h"
#import "TPCircularBuffer.h"
#import "TPCircularBuffer+AudioBufferList.h"

static const int kAudioBufferLength = 16384;

@interface AEPlaythroughChannel () {
    TPCircularBuffer _buffer;
    UInt32           _bufferMaxLatencyInFrames;
}
@property (nonatomic, retain) AEAudioController *audioController;
@end

@implementation AEPlaythroughChannel
@synthesize audioController=_audioController, volume = _volume;

+(NSSet *)keyPathsForValuesAffectingAudioDescription {
    return [NSSet setWithObject:@"audioController.inputAudioDescription"];
}

- (id)initWithAudioController:(AEAudioController*)audioController {
    if ( !(self = [super init]) ) return nil;
    TPCircularBufferInit(&_buffer, kAudioBufferLength);
    self.audioController = audioController;
    _volume = 1.0;
    _bufferMaxLatencyInFrames = AEConvertSecondsToFrames(audioController, audioController.preferredBufferDuration);
    return self;
}

- (void)dealloc {
    TPCircularBufferCleanup(&_buffer);
    self.audioController = nil;
    [super dealloc];
}

static void inputCallback(id                        receiver,
                          AEAudioController        *audioController,
                          void                     *source,
                          const AudioTimeStamp     *time,
                          UInt32                    frames,
                          AudioBufferList          *audio) {
    AEPlaythroughChannel *THIS = receiver;
    
    TPCircularBufferCopyAudioBufferList(&THIS->_buffer, audio, time, kTPCircularBufferCopyAll, NULL);
}

-(AEAudioControllerAudioCallback)receiverCallback {
    return inputCallback;
}

static OSStatus renderCallback(id                        channel,
                               AEAudioController        *audioController,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    AEPlaythroughChannel *THIS = channel;
    
    UInt32 fillCount = TPCircularBufferPeek(&THIS->_buffer, NULL, AEAudioControllerAudioDescription(audioController));
    if ( fillCount >= frames+THIS->_bufferMaxLatencyInFrames ) {
        UInt32 skip = fillCount - frames;
        TPCircularBufferDequeueBufferListFrames(&THIS->_buffer, &skip, NULL, NULL, AEAudioControllerAudioDescription(audioController));
    }
    
    TPCircularBufferDequeueBufferListFrames(&THIS->_buffer, &frames, audio, NULL, AEAudioControllerAudioDescription(audioController));
    return noErr;
}

-(AEAudioControllerRenderCallback)renderCallback {
    return renderCallback;
}

-(AudioStreamBasicDescription)audioDescription {
    return _audioController.inputAudioDescription;
}

@end


