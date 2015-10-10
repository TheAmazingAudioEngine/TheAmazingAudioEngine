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
#import "AEUtilities.h"

@interface AEAudioUnitChannel () {
    AudioComponentDescription _componentDescription;
    AUGraph _audioGraph;
    AUNode _node;
    AudioUnit _audioUnit;
    AUNode _converterNode;
    AudioUnit _converterUnit;
}
@property (nonatomic, copy) void (^preInitializeBlock)(AudioUnit audioUnit);
@property (nonatomic, strong) NSMutableDictionary * savedParameters;
@end

@implementation AEAudioUnitChannel
@synthesize audioGraphNode = _node;

- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription {
    return [self initWithComponentDescription:audioComponentDescription preInitializeBlock:nil];
}

- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                preInitializeBlock:(void(^)(AudioUnit audioUnit))preInitializeBlock {
    
    if ( !(self = [super init]) ) return nil;
    
    // Create the node, and the audio unit
    _componentDescription = audioComponentDescription;
    self.preInitializeBlock = preInitializeBlock;
    
    self.volume = 1.0;
    self.pan = 0.0;
    self.channelIsMuted = NO;
    self.channelIsPlaying = YES;
    
    return self;
}

AudioUnit AEAudioUnitChannelGetAudioUnit(__unsafe_unretained AEAudioUnitChannel * channel) {
    return channel->_audioUnit;
}

- (void)setupWithAudioController:(AEAudioController *)audioController {
    
    _audioGraph = audioController.audioGraph;
    
    // Create an instance of the audio unit
    OSStatus result;
    if ( !AECheckOSStatus(result=AUGraphAddNode(_audioGraph, &_componentDescription, &_node), "AUGraphAddNode") ||
        !AECheckOSStatus(result=AUGraphNodeInfo(_audioGraph, _node, NULL, &_audioUnit), "AUGraphNodeInfo") ) {
        
        NSLog(@"%@: Couldn't initialise audio unit", NSStringFromClass([self class]));
        return;
    }
    
    // Set max frames per slice for screen-off state
    UInt32 maxFPS = 4096;
    AECheckOSStatus(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)), "kAudioUnitProperty_MaximumFramesPerSlice");
    
    // Try to set the output audio description
    AudioStreamBasicDescription audioDescription = audioController.audioDescription;
    result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription));
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The audio description isn't supported. Assign modified default audio description, and create an audio converter.
        AudioStreamBasicDescription defaultAudioDescription;
        UInt32 size = sizeof(defaultAudioDescription);
        AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, &size);
        defaultAudioDescription.mSampleRate = audioDescription.mSampleRate;
        AEAudioStreamBasicDescriptionSetChannelsPerFrame(&defaultAudioDescription, audioDescription.mChannelsPerFrame);
        if ( !AECheckOSStatus(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, size), "AudioUnitSetProperty") ) {
            AUGraphRemoveNode(_audioGraph, _node);
            _node = 0;
            _audioUnit = NULL;
            NSLog(@"%@: Incompatible audio format", NSStringFromClass([self class]));
            return;
        }
        
        AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
        if ( !AECheckOSStatus(result=AUGraphAddNode(_audioGraph, &audioConverterDescription, &_converterNode), "AUGraphAddNode") ||
            !AECheckOSStatus(result=AUGraphNodeInfo(_audioGraph, _converterNode, NULL, &_converterUnit), "AUGraphNodeInfo") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)), "kAudioUnitProperty_MaximumFramesPerSlice") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &(AudioUnitConnection) {
            .sourceAudioUnit = _audioUnit,
            .sourceOutputNumber = 0,
            .destInputNumber = 0
        }, sizeof(AudioUnitConnection)), "kAudioUnitProperty_MakeConnection") ) {
            AUGraphRemoveNode(_audioGraph, _node);
            _node = 0;
            _audioUnit = NULL;
            if ( _converterNode ) {
                AUGraphRemoveNode(_audioGraph, _converterNode);
                _converterUnit = NULL;
                _converterNode = 0;
            }
            NSLog(@"%@: Couldn't setup converter audio unit", NSStringFromClass([self class]));
            return;
        }
    }
    
    if ( _savedParameters ) {
        // Restore parameters
        for ( NSNumber * key in _savedParameters.allKeys ) {
            NSNumber * value = _savedParameters[key];
            AECheckOSStatus(AudioUnitSetParameter(_audioUnit,
                                                  (AudioUnitParameterID)[key unsignedIntValue],
                                                  kAudioUnitScope_Global,
                                                  0,
                                                  (AudioUnitParameterValue)[value doubleValue],
                                                  0), "AudioUnitSetParameter");
        }
    }
    
    if ( _preInitializeBlock ) _preInitializeBlock(_audioUnit);

    AECheckOSStatus(AudioUnitInitialize(_audioUnit), "AudioUnitInitialize");
    
    if ( _converterUnit ) {
        AECheckOSStatus(AudioUnitInitialize(_converterUnit), "AudioUnitInitialize");
    }
}

- (void)teardown {
    if ( _node ) {
        AUGraphRemoveNode(_audioGraph, _node);
        _node = 0;
        _audioUnit = NULL;
    }
    if ( _converterNode ) {
        AUGraphRemoveNode(_audioGraph, _converterNode);
        _converterUnit = NULL;
        _converterNode = 0;
    }
    _audioGraph = NULL;
}

-(void)dealloc {
    if ( _audioUnit ) {
        [self teardown];
    }
}

-(AudioUnit)audioUnit {
    return _audioUnit;
}

- (double)getParameterValueForId:(AudioUnitParameterID)parameterId {
    if ( !_audioUnit ) {
        return [_savedParameters[@(parameterId)] doubleValue];
    }
    
    AudioUnitParameterValue value = 0;
    AECheckOSStatus(AudioUnitGetParameter(_audioUnit, parameterId, kAudioUnitScope_Global, 0, &value),
                    "AudioUnitGetParameter");
    return value;
}

- (void)setParameterValue:(double)value forId:(AudioUnitParameterID)parameterId {
    if ( !_savedParameters ) {
        self.savedParameters = [[NSMutableDictionary alloc] init];
    }
    _savedParameters[@(parameterId)] = @(value);
    if ( _audioUnit ) {
        AECheckOSStatus(AudioUnitSetParameter(_audioUnit, parameterId, kAudioUnitScope_Global, 0, value, 0),
                        "AudioUnitSetParameter");
    }
}

static OSStatus renderCallback(__unsafe_unretained AEAudioUnitChannel *THIS,
                               __unsafe_unretained AEAudioController *audioController,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    
    if ( !THIS->_audioUnit ) {
        return noErr;
    }
    
    AudioUnitRenderActionFlags flags = 0;
    AECheckOSStatus(AudioUnitRender(THIS->_converterUnit ? THIS->_converterUnit : THIS->_audioUnit, &flags, time, 0, frames, audio), "AudioUnitRender");
    return noErr;
}

-(AEAudioRenderCallback)renderCallback {
    return renderCallback;
}

@end
