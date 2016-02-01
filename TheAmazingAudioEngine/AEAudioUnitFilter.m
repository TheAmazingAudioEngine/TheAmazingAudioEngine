//
//  AEAudioUnitFilter.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 05/02/2013.
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

#import "AEAudioUnitFilter.h"

@interface AEAudioUnitFilter () {
    AudioComponentDescription _componentDescription;
    AUGraph _audioGraph;
    AUNode _node;
    AudioUnit _audioUnit;
    AUNode _inConverterNode;
    AudioUnit _inConverterUnit;
    AUNode _outConverterNode;
    AudioUnit _outConverterUnit;
    AEAudioFilterProducer _currentProducer;
    void *_currentProducerToken;
    BOOL _wasBypassed;
}
@property (nonatomic, copy) void (^preInitializeBlock)(AudioUnit audioUnit);
@property (nonatomic, strong) NSMutableDictionary * savedParameters;
@end

@implementation AEAudioUnitFilter
@synthesize audioGraphNode = _node;

- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription {
    return [self initWithComponentDescription:audioComponentDescription preInitializeBlock:nil];
}

-(id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription
               preInitializeBlock:(void(^)(AudioUnit audioUnit))preInitializeBlock {
    if ( !(self = [super init]) ) return nil;
    
    // Create the node, and the audio unit
    _componentDescription = audioComponentDescription;
    self.preInitializeBlock = preInitializeBlock;

    self.bypassed = false;
    _wasBypassed  = false;

    return self;
}

AudioUnit AEAudioUnitFilterGetAudioUnit(__unsafe_unretained AEAudioUnitFilter * filter) {
    return filter->_audioUnit;
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
        if ( !AECheckOSStatus(result=AUGraphAddNode(_audioGraph, &audioConverterDescription, &_outConverterNode), "AUGraphAddNode") ||
            !AECheckOSStatus(result=AUGraphNodeInfo(_audioGraph, _outConverterNode, NULL, &_outConverterUnit), "AUGraphNodeInfo") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_outConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_outConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_outConverterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)), "kAudioUnitProperty_MaximumFramesPerSlice") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_outConverterUnit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &(AudioUnitConnection) {
                    .sourceAudioUnit = _audioUnit,
                    .sourceOutputNumber = 0,
                    .destInputNumber = 0
                }, sizeof(AudioUnitConnection)), "kAudioUnitProperty_MakeConnection") ) {
            AUGraphRemoveNode(_audioGraph, _node);
            _node = 0;
            _audioUnit = NULL;
            if ( _outConverterNode ) {
                AUGraphRemoveNode(_audioGraph, _outConverterNode);
                _outConverterUnit = NULL;
                _outConverterNode = 0;
            }
            NSLog(@"%@: Couldn't setup converter audio unit", NSStringFromClass([self class]));
            return;
        }
    }
    
    // Try to set the input audio description
    audioDescription = audioController.audioDescription;
    
    if ( !_useDefaultInputFormatWorkaround ) {
        result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioDescription, sizeof(AudioStreamBasicDescription));
    }
    
    if ( _useDefaultInputFormatWorkaround || result == kAudioUnitErr_FormatNotSupported ) {
        // The audio description isn't supported. Assign modified default audio description, and create an audio converter.
        AudioStreamBasicDescription defaultAudioDescription;
        UInt32 size = sizeof(defaultAudioDescription);
        AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, &size);
        
        AudioStreamBasicDescription replacementAudioDescription = defaultAudioDescription;
        
        if ( !_useDefaultInputFormatWorkaround ) {
            // Try to modify this audio description to assign the system sample rate and channel count
            replacementAudioDescription.mSampleRate = audioDescription.mSampleRate;
            AEAudioStreamBasicDescriptionSetChannelsPerFrame(&replacementAudioDescription, audioDescription.mChannelsPerFrame);
            result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &replacementAudioDescription, sizeof(AudioStreamBasicDescription));
            if ( result == kAudioUnitErr_FormatNotSupported ) {
                // These aren't supported either - use base format
                replacementAudioDescription = defaultAudioDescription;
            }
        }
        
        if ( !AECheckOSStatus(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &replacementAudioDescription, size), "AudioUnitSetProperty") ) {
            AUGraphRemoveNode(_audioGraph, _node);
            _node = 0;
            _audioUnit = NULL;
            if ( _outConverterNode ) {
                AUGraphRemoveNode(_audioGraph, _outConverterNode);
                _outConverterUnit = NULL;
                _outConverterNode = 0;
            }
            NSLog(@"%@: Incompatible audio format", NSStringFromClass([self class]));
            return;
        }
        
        AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
        if ( !AECheckOSStatus(result=AUGraphAddNode(_audioGraph, &audioConverterDescription, &_inConverterNode), "AUGraphAddNode") ||
            !AECheckOSStatus(result=AUGraphNodeInfo(_audioGraph, _inConverterNode, NULL, &_inConverterUnit), "AUGraphNodeInfo") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_inConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_inConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &replacementAudioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_inConverterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)), "kAudioUnitProperty_MaximumFramesPerSlice") ||
            !AECheckOSStatus(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &(AudioUnitConnection) {
                    .sourceAudioUnit = _inConverterUnit,
                    .sourceOutputNumber = 0,
                    .destInputNumber = 0
                }, sizeof(AudioUnitConnection)), "kAudioUnitProperty_MakeConnection") ) {
            AUGraphRemoveNode(_audioGraph, _node);
            _node = 0;
            _audioUnit = NULL;
            if ( _outConverterNode ) {
                AUGraphRemoveNode(_audioGraph, _outConverterNode);
                _outConverterUnit = NULL;
                _outConverterNode = 0;
            }
            if ( _inConverterNode ) {
                AUGraphRemoveNode(_audioGraph, _inConverterNode);
                _inConverterUnit = NULL;
                _inConverterNode = 0;
            }
            NSLog(@"%@: Couldn't setup converter audio unit", NSStringFromClass([self class]));
            return;
        }
    }
    
    // Set the audio unit's input callback
    // Setup render callback struct
    AURenderCallbackStruct rcbs;
    rcbs.inputProc = &audioUnitRenderCallback;
    rcbs.inputProcRefCon = (__bridge void *)self;
    AECheckOSStatus(AudioUnitSetProperty(_inConverterUnit ? _inConverterUnit : _audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &rcbs, sizeof(rcbs)),
                "AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback)");
    
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
    
    if ( _inConverterUnit ) {
        AECheckOSStatus(AudioUnitInitialize(_inConverterUnit), "AudioUnitInitialize");
    }
    
    if ( _outConverterUnit ) {
        AECheckOSStatus(AudioUnitInitialize(_outConverterUnit), "AudioUnitInitialize");
    }
}

- (void)teardown {
    if ( _node ) {
        AUGraphRemoveNode(_audioGraph, _node);
        _node = 0;
        _audioUnit = NULL;
    }
    if ( _outConverterNode ) {
        AUGraphRemoveNode(_audioGraph, _outConverterNode);
        _outConverterUnit = NULL;
        _outConverterNode = 0;
    }
    if ( _inConverterNode ) {
        AUGraphRemoveNode(_audioGraph, _inConverterNode);
        _inConverterUnit = NULL;
        _inConverterNode = 0;
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

static OSStatus filterCallback(__unsafe_unretained AEAudioUnitFilter *THIS,
                               __unsafe_unretained AEAudioController *audioController,
                               AEAudioFilterProducer producer,
                               void                     *producerToken,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    
    if ( !THIS->_audioUnit ) {
        THIS->_currentProducer(THIS->_currentProducerToken, audio, &frames);
        return noErr;
    }
    
    THIS->_currentProducer = producer;
    THIS->_currentProducerToken = producerToken;
    
    AudioUnitRenderActionFlags flags = 0;
    
    if ( THIS->_bypassed ) {
        // Bypassed: just advance.
        THIS->_currentProducer(THIS->_currentProducerToken, audio, &frames);
    } else {
        // First check if it was bypassed last time (if so give it a reset so things like reverb don't ring from previous audio).
        if ( THIS->_wasBypassed ) AudioUnitReset (THIS->_audioUnit, kAudioUnitScope_Global, 0);
        
        // Render the AudioUnit.
        AECheckOSStatus(AudioUnitRender(THIS->_outConverterUnit ? THIS->_outConverterUnit : THIS->_audioUnit, &flags, time, 0, frames, audio), "AudioUnitRender");
    }
    
    THIS->_wasBypassed = THIS->_bypassed;
    
    return noErr;
}

-(AEAudioFilterCallback)filterCallback {
    return filterCallback;
}

static OSStatus audioUnitRenderCallback(void                       *inRefCon,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp       *inTimeStamp,
                                        UInt32                      inBusNumber,
                                        UInt32                      inNumberFrames,
                                        AudioBufferList            *ioData) {
    __unsafe_unretained AEAudioUnitFilter *THIS = (__bridge AEAudioUnitFilter*)inRefCon;
    return THIS->_currentProducer(THIS->_currentProducerToken, ioData, &inNumberFrames);
}

@end
