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
}
@property (nonatomic, retain) AEAudioController *audioController;
@end

@implementation AEPlaythroughChannel
@synthesize audioController=_audioController;

- (id)initWithAudioController:(AEAudioController*)audioController {
    if ( !(self = [super init]) ) return nil;
    TPCircularBufferInit(&_buffer, kAudioBufferLength);
    self.audioController = audioController;
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
    
    TPCircularBufferCopyAudioBufferList(&((AEPlaythroughChannel*)receiver)->_buffer, 
                                        audio, 
                                        time);
}

-(AEAudioControllerAudioCallback)receiverCallback {
    return inputCallback;
}

static OSStatus renderCallback(id                        channel,
                               AEAudioController        *audioController,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    
    TPCircularBufferConsumeBufferListFrames(&((AEPlaythroughChannel*)channel)->_buffer, 
                                            &frames, 
                                            audio, 
                                            NULL, 
                                            AEAudioControllerAudioDescription(audioController));
    return noErr;
}

-(AEAudioControllerRenderCallback)renderCallback {
    return renderCallback;
}

@end


