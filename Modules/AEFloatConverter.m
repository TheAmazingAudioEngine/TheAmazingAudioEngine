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

    AudioStreamBasicDescription floatAudioDescription;
    floatAudioDescription.mFormatID          = kAudioFormatLinearPCM;
    floatAudioDescription.mFormatFlags       = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    floatAudioDescription.mChannelsPerFrame  = 2;
    floatAudioDescription.mBytesPerPacket    = sizeof(float);
    floatAudioDescription.mFramesPerPacket   = 1;
    floatAudioDescription.mBytesPerFrame     = sizeof(float);
    floatAudioDescription.mBitsPerChannel    = 8 * sizeof(float);
    floatAudioDescription.mSampleRate        = sourceFormat.mSampleRate;
    
    memcpy(&_sourceAudioDescription, &sourceFormat, sizeof(AudioStreamBasicDescription));
    
    if ( memcmp(&sourceFormat, &floatAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
        checkResult(AudioConverterNew(&sourceFormat, &floatAudioDescription, &_toFloatConverter), "AudioConverterNew");
        checkResult(AudioConverterNew(&floatAudioDescription, &sourceFormat, &_fromFloatConverter), "AudioConverterNew");
        _scratchBufferList = (AudioBufferList*)malloc(sizeof(AudioBufferList) + (floatAudioDescription.mChannelsPerFrame-1)*sizeof(AudioBuffer));
        _scratchBufferList->mNumberBuffers = floatAudioDescription.mChannelsPerFrame;
        _scratchBufferList->mBuffers[0].mNumberChannels = _scratchBufferList->mBuffers[1].mNumberChannels = 1;
    }
    
    return self;
}

-(void)dealloc {
    if ( _toFloatConverter ) AudioConverterDispose(_toFloatConverter);
    if ( _fromFloatConverter ) AudioConverterDispose(_fromFloatConverter);
    if ( _scratchBufferList ) free(_scratchBufferList);
    [super dealloc];
}


BOOL AEFloatConverterToFloat(AEFloatConverter* THIS, AudioBufferList *sourceBuffer, float* targetBuffers[2], UInt32 frames) {
    if ( THIS->_toFloatConverter ) {
        UInt32 originalBufferSize = sourceBuffer->mBuffers[0].mDataByteSize;
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            sourceBuffer->mBuffers[i].mDataByteSize = frames * THIS->_sourceAudioDescription.mBytesPerFrame;
        }
        
        THIS->_scratchBufferList->mBuffers[0].mData = targetBuffers[0];
        THIS->_scratchBufferList->mBuffers[0].mDataByteSize = frames * sizeof(float);
        THIS->_scratchBufferList->mBuffers[1].mData = targetBuffers[1];
        THIS->_scratchBufferList->mBuffers[1].mDataByteSize = frames * sizeof(float);
        
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
        memcpy(targetBuffers[0], sourceBuffer->mBuffers[0].mData, frames * sizeof(float));
        memcpy(targetBuffers[1], sourceBuffer->mBuffers[1].mData, frames * sizeof(float));
    }
    
    return YES;
}

BOOL AEFloatConverterFromFloat(AEFloatConverter* THIS, float* sourceBuffers[2], AudioBufferList *targetBuffer, UInt32 frames) {
    for ( int i=0; i<targetBuffer->mNumberBuffers; i++ ) {
        targetBuffer->mBuffers[i].mDataByteSize = frames * THIS->_sourceAudioDescription.mBytesPerFrame;
    }
    
    if ( THIS->_fromFloatConverter ) {
        THIS->_scratchBufferList->mBuffers[0].mData = sourceBuffers[0];
        THIS->_scratchBufferList->mBuffers[0].mDataByteSize = frames * sizeof(float);
        THIS->_scratchBufferList->mBuffers[1].mData = sourceBuffers[1];
        THIS->_scratchBufferList->mBuffers[1].mDataByteSize = frames * sizeof(float);
        
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
        memcpy(targetBuffer->mBuffers[0].mData, sourceBuffers[0], frames * sizeof(float));
        memcpy(targetBuffer->mBuffers[1].mData, sourceBuffers[1], frames * sizeof(float));
    }
    
    return YES;
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

@end