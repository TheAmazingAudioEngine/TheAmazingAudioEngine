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
    AudioComponentDescription _componentDescription;
    AudioUnit _audioUnit;
    AudioUnit _converterUnit;
}
@property (nonatomic, copy) void (^preInitializeBlock)(AudioUnit audioUnit);
@end

@implementation AEAudioUnitChannel

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
    
    // Create an instance of the audio unit
    AudioComponent audioComponent = AudioComponentFindNext(NULL, &_componentDescription);
    OSStatus result = AudioComponentInstanceNew(audioComponent, &_audioUnit);
    if ( !checkResult(result, "AudioComponentInstanceNew") ) {
        NSLog(@"%@: Couldn't initialise audio unit", NSStringFromClass([self class]));
        return;
    }
    
    // Set max frames per slice for screen-off state
    UInt32 maxFPS = 4096;
    checkResult(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)), "kAudioUnitProperty_MaximumFramesPerSlice");
    
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
        if ( !checkResult(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, size), "AudioUnitSetProperty") ) {
            AudioComponentInstanceDispose(_audioUnit);
            _audioUnit = NULL;
            NSLog(@"%@: Incompatible audio format", NSStringFromClass([self class]));
            return;
        }
        
        AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
        audioComponent = AudioComponentFindNext(NULL, &audioConverterDescription);
        if ( !checkResult(result=AudioComponentInstanceNew(audioComponent, &_converterUnit), "AudioComponentInstanceNew") ||
            !checkResult(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
            !checkResult(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
            !checkResult(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)), "kAudioUnitProperty_MaximumFramesPerSlice") ||
            !checkResult(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &(AudioUnitConnection) {
            .sourceAudioUnit = _audioUnit,
            .sourceOutputNumber = 0,
            .destInputNumber = 0
        }, sizeof(AudioUnitConnection)), "kAudioUnitProperty_MakeConnection") ) {
            AudioComponentInstanceDispose(_audioUnit);
            _audioUnit = NULL;
            if ( _converterUnit ) {
                AudioComponentInstanceDispose(_converterUnit);
                _converterUnit = NULL;
            }
            NSLog(@"%@: Couldn't setup converter audio unit", NSStringFromClass([self class]));
            return;
        }
    }
    
    if( _preInitializeBlock ) _preInitializeBlock(_audioUnit);

    checkResult(AudioUnitInitialize(_audioUnit), "AudioUnitInitialize");
    
    if ( _converterUnit ) {
        checkResult(AudioUnitInitialize(_converterUnit), "AudioUnitInitialize");
    }
}

- (void)teardown {
    if ( _audioUnit ) {
        checkResult(AudioUnitUninitialize(_audioUnit), "AudioUnitUninitialize");
        checkResult(AudioComponentInstanceDispose(_audioUnit), "AudioComponentInstanceDispose");
        _audioUnit = NULL;
    }
    if ( _converterUnit ) {
        checkResult(AudioUnitUninitialize(_converterUnit), "AudioUnitUninitialize");
        checkResult(AudioComponentInstanceDispose(_converterUnit), "AudioComponentInstanceDispose");
        _converterUnit = NULL;
    }
}

-(void)dealloc {
    if ( _audioUnit ) {
        [self teardown];
    }
}

-(AudioUnit)audioUnit {
    return _audioUnit;
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

@end
