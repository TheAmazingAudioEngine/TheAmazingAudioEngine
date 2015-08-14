//
//  AESampleRateConverter.m
//  TheAmazingAudioEngine
//
//  Created by Steve Rubin on 8/14/15.
//  Copyright (c) 2015 A Tasty Pixel. All rights reserved.
//

#import "AESampleRateConverter.h"

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
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

@interface AESampleRateConverter () {
    AudioStreamBasicDescription _sourceAudioDescription;
    AudioStreamBasicDescription _destAudioDescription;
    AudioConverterRef           _sampleRateConverter;
    AudioBufferList            *_scratchBufferList;
}

static OSStatus complexInputDataProc(AudioConverterRef             inAudioConverter,
                                     UInt32                        *ioNumberDataPackets,
                                     AudioBufferList               *ioData,
                                     AudioStreamPacketDescription  **outDataPacketDescription,
                                     void                          *inUserData);

@end

@implementation AESampleRateConverter

- (id)initWithSourceFormat:(AudioStreamBasicDescription)sourceFormat {
    if ( !(self = [super init]) ) return nil;
    
    self.sourceFormat = sourceFormat;
    
    return self;
}

-(void)setSourceFormat:(AudioStreamBasicDescription)sourceFormat {
    if ( !memcmp(&sourceFormat, &_sourceAudioDescription, sizeof(sourceFormat)) ) return;
    
    _sourceAudioDescription = sourceFormat;
    
    [self updateFormats];
}

- (void)setDestFormat:(AudioStreamBasicDescription)destFormat {
    if ( !memcmp(&destFormat, &_destAudioDescription, sizeof(destFormat)) ) return;
    
    _destAudioDescription = destFormat;
    
    [self updateFormats];
}

- (void)updateFormats {
    if ( _sampleRateConverter ) {
        AudioConverterDispose(_sampleRateConverter);
        _sampleRateConverter = NULL;
    }
    
    if ( _destAudioDescription.mSampleRate == 0 || _sourceAudioDescription.mSampleRate == 0 ) return;
    
    if ( memcmp(&_sourceAudioDescription, &_destAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
        checkResult(AudioConverterNew(&_sourceAudioDescription, &_destAudioDescription, &_sampleRateConverter), "AudioConverterNew");
        
        UInt32 primeMethod;
        primeMethod = kConverterPrimeMethod_None;
        checkResult(AudioConverterSetProperty(_sampleRateConverter, kAudioConverterPrimeMethod, sizeof(primeMethod), &primeMethod), "AudioConverterSetProperty(kAudioConverterPrimeMethod)");

        UInt32 quality = kAudioConverterQuality_Max;
        checkResult(AudioConverterSetProperty(_sampleRateConverter, kAudioConverterSampleRateConverterQuality, sizeof(quality), &quality), "AudioConverterSetProperty(kAudioConverterSampleRateConverterQuality)");
        
        UInt32 complexity = kAudioConverterSampleRateConverterComplexity_Mastering;
        checkResult(AudioConverterSetProperty(_sampleRateConverter, kAudioConverterSampleRateConverterComplexity, sizeof(complexity), &complexity), "AudioConverterSetProperty(kAudioConverterSampleRateConverterComplexity)");
        
        _scratchBufferList = (AudioBufferList*)malloc(sizeof(AudioBufferList) + (_sourceAudioDescription.mChannelsPerFrame-1)*sizeof(AudioBuffer));
        _scratchBufferList->mNumberBuffers = _sourceAudioDescription.mChannelsPerFrame;
        for ( int i=0; i<_scratchBufferList->mNumberBuffers; i++ ) {
            _scratchBufferList->mBuffers[i].mNumberChannels = 1;
        }
    }
}

BOOL AESampleRateConverterToBuffers(__unsafe_unretained AESampleRateConverter* THIS, AudioBufferList *sourceBuffer, float * const * targetBuffers, UInt32 inFrames, UInt32 *outFrames) {
    if ( inFrames == 0 ) return YES;
    
    if ( THIS->_sampleRateConverter ) {
        UInt32 priorDataByteSize = sourceBuffer->mBuffers[0].mDataByteSize;
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            sourceBuffer->mBuffers[i].mDataByteSize = inFrames * THIS->_sourceAudioDescription.mBytesPerFrame;
        }
        
        float rateMultiplier = THIS->_destAudioDescription.mSampleRate / THIS->_sourceAudioDescription.mSampleRate;
        *outFrames = (UInt32)(inFrames * rateMultiplier) + 1;
        
        for ( int i=0; i<THIS->_scratchBufferList->mNumberBuffers; i++ ) {
            THIS->_scratchBufferList->mBuffers[i].mData = targetBuffers[i];
            THIS->_scratchBufferList->mBuffers[i].mDataByteSize = *outFrames * sizeof(float);
        }
        
        OSStatus result = AudioConverterFillComplexBuffer(THIS->_sampleRateConverter,
                                                          complexInputDataProc,
                                                          &(struct complexInputDataProc_t) { .sourceBuffer = sourceBuffer },
                                                          &inFrames,
                                                          THIS->_scratchBufferList,
                                                          NULL);
        
        *outFrames = inFrames;
        
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            sourceBuffer->mBuffers[i].mDataByteSize = priorDataByteSize;
        }
        
        if ( result != kAudioConverterErr_InvalidInputSize && result != kNoMoreDataErr ) {
            if ( !checkResult(result, "AudioConverterConvertComplexBuffer") ) {
                return NO;
            }
        }
        
    } else {
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            memcpy(targetBuffers[i], sourceBuffer->mBuffers[i].mData, inFrames * sizeof(float));
        }
        *outFrames = inFrames;
    }
    
    return YES;
}

BOOL AESampleRateConverterToBufferList(__unsafe_unretained AESampleRateConverter* THIS, AudioBufferList *sourceBuffer, AudioBufferList *targetBuffer, UInt32 inFrames, UInt32 *outFrames) {
    assert(targetBuffer->mNumberBuffers == THIS->_sourceAudioDescription.mChannelsPerFrame);
    
    float *targetBuffers[targetBuffer->mNumberBuffers];
    for ( int i=0; i<targetBuffer->mNumberBuffers; i++ ) {
        targetBuffers[i] = (float*)targetBuffer->mBuffers[i].mData;
    }
    return AESampleRateConverterToBuffers(THIS, sourceBuffer, targetBuffers, inFrames, outFrames);
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
    
    // This prevents the kAudioConverterErr_InvalidInputSize error, but leads to other problems
//    *ioNumberDataPackets = ioData->mBuffers[0].mDataByteSize / sizeof(float);

    return noErr;
}

- (void)dealloc {
    if ( _sampleRateConverter ) AudioConverterDispose(_sampleRateConverter);
    if ( _scratchBufferList ) free(_scratchBufferList);
}

@end
