//
//  AEAudioUnitChannel.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 01/02/2013.
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
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
    AEAudioController *_audioController;
    AudioComponentDescription _componentDescription;
    AUNode _node;
    AudioUnit _audioUnit;
    AUNode _converterNode;
    AudioUnit _converterUnit;
    AUGraph _audioGraph;
}
@end

@implementation AEAudioUnitChannel

- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                       audioController:(AEAudioController*)audioController
                                 error:(NSError**)error {
    return [self initWithComponentDescription:audioComponentDescription audioController:audioController  preInitializeBlock:nil error:error];
}

- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                   audioController:(AEAudioController*)audioController
                preInitializeBlock:(void(^)(AudioUnit audioUnit))block
                             error:(NSError**)error {
    
    if ( !(self = [super init]) ) return nil;
    
    // Create the node, and the audio unit
    _audioController = audioController;
    _componentDescription = audioComponentDescription;
    _audioGraph = _audioController.audioGraph;
    
    if ( ![self setup:block error:error] ) {
        return nil;
    }
    
    self.volume = 1.0;
    self.pan = 0.0;
    self.channelIsMuted = NO;
    self.channelIsPlaying = YES;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didRecreateGraph:) name:AEAudioControllerDidRecreateGraphNotification object:_audioController];
    
    return self;
}

- (BOOL)setup:(void(^)(AudioUnit audioUnit))block error:(NSError**)error {
	OSStatus result;
    if ( !checkResult(result=AUGraphAddNode(_audioGraph, &_componentDescription, &_node), "AUGraphAddNode") ||
         !checkResult(result=AUGraphNodeInfo(_audioGraph, _node, NULL, &_audioUnit), "AUGraphNodeInfo") ) {
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:@{NSLocalizedDescriptionKey: @"Couldn't initialise audio unit"}];
        return NO;
    }
    
    UInt32 maxFPS = 4096;
    checkResult(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)), "kAudioUnitProperty_MaximumFramesPerSlice");

    // Try to set the output audio description
    AudioStreamBasicDescription audioDescription = _audioController.audioDescription;
    result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription));
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The audio description isn't supported. Assign modified default audio description, and create an audio converter.
        AudioStreamBasicDescription defaultAudioDescription;
        UInt32 size = sizeof(defaultAudioDescription);
        AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, &size);
        defaultAudioDescription.mSampleRate = audioDescription.mSampleRate;
        AEAudioStreamBasicDescriptionSetChannelsPerFrame(&defaultAudioDescription, audioDescription.mChannelsPerFrame);
        if ( !checkResult(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, size), "AudioUnitSetProperty") ) {
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:@{NSLocalizedDescriptionKey: @"Incompatible audio format"}];
            return NO;
        }
        
        AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
        if ( !checkResult(result=AUGraphAddNode(_audioGraph, &audioConverterDescription, &_converterNode), "AUGraphAddNode") ||
             !checkResult(result=AUGraphNodeInfo(_audioGraph, _converterNode, NULL, &_converterUnit), "AUGraphNodeInfo") ||
             !checkResult(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
             !checkResult(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
             !checkResult(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)), "kAudioUnitProperty_MaximumFramesPerSlice") ||
             !checkResult(result=AUGraphConnectNodeInput(_audioGraph, _node, 0, _converterNode, 0), "AUGraphConnectNodeInput") ) {
            
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:@{NSLocalizedDescriptionKey: @"Couldn't setup converter audio unit"}];
            return NO;
        }
        
        // Set the audio unit to handle up to 4096 frames per slice to keep rendering during screen lock
        UInt32 maxFPS = 4096;
        checkResult(AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)),
                    "AudioUnitSetProperty(kAudioUnitProperty_MaximumFramesPerSlice)");
    }
    
    checkResult(AUGraphUpdate(_audioGraph, NULL), "AUGraphUpdate");

    if(block) block(_audioUnit);

    checkResult(AudioUnitInitialize(_audioUnit), "AudioUnitInitialize");
    
    if ( _converterUnit ) {
        checkResult(AudioUnitInitialize(_converterUnit), "AudioUnitInitialize");
    }

    return YES;
}

-(void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AEAudioControllerDidRecreateGraphNotification object:_audioController];
    
    if ( _node ) {
        checkResult(AUGraphRemoveNode(_audioGraph, _node), "AUGraphRemoveNode");
    }
    if ( _converterNode ) {
        checkResult(AUGraphRemoveNode(_audioGraph, _converterNode), "AUGraphRemoveNode");
    }

    checkResult(AUGraphUpdate(_audioGraph, NULL), "AUGraphUpdate");
    
}

-(AudioUnit)audioUnit {
    return _audioUnit;
}

-(AUNode)audioGraphNode {
    return _node;
}

static OSStatus renderCallback(__unsafe_unretained AEAudioUnitChannel *THIS,
                               __unsafe_unretained AEAudioController *audioController,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    AudioUnitRenderActionFlags flags = 0;
    checkResult(AudioUnitRender(THIS->_converterUnit ? THIS->_converterUnit : THIS->_audioUnit, &flags, time, 0, frames, audio), "AudioUnitRender");
    return noErr;
}

-(AEAudioControllerRenderCallback)renderCallback {
    return renderCallback;
}

- (void)didRecreateGraph:(NSNotification*)notification {
    _node = 0;
    _audioUnit = NULL;
    _converterNode = 0;
    _converterUnit = NULL;
    _audioGraph = _audioController.audioGraph;
    [self setup:nil error:NULL];
}

@end
