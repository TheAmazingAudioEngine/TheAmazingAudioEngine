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

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/'),__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s", file, line, operation, (int)result, (int)result, (char*)&result);
        return NO;
    }
    return YES;
}

#define                        kNoMoreDataErr                            -2222

static const UInt32 kMinimumAllowedConversionBlockSize = 64;

struct complexInputDataProc_t {
    AudioBufferList *sourceBuffer;
};

@interface AEFloatConverter () {
    AudioStreamBasicDescription _sourceAudioDescription;
    AudioStreamBasicDescription _floatAudioDescription;
    AudioConverterRef           _toFloatConverter;
    AudioConverterRef           _fromFloatConverter;
    AudioBufferList            *_scratchFloatBufferList;
    AudioBufferList            *_undersizeWorkaroundBuffer;
    AudioBufferList            *_undersizeWorkaroundFloatBuffer;
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
        _scratchFloatBufferList = (AudioBufferList*)malloc(sizeof(AudioBufferList) + (_floatAudioDescription.mChannelsPerFrame-1)*sizeof(AudioBuffer));
        _scratchFloatBufferList->mNumberBuffers = _floatAudioDescription.mChannelsPerFrame;
        for ( int i=0; i<_scratchFloatBufferList->mNumberBuffers; i++ ) {
            _scratchFloatBufferList->mBuffers[i].mNumberChannels = 1;
        }
        
        int numberOfSourceBuffers = sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? sourceFormat.mChannelsPerFrame : 1;
        int channelsPerSourceBuffer = sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : sourceFormat.mChannelsPerFrame;
        _undersizeWorkaroundBuffer = (AudioBufferList*)malloc(sizeof(AudioBufferList) + (numberOfSourceBuffers-1)*sizeof(AudioBuffer));
        _undersizeWorkaroundBuffer->mNumberBuffers = numberOfSourceBuffers;
        for ( int i=0; i<_undersizeWorkaroundBuffer->mNumberBuffers; i++ ) {
            _undersizeWorkaroundBuffer->mBuffers[i].mData = malloc(sourceFormat.mBytesPerFrame * kMinimumAllowedConversionBlockSize);
            _undersizeWorkaroundBuffer->mBuffers[i].mNumberChannels = channelsPerSourceBuffer;
        }
        
        _undersizeWorkaroundFloatBuffer = (AudioBufferList*)malloc(sizeof(AudioBufferList) + (_floatAudioDescription.mChannelsPerFrame-1)*sizeof(AudioBuffer));
        _undersizeWorkaroundFloatBuffer->mNumberBuffers = _floatAudioDescription.mChannelsPerFrame;
        for ( int i=0; i<_undersizeWorkaroundFloatBuffer->mNumberBuffers; i++ ) {
            _undersizeWorkaroundFloatBuffer->mBuffers[i].mData = malloc(_floatAudioDescription.mBytesPerFrame * kMinimumAllowedConversionBlockSize);
            _undersizeWorkaroundFloatBuffer->mBuffers[i].mNumberChannels = 1;
        }
    }
    
    return self;
}

-(void)dealloc {
    if ( _toFloatConverter ) AudioConverterDispose(_toFloatConverter);
    if ( _fromFloatConverter ) AudioConverterDispose(_fromFloatConverter);
    if ( _scratchFloatBufferList ) free(_scratchFloatBufferList);
    if ( _undersizeWorkaroundBuffer ) {
        for ( int i=0; i<_undersizeWorkaroundBuffer->mNumberBuffers; i++ ) {
            free(_undersizeWorkaroundBuffer->mBuffers[i].mData);
        }
        free(_undersizeWorkaroundBuffer);
    }
    if ( _undersizeWorkaroundFloatBuffer ) {
        for ( int i=0; i<_undersizeWorkaroundFloatBuffer->mNumberBuffers; i++ ) {
            free(_undersizeWorkaroundFloatBuffer->mBuffers[i].mData);
        }
        free(_undersizeWorkaroundFloatBuffer);
    }
    [super dealloc];
}


BOOL AEFloatConverterToFloat(AEFloatConverter* THIS, AudioBufferList *sourceBuffer, float * const * targetBuffers, UInt32 frames) {
    if ( frames == 0 ) return YES;
    
    if ( THIS->_toFloatConverter ) {
        for ( int i=0; i<sourceBuffer->mNumberBuffers; i++ ) {
            sourceBuffer->mBuffers[i].mDataByteSize = frames * THIS->_sourceAudioDescription.mBytesPerFrame;
        }
        
        for ( int i=0; i<THIS->_scratchFloatBufferList->mNumberBuffers; i++ ) {
            THIS->_scratchFloatBufferList->mBuffers[i].mData = targetBuffers[i];
            THIS->_scratchFloatBufferList->mBuffers[i].mDataByteSize = frames * sizeof(float);
        }
        
        UInt32 originalFrameCount = frames;
        
        if ( frames < kMinimumAllowedConversionBlockSize ) {
            // Workaround for limitation in audio converter that seems to disallow block sizes < 64 frames
            // Provide our own buffers, of 64 frames
            for ( int i=0; i<THIS->_undersizeWorkaroundBuffer->mNumberBuffers; i++ ) {
                THIS->_undersizeWorkaroundBuffer->mBuffers[i].mDataByteSize = kMinimumAllowedConversionBlockSize * THIS->_sourceAudioDescription.mBytesPerFrame;
                memset(THIS->_undersizeWorkaroundBuffer->mBuffers[i].mData, 0, THIS->_undersizeWorkaroundBuffer->mBuffers[i].mDataByteSize);
                memcpy(THIS->_undersizeWorkaroundBuffer->mBuffers[i].mData, sourceBuffer->mBuffers[i].mData, frames * THIS->_sourceAudioDescription.mBytesPerFrame);
            }
            
            for ( int i=0; i<THIS->_scratchFloatBufferList->mNumberBuffers; i++ ) {
                THIS->_scratchFloatBufferList->mBuffers[i].mDataByteSize = kMinimumAllowedConversionBlockSize * THIS->_floatAudioDescription.mBytesPerFrame;
                THIS->_scratchFloatBufferList->mBuffers[i].mData = THIS->_undersizeWorkaroundFloatBuffer->mBuffers[i].mData;
            }
            
            sourceBuffer = THIS->_undersizeWorkaroundBuffer;
            frames = kMinimumAllowedConversionBlockSize;
        }
        
        OSStatus result = AudioConverterFillComplexBuffer(THIS->_toFloatConverter,
                                                          complexInputDataProc,
                                                          &(struct complexInputDataProc_t) { .sourceBuffer = sourceBuffer },
                                                          &frames,
                                                          THIS->_scratchFloatBufferList,
                                                          NULL);
        
        if ( !checkResult(result, "AudioConverterConvertComplexBuffer") ) {
            return NO;
        }
        
        if ( originalFrameCount < kMinimumAllowedConversionBlockSize ) {
            for ( int i=0; i<THIS->_scratchFloatBufferList->mNumberBuffers; i++ ) {
                memcpy(targetBuffers[i], THIS->_scratchFloatBufferList->mBuffers[i].mData, originalFrameCount * THIS->_sourceAudioDescription.mBytesPerFrame);
            }
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
    if ( frames == 0 ) return YES;
    
    for ( int i=0; i<targetBuffer->mNumberBuffers; i++ ) {
        targetBuffer->mBuffers[i].mDataByteSize = frames * THIS->_sourceAudioDescription.mBytesPerFrame;
    }
    
    if ( THIS->_fromFloatConverter ) {
        for ( int i=0; i<THIS->_scratchFloatBufferList->mNumberBuffers; i++ ) {
            THIS->_scratchFloatBufferList->mBuffers[i].mData = sourceBuffers[i];
            THIS->_scratchFloatBufferList->mBuffers[i].mDataByteSize = frames * sizeof(float);
        }
        
        UInt32 originalFrameCount = frames;
        AudioBufferList *originalTargetBuffer = targetBuffer;
        
        if ( frames < kMinimumAllowedConversionBlockSize ) {
            // Workaround for limitation in audio converter that seems to disallow block sizes < 64 frames
            // Provide our own buffers, of 64 frames
            for ( int i=0; i<THIS->_scratchFloatBufferList->mNumberBuffers; i++ ) {
                THIS->_scratchFloatBufferList->mBuffers[i].mDataByteSize = kMinimumAllowedConversionBlockSize * THIS->_floatAudioDescription.mBytesPerFrame;
                THIS->_scratchFloatBufferList->mBuffers[i].mData = THIS->_undersizeWorkaroundFloatBuffer->mBuffers[i].mData;
                memset(THIS->_scratchFloatBufferList->mBuffers[i].mData, 0, THIS->_scratchFloatBufferList->mBuffers[i].mDataByteSize);
                memcpy(THIS->_scratchFloatBufferList->mBuffers[i].mData, sourceBuffers[i], frames * THIS->_floatAudioDescription.mBytesPerFrame);
            }
            
            for ( int i=0; i<THIS->_undersizeWorkaroundBuffer->mNumberBuffers; i++ ) {
                THIS->_undersizeWorkaroundBuffer->mBuffers[i].mDataByteSize = kMinimumAllowedConversionBlockSize * THIS->_sourceAudioDescription.mBytesPerFrame;
            }
            
            targetBuffer = THIS->_undersizeWorkaroundBuffer;
            frames = kMinimumAllowedConversionBlockSize;
        }
        
        OSStatus result = AudioConverterFillComplexBuffer(THIS->_fromFloatConverter,
                                                          complexInputDataProc,
                                                          &(struct complexInputDataProc_t) { .sourceBuffer = THIS->_scratchFloatBufferList },
                                                          &frames,
                                                          targetBuffer,
                                                          NULL);
        if ( !checkResult(result, "AudioConverterConvertComplexBuffer") ) {
            return NO;
        }
        
        if ( originalFrameCount < kMinimumAllowedConversionBlockSize ) {
            for ( int i=0; i<THIS->_undersizeWorkaroundBuffer->mNumberBuffers; i++ ) {
                memcpy(originalTargetBuffer->mBuffers[i].mData, THIS->_undersizeWorkaroundBuffer->mBuffers[i].mData, originalFrameCount * THIS->_sourceAudioDescription.mBytesPerFrame);
            }
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