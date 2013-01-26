//
//  AEFloatConverter.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 25/10/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEFloatConverter.h"

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/'),__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s", file, line, operation, (int)result, (int)result, (char*)&result);
        return NO;
    }
    return YES;
}

#define                        kNoMoreDataErr                            -2222

struct complexInputDataProc_t {
    AudioBufferList *sourceBuffer;
};

@interface AEFloatConverter () {
    AudioStreamBasicDescription _sourceAudioDescription;
    AudioStreamBasicDescription _floatAudioDescription;
    AudioConverterRef           _toFloatConverter;
    AudioConverterRef           _fromFloatConverter;
    AudioBufferList            *_scratchBufferList;
}

static OSStatus complexInputDataProc(AudioConverterRef             inAudioConverter,
                                     UInt32                        *ioNumberDataPackets,
                                     AudioBufferList               *ioData,
                                     AudioStreamPacketDescription  **outDataPacketDescription,
                                     void                          *inUserData);
@end

@implementation AEFloatConverter

-(id)initWithSourceFormat:(AudioStreamBasicDescription)sourceFormat {
    if ( !(self = [super init]) ) return nil;

    _floatAudioDescription.mFormatID          = kAudioFormatLinearPCM;
    _floatAudioDescription.mFormatFlags       = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    _floatAudioDescription.mChannelsPerFrame  = sourceFormat.mChannelsPerFrame;
    _floatAudioDescription.mBytesPerPacket    = sizeof(float);
    _floatAudioDescription.mFramesPerPacket   = 1;
    _floatAudioDescription.mBytesPerFrame     = sizeof(float);
    _floatAudioDescription.mBitsPerChannel    = 8 * sizeof(float);
    _floatAudioDescription.mSampleRate        = sourceFormat.mSampleRate;
    
    memcpy(&_sourceAudioDescription, &sourceFormat, sizeof(AudioStreamBasicDescription));
    
    if ( memcmp(&sourceFormat, &_floatAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
        checkResult(AudioConverterNew(&sourceFormat, &_floatAudioDescription, &_toFloatConverter), "AudioConverterNew");
        checkResult(AudioConverterNew(&_floatAudioDescription, &sourceFormat, &_fromFloatConverter), "AudioConverterNew");
        _scratchBufferList = (AudioBufferList*)malloc(sizeof(AudioBufferList) + (_floatAudioDescription.mChannelsPerFrame-1)*sizeof(AudioBuffer));
        _scratchBufferList->mNumberBuffers = _floatAudioDescription.mChannelsPerFrame;
        for ( int i=0; i<_scratchBufferList->mNumberBuffers; i++ ) {
            _scratchBufferList->mBuffers[i].mNumberChannels = 1;
        }
    }
    
    return self;
}

-(void)dealloc {
    if ( _toFloatConverter ) AudioConverterDispose(_toFloatConverter);
    if ( _fromFloatConverter ) AudioConverterDispose(_fromFloatConverter);
    if ( _scratchBufferList ) free(_scratchBufferList);
    [super dealloc];
}


BOOL AEFloatConverterToFloat(AEFloatConverter* THIS, AudioBufferList *sourceBuffer, float * const * targetBuffers, UInt32 frames) {
    if ( THIS->_toFloatConverter ) {
        UInt32 originalBufferSize = sourceBuffer->mBuffers[0].mDataByteSize;
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            sourceBuffer->mBuffers[i].mDataByteSize = frames * THIS->_sourceAudioDescription.mBytesPerFrame;
        }
        
        for ( int i=0; i<THIS->_scratchBufferList->mNumberBuffers; i++ ) {
            THIS->_scratchBufferList->mBuffers[i].mData = targetBuffers[i];
            THIS->_scratchBufferList->mBuffers[i].mDataByteSize = frames * sizeof(float);
        }
        
        OSStatus result = AudioConverterFillComplexBuffer(THIS->_toFloatConverter,
                                                          complexInputDataProc,
                                                          &(struct complexInputDataProc_t) { .sourceBuffer = sourceBuffer },
                                                          &frames,
                                                          THIS->_scratchBufferList,
                                                          NULL);
        
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            sourceBuffer->mBuffers[i].mDataByteSize = originalBufferSize;
        }
        
        if ( !checkResult(result, "AudioConverterConvertComplexBuffer") ) {
            return NO;
        }
    } else {
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            memcpy(targetBuffers[i], sourceBuffer->mBuffers[i].mData, frames * sizeof(float));
        }
    }
    
    return YES;
}

BOOL AEFloatConverterToFloatBufferList(AEFloatConverter* converter, AudioBufferList *sourceBuffer,  AudioBufferList *targetBuffer, UInt32 frames) {
    float *targetBuffers[targetBuffer->mNumberBuffers];
    for ( int i=0; i<targetBuffer->mNumberBuffers; i++ ) {
        targetBuffers[i] = (float*)targetBuffer->mBuffers[i].mData;
    }
    return AEFloatConverterToFloat(converter, sourceBuffer, targetBuffers, frames);
}

BOOL AEFloatConverterFromFloat(AEFloatConverter* THIS, float * const * sourceBuffers, AudioBufferList *targetBuffer, UInt32 frames) {
    for ( int i=0; i<targetBuffer->mNumberBuffers; i++ ) {
        targetBuffer->mBuffers[i].mDataByteSize = frames * THIS->_sourceAudioDescription.mBytesPerFrame;
    }
    
    if ( THIS->_fromFloatConverter ) {
        for ( int i=0; i<THIS->_scratchBufferList->mNumberBuffers; i++ ) {
            THIS->_scratchBufferList->mBuffers[i].mData = sourceBuffers[i];
            THIS->_scratchBufferList->mBuffers[i].mDataByteSize = frames * sizeof(float);
        }
        
        OSStatus result = AudioConverterFillComplexBuffer(THIS->_fromFloatConverter,
                                                          complexInputDataProc,
                                                          &(struct complexInputDataProc_t) { .sourceBuffer = THIS->_scratchBufferList },
                                                          &frames,
                                                          targetBuffer,
                                                          NULL);
        if ( !checkResult(result, "AudioConverterConvertComplexBuffer") ) {
            return NO;
        }
    } else {
        for ( int i=0; i<targetBuffer->mNumberBuffers; i++ ) {
            memcpy(targetBuffer->mBuffers[i].mData, sourceBuffers[i], frames * sizeof(float));
        }
    }
    
    return YES;
}

BOOL AEFloatConverterFromFloatBufferList(AEFloatConverter* converter, AudioBufferList *sourceBuffer, AudioBufferList *targetBuffer, UInt32 frames) {
    float *sourceBuffers[sourceBuffer->mNumberBuffers];
    for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
        sourceBuffers[i] = (float*)sourceBuffer->mBuffers[i].mData;
    }
    return AEFloatConverterFromFloat(converter, sourceBuffers, targetBuffer, frames);
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