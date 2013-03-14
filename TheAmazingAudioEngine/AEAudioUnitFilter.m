//
//  AEAudioUnitFilter.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 05/02/2013.
//  Copyright (c) 2013 A Tasty Pixel. All rights reserved.
//

#import "AEAudioUnitFilter.h"

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        int fourCC = CFSwapInt32HostToBig(result);
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&fourCC);
        return NO;
    }
    return YES;
}

@interface AEAudioUnitFilter () {
    AUNode _node;
    AudioUnit _audioUnit;
    AUNode _inConverterNode;
    AudioUnit _inConverterUnit;
    AUNode _outConverterNode;
    AudioUnit _outConverterUnit;
    AUGraph _audioGraph;
    AEAudioControllerFilterProducer _currentProducer;
    void *_currentProducerToken;
}
@end

@implementation AEAudioUnitFilter

- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                   audioController:(AEAudioController*)audioController
                             error:(NSError**)error {
    if ( !(self = [super init]) ) return nil;

    // Create the node, and the audio unit
    _audioGraph = audioController.audioGraph;
	OSStatus result;
    if ( !checkResult(result=AUGraphAddNode(_audioGraph, &audioComponentDescription, &_node), "AUGraphAddNode") ||
         !checkResult(result=AUGraphNodeInfo(_audioGraph, _node, NULL, &_audioUnit), "AUGraphNodeInfo") ) {
        
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Couldn't initialise audio unit" forKey:NSLocalizedDescriptionKey]];
        [self release];
        return nil;
    }
    
    // Try to set the output audio description
    AudioStreamBasicDescription audioDescription = audioController.audioDescription;
    result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription));
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The audio description isn't supported. Assign modified default audio description, and create an audio converter.
        AudioStreamBasicDescription defaultAudioDescription;
        UInt32 size = sizeof(defaultAudioDescription);
        result = AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, &size);
        defaultAudioDescription.mSampleRate = audioDescription.mSampleRate;
        AEAudioStreamBasicDescriptionSetChannelsPerFrame(&defaultAudioDescription, audioDescription.mChannelsPerFrame);
        if ( !checkResult(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, size), "AudioUnitSetProperty") ) {
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Incompatible audio format" forKey:NSLocalizedDescriptionKey]];
            [self release];
            return nil;
        }
        
        AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
        
        if ( !checkResult(result=AUGraphAddNode(_audioGraph, &audioConverterDescription, &_outConverterNode), "AUGraphAddNode") ||
             !checkResult(result=AUGraphNodeInfo(_audioGraph, _outConverterNode, NULL, &_outConverterUnit), "AUGraphNodeInfo") ||
             !checkResult(result=AUGraphConnectNodeInput(_audioGraph, _node, 0, _outConverterNode, 0), "AUGraphConnectNodeInput") ||
             !checkResult(result=AudioUnitSetProperty(_outConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
             !checkResult(result=AudioUnitSetProperty(_outConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) {
            
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Couldn't setup converter audio unit" forKey:NSLocalizedDescriptionKey]];
            [self release];
            return nil;
        }
    }
    
    // Try to set the input audio description
    audioDescription = audioController.audioDescription;
    result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioDescription, sizeof(AudioStreamBasicDescription));
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The audio description isn't supported. Assign modified default audio description, and create an audio converter.
        AudioStreamBasicDescription defaultAudioDescription;
        UInt32 size = sizeof(defaultAudioDescription);
        result = AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, &size);
        defaultAudioDescription.mSampleRate = audioDescription.mSampleRate;
        AEAudioStreamBasicDescriptionSetChannelsPerFrame(&defaultAudioDescription, audioDescription.mChannelsPerFrame);
        if ( !checkResult(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, size), "AudioUnitSetProperty") ) {
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Incompatible audio format" forKey:NSLocalizedDescriptionKey]];
            [self release];
            return nil;
        }
        
        AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
        
        if ( !checkResult(result=AUGraphAddNode(_audioGraph, &audioConverterDescription, &_inConverterNode), "AUGraphAddNode") ||
             !checkResult(result=AUGraphNodeInfo(_audioGraph, _inConverterNode, NULL, &_inConverterUnit), "AUGraphNodeInfo") ||
             !checkResult(result=AUGraphConnectNodeInput(_audioGraph, _inConverterNode, 0, _node, 0), "AUGraphConnectNodeInput") ||
             !checkResult(result=AudioUnitSetProperty(_inConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
             !checkResult(result=AudioUnitSetProperty(_inConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) {
            
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Couldn't setup converter audio unit" forKey:NSLocalizedDescriptionKey]];
            [self release];
            return nil;
        }
    }
    
    // Set the audio unit's input callback
    // Setup render callback struct
    AURenderCallbackStruct rcbs;
    rcbs.inputProc = &audioUnitRenderCallback;
    rcbs.inputProcRefCon = self;
    checkResult(AudioUnitSetProperty(_inConverterUnit ? _inConverterUnit : _audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &rcbs, sizeof(rcbs)),
                "AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback)");
    
    // Attempt to set the max frames per slice
    UInt32 maxFPS = 4096;
    AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    
    if ( _inConverterUnit ) {
        AudioUnitSetProperty(_inConverterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    }
    
    if ( _outConverterUnit ) {
        AudioUnitSetProperty(_outConverterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    }
    
    checkResult(AUGraphUpdate(_audioGraph, NULL), "AUGraphUpdate");
    
    return self;
}

-(void)dealloc {
    if ( _node ) {
        checkResult(AUGraphRemoveNode(_audioGraph, _node), "AUGraphRemoveNode");
    }
    if ( _outConverterNode ) {
        checkResult(AUGraphRemoveNode(_audioGraph, _outConverterNode), "AUGraphRemoveNode");
    }
    if ( _inConverterNode ) {
        checkResult(AUGraphRemoveNode(_audioGraph, _inConverterNode), "AUGraphRemoveNode");
    }
    
    [super dealloc];
}

-(AudioUnit)audioUnit {
    return _audioUnit;
}

static OSStatus filterCallback(id                        filter,
                               AEAudioController        *audioController,
                               AEAudioControllerFilterProducer producer,
                               void                     *producerToken,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    AEAudioUnitFilter *THIS = (AEAudioUnitFilter*)filter;
    
    THIS->_currentProducer = producer;
    THIS->_currentProducerToken = producerToken;
    
    AudioUnitRenderActionFlags flags = 0;
    checkResult(AudioUnitRender(THIS->_outConverterUnit ? THIS->_outConverterUnit : THIS->_audioUnit, &flags, time, 0, frames, audio), "AudioUnitRender");
    
    return noErr;
}

-(AEAudioControllerFilterCallback)filterCallback {
    return filterCallback;
}

static OSStatus audioUnitRenderCallback(void                       *inRefCon,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp       *inTimeStamp,
                                        UInt32                      inBusNumber,
                                        UInt32                      inNumberFrames,
                                        AudioBufferList            *ioData) {
    AEAudioUnitFilter *THIS = (AEAudioUnitFilter*)inRefCon;
    return THIS->_currentProducer(THIS->_currentProducerToken, ioData, &inNumberFrames);
}

@end
