//
//  AEAudioUnitChannel.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 01/02/2013.
//  Copyright (c) 2013 A Tasty Pixel. All rights reserved.
//

#import "AEAudioUnitChannel.h"

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        int fourCC = CFSwapInt32HostToBig(result);
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&fourCC);
        return NO;
    }
    return YES;
}

@interface AEAudioUnitChannel () {
    AUNode _node;
    AudioUnit _audioUnit;
    AUGraph _audioGraph;
}
@end

@implementation AEAudioUnitChannel

+ (AEAudioUnitChannel*)audioUnitChannelWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                                                audioController:(AEAudioController*)audioController
                                                          error:(NSError**)error {
    
    AEAudioUnitChannel *channel = [[[AEAudioUnitChannel alloc] init] autorelease];
    
    // Create the node, and the audio unit
    channel->_audioGraph = audioController.audioGraph;
	OSStatus result;
    if ( !checkResult(result=AUGraphAddNode(channel->_audioGraph, &audioComponentDescription, &channel->_node), "AUGraphAddNode") ||
         !checkResult(result=AUGraphNodeInfo(channel->_audioGraph, channel->_node, NULL, &channel->_audioUnit), "AUGraphNodeInfo") ) {
        
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Couldn't initialise audio unit" forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    checkResult(AudioUnitInitialize(channel->_audioUnit), "AudioUnitInitialize");
    
    // Try to set the output audio description
    channel->_audioDescription = audioController.audioDescription;
    result = AudioUnitSetProperty(channel->_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &channel->_audioDescription, sizeof(AudioStreamBasicDescription));
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The default audio description isn't supported. Just get the audio unit's default, and use that (but set the sample rate)
        UInt32 size = sizeof(AudioStreamBasicDescription);
        checkResult(AudioUnitGetProperty(channel->_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &channel->_audioDescription, &size),
                    "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
        
        channel->_audioDescription.mSampleRate = audioController.audioDescription.mSampleRate;
        
        checkResult(AudioUnitSetProperty(channel->_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &channel->_audioDescription, sizeof(AudioStreamBasicDescription)),
                    "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat");
    }
    
    // Attempt to set the max frames per slice
    UInt32 maxFPS = 4096;
    AudioUnitSetProperty(channel->_audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    
    return channel;
}

- (id)init {
    if ( !(self = [super init]) ) self = nil;
    self.volume = 1.0;
    self.pan = 0.0;
    self.channelIsMuted = NO;
    self.channelIsPlaying = YES;
    return self;
}

- (BOOL)changeAudioDescription:(AudioStreamBasicDescription)audioDescription {
    OSStatus result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription));
    if ( result == noErr ) {
        [self willChangeValueForKey:@"audioDescription"];
        _audioDescription = audioDescription;
        [self didChangeValueForKey:@"audioDescription"];
        return YES;
    } else {
        return NO;
    }
}

-(void)dealloc {
    AUGraphRemoveNode(_audioGraph, _node);
    [super dealloc];
}

-(AudioUnit)audioUnit {
    return _audioUnit;
}

static OSStatus renderCallback(id                        channel,
                               AEAudioController        *audioController,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    AEAudioUnitChannel *THIS = (AEAudioUnitChannel*)channel;
    AudioUnitRenderActionFlags flags = 0;
    checkResult(AudioUnitRender(THIS->_audioUnit, &flags, time, 0, frames, audio), "AudioUnitRender");
    return noErr;
}

-(AEAudioControllerRenderCallback)renderCallback {
    return renderCallback;
}

@end
