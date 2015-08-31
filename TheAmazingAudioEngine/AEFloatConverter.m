//
//  AEFloatConverter.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 25/10/2012.
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

#import "AEFloatConverter.h"
#import "AEUtilities.h"

#define                        kNoMoreDataErr                            -2222

struct complexInputDataProc_t {
    AudioBufferList *sourceBuffer;
};

@interface AEFloatConverter () {
    AudioStreamBasicDescription _sourceAudioDescription;
    AudioStreamBasicDescription _floatAudioDescription;
    AudioConverterRef           _toFloatConverter;
    AudioConverterRef           _fromFloatConverter;
    AudioBufferList            *_scratchFloatBufferList;
}

static OSStatus complexInputDataProc(AudioConverterRef             inAudioConverter,
                                     UInt32                        *ioNumberDataPackets,
                                     AudioBufferList               *ioData,
                                     AudioStreamPacketDescription  **outDataPacketDescription,
                                     void                          *inUserData);
@end

@implementation AEFloatConverter
@synthesize sourceFormat = _sourceAudioDescription;

-(id)initWithSourceFormat:(AudioStreamBasicDescription)sourceFormat {
    if ( !(self = [super init]) ) return nil;

    self.sourceFormat = sourceFormat;
    
    return self;
}

-(void)dealloc {
    if ( _toFloatConverter ) AudioConverterDispose(_toFloatConverter);
    if ( _fromFloatConverter ) AudioConverterDispose(_fromFloatConverter);
    if ( _scratchFloatBufferList ) free(_scratchFloatBufferList);
}

-(void)setSourceFormat:(AudioStreamBasicDescription)sourceFormat {
    if ( !memcmp(&sourceFormat, &_sourceAudioDescription, sizeof(sourceFormat)) ) return;
    
    _sourceAudioDescription = sourceFormat;
    
    [self updateFormats];
}

- (void)updateFormats {
    _floatAudioDescription = (AudioStreamBasicDescription) {
        .mFormatID          = kAudioFormatLinearPCM,
        .mFormatFlags       = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        .mChannelsPerFrame  = _floatFormatChannelsPerFrame ? _floatFormatChannelsPerFrame : _sourceAudioDescription.mChannelsPerFrame,
        .mBytesPerPacket    = sizeof(float),
        .mFramesPerPacket   = 1,
        .mBytesPerFrame     = sizeof(float),
        .mBitsPerChannel    = 8 * sizeof(float),
        .mSampleRate        = _sourceAudioDescription.mSampleRate
    };
    
    if ( _toFloatConverter ) {
        AudioConverterDispose(_toFloatConverter);
        _toFloatConverter = NULL;
    }
    if ( _fromFloatConverter ) {
        AudioConverterDispose(_fromFloatConverter);
        _fromFloatConverter = NULL;
    }
    if ( _scratchFloatBufferList ) {
        free(_scratchFloatBufferList);
        _scratchFloatBufferList = NULL;
    }
    
    if ( memcmp(&_sourceAudioDescription, &_floatAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
        AECheckOSStatus(AudioConverterNew(&_sourceAudioDescription, &_floatAudioDescription, &_toFloatConverter), "AudioConverterNew");
        AECheckOSStatus(AudioConverterNew(&_floatAudioDescription, &_sourceAudioDescription, &_fromFloatConverter), "AudioConverterNew");
        _scratchFloatBufferList = (AudioBufferList*)malloc(sizeof(AudioBufferList) + (_floatAudioDescription.mChannelsPerFrame-1)*sizeof(AudioBuffer));
        _scratchFloatBufferList->mNumberBuffers = _floatAudioDescription.mChannelsPerFrame;
        for ( int i=0; i<_scratchFloatBufferList->mNumberBuffers; i++ ) {
            _scratchFloatBufferList->mBuffers[i].mNumberChannels = 1;
        }
    }
}

-(void)setFloatFormatChannelsPerFrame:(int)floatFormatChannelsPerFrame {
    _floatFormatChannelsPerFrame = floatFormatChannelsPerFrame;
    
    [self updateFormats];
}

BOOL AEFloatConverterToFloat(__unsafe_unretained AEFloatConverter* THIS, AudioBufferList *sourceBuffer, float * const * targetBuffers, UInt32 frames) {
    if ( frames == 0 ) return YES;
    
    if ( THIS->_toFloatConverter ) {
        UInt32 priorDataByteSize = sourceBuffer->mBuffers[0].mDataByteSize;
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            sourceBuffer->mBuffers[i].mDataByteSize = frames * THIS->_sourceAudioDescription.mBytesPerFrame;
        }
        
        for ( int i=0; i<THIS->_scratchFloatBufferList->mNumberBuffers; i++ ) {
            THIS->_scratchFloatBufferList->mBuffers[i].mData = targetBuffers[i];
            THIS->_scratchFloatBufferList->mBuffers[i].mDataByteSize = frames * sizeof(float);
        }
        
        OSStatus result = AudioConverterFillComplexBuffer(THIS->_toFloatConverter,
                                                          complexInputDataProc,
                                                          &(struct complexInputDataProc_t) { .sourceBuffer = sourceBuffer },
                                                          &frames,
                                                          THIS->_scratchFloatBufferList,
                                                          NULL);
        
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            sourceBuffer->mBuffers[i].mDataByteSize = priorDataByteSize;
        }
        
        if ( !AECheckOSStatus(result, "AudioConverterConvertComplexBuffer") ) {
            return NO;
        }
        
    } else {
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            memcpy(targetBuffers[i], sourceBuffer->mBuffers[i].mData, frames * sizeof(float));
        }
    }
    
    return YES;
}

BOOL AEFloatConverterToFloatBufferList(__unsafe_unretained AEFloatConverter* THIS, AudioBufferList *sourceBuffer, AudioBufferList *targetBuffer, UInt32 frames) {
    assert(targetBuffer->mNumberBuffers == THIS->_floatAudioDescription.mChannelsPerFrame);
    
    float *targetBuffers[targetBuffer->mNumberBuffers];
    for ( int i=0; i<targetBuffer->mNumberBuffers; i++ ) {
        targetBuffers[i] = (float*)targetBuffer->mBuffers[i].mData;
    }
    return AEFloatConverterToFloat(THIS, sourceBuffer, targetBuffers, frames);
}

BOOL AEFloatConverterFromFloat(__unsafe_unretained AEFloatConverter* THIS, float * const * sourceBuffers, AudioBufferList *targetBuffer, UInt32 frames) {
    if ( frames == 0 ) return YES;
    
    if ( THIS->_fromFloatConverter ) {
        for ( int i=0; i<THIS->_scratchFloatBufferList->mNumberBuffers; i++ ) {
            THIS->_scratchFloatBufferList->mBuffers[i].mData = sourceBuffers[i];
            THIS->_scratchFloatBufferList->mBuffers[i].mDataByteSize = frames * sizeof(float);
        }
        
        UInt32 priorDataByteSize = targetBuffer->mBuffers[0].mDataByteSize;
        for ( int i=0; i<targetBuffer->mNumberBuffers; i++ ) {
            targetBuffer->mBuffers[i].mDataByteSize = frames * THIS->_sourceAudioDescription.mBytesPerFrame;
        }
        
        OSStatus result = AudioConverterFillComplexBuffer(THIS->_fromFloatConverter,
                                                          complexInputDataProc,
                                                          &(struct complexInputDataProc_t) { .sourceBuffer = THIS->_scratchFloatBufferList },
                                                          &frames,
                                                          targetBuffer,
                                                          NULL);
        
        for ( int i=0; i<targetBuffer->mNumberBuffers; i++ ) {
            targetBuffer->mBuffers[i].mDataByteSize = priorDataByteSize;
        }
        
        if ( !AECheckOSStatus(result, "AudioConverterConvertComplexBuffer") ) {
            return NO;
        }
    } else {
        for ( int i=0; i<targetBuffer->mNumberBuffers; i++ ) {
            memcpy(targetBuffer->mBuffers[i].mData, sourceBuffers[i], frames * sizeof(float));
        }
    }
    
    return YES;
}

BOOL AEFloatConverterFromFloatBufferList(__unsafe_unretained AEFloatConverter* THIS, AudioBufferList *sourceBuffer, AudioBufferList *targetBuffer, UInt32 frames) {
    assert(sourceBuffer->mNumberBuffers == THIS->_floatAudioDescription.mChannelsPerFrame);
    
    float *sourceBuffers[sourceBuffer->mNumberBuffers];
    for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
        sourceBuffers[i] = (float*)sourceBuffer->mBuffers[i].mData;
    }
    return AEFloatConverterFromFloat(THIS, sourceBuffers, targetBuffer, frames);
}

static OSStatus complexInputDataProc(AudioConverterRef             inAudioConverter,
                                     UInt32                        *ioNumberDataPackets,
                                     AudioBufferList               *ioData,
                                     AudioStreamPacketDescription  **outDataPacketDescription,
                                     void                          *inUserData) {
    struct complexInputDataProc_t *arg = (struct complexInputDataProc_t*)inUserData;
    if ( !arg->sourceBuffer ) {
        return kNoMoreDataErr;
    }
    
    memcpy(ioData, arg->sourceBuffer, sizeof(AudioBufferList) + (arg->sourceBuffer->mNumberBuffers-1)*sizeof(AudioBuffer));
    arg->sourceBuffer = NULL;
    
    return noErr;
}

-(AudioStreamBasicDescription)floatingPointAudioDescription {
    return _floatAudioDescription;
}

@end