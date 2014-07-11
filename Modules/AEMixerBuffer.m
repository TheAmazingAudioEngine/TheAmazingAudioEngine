//
//  AEMixerBuffer.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 12/04/2012.
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

#import "AEMixerBuffer.h"
#import "TPCircularBuffer.h"
#import "TPCircularBuffer+AudioBufferList.h"
#import "AEFloatConverter.h"
#import <libkern/OSAtomic.h>
#import <mach/mach_time.h>
#import <Accelerate/Accelerate.h>
#import <pthread.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
        return NO;
    }
    return YES;
}

#ifdef DEBUG
#define dprintf(THIS, n, __FORMAT__, ...) {if ( THIS->_debugLevel >= (n) ) { printf("<AEMixerBuffer %p>: "__FORMAT__ "\n", THIS, ##__VA_ARGS__); }}
#else
#define dprintf(THIS, n, __FORMAT__, ...)
#endif

typedef struct {
    AEMixerBufferSource                     source;
    AEMixerBufferSourcePeekCallback         peekCallback;
    AEMixerBufferSourceRenderCallback       renderCallback;
    void                                   *callbackUserinfo;
    TPCircularBuffer                        buffer;
    uint64_t                                lastAudioTimestamp;
    BOOL                                    synced;
    UInt32                                  consumedFramesInCurrentTimeSlice;
    AudioStreamBasicDescription             audioDescription;
    void                                   *floatConverter;
    float                                   volume;
    float                                   pan;
    BOOL                                    started;
    AudioBufferList                        *skipFadeBuffer;
    BOOL                                    unregistering;
} source_t;

typedef void(*AEMixerBufferAction)(AEMixerBuffer *buffer, void *userInfo);

typedef struct {
    AEMixerBufferAction action;
    void *userInfo;
} action_t;

#define kMaxSources 30
static const NSTimeInterval kResyncTimestampThreshold       = 0.002;
static const NSTimeInterval kSourceTimestampIdleThreshold   = 1.0;
static const UInt32 kConversionBufferLength                 = 16384;
static const UInt32 kScratchBufferBytesPerChannel           = 16384;
static const UInt32 kSourceBufferFrames                     = 8192;
static const int kActionBufferSize                          = 2048;
static const NSTimeInterval kActionMainThreadPollDuration   = 0.2;
static const int kMinimumFrameCount                         = 64;
static const UInt32 kMaxMicrofadeDuration                   = 512;

@interface AEMixerBuffer () {
    AudioStreamBasicDescription _clientFormat;
    AudioStreamBasicDescription _mixerOutputFormat;
    source_t                    _table[kMaxSources];
    AudioTimeStamp              _currentSliceTimestamp;
    UInt32                      _sampleTime;
    UInt32                      _currentSliceFrameCount;
    AUGraph                     _graph;
    AUNode                      _mixerNode;
    AudioUnit                   _mixerUnit;
    AudioConverterRef           _audioConverter;
    TPCircularBuffer            _audioConverterBuffer;
    BOOL                        _audioConverterHasBuffer;
    uint8_t                    *_scratchBuffer;
    BOOL                        _graphReady;
    BOOL                        _automaticSingleSourceDequeueing;
    TPCircularBuffer            _mainThreadActionBuffer;
    NSTimer                    *_mainThreadActionPollTimer;
    float                      **_microfadeBuffer;
    int                          _configuredChannels;
}

static UInt32 _AEMixerBufferPeek(AEMixerBuffer *THIS, AudioTimeStamp *outNextTimestamp, BOOL respectInfiniteSourceFlag);
static inline source_t *sourceWithID(AEMixerBuffer *THIS, AEMixerBufferSource sourceID, int* index);
static inline void unregisterSources(AEMixerBuffer *THIS);
static void prepareNewSource(AEMixerBuffer *THIS, AEMixerBufferSource sourceID);
static void prepareSkipFadeBufferForSource(AEMixerBuffer *THIS, source_t* source);
- (void)refreshMixingGraph;

@property (nonatomic, strong) AEFloatConverter *floatConverter;
@end

@interface AEMixerBufferPollProxy : NSObject {
    AEMixerBuffer *_mixerBuffer;
}
- (id)initWithMixerBuffer:(AEMixerBuffer*)mixerBuffer;
@end

@implementation AEMixerBuffer
@synthesize sourceIdleThreshold = _sourceIdleThreshold;
@synthesize assumeInfiniteSources = _assumeInfiniteSources;
@synthesize floatConverter = _floatConverter;
@synthesize debugLevel = _debugLevel;

+(void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    __hostTicksToSeconds = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
    __secondsToHostTicks = 1.0 / __hostTicksToSeconds;
}

- (id)initWithClientFormat:(AudioStreamBasicDescription)clientFormat {
    if ( !(self = [super init]) ) return nil;
    
    self.clientFormat = clientFormat;
    
    _sourceIdleThreshold = kSourceTimestampIdleThreshold;
    TPCircularBufferInit(&_mainThreadActionBuffer, kActionBufferSize);
    _mainThreadActionPollTimer = [NSTimer scheduledTimerWithTimeInterval:kActionMainThreadPollDuration
                                                                  target:[[AEMixerBufferPollProxy alloc] initWithMixerBuffer:self]
                                                                selector:@selector(pollActionBuffer) 
                                                                userInfo:nil
                                                                 repeats:YES];
        
    return self;
}

- (void)dealloc {
    [_mainThreadActionPollTimer invalidate];
    TPCircularBufferCleanup(&_mainThreadActionBuffer);
    
    if ( _graph ) {
        checkResult(AUGraphClose(_graph), "AUGraphClose");
        checkResult(DisposeAUGraph(_graph), "AUGraphClose");
    }
    
    if ( _audioConverter ) {
        checkResult(AudioConverterDispose(_audioConverter), "AudioConverterDispose");
        _audioConverter = NULL;
        TPCircularBufferCleanup(&_audioConverterBuffer);
    }
    
    
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( _table[i].source ) {
            if ( !_table[i].renderCallback ) {
                TPCircularBufferCleanup(&_table[i].buffer);
            }
            if ( _table[i].skipFadeBuffer ) {
                for ( int j=0; j<_table[i].skipFadeBuffer->mNumberBuffers; j++ ) {
                    free(_table[i].skipFadeBuffer->mBuffers[j].mData);
                }
                free(_table[i].skipFadeBuffer);
            }
            if ( _table[i].floatConverter ) {
                CFBridgingRelease(_table[i].floatConverter);
            }
        }
    }
    
    free(_scratchBuffer);
    
    for ( int i=0; i<_configuredChannels * 2; i++ ) {
        free(_microfadeBuffer[i]);
    }
    free(_microfadeBuffer);
    
}

-(void)setClientFormat:(AudioStreamBasicDescription)clientFormat {
    if ( memcmp(&_clientFormat, &clientFormat, sizeof(AudioStreamBasicDescription)) == 0 ) return;
    
    _clientFormat = clientFormat;
    
    [self respondToChannelCountChange];
    
    self.floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:_clientFormat];
    
    for ( int i=0; i<kMaxSources; i++ ) {
        source_t *source = &_table[i];
        if ( source->source && !source->audioDescription.mSampleRate ) {
            if ( source->skipFadeBuffer ) {
                for ( int j=0; j<source->skipFadeBuffer->mNumberBuffers; j++ ) {
                    free(source->skipFadeBuffer->mBuffers[j].mData);
                }
                free(source->skipFadeBuffer);
            }
            
            prepareSkipFadeBufferForSource(self, source);
            
            if ( !source->renderCallback ) {
                TPCircularBufferClear(&source->buffer);
            }
        }
    }
    
    if ( _audioConverter ) {
        checkResult(AudioConverterDispose(_audioConverter), "AudioConverterDispose");
        _audioConverter = NULL;
        _audioConverterHasBuffer = NO;
        TPCircularBufferCleanup(&_audioConverterBuffer);
    }
    
    if ( _mixerUnit ) {
        // Try to set mixer's output stream format to our client format
        OSStatus result = AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_clientFormat, sizeof(_clientFormat));
        
        if ( result == kAudioUnitErr_FormatNotSupported ) {
            // The mixer only supports a subset of formats. If it doesn't support this one, then we'll convert manually
            
            // Get the existing format, and apply just the sample rate
            UInt32 size = sizeof(_mixerOutputFormat);
            checkResult(AudioUnitGetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_mixerOutputFormat, &size),
                        "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
            _mixerOutputFormat.mSampleRate = _clientFormat.mSampleRate;
            
            checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_mixerOutputFormat, sizeof(_mixerOutputFormat)),
                        "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat");
            
            
            
            // Create the audio converter
            checkResult(AudioConverterNew(&_mixerOutputFormat, &_clientFormat, &_audioConverter), "AudioConverterNew");
            TPCircularBufferInit(&_audioConverterBuffer, kConversionBufferLength);
        } else {
            checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        }
    }
    
    [self refreshMixingGraph];
}

void AEMixerBufferEnqueue(__unsafe_unretained AEMixerBuffer *THIS, AEMixerBufferSource sourceID, AudioBufferList *audio, UInt32 lengthInFrames, const AudioTimeStamp *timestamp) {
    dprintf(THIS, 1, "Enqueue %u frames at time %0.5lfs for source %p", (unsigned int)lengthInFrames, timestamp ? timestamp->mHostTime*__hostTicksToSeconds : 0, sourceID);
    source_t *source = sourceWithID(THIS, sourceID, NULL);
    if ( !source ) {
        if ( pthread_main_np() != 0 ) {
            dprintf(THIS, 3, "Preparing new source %p\n", sourceID);
            prepareNewSource(THIS, sourceID);
            source = sourceWithID(THIS, sourceID, NULL);
        } else {
            dprintf(THIS, 3, "Enqueueing prepare for new source %p", sourceID);
            action_t action = {.action = prepareNewSource, .userInfo = sourceID};
            TPCircularBufferProduceBytes(&THIS->_mainThreadActionBuffer, &action, sizeof(action));
            return;
        }
    }
    
    if ( !audio ) return;
    
    assert(!source->renderCallback);

    AudioStreamBasicDescription audioDescription = source->audioDescription.mSampleRate ? source->audioDescription : THIS->_clientFormat;
    if ( !TPCircularBufferCopyAudioBufferList(&source->buffer, audio, timestamp, lengthInFrames, &audioDescription) ) {
        dprintf(THIS, 0, "Out of buffer space");
    }
}

- (void)setRenderCallback:(AEMixerBufferSourceRenderCallback)renderCallback peekCallback:(AEMixerBufferSourcePeekCallback)peekCallback userInfo:(void *)userInfo forSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    
    if ( !source ) {
        source = sourceWithID(self, NULL, NULL);
        if ( !source ) return;
        memset(source, 0, sizeof(source_t));
        source->source = sourceID;
        source->volume = 1.0;
        source->pan = 0.0;
        source->lastAudioTimestamp = mach_absolute_time();
        prepareSkipFadeBufferForSource(self, source);
        [self refreshMixingGraph];
    } else {
        TPCircularBufferCleanup(&source->buffer);
    }
    
    source->renderCallback = renderCallback;
    source->peekCallback = peekCallback;
    source->callbackUserinfo = userInfo;
}

struct fillComplexBufferInputProc_t { AudioBufferList *bufferList; UInt32 frames;  };
static OSStatus fillComplexBufferInputProc(AudioConverterRef             inAudioConverter,
                                           UInt32                        *ioNumberDataPackets,
                                           AudioBufferList               *ioData,
                                           AudioStreamPacketDescription  **outDataPacketDescription,
                                           void                          *inUserData) {
    struct fillComplexBufferInputProc_t *arg = inUserData;
    for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
        ioData->mBuffers[i].mData = arg->bufferList->mBuffers[i].mData;
        ioData->mBuffers[i].mDataByteSize = arg->bufferList->mBuffers[i].mDataByteSize;
    }
    *ioNumberDataPackets = arg->frames;
    return noErr;
}

void AEMixerBufferDequeue(__unsafe_unretained AEMixerBuffer *THIS, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, AudioTimeStamp *outTimestamp) {
    dprintf(THIS, 1, "Dequeue %u frames", (unsigned int)*ioLengthInFrames);
    
    unregisterSources(THIS);
    
    if ( !THIS->_graphReady ) {
        *ioLengthInFrames = 0;
        return;
    }
    
    // If buffer list is provided with NULL mData pointers, use our own scratch buffer
    if ( bufferList && !bufferList->mBuffers[0].mData ) {
        *ioLengthInFrames = MIN(*ioLengthInFrames, kScratchBufferBytesPerChannel / (THIS->_clientFormat.mBitsPerChannel/8));
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mDataByteSize = kScratchBufferBytesPerChannel * bufferList->mBuffers[i].mNumberChannels;
            bufferList->mBuffers[i].mData = THIS->_scratchBuffer + i * bufferList->mBuffers[i].mDataByteSize;
        }
    }
    
    // Reset time slice
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) THIS->_table[i].consumedFramesInCurrentTimeSlice = 0;
    }
    
    // Determine how many frames are available globally
    UInt32 sliceFrameCount = _AEMixerBufferPeek(THIS, &THIS->_currentSliceTimestamp, YES);
    THIS->_currentSliceFrameCount = sliceFrameCount;
    
    if ( bufferList ) {
        *ioLengthInFrames = MIN(*ioLengthInFrames, bufferList->mBuffers[0].mDataByteSize / THIS->_clientFormat.mBytesPerFrame);
    }
    
    *ioLengthInFrames = MIN(*ioLengthInFrames, sliceFrameCount);
    
    if ( !bufferList ) {
        // Just consume frames
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source ) {
                AEMixerBufferDequeueSingleSource(THIS, THIS->_table[i].source, NULL, ioLengthInFrames, outTimestamp);
            }
        }
        
        // Reset time slice info
        THIS->_currentSliceFrameCount = 0;
        memset(&THIS->_currentSliceTimestamp, 0, sizeof(AudioTimeStamp));
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source ) THIS->_table[i].consumedFramesInCurrentTimeSlice = 0;
        }
        return;
    }
    
    int numberOfSources = 0;
    AEMixerBufferSource firstSource = NULL;
    source_t *firstSourceEntry = NULL;
    for ( int i=0; i<kMaxSources && numberOfSources < 2; i++ ) {
        if ( THIS->_table[i].source ) {
            if ( !firstSource ) {
                firstSource = THIS->_table[i].source;
                firstSourceEntry = &THIS->_table[i];
            }
            numberOfSources++;
        }
    }
    
    if ( outTimestamp ) {
        *outTimestamp = THIS->_currentSliceTimestamp;
    }
    
    if ( numberOfSources == 1 && (!firstSourceEntry->audioDescription.mSampleRate || memcmp(&firstSourceEntry->audioDescription, &THIS->_clientFormat, sizeof(AudioStreamBasicDescription)) == 0) ) {
        // Just one source, with the same audio format - pull straight from it
        AEMixerBufferDequeueSingleSource(THIS, firstSource, bufferList, ioLengthInFrames, NULL);
        
        // Reset time slice info
        THIS->_currentSliceFrameCount = 0;
        memset(&THIS->_currentSliceTimestamp, 0, sizeof(AudioTimeStamp));
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source ) THIS->_table[i].consumedFramesInCurrentTimeSlice = 0;
        }
        return;
    }
    
    // We'll advance the buffer list pointers as we add audio - save the original buffer list to restore later
    char savedBufferListSpace[sizeof(AudioBufferList)+(bufferList->mNumberBuffers-1)*sizeof(AudioBuffer)];
    AudioBufferList *savedBufferList = (AudioBufferList*)savedBufferListSpace;
    memcpy(savedBufferList, bufferList, sizeof(savedBufferListSpace));

    THIS->_automaticSingleSourceDequeueing = YES;
    int framesToGo = MIN(*ioLengthInFrames, bufferList->mBuffers[0].mDataByteSize / THIS->_clientFormat.mBytesPerFrame);
    
    // Process in small blocks so we don't overwhelm the mixer/converter buffers
    int blockSize = framesToGo;
    while ( blockSize > 512 ) blockSize /= 2;
    
    while ( framesToGo > 0 ) {
        
        UInt32 frames = MIN(framesToGo, blockSize);
        
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mDataByteSize = frames * THIS->_clientFormat.mBytesPerFrame;
        }
        
        AudioBufferList *intermediateBufferList = bufferList;
    
        if ( THIS->_audioConverter ) {
            // Initialise output buffer (to receive audio in mixer format)
            intermediateBufferList = TPCircularBufferPrepareEmptyAudioBufferListWithAudioFormat(&THIS->_audioConverterBuffer, &THIS->_mixerOutputFormat, frames, NULL);
            assert(intermediateBufferList != NULL);
            
            for ( int i=0; i<intermediateBufferList->mNumberBuffers; i++ ) {
                intermediateBufferList->mBuffers[i].mNumberChannels = THIS->_mixerOutputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : THIS->_mixerOutputFormat.mChannelsPerFrame;
            }
        }
        
        // Perform render
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp renderTimestamp;
        memset(&renderTimestamp, 0, sizeof(AudioTimeStamp));
        renderTimestamp.mSampleTime = THIS->_sampleTime;
        renderTimestamp.mFlags = kAudioTimeStampSampleTimeValid;
        OSStatus result = AudioUnitRender(THIS->_mixerUnit, &flags, &renderTimestamp, 0, frames, intermediateBufferList);
        if ( !checkResult(result, "AudioUnitRender") ) {
            break;
        }
        
        THIS->_currentSliceTimestamp.mSampleTime += frames;
        THIS->_currentSliceTimestamp.mHostTime += ((double)frames/THIS->_clientFormat.mSampleRate) * __secondsToHostTicks;
        THIS->_sampleTime += frames;
        THIS->_currentSliceFrameCount -= frames;
        
        if ( THIS->_audioConverter ) {
            // Convert output into client format
            OSStatus result = AudioConverterFillComplexBuffer(THIS->_audioConverter, 
                                                              fillComplexBufferInputProc, 
                                                              &(struct fillComplexBufferInputProc_t) { .bufferList = intermediateBufferList, .frames = frames }, 
                                                              &frames, 
                                                              bufferList, 
                                                              NULL);
            if ( !checkResult(result, "AudioConverterConvertComplexBuffer") ) {
                break;
            }
        }
        
        // Advance buffers
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mData = (uint8_t*)bufferList->mBuffers[i].mData + (frames * THIS->_clientFormat.mBytesPerFrame);
        }
        
        if ( frames == 0 ) break;
        
        framesToGo -= frames;
    }
    THIS->_automaticSingleSourceDequeueing = NO;
    
    *ioLengthInFrames -= framesToGo;
    
    // Reset time slice info
    THIS->_currentSliceFrameCount = 0;
    memset(&THIS->_currentSliceTimestamp, 0, sizeof(AudioTimeStamp));
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) THIS->_table[i].consumedFramesInCurrentTimeSlice = 0;
    }
    
    // Restore buffers
    memcpy(bufferList, savedBufferList, sizeof(savedBufferListSpace));
}


void AEMixerBufferDequeueSingleSource(__unsafe_unretained AEMixerBuffer *THIS, AEMixerBufferSource sourceID, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, AudioTimeStamp *outTimestamp) {
    source_t *source = sourceWithID(THIS, sourceID, NULL);
    
    dprintf(THIS, 1, "Dequeue %u frames from source %p", (unsigned int)*ioLengthInFrames, sourceID);
    
    AudioTimeStamp sliceTimestamp = THIS->_currentSliceTimestamp;
    UInt32 sliceFrameCount = THIS->_currentSliceFrameCount;
    
    if ( sliceTimestamp.mFlags == 0 || sliceFrameCount == 0 ) {
        // Determine how many frames are available globally
        sliceFrameCount = _AEMixerBufferPeek(THIS, &sliceTimestamp, YES);
        THIS->_currentSliceTimestamp = sliceTimestamp;
        THIS->_currentSliceFrameCount = sliceFrameCount;
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source ) THIS->_table[i].consumedFramesInCurrentTimeSlice = 0;
        }
    }
    
    AudioStreamBasicDescription audioDescription = source && source->audioDescription.mSampleRate ? source->audioDescription : THIS->_clientFormat;
        
    if ( outTimestamp ) {
        *outTimestamp = sliceTimestamp;
        if ( source ) {
            outTimestamp->mSampleTime += source->consumedFramesInCurrentTimeSlice;
            if ( outTimestamp->mFlags & kAudioTimeStampHostTimeValid ) {
                outTimestamp->mHostTime += ((double)source->consumedFramesInCurrentTimeSlice / audioDescription.mSampleRate) * __secondsToHostTicks;
            }
        }
    }
    
    *ioLengthInFrames = MIN(*ioLengthInFrames, sliceFrameCount - (source ? source->consumedFramesInCurrentTimeSlice : 0));

    // If buffer list is provided with NULL mData pointers, use our own scratch buffer
    if ( bufferList && !bufferList->mBuffers[0].mData ) {
        *ioLengthInFrames = MIN(*ioLengthInFrames, kScratchBufferBytesPerChannel / (audioDescription.mBitsPerChannel/8));
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mDataByteSize = kScratchBufferBytesPerChannel * bufferList->mBuffers[i].mNumberChannels;
            bufferList->mBuffers[i].mData = THIS->_scratchBuffer + i*bufferList->mBuffers[i].mDataByteSize;
        }
    }
    
    if ( bufferList ) {
        // Silence buffer list in advance
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            memset(bufferList->mBuffers[i].mData, 0, bufferList->mBuffers[i].mDataByteSize);
        }
    }
    
    if ( !source ) {
        return;
    }
    
    AudioTimeStamp sourceTimestamp;
    memset(&sourceTimestamp, 0, sizeof(sourceTimestamp));
    UInt32 sourceFrameCount = 0;
    
    if ( sliceFrameCount > 0 ) {
        // Now determine the frame count and timestamp on the current source
        if ( source->peekCallback ) {
            sourceFrameCount = source->peekCallback(source->source, &sourceTimestamp, source->callbackUserinfo);
            if ( sourceFrameCount == AEMixerBufferSourceInactive ) {
                dprintf(THIS, 3, "Source %p is inactive", source->source);
            } else {
                dprintf(THIS, 3, "Source %p: %u frames @ %0.5lfs", source->source, (unsigned int)sourceFrameCount, sourceTimestamp.mHostTime*__hostTicksToSeconds);
            }
            if ( sourceFrameCount != AEMixerBufferSourceInactive && THIS->_assumeInfiniteSources ) sourceFrameCount = UINT32_MAX;
            if ( sourceFrameCount == AEMixerBufferSourceInactive ) sourceFrameCount = 0;
            
        } else {
            sourceFrameCount = TPCircularBufferPeek(&source->buffer, &sourceTimestamp, &audioDescription);
            dprintf(THIS, 3, "Source %p: %u frames @ %0.5lfs", source->source, (unsigned int)sourceFrameCount, sourceTimestamp.mHostTime*__hostTicksToSeconds);
        }
    }
    
    if ( sourceFrameCount > 0 ) {
        int totalRequiredSkipFrames = 0;
        int skipFrames = 0;

        if ( sourceTimestamp.mFlags & kAudioTimeStampHostTimeValid
             && sliceTimestamp.mFlags & kAudioTimeStampHostTimeValid
             && sourceTimestamp.mHostTime < sliceTimestamp.mHostTime - ((!source->synced ? 0.001 : kResyncTimestampThreshold)*__secondsToHostTicks) ) {
            
            // This source is behind. We'll skip some frames.
            NSTimeInterval discrepancy = (sliceTimestamp.mHostTime - sourceTimestamp.mHostTime) * __hostTicksToSeconds;
            totalRequiredSkipFrames = discrepancy * audioDescription.mSampleRate;
            skipFrames = MIN(totalRequiredSkipFrames, sourceFrameCount > *ioLengthInFrames ? sourceFrameCount - *ioLengthInFrames : 0);
            
            dprintf(THIS, 3, "Need to skip %d frames, as source is %0.4lfs behind (will skip %d)", totalRequiredSkipFrames, discrepancy, skipFrames);
        } else {
            source->synced = YES;
            source->started = YES;
        }
        
        if ( skipFrames > 0 || source->skipFadeBuffer->mBuffers[0].mDataByteSize > 0 ) {
            UInt32 microfadeFrames = 0;
            if ( skipFrames > 0 && source->synced ) {
#ifdef DEBUG
                dprintf(THIS, 1, "Mixer buffer %p skipping %d frames of source %p due to %0.4lfs discrepancy (%0.4lf source, %0.4lf stream)\n",
                       THIS,
                       totalRequiredSkipFrames,
                       source->source, 
                       (sliceTimestamp.mHostTime - sourceTimestamp.mHostTime) * __hostTicksToSeconds,
                       sourceTimestamp.mHostTime * __hostTicksToSeconds,
                       sliceTimestamp.mHostTime * __hostTicksToSeconds);
#endif
                source->synced = NO;
            }
    
            if ( source->skipFadeBuffer->mBuffers[0].mDataByteSize > 0 ) {
                // We have some frames in the skip buffer, ready to crossfade
                microfadeFrames = MIN(*ioLengthInFrames, source->skipFadeBuffer->mBuffers[0].mDataByteSize / audioDescription.mBytesPerFrame);
            } else {
                // Take the first of the frames we're going to skip
                microfadeFrames = MIN(skipFrames, MIN(*ioLengthInFrames, kMaxMicrofadeDuration));
                for ( int i=0; i<source->skipFadeBuffer->mNumberBuffers; i++ ) {
                    source->skipFadeBuffer->mBuffers[i].mDataByteSize = audioDescription.mBytesPerFrame * microfadeFrames;
                }
                
                dprintf(THIS, 3, "Taking %u frames for microfade", (unsigned int)microfadeFrames);
                
                if ( source->renderCallback ) {
                    source->renderCallback(source->source, microfadeFrames, source->skipFadeBuffer, &sourceTimestamp, source->callbackUserinfo);
                } else {
                    TPCircularBufferDequeueBufferListFrames(&source->buffer, &microfadeFrames, source->skipFadeBuffer, NULL, &audioDescription);
                }
                
                sourceTimestamp.mSampleTime += microfadeFrames;
                sourceTimestamp.mHostTime += ((double)microfadeFrames / (double)source->audioDescription.mSampleRate) * __secondsToHostTicks;
                
                skipFrames -= microfadeFrames;
            }
            
            // Convert the audio to float
            if ( !AEFloatConverterToFloat(source->floatConverter ? (__bridge AEFloatConverter*)source->floatConverter : THIS->_floatConverter,
                                          source->skipFadeBuffer,
                                          THIS->_microfadeBuffer,
                                          microfadeFrames) ) {
                return;
            }
            
            // Apply fade out
            float start = 1.0;
            float step = -1.0 / (float)microfadeFrames;
            if ( audioDescription.mChannelsPerFrame == 2 ) {
                vDSP_vrampmul2(THIS->_microfadeBuffer[0], THIS->_microfadeBuffer[1], 1, &start, &step, THIS->_microfadeBuffer[0], THIS->_microfadeBuffer[1], 1, microfadeFrames);
            } else {
                for ( int i=0; i<audioDescription.mChannelsPerFrame; i++ ) {
                    start = 1.0;
                    vDSP_vrampmul(THIS->_microfadeBuffer[i], 1, &start, &step, THIS->_microfadeBuffer[i], 1, microfadeFrames);
                }
            }
            
            if ( skipFrames > 0 ) {
                // Throw away the rest
                dprintf(THIS, 3, "Discarding %d frames", skipFrames);
                UInt32 discardFrames = skipFrames;
                if ( source->renderCallback ) {
                    source->renderCallback(source->source, discardFrames, NULL, &sourceTimestamp, source->callbackUserinfo);
                } else {
                    TPCircularBufferDequeueBufferListFrames(&source->buffer, &discardFrames, NULL, NULL, &audioDescription);
                }
                
                sourceTimestamp.mSampleTime += discardFrames;
                sourceTimestamp.mHostTime += ((double)discardFrames / (double)source->audioDescription.mSampleRate) * __secondsToHostTicks;
            }
            
            for ( int i=0; i<source->skipFadeBuffer->mNumberBuffers; i++ ) {
                source->skipFadeBuffer->mBuffers[i].mDataByteSize = 0;
            }
            
            // Take the fresh audio
            UInt32 freshFrames = *ioLengthInFrames;
            dprintf(THIS, 3, "Dequeuing %u fresh frames", (unsigned int)freshFrames);
            if ( source->renderCallback ) {
                source->renderCallback(source->source, freshFrames, bufferList, &sourceTimestamp, source->callbackUserinfo);
            } else {
                TPCircularBufferDequeueBufferListFrames(&source->buffer, &freshFrames, bufferList, NULL, &audioDescription);
            }
            sourceTimestamp.mSampleTime += freshFrames;
            sourceTimestamp.mHostTime += ((double)freshFrames / (double)source->audioDescription.mSampleRate) * __secondsToHostTicks;
            
            microfadeFrames = MIN(microfadeFrames, freshFrames);
            
            if ( bufferList ) {
                // Convert the audio to float
                if ( !AEFloatConverterToFloat(source->floatConverter ? (__bridge AEFloatConverter*)source->floatConverter : THIS->_floatConverter,
                                              bufferList,
                                              THIS->_microfadeBuffer + audioDescription.mChannelsPerFrame,
                                              microfadeFrames) ) {
                    return;
                }
                
                // Apply fade in
                start = 0.0;
                step = 1.0 / (float)microfadeFrames;
                if ( audioDescription.mChannelsPerFrame == 2 ) {
                    vDSP_vrampmul2(THIS->_microfadeBuffer[2+0], THIS->_microfadeBuffer[2+1], 1, &start, &step, THIS->_microfadeBuffer[2+0], THIS->_microfadeBuffer[2+1], 1, microfadeFrames);
                } else {
                    for ( int i=0; i<audioDescription.mChannelsPerFrame; i++ ) {
                        start = 1.0;
                        vDSP_vrampmul(THIS->_microfadeBuffer[audioDescription.mChannelsPerFrame + i], 1, &start, &step, THIS->_microfadeBuffer[audioDescription.mChannelsPerFrame + i], 1, microfadeFrames);
                    }
                }
                
                // Add buffers together
                for ( int i=0; i<audioDescription.mChannelsPerFrame; i++ ) {
                    vDSP_vadd(THIS->_microfadeBuffer[i], 1, THIS->_microfadeBuffer[audioDescription.mChannelsPerFrame + i], 1, THIS->_microfadeBuffer[i], 1, microfadeFrames);
                }
                
                // Store in output
                if ( !AEFloatConverterFromFloat(source->floatConverter ? (__bridge AEFloatConverter*)source->floatConverter : THIS->_floatConverter,
                                                THIS->_microfadeBuffer,
                                                bufferList,
                                                microfadeFrames) ) {
                    return;
                }
            }
            
            if ( skipFrames > 0 && skipFrames == totalRequiredSkipFrames ) {
                // Now synced
                if ( source->started ) {
                    dprintf(THIS, 3, "Source %p synced", source->source);
                }
                source->synced = YES;
                source->started = YES;
            }
        } else {
            // Consume audio
            dprintf(THIS, 3, "Consuming %u frames", (unsigned int)*ioLengthInFrames);
            if ( source->renderCallback ) {
                source->renderCallback(source->source, *ioLengthInFrames, bufferList, &sourceTimestamp, source->callbackUserinfo);
            } else {
                TPCircularBufferDequeueBufferListFrames(&source->buffer, ioLengthInFrames, bufferList, NULL, &audioDescription);
            }
        }
    }
    
    if ( !THIS->_automaticSingleSourceDequeueing ) {
        // If we're pulling the sources individually...
        
        // Increment the consumed frame count for this source for the current time slice
        source->consumedFramesInCurrentTimeSlice += *ioLengthInFrames;
        
        // Determine the globally consumed frames
        int sourceCount  = 0;
        UInt32 minConsumedFrameCount = UINT32_MAX;
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source ) {
                sourceCount++;
                minConsumedFrameCount = MIN(minConsumedFrameCount, THIS->_table[i].consumedFramesInCurrentTimeSlice);
            }
        }
        
        if ( minConsumedFrameCount > 0 ) {
            dprintf(THIS, 3, "Increasing timeline by %u frames", (unsigned int)minConsumedFrameCount);
            
            // Increment time slice info
            THIS->_sampleTime += minConsumedFrameCount;
            THIS->_currentSliceFrameCount -= minConsumedFrameCount;
            THIS->_currentSliceTimestamp.mSampleTime += minConsumedFrameCount;
            THIS->_currentSliceTimestamp.mHostTime += ((double)minConsumedFrameCount/THIS->_clientFormat.mSampleRate) * __secondsToHostTicks;
            for ( int i=0; i<kMaxSources; i++ ) {
                if ( THIS->_table[i].source ) THIS->_table[i].consumedFramesInCurrentTimeSlice = 0;
            }
        }
    }
}

UInt32 AEMixerBufferPeek(__unsafe_unretained AEMixerBuffer *THIS, AudioTimeStamp *outNextTimestamp) {
    unregisterSources(THIS);
    return _AEMixerBufferPeek(THIS, outNextTimestamp, NO);
}

static UInt32 _AEMixerBufferPeek(__unsafe_unretained AEMixerBuffer *THIS, AudioTimeStamp *outNextTimestamp, BOOL respectInfiniteSourceFlag) {
    dprintf(THIS, 3, "Peeking");
    
    // Make sure we have at least one source
    BOOL hasSources = NO;
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) {
            hasSources = YES;
            break;
        }
    }
    
    if ( !hasSources ) {
        dprintf(THIS, 3, "No sources");
        if ( outNextTimestamp ) memset(outNextTimestamp, 0, sizeof(AudioTimeStamp));
        return 0;
    }
    
    // Clear time slice info
    THIS->_currentSliceFrameCount = 0;
    memset(&THIS->_currentSliceTimestamp, 0, sizeof(AudioTimeStamp));
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) THIS->_table[i].consumedFramesInCurrentTimeSlice = 0;
    }
    
    // Determine lowest buffer fill count, excluding drained sources that we aren't receiving from (for those, we'll return silence),
    // and address sources that are behind the timeline
    uint64_t now = mach_absolute_time();
    AudioTimeStamp earliestEndTimestamp = { .mHostTime = UINT64_MAX };
    AudioTimeStamp latestStartTimestamp = { .mHostTime = 0 };
    source_t *earliestEndSource = NULL;
    UInt32 minFrameCount = UINT32_MAX;
    BOOL hasActiveSources = NO;
    
    struct {
        source_t *source;
        uint64_t endHostTime;
        UInt32 frameCount;
        AudioTimeStamp timestamp; } peekEntries[kMaxSources];
    memset(&peekEntries, 0, sizeof(peekEntries));
    int peekEntriesCount = 0;
     
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) {
            source_t *source = &THIS->_table[i];
            
            AudioTimeStamp timestamp;
            memset(&timestamp, 0, sizeof(timestamp));
            UInt32 frameCount = 0;
            
            AudioStreamBasicDescription audioDescription = source->audioDescription.mSampleRate ? source->audioDescription : THIS->_clientFormat;
            
            if ( source->peekCallback ) {
                frameCount = source->peekCallback(source->source, &timestamp, source->callbackUserinfo);
                if ( frameCount != AEMixerBufferSourceInactive && respectInfiniteSourceFlag && THIS->_assumeInfiniteSources ) frameCount = UINT32_MAX;
            } else {
                frameCount = TPCircularBufferPeek(&source->buffer, &timestamp, &audioDescription);
            }
            
            if ( frameCount == AEMixerBufferSourceInactive ) {
                dprintf(THIS, 3, "Source %p is inactive", source->source);
            } else {
                dprintf(THIS, 3, "Source %p: %u frames @ %0.5lfs", source->source, (unsigned int)frameCount, timestamp.mHostTime*__hostTicksToSeconds);
            }
            
            if ( (frameCount == 0 && (now - source->lastAudioTimestamp) * __hostTicksToSeconds > THIS->_sourceIdleThreshold)
                    || frameCount == AEMixerBufferSourceInactive ) {
                
                // Not receiving audio - ignore this empty source
                dprintf(THIS, 3, "Skipping empty and idle source %p", source->source);
                continue;
            }
            
            if ( frameCount < minFrameCount ) minFrameCount = frameCount;
            source->lastAudioTimestamp = now;
            
            hasActiveSources = YES;
            
            if ( !(timestamp.mFlags & kAudioTimeStampHostTimeValid) ) {
                continue;
            }

            AudioTimeStamp endTimestamp = timestamp;
            endTimestamp.mHostTime = frameCount == UINT32_MAX ? UINT64_MAX : (UInt64)(endTimestamp.mHostTime + (((double)frameCount / audioDescription.mSampleRate) * __secondsToHostTicks));
            endTimestamp.mSampleTime = frameCount == UINT32_MAX ? UINT32_MAX : (endTimestamp.mSampleTime + frameCount);
            
            peekEntries[peekEntriesCount].source = source;
            peekEntries[peekEntriesCount].endHostTime = endTimestamp.mHostTime;
            peekEntries[peekEntriesCount].frameCount = frameCount;
            peekEntries[peekEntriesCount].timestamp = timestamp;
            peekEntriesCount++;
            
            if ( timestamp.mHostTime > latestStartTimestamp.mHostTime ) {
                latestStartTimestamp = timestamp;
            }
            if ( endTimestamp.mHostTime < earliestEndTimestamp.mHostTime ) {
                earliestEndTimestamp = endTimestamp;
                earliestEndSource = source;
            }
        }
    }
    
    if ( !hasActiveSources || minFrameCount == 0 ) {
        // No audio available
        dprintf(THIS, 3, "No audio available");
        if ( outNextTimestamp ) memset(outNextTimestamp, 0, sizeof(AudioTimeStamp));
        return 0;
    }
    
    unsigned long long latestStartFrames = latestStartTimestamp.mFlags & kAudioTimeStampHostTimeValid
                                            ? round((double)latestStartTimestamp.mHostTime * __hostTicksToSeconds * THIS->_clientFormat.mSampleRate)
                                            : 0;
    unsigned long long earliestEndFrames = earliestEndTimestamp.mFlags & kAudioTimeStampHostTimeValid
                                            ? round((double)earliestEndTimestamp.mHostTime * __hostTicksToSeconds * THIS->_clientFormat.mSampleRate)
                                            : minFrameCount;
    
    if ( earliestEndSource && latestStartFrames >= earliestEndFrames ) {
        // One or more of the sources is behind - skip all frames of these sources
        for ( int i=0; i<peekEntriesCount; i++ ) {
            unsigned long long sourceEndFrames = round((double)peekEntries[i].endHostTime * __hostTicksToSeconds * THIS->_clientFormat.mSampleRate);
            
            if ( latestStartFrames >= sourceEndFrames ) {
                
                #ifdef DEBUG
                dprintf(THIS, 1, "Mixer buffer %p skipping %u frames of source %p (ends %0.4lfs/%d frames before earliest source starts)",
                       THIS,
                       (unsigned int)peekEntries[i].frameCount,
                       peekEntries[i].source->source,
                       (latestStartTimestamp.mHostTime-peekEntries[i].endHostTime)*__hostTicksToSeconds,
                       (int)(latestStartFrames-sourceEndFrames));
                #endif
                
                UInt32 skipFrames = peekEntries[i].frameCount;
                AudioStreamBasicDescription sourceASBD = peekEntries[i].source->audioDescription.mSampleRate ? peekEntries[i].source->audioDescription : THIS->_clientFormat;
                
                if ( peekEntries[i].source->skipFadeBuffer->mBuffers[0].mDataByteSize == 0 ) {
                    // Take the first of the frames we're going to skip, to crossfade later
                    UInt32 microfadeFrames = MIN(peekEntries[i].frameCount, kMaxMicrofadeDuration);
                    skipFrames -= microfadeFrames;
                    
                    for ( int j=0; j<peekEntries[i].source->skipFadeBuffer->mNumberBuffers; j++ ) {
                        peekEntries[i].source->skipFadeBuffer->mBuffers[j].mDataByteSize = sourceASBD.mBytesPerFrame * microfadeFrames;
                    }
                    if ( peekEntries[i].source->renderCallback ) {
                        peekEntries[i].source->renderCallback(peekEntries[i].source->source, microfadeFrames, peekEntries[i].source->skipFadeBuffer, &peekEntries[i].timestamp, peekEntries[i].source->callbackUserinfo);
                    } else {
                        TPCircularBufferDequeueBufferListFrames(&peekEntries[i].source->buffer, &microfadeFrames, peekEntries[i].source->skipFadeBuffer, NULL, &sourceASBD);
                    }
                    peekEntries[i].timestamp.mSampleTime += microfadeFrames;
                    peekEntries[i].timestamp.mHostTime += ((double)microfadeFrames / (double)peekEntries[i].source->audioDescription.mSampleRate) * __secondsToHostTicks;
                }
                
                if ( skipFrames > 0 ) {
                    if ( peekEntries[i].source->renderCallback ) {
                        peekEntries[i].source->renderCallback(peekEntries[i].source->source, skipFrames, NULL, &peekEntries[i].timestamp, peekEntries[i].source->callbackUserinfo);
                    } else {
                        TPCircularBufferDequeueBufferListFrames(&peekEntries[i].source->buffer, &skipFrames, NULL, NULL, &sourceASBD);
                    }
                }
            }
        }
        
        if ( outNextTimestamp ) memset(outNextTimestamp, 0, sizeof(AudioTimeStamp));
        return 0;
    }
    
    UInt32 frameCount = (UInt32)(earliestEndFrames - latestStartFrames);
    int frameDiscrepancyThreshold = kResyncTimestampThreshold * THIS->_clientFormat.mSampleRate; // Account for small time discrepancies
    if ( frameCount > (minFrameCount >= frameDiscrepancyThreshold ? minFrameCount - frameDiscrepancyThreshold : minFrameCount) ) {
        frameCount = minFrameCount;
    }
    
    dprintf(THIS, 3, "%u frames available @ %0.5lfs", (unsigned int)frameCount, latestStartTimestamp.mHostTime*__hostTicksToSeconds);
    
    if ( frameCount < kMinimumFrameCount ) {
        dprintf(THIS, 3, "Less than minimum frame count");
        if ( outNextTimestamp ) memset(outNextTimestamp, 0, sizeof(AudioTimeStamp));
        return 0;
    }
    
    if ( outNextTimestamp ) {
        *outNextTimestamp = latestStartTimestamp;
        outNextTimestamp->mSampleTime = THIS->_sampleTime;
        outNextTimestamp->mFlags |= kAudioTimeStampSampleTimeValid;
    }
    return frameCount;
}


void AEMixerBufferEndTimeInterval(__unsafe_unretained AEMixerBuffer *THIS) {
    if ( THIS->_currentSliceFrameCount == 0 ) return;
    
    dprintf(THIS, 3, "End of time interval marked");
    
    // Determine the minimum consumed frames across those sources that have had frames consumed
    UInt32 minConsumedFrameCount = UINT32_MAX;
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source && THIS->_table[i].consumedFramesInCurrentTimeSlice != 0 ) {
            minConsumedFrameCount = MIN(minConsumedFrameCount, THIS->_table[i].consumedFramesInCurrentTimeSlice);
        }
    }
    
    // Discard audio of sources that haven't had frames consumed
    if ( minConsumedFrameCount > 0 ) {
        THIS->_automaticSingleSourceDequeueing = YES;
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source && THIS->_table[i].consumedFramesInCurrentTimeSlice == 0 ) {
                UInt32 frames = minConsumedFrameCount;
                dprintf(THIS, 3, "Discarding %u frames from source %p", (unsigned int)frames, THIS->_table[i].source);
                AEMixerBufferDequeueSingleSource(THIS, THIS->_table[i].source, NULL, &frames, NULL);
            }
        }
        THIS->_automaticSingleSourceDequeueing = NO;
        
        // Increment sample time
        THIS->_sampleTime += minConsumedFrameCount;
    }
    
    // Clear time slice info
    THIS->_currentSliceFrameCount = 0;
    memset(&THIS->_currentSliceTimestamp, 0, sizeof(AudioTimeStamp));
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) THIS->_table[i].consumedFramesInCurrentTimeSlice = 0;
    }
}

void AEMixerBufferMarkSourceIdle(__unsafe_unretained AEMixerBuffer *THIS, AEMixerBufferSource sourceID) {
    source_t *source = sourceWithID(THIS, sourceID, NULL);
    if ( source ) {
        dprintf(THIS, 3, "Marking source %p idle", sourceID);
        source->lastAudioTimestamp = 0;
        source->synced = NO;
    }
}

- (void)setAudioDescription:(AudioStreamBasicDescription)audioDescription forSource:(AEMixerBufferSource)sourceID {
    int index;
    source_t *source = sourceWithID(self, sourceID, &index);
    
    if ( !source ) {
        prepareNewSource(self, sourceID);
        source = sourceWithID(self, sourceID, &index);
    }
    
    source->audioDescription = audioDescription;
    
    if ( source->floatConverter ) {
        CFBridgingRelease(source->floatConverter);
        source->floatConverter = NULL;
    }
    
    if ( source->skipFadeBuffer ) {
        for ( int j=0; j<source->skipFadeBuffer->mNumberBuffers; j++ ) {
            free(source->skipFadeBuffer->mBuffers[j].mData);
        }
        free(source->skipFadeBuffer);
    }
    
    if ( source->audioDescription.mSampleRate && memcmp(&source->audioDescription, &self->_clientFormat, sizeof(AudioStreamBasicDescription)) != 0 ) {
        source->floatConverter = (__bridge_retained void*)[[AEFloatConverter alloc] initWithSourceFormat:source->audioDescription];
    }
    
    prepareSkipFadeBufferForSource(self, source);
    
    if ( !source->renderCallback ) {
        TPCircularBufferClear(&source->buffer);
        int bufferSize = kSourceBufferFrames * (source->audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? source->audioDescription.mBytesPerFrame * source->audioDescription.mChannelsPerFrame : source->audioDescription.mBytesPerFrame);
        if ( source->buffer.length != bufferSize ) {
            TPCircularBufferCleanup(&source->buffer);
            TPCircularBufferInit(&source->buffer, bufferSize);
        }
    }
    
    // Set input stream format
    checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, index, &source->audioDescription, sizeof(source->audioDescription)),
                "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
    
    [self respondToChannelCountChange];
}

- (void)setVolume:(float)volume forSource:(AEMixerBufferSource)sourceID {
    int index;
    source_t *source = sourceWithID(self, sourceID, &index);
    
    if ( !source ) {
        prepareNewSource(self, sourceID);
        source = sourceWithID(self, sourceID, &index);
    }
    
    source->volume = volume;
    
    // Set volume
    AudioUnitParameterValue value = source->volume;
    checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0),
                "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");

}

- (float)volumeForSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    if ( !source ) return 0.0;
    return source->volume;
}

- (void)setPan:(float)pan forSource:(AEMixerBufferSource)sourceID {
    int index;
    source_t *source = sourceWithID(self, sourceID, &index);
    
    if ( !source ) {
        prepareNewSource(self, sourceID);
        source = sourceWithID(self, sourceID, &index);
    }
    
    source->pan = pan;
    
    // Set pan
    AudioUnitParameterValue value = source->pan;
    if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
    if ( value == 1.0 ) value = 0.999;
    checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0),
                "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
}

- (float)panForSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    if ( !source ) return 0.0;
    return source->pan;
}

- (void)unregisterSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    if ( !source ) return;
    
    source->unregistering = YES;
    
    [self refreshMixingGraph];

    Boolean isInited = false;
    AUGraphIsInitialized(_graph, &isInited);
    if ( !isInited ) {
        source->source = NULL;
    } else {
        // Wait for render thread to mark source as unregistered
        int count=0;
        while ( source->source != NULL && count++ < 15 ) {
            [NSThread sleepForTimeInterval:0.001];
        }
        source->source = NULL;
    }
    
    if ( !source->renderCallback ) {
        TPCircularBufferCleanup(&source->buffer);
    }
    if ( source->skipFadeBuffer ) {
        for ( int j=0; j<source->skipFadeBuffer->mNumberBuffers; j++ ) {
            free(source->skipFadeBuffer->mBuffers[j].mData);
        }
        free(source->skipFadeBuffer);
    }
    
    memset(source, 0, sizeof(source_t));
}

static OSStatus sourceInputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    __unsafe_unretained AEMixerBuffer *THIS = (__bridge AEMixerBuffer*)inRefCon;
    
    for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
        memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
    }
    
    source_t *source = &THIS->_table[inBusNumber];
    
    if ( source->source ) {
        AEMixerBufferDequeueSingleSource(THIS, source->source, ioData, &inNumberFrames, NULL);
    }
    
    return noErr;
}

- (void)refreshMixingGraph {
    if ( !_graph ) {
        [self createMixingGraph];
    }
    
    // Set bus count
	UInt32 busCount = 0;
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( _table[i].source ) busCount++;
    }
    
    if ( !checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)),
                      "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // Configure each bus
    for ( int busNumber=0; busNumber<busCount; busNumber++ ) {
        source_t *source = &_table[busNumber];
        
        // Set input stream format
        checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, busNumber, source->audioDescription.mSampleRate ? &source->audioDescription : &_clientFormat, sizeof(AudioStreamBasicDescription)),
                    "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        
        // Set volume
        AudioUnitParameterValue value = source->volume;
        checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, busNumber, value, 0),
                    "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
        
        // Set pan
        value = source->pan;
        if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
        if ( value == 1.0 ) value = 0.999;
        checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, busNumber, value, 0),
                    "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
        
        // Set the render callback
        AURenderCallbackStruct rcbs;
        rcbs.inputProc = &sourceInputCallback;
        rcbs.inputProcRefCon = (__bridge void *)self;
        OSStatus result = AUGraphSetNodeInputCallback(_graph, _mixerNode, busNumber, &rcbs);
        if ( result != kAUGraphErr_InvalidConnection /* Ignore this error */ )
            checkResult(result, "AUGraphSetNodeInputCallback");
    }
    
    Boolean isInited = false;
    AUGraphIsInitialized(_graph, &isInited);
    if ( !isInited ) {
        checkResult(AUGraphInitialize(_graph), "AUGraphInitialize");
        
        OSMemoryBarrier();
        _graphReady = YES;
    } else {
        for ( int retries=3; retries > 0; retries-- ) {
            if ( checkResult(AUGraphUpdate(_graph, NULL), "AUGraphUpdate") ) {
                break;
            }
            [NSThread sleepForTimeInterval:0.01];
        }
    }
}

- (void)createMixingGraph {
    // Create a new AUGraph
	OSStatus result = NewAUGraph(&_graph);
    if ( !checkResult(result, "NewAUGraph") ) return;
    
    // Multichannel mixer unit
    AudioComponentDescription mixer_desc = {
        .componentType = kAudioUnitType_Mixer,
        .componentSubType = kAudioUnitSubType_MultiChannelMixer,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    // Add mixer node to graph
    result = AUGraphAddNode(_graph, &mixer_desc, &_mixerNode );
    if ( !checkResult(result, "AUGraphAddNode mixer") ) return;
    
    // Open the graph - AudioUnits are open but not initialized (no resource allocation occurs here)
	result = AUGraphOpen(_graph);
	if ( !checkResult(result, "AUGraphOpen") ) return;
    
    // Get reference to the audio unit
    result = AUGraphNodeInfo(_graph, _mixerNode, NULL, &_mixerUnit);
    if ( !checkResult(result, "AUGraphNodeInfo") ) return;
    
    // Set the audio unit to handle up to 4096 frames per slice to keep rendering during screen lock
    UInt32 maxFPS = 4096;
    checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)),
                "AudioUnitSetProperty(kAudioUnitProperty_MaximumFramesPerSlice)");
    
    // Try to set mixer's output stream format to our client format
    result = AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_clientFormat, sizeof(_clientFormat));
    
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The mixer only supports a subset of formats. If it doesn't support this one, then we'll convert manually
        
        // Get the existing format, and apply just the sample rate
        UInt32 size = sizeof(_mixerOutputFormat);
        checkResult(AudioUnitGetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_mixerOutputFormat, &size),
                    "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
        _mixerOutputFormat.mSampleRate = _clientFormat.mSampleRate;
        
        checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_mixerOutputFormat, sizeof(_mixerOutputFormat)), 
                    "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat");

        // Create the audio converter
        checkResult(AudioConverterNew(&_mixerOutputFormat, &_clientFormat, &_audioConverter), "AudioConverterNew");
        TPCircularBufferInit(&_audioConverterBuffer, kConversionBufferLength);
    } else {
        checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
    }
}

- (void)pollActionBuffer {
    while ( 1 ) {
        int32_t availableBytes;
        action_t *action = TPCircularBufferTail(&_mainThreadActionBuffer, &availableBytes);
        if ( !action ) break;
        action->action(self, action->userInfo);
        TPCircularBufferConsume(&_mainThreadActionBuffer, sizeof(action_t));
    }
}

- (void)respondToChannelCountChange {
    int maxChannelCount = _clientFormat.mChannelsPerFrame;
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( _table[i].source && _table[i].audioDescription.mSampleRate ) {
            maxChannelCount = MAX(maxChannelCount, _table[i].audioDescription.mChannelsPerFrame);
        }
    }
    
    if ( _configuredChannels != maxChannelCount ) {
        if ( _scratchBuffer ) {
            free(_scratchBuffer);
        }
        
        _scratchBuffer = (uint8_t*)malloc(kScratchBufferBytesPerChannel * maxChannelCount);
        assert(_scratchBuffer);
        
        if ( _microfadeBuffer ) {
            for ( int i=0; i<_configuredChannels * 2; i++ ) {
                free(_microfadeBuffer[i]);
            }
            free(_microfadeBuffer);
        }
        
        _microfadeBuffer = (float**)malloc(sizeof(float*) * maxChannelCount * 2);
        for ( int i=0; i<maxChannelCount * 2; i++ ) {
            _microfadeBuffer[i] = (float*)malloc(sizeof(float) * kMaxMicrofadeDuration);
            assert(_microfadeBuffer[i]);
        }
        
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( _table[i].source && !_table[i].renderCallback && !_table[i].audioDescription.mSampleRate ) {
                int bufferSize = kSourceBufferFrames * (_clientFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? _clientFormat.mBytesPerFrame * _clientFormat.mChannelsPerFrame : _clientFormat.mBytesPerFrame);
                if ( _table[i].buffer.length != bufferSize ) {
                    TPCircularBufferCleanup(&_table[i].buffer);
                    TPCircularBufferInit(&_table[i].buffer, bufferSize);
                } else {
                    TPCircularBufferClear(&_table[i].buffer);
                }
            }
        }
        
        _configuredChannels = maxChannelCount;
    }
}

static inline source_t *sourceWithID(__unsafe_unretained AEMixerBuffer *THIS, AEMixerBufferSource sourceID, int *index) {
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source == sourceID ) {
            if ( index ) *index = i;
            return &THIS->_table[i];
        }
    }
    return NULL;
}

static inline void unregisterSources(__unsafe_unretained AEMixerBuffer *THIS) {
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].unregistering ) {
            THIS->_table[i].source = NULL;
        }
    }
}

static void prepareNewSource(__unsafe_unretained AEMixerBuffer *THIS, AEMixerBufferSource sourceID) {
    if ( sourceWithID(THIS, sourceID, NULL) ) return;
    
    source_t *source = sourceWithID(THIS, NULL, NULL);
    if ( !source ) return;
    
    memset(source, 0, sizeof(source_t));
    source->volume = 1.0;
    source->pan = 0.0;
    source->lastAudioTimestamp = mach_absolute_time();
    prepareSkipFadeBufferForSource(THIS, source);
    
    int bufferSize = kSourceBufferFrames * (THIS->_clientFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? THIS->_clientFormat.mBytesPerFrame * THIS->_clientFormat.mChannelsPerFrame : THIS->_clientFormat.mBytesPerFrame);
    TPCircularBufferInit(&source->buffer, bufferSize);
    
    OSMemoryBarrier();
    source->source = sourceID;
    [THIS refreshMixingGraph];
}

static void prepareSkipFadeBufferForSource(__unsafe_unretained AEMixerBuffer *THIS, source_t* source) {
    AudioStreamBasicDescription audioDescription = source->audioDescription.mSampleRate ? source->audioDescription : THIS->_clientFormat;
    source->skipFadeBuffer = malloc(sizeof(AudioBufferList)+((audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? audioDescription.mChannelsPerFrame-1 : 0)*sizeof(AudioBuffer)));
    source->skipFadeBuffer->mNumberBuffers = audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? audioDescription.mChannelsPerFrame : 1;
    for ( int i=0; i<source->skipFadeBuffer->mNumberBuffers; i++ ) {
        source->skipFadeBuffer->mBuffers[i].mNumberChannels = audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : audioDescription.mChannelsPerFrame;
        source->skipFadeBuffer->mBuffers[i].mData = malloc(audioDescription.mBytesPerFrame * kMaxMicrofadeDuration);
        source->skipFadeBuffer->mBuffers[i].mDataByteSize = 0;
    }
}

@end


@implementation AEMixerBufferPollProxy
- (id)initWithMixerBuffer:(AEMixerBuffer*)mixerBuffer {
    if ( !(self = [super init]) ) return nil;
    _mixerBuffer = mixerBuffer;
    return self;
}
- (void)pollActionBuffer {
    [_mixerBuffer pollActionBuffer];
}
@end