//
//  AEAudioController.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 25/11/2011.
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

#import "AEAudioController.h"
#import "AEUtilities.h"
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#import <AVFoundation/AVFoundation.h>
#import <libkern/OSAtomic.h>
#import "TPCircularBuffer.h"
#include <sys/types.h>
#include <sys/sysctl.h>
#import <Accelerate/Accelerate.h>
#import "AEAudioController+Audiobus.h"
#import "AEAudioController+AudiobusStub.h"
#import "AEFloatConverter.h"
#import "AEBlockChannel.h"
#import <pthread.h>

// Uncomment the following or define the following symbol as part of your build process to enable per-second performance reports
// #define TAAE_REPORT_RENDER_TIME

static const int kMaximumChannelsPerGroup              = 100;
static const int kMaximumCallbacksPerSource            = 15;
static const int kMessageBufferLength                  = 8192;
static const UInt32 kMaxFramesPerSlice                 = 4096;
static const int kScratchBufferFrames                  = kMaxFramesPerSlice;
static const int kInputAudioBufferFrames               = kMaxFramesPerSlice;
static const int kLevelMonitorScratchBufferSize        = kMaxFramesPerSlice;
static const int kMaximumMonitoringChannels            = 16;
#if TARGET_OS_IPHONE
static const NSTimeInterval kMaxBufferDurationWithVPIO = 0.01;
static const float kBoostForBuiltInMicInMeasurementMode= 4.0;
static const Float32 kNoValue                          = -1.0;
#endif
#define kNoAudioErr                            -2222

static void * kChannelPropertyChanged = &kChannelPropertyChanged;

#if TARGET_OS_IPHONE
static Float32 __cachedInputLatency = kNoValue;
static Float32 __cachedOutputLatency = kNoValue;
#endif

static pthread_t __audioThread = NULL;

NSString * const AEAudioControllerSessionInterruptionBeganNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionBeganNotification";
NSString * const AEAudioControllerSessionInterruptionEndedNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionEndedNotification";
NSString * const AEAudioControllerSessionRouteChangeNotification = @"com.theamazingaudioengine.AEAudioControllerRouteChangeNotification";
NSString * const AEAudioControllerDidRecreateGraphNotification = @"com.theamazingaudioengine.AEAudioControllerDidRecreateGraphNotification";
NSString * const AEAudioControllerErrorOccurredNotification = @"com.theamazingaudioengine.AEAudioControllerErrorOccurredNotification";

NSString * const AEAudioControllerErrorKey = @"error";

NSString * const AEAudioControllerErrorDomain = @"com.theamazingaudioengine.errors";

const NSString *kAEAudioControllerCallbackKey = @"callback";
const NSString *kAEAudioControllerUserInfoKey = @"userinfo";

static inline int min(int a, int b) { return a>b ? b : a; }

static BOOL __AEAllocated = NO;

@interface NSError (AEAudioControllerAdditions)
+ (NSError*)audioControllerErrorWithMessage:(NSString*)message OSStatus:(OSStatus)status;
@end
@implementation NSError (AEAudioControllerAdditions)
+ (NSError*)audioControllerErrorWithMessage:(NSString*)message OSStatus:(OSStatus)status {
    int fourCC = CFSwapInt32HostToBig(status);
    return [NSError errorWithDomain:NSOSStatusErrorDomain
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (error %d/%4.4s)", message, (int)status, (char*)&fourCC]}];
}
@end

#pragma mark - Core types

enum {
    kFilterFlag               = 1<<0,
    kReceiverFlag             = 1<<1,
    kAudiobusSenderPortFlag   = 1<<3
};

/*!
 * Callback
 */
typedef struct __callback_t {
    void *callback;
    void *userInfo;
    uint8_t flags;
} callback_t;

/*!
 * Callback table
 */
typedef struct __callback_table_t {
    int count;
    callback_t callbacks[kMaximumCallbacksPerSource];
} callback_table_t;

/*!
 * Mulichannel input callback table
 */
typedef struct __input_callback_table_t {
    callback_table_t    callbacks;
    void               *channelMap;
    AudioStreamBasicDescription audioDescription;
    AudioBufferList    *audioBufferList;
    AudioConverterRef   audioConverter;
} input_callback_table_t;


/*!
 * Audio level monitoring data
 */
typedef struct __audio_level_monitor_t {
    BOOL                monitoringEnabled;
    double              meanAccumulator;
    double              chanMeanAccumulator[kMaximumMonitoringChannels];
    int                 meanBlockCount;
    int                 chanMeanBlockCount;
    float               chanPeak[kMaximumMonitoringChannels];
    float               chanAverage[kMaximumMonitoringChannels];
    float               peak;
    float               average;
    void                *floatConverter;
    AudioBufferList    *scratchBuffer;
    int                 channels;
    BOOL                reset;
} audio_level_monitor_t;

/*!
 * Source types
 */
typedef enum {
    kChannelTypeChannel,
    kChannelTypeGroup
} ChannelType;

/*!
 * Channel
 */
typedef struct __channel_t {
    ChannelType      type;
    void            *ptr;
    void            *object;
    AEChannelGroupRef parentGroup;
    BOOL             playing;
    float            volume;
    float            pan;
    BOOL             muted;
    AudioStreamBasicDescription audioDescription;
    callback_table_t callbacks;
    AudioTimeStamp   timeStamp;
    
    BOOL             setRenderNotification;
    
    void             *audioController;
    void             *audiobusSenderPort;
    void             *audiobusFloatConverter;
    AudioBufferList *audiobusScratchBuffer;
} channel_t, *AEChannelRef;

/*!
 * Channel group
 */
typedef struct _channel_group_t {
    AEChannelRef        channel;
    AUNode              mixerNode;
    AudioUnit           mixerAudioUnit;
    AEChannelRef        channels[kMaximumChannelsPerGroup];
    int                 channelCount;
    AUNode              converterNode;
    AudioUnit           converterUnit;
    audio_level_monitor_t level_monitor_data;
} channel_group_t;

/*!
 * Message queue
 */
@interface AEAudioControllerMessageQueue : AEMessageQueue
@property (nonatomic, weak) AEAudioController * audioController;
@end

#pragma mark -

@interface AEAudioControllerProxy : NSProxy
- (id)initWithAudioController:(AEAudioController*)audioController;
@property (nonatomic, weak) AEAudioController *audioController;
@end

@interface AEAudioController () {
    AUGraph             _audioGraph;
    AUNode              _ioNode;
    AudioUnit           _ioAudioUnit;
    BOOL                _started;
    BOOL                _interrupted;
    BOOL                _hardwareInputAvailable;
    BOOL                _hasSystemError;
#if !TARGET_OS_IPHONE
    AudioUnit           _iAudioUnit;
#endif
    
    AEChannelGroupRef   _topGroup;
    AEChannelRef        _topChannel;
    
    callback_table_t    _timingCallbacks;
    
    input_callback_table_t *_inputCallbacks;
    int                 _inputCallbackCount;
    AudioStreamBasicDescription _rawInputAudioDescription;
    AudioBufferList    *_inputAudioBufferList;
#if TARGET_OS_IPHONE
    AudioBufferList    *_inputAudioScratchBufferList;
    AEFloatConverter   *_inputAudioFloatConverter;
#endif
    UInt32              _lastAvailableInputFrames;
    AudioTimeStamp      _lastInputBusTimeStamp;
    AudioTimeStamp      _lastInputOrOutputBusTimeStamp;

    audio_level_monitor_t _inputLevelMonitorData;
    BOOL                _usingAudiobusInput;
    AEChannelRef        _channelBeingRendered;
    
    AudioBufferList    *_audiobusMonitorBuffer;

    BOOL                _useHardwareSampleRate;

#ifdef DEBUG
    uint64_t            _firstRenderTime;
    uint64_t            _lastReportTime;
    uint64_t            _renderStartTime[2];
    uint64_t            _renderDuration[2];
#endif
}

- (BOOL)mustUpdateVoiceProcessingSettings;
- (void)replaceIONode;
- (BOOL)updateInputDeviceStatus;

@property (nonatomic, assign, readwrite) NSTimeInterval currentBufferDuration;
@property (nonatomic, readwrite) BOOL inputEnabled;
@property (nonatomic, readwrite) BOOL outputEnabled;
@property (nonatomic, strong) NSError *lastError;
#if TARGET_OS_IPHONE
@property (nonatomic, strong) NSTimer *housekeepingTimer;
#endif
@property (nonatomic, strong) ABReceiverPort *audiobusReceiverPort;
@property (nonatomic, strong) ABFilterPort *audiobusFilterPort;
@property (nonatomic, strong) ABSenderPort *audiobusSenderPort;
@property (nonatomic, strong) AEBlockChannel *audiobusMonitorChannel;
@end

@implementation AEAudioController
#if TARGET_OS_IPHONE
@synthesize audioSessionCategory = _audioSessionCategory, audioUnit = _ioAudioUnit;
#endif
@dynamic running, inputGainAvailable, inputGain, audiobusSenderPort, inputAudioDescription, inputChannelSelection;

#pragma mark -
#pragma mark Input and render callbacks

struct fillComplexBufferInputProc_t { AudioBufferList *bufferList; UInt32 frames; UInt32 bytesPerFrame; };
static OSStatus fillComplexBufferInputProc(AudioConverterRef             inAudioConverter,
                                           UInt32                        *ioNumberDataPackets,
                                           AudioBufferList               *ioData,
                                           AudioStreamPacketDescription  **outDataPacketDescription,
                                           void                          *inUserData) {

    struct fillComplexBufferInputProc_t *arg = inUserData;
    
    UInt32 bytesToWrite = MIN(*ioNumberDataPackets * arg->bytesPerFrame, arg->bufferList->mBuffers[0].mDataByteSize);
    for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
        ioData->mBuffers[i].mData = arg->bufferList->mBuffers[i].mData;
        ioData->mBuffers[i].mDataByteSize = bytesToWrite;
    }
    *ioNumberDataPackets = bytesToWrite / arg->bytesPerFrame;
    return noErr;
}

typedef struct __channel_producer_arg_t {
    AEChannelRef channel;
    AudioTimeStamp timeStamp;
    AudioTimeStamp originalTimeStamp;
    AudioUnitRenderActionFlags *ioActionFlags;
    int nextFilterIndex;
} channel_producer_arg_t;

static OSStatus channelAudioProducer(void *userInfo, AudioBufferList *audio, UInt32 *frames) {
    channel_producer_arg_t *arg = (channel_producer_arg_t*)userInfo;
    AEChannelRef channel = arg->channel;
    
    OSStatus status = noErr;
    
    // See if there's another filter
    for ( int i=channel->callbacks.count-1, filterIndex=0; i>=0; i-- ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kFilterFlag ) {
            if ( filterIndex == arg->nextFilterIndex ) {
                // Run this filter
                channel_producer_arg_t filterArg = *arg;
                filterArg.nextFilterIndex = filterIndex+1;
                return ((AEAudioFilterCallback)callback->callback)((__bridge id)callback->userInfo, (__bridge AEAudioController *)channel->audioController, &channelAudioProducer, (void*)&filterArg, &arg->timeStamp, *frames, audio);
            }
            filterIndex++;
        }
    }

    for ( int i=0; i<audio->mNumberBuffers; i++ ) {
        memset(audio->mBuffers[i].mData, 0, audio->mBuffers[i].mDataByteSize);
    }
    
    if ( channel->type == kChannelTypeChannel ) {
        AEAudioRenderCallback callback = (AEAudioRenderCallback) channel->ptr;
        __unsafe_unretained id<AEAudioPlayable> channelObj = (__bridge id<AEAudioPlayable>) channel->object;
        
        status = callback(channelObj, (__bridge AEAudioController*)channel->audioController, &channel->timeStamp, *frames, audio);
        channel->timeStamp.mSampleTime += *frames;
        
    } else if ( channel->type == kChannelTypeGroup ) {
        AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
        
        // Tell mixer/mixer's converter unit to render into audio
        status = AudioUnitRender(group->converterUnit ? group->converterUnit : group->mixerAudioUnit, arg->ioActionFlags, &arg->originalTimeStamp, 0, *frames, audio);
        if ( !AECheckOSStatus(status, "AudioUnitRender") ) return status;
        
        if ( group->level_monitor_data.monitoringEnabled ) {
            performLevelMonitoring(&group->level_monitor_data, audio, *frames);
        }
        
        // Advance the sample time, to make sure we continue to render if we're called again with the same arguments
        arg->timeStamp.mSampleTime += *frames;
        arg->originalTimeStamp.mSampleTime += *frames;
    }
    
    return status;
}

static OSStatus renderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEChannelRef channel = (AEChannelRef)inRefCon;
    
    __unsafe_unretained AEAudioController * THIS = (__bridge AEAudioController*)channel->audioController;

    if ( channel == NULL || channel->ptr == NULL || !channel->playing ) {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        for ( int i=0; i<ioData->mNumberBuffers; i++ ) memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        return noErr;
    }
    
    AudioTimeStamp timestamp = *inTimeStamp;
#if TARGET_OS_IPHONE
    if ( THIS->_automaticLatencyManagement ) {
        // Adjust timestamp to factor in hardware output latency
        timestamp.mHostTime += AEHostTicksFromSeconds(AEAudioControllerOutputLatency(THIS));
    }
#endif
    
    if ( channel->timeStamp.mFlags == 0 ) {
        channel->timeStamp = timestamp;
    } else {
        channel->timeStamp.mHostTime = timestamp.mHostTime;
    }
    
    channel_producer_arg_t arg = {
        .channel = channel,
        .timeStamp = timestamp,
        .originalTimeStamp = *inTimeStamp,
        .ioActionFlags = ioActionFlags,
        .nextFilterIndex = 0
    };
    
    THIS->_channelBeingRendered = channel;
    
    OSStatus result = channelAudioProducer((void*)&arg, ioData, &inNumberFrames);
    
    handleCallbacksForChannel(channel, &timestamp, inNumberFrames, ioData);
    
    THIS->_channelBeingRendered = NULL;
    
    if ( channel->audiobusSenderPort && ABSenderPortIsConnected((__bridge id)channel->audiobusSenderPort) && channel->audiobusFloatConverter ) {
        // Convert the audio to float, and apply volume/pan if necessary
        if ( AEFloatConverterToFloatBufferList((__bridge AEFloatConverter*)channel->audiobusFloatConverter, ioData, channel->audiobusScratchBuffer, inNumberFrames) ) {
            if ( fabs(1.0 - channel->volume) > 0.01 || fabs(0.0 - channel->pan) > 0.01 ) {
                float volume = channel->volume;
                for ( int i=0; i<channel->audiobusScratchBuffer->mNumberBuffers; i++ ) {
                    float gain = (channel->audiobusScratchBuffer->mNumberBuffers == 2 ?
                                  i == 0 ? (channel->pan <= 0.0 ? 1.0 : (1.0-((channel->pan/2)+0.5))*2.0) :
                                  i == 1 ? (channel->pan >= 0.0 ? 1.0 : ((channel->pan/2)+0.5)*2.0) :
                                  1 : 1) * volume;
                    vDSP_vsmul(channel->audiobusScratchBuffer->mBuffers[i].mData, 1, &gain, channel->audiobusScratchBuffer->mBuffers[i].mData, 1, inNumberFrames);
                }
            }
        }
        
        // Send via Audiobus
        ABSenderPortSend((__bridge id)channel->audiobusSenderPort, channel->audiobusScratchBuffer, inNumberFrames, &timestamp);
        
        if ( !ABSenderPortIsMuted((__bridge id)channel->audiobusSenderPort)
                && upstreamChannelsMutedByAudiobus(channel)
                && THIS->_audiobusMonitorBuffer ) {
            
            // Mix with monitoring buffer, as we need to monitor this channel but an upstream channel is muted by Audiobus
            AudioBufferList *monitorBuffer = THIS->_audiobusMonitorBuffer;
            for ( int i=0; i<MIN(monitorBuffer->mNumberBuffers, channel->audiobusScratchBuffer->mNumberBuffers); i++ ) {
                vDSP_vadd((float*)monitorBuffer->mBuffers[i].mData, 1, (float*)channel->audiobusScratchBuffer->mBuffers[i].mData, 1, (float*)monitorBuffer->mBuffers[i].mData, 1, MIN(inNumberFrames, kMaxFramesPerSlice));
            }
        }
    }
    
    if ( channel->audiobusSenderPort && ABSenderPortIsMuted((__bridge id)channel->audiobusSenderPort) && !upstreamChannelsConnectedToAudiobus(channel) ) {
        // Silence output
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        for ( int i=0; i<ioData->mNumberBuffers; i++ ) memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
    }
    
    return result;
}

typedef struct __input_producer_arg_t {
    void *THIS;
    input_callback_table_t *table;
    AudioTimeStamp inTimeStamp;
    AudioUnitRenderActionFlags *ioActionFlags;
    int nextFilterIndex;
} input_producer_arg_t;

static OSStatus inputAudioProducer(void *userInfo, AudioBufferList *audio, UInt32 *frames) {
    input_producer_arg_t *arg = (input_producer_arg_t*)userInfo;
    __unsafe_unretained AEAudioController *THIS = (__bridge AEAudioController*)arg->THIS;
    
    // See if there's another filter
    for ( int i=arg->table->callbacks.count-1, filterIndex=0; i>=0; i-- ) {
        callback_t *callback = &arg->table->callbacks.callbacks[i];
        if ( callback->flags & kFilterFlag ) {
            if ( filterIndex == arg->nextFilterIndex ) {
                // Run this filter
                input_producer_arg_t filterArg = *arg;
                filterArg.nextFilterIndex = filterIndex+1;
                return ((AEAudioFilterCallback)callback->callback)((__bridge id)callback->userInfo, THIS, &inputAudioProducer, (void*)&filterArg, &arg->inTimeStamp, *frames, audio);
            }
            filterIndex++;
        }
    }
    
    if ( !THIS->_inputAudioBufferList ) {
        return noErr;
    }
    
    if ( arg->table->audioConverter ) {
        // Perform conversion
        assert(THIS->_inputAudioBufferList->mBuffers[0].mData && THIS->_inputAudioBufferList->mBuffers[0].mDataByteSize > 0);
        assert(audio->mBuffers[0].mData && audio->mBuffers[0].mDataByteSize > 0);
        
        UInt32 targetFrames = (UInt32)(arg->table->audioDescription.mSampleRate / THIS->_rawInputAudioDescription.mSampleRate * *frames);
        
        OSStatus result = AudioConverterFillComplexBuffer(arg->table->audioConverter,
                                                          fillComplexBufferInputProc,
                                                          &(struct fillComplexBufferInputProc_t) { .bufferList = THIS->_inputAudioBufferList, .frames = *frames, .bytesPerFrame = THIS->_rawInputAudioDescription.mBytesPerFrame },
                                                          &targetFrames,
                                                          audio,
                                                          NULL);
        *frames = targetFrames;
        AECheckOSStatus(result, "AudioConverterFillComplexBuffer");
    } else {
        for ( int i=0; i<audio->mNumberBuffers && i<THIS->_inputAudioBufferList->mNumberBuffers; i++ ) {
            audio->mBuffers[i].mDataByteSize = MIN(audio->mBuffers[i].mDataByteSize, THIS->_inputAudioBufferList->mBuffers[i].mDataByteSize);
            memcpy(audio->mBuffers[i].mData, THIS->_inputAudioBufferList->mBuffers[i].mData, audio->mBuffers[i].mDataByteSize);
        }
    }

    return noErr;
}

static OSStatus inputAvailableCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    __unsafe_unretained AEAudioController *THIS = (__bridge AEAudioController *)inRefCon;
    
    // Take note of frame count and timestamp, for use when we actually service the input
    THIS->_lastAvailableInputFrames = inNumberFrames;
    THIS->_lastInputBusTimeStamp = *inTimeStamp;
    
#if TARGET_OS_IPHONE
    if ( !THIS->_outputEnabled ) {
        // If output isn't enabled, service the input from here
        serviceAudioInput(THIS, NULL, inTimeStamp, THIS->_lastAvailableInputFrames);
    }
#else
    serviceAudioInput(THIS, NULL, inTimeStamp, THIS->_lastAvailableInputFrames);
#endif
    
    return noErr;
}

static OSStatus groupRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEChannelRef channel = (AEChannelRef)inRefCon;
    AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
    __unsafe_unretained AEAudioController * THIS = (__bridge AEAudioController*)channel->audioController;
    
    if ( !(*ioActionFlags & kAudioUnitRenderAction_PreRender) ) {
        // After render
        THIS->_channelBeingRendered = channel;
        
        handleCallbacksForChannel(channel, inTimeStamp, inNumberFrames, ioData);
        
        THIS->_channelBeingRendered = NULL;
        
        if ( group->level_monitor_data.monitoringEnabled ) {
            performLevelMonitoring(&group->level_monitor_data, ioData, inNumberFrames);
        }
    }
    
    return noErr;
}

static OSStatus topRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    __unsafe_unretained AEAudioController *THIS = (__bridge AEAudioController *)inRefCon;

    if ( !__audioThread ) {
        __audioThread = pthread_self();
    }
    
    if ( *ioActionFlags & kAudioUnitRenderAction_PreRender ) {
        // Before main render: First process messages
        AEMessageQueueProcessMessagesOnRealtimeThread(THIS->_messageQueue);
        
        // Service input
#if TARGET_OS_IPHONE
        if ( THIS->_inputEnabled ) {
            serviceAudioInput(THIS, inTimeStamp, &THIS->_lastInputBusTimeStamp, THIS->_lastAvailableInputFrames);
        }
#endif
        
        // Perform timing callbacks
        AudioTimeStamp timestamp = *inTimeStamp;
#if TARGET_OS_IPHONE
        if ( THIS->_automaticLatencyManagement ) {
            // Adjust timestamp to factor in hardware output latency
            timestamp.mHostTime += AEHostTicksFromSeconds(AEAudioControllerOutputLatency(THIS));
        }
#endif
        
        THIS->_lastInputOrOutputBusTimeStamp = timestamp;
        
        for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
            callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
            ((AEAudioTimingCallback)callback->callback)((__bridge id)callback->userInfo, THIS, &timestamp, inNumberFrames, AEAudioTimingContextOutput);
        }
    } else {
        // After render
        if ( THIS->_muteOutput ) {
            for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
                memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
            }
        }
    }
    
    return noErr;
}

static void serviceAudioInput(__unsafe_unretained AEAudioController * THIS, const AudioTimeStamp *outputBusTimeStamp, const AudioTimeStamp *inputBusTimeStamp, UInt32 inNumberFrames) {
    
    if ( !THIS->_inputAudioBufferList ) {
        // If we're not yet prepared to receive audio, skip for now
        return;
    }
    
#ifdef DEBUG
    if ( !THIS->_firstRenderTime ) THIS->_firstRenderTime = AECurrentTimeInHostTicks();
    THIS->_renderStartTime[1] = AECurrentTimeInHostTicks();
#endif
    
    AudioTimeStamp timestamp;
    
    BOOL useAudiobusReceiverPort = THIS->_audiobusReceiverPort && THIS->_usingAudiobusInput;
    if ( useAudiobusReceiverPort ) {
        // If Audiobus is connected, then serve Audiobus queue rather than serving system input queue
        timestamp = outputBusTimeStamp ? *outputBusTimeStamp : *inputBusTimeStamp;
        static Float64 __sampleTime = 0;
        ABReceiverPortReceive(THIS->_audiobusReceiverPort, nil, THIS->_inputAudioBufferList, inNumberFrames, &timestamp);
        timestamp.mSampleTime = __sampleTime;
#if TARGET_OS_IPHONE
        if ( outputBusTimeStamp && THIS->_automaticLatencyManagement ) {
            // Adjust timestamp to factor in hardware output latency. Note that we do this after
            // ABReceiverPortReceive, which needs an uncompensated audio timestamp
            timestamp.mHostTime += AEHostTicksFromSeconds(AEAudioControllerOutputLatency(THIS));
        }
#endif
        __sampleTime += inNumberFrames;
    } else {
        timestamp = *inputBusTimeStamp;
#if TARGET_OS_IPHONE
        if ( THIS->_automaticLatencyManagement ) {
            // Adjust timestamp to factor in hardware input latency
            timestamp.mHostTime -= AEHostTicksFromSeconds(AEAudioControllerInputLatency(THIS));
        }
#endif
    }
    
    THIS->_lastInputOrOutputBusTimeStamp = timestamp;
    
    for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
        callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
        ((AEAudioTimingCallback)callback->callback)((__bridge id)callback->userInfo, THIS, &timestamp, inNumberFrames, AEAudioTimingContextInput);
    }
    
    OSStatus result = noErr;
    
    // Render audio into buffer
    if ( !useAudiobusReceiverPort ) {
        UInt32 bytesPerBuffer = MIN(inNumberFrames, kInputAudioBufferFrames) * THIS->_rawInputAudioDescription.mBytesPerFrame;
        for ( int i=0; i<THIS->_inputAudioBufferList->mNumberBuffers; i++ ) {
            THIS->_inputAudioBufferList->mBuffers[i].mDataByteSize = bytesPerBuffer;
        }
        AudioUnitRenderActionFlags flags = 0;
#if TARGET_OS_IPHONE
        AudioUnit inputAudioUnit = THIS->_ioAudioUnit;
#else
        AudioUnit inputAudioUnit = THIS->_iAudioUnit;
#endif
        OSStatus err = AudioUnitRender(inputAudioUnit, &flags, &timestamp, 1, inNumberFrames, THIS->_inputAudioBufferList);
        if ( !AECheckOSStatus(err, "AudioUnitRender") ) {
            result = err;
        }
        
        if ( THIS->_inputAudioBufferList->mBuffers[0].mDataByteSize != bytesPerBuffer ) {
            UInt32 actualFrameCount = THIS->_inputAudioBufferList->mBuffers[0].mDataByteSize / THIS->_rawInputAudioDescription.mBytesPerFrame;
#ifdef DEBUG
            static BOOL reportedBufferMismatch = NO;
            if ( !reportedBufferMismatch ) {
                reportedBufferMismatch = YES;
                NSLog(@"TAAE: Mismatch between received input buffer size (%d frames) and reported frame count (%d).",
                      (int)actualFrameCount,
                      (int)inNumberFrames);
            }
#endif
            inNumberFrames = actualFrameCount;
        }
        
#if TARGET_OS_IPHONE
        if ( THIS->_recordingThroughDeviceMicrophone && THIS->_useMeasurementMode && THIS->_boostBuiltInMicGainInMeasurementMode
                && THIS->_inputAudioFloatConverter && THIS->_inputAudioScratchBufferList->mNumberBuffers == THIS->_rawInputAudioDescription.mChannelsPerFrame ) {
            // Boost input volume
            AEFloatConverterToFloatBufferList(THIS->_inputAudioFloatConverter, THIS->_inputAudioBufferList, THIS->_inputAudioScratchBufferList, inNumberFrames);
            for ( int i=0; i<THIS->_inputAudioScratchBufferList->mNumberBuffers; i++ ) {
                vDSP_vsmul(THIS->_inputAudioScratchBufferList->mBuffers[i].mData, 1, &kBoostForBuiltInMicInMeasurementMode, THIS->_inputAudioScratchBufferList->mBuffers[i].mData, 1, inNumberFrames);
            }
            AEFloatConverterFromFloatBufferList(THIS->_inputAudioFloatConverter, THIS->_inputAudioScratchBufferList, THIS->_inputAudioBufferList, inNumberFrames);
        }
#endif
    }
    
    if ( result == noErr && inNumberFrames == 0 ) {
        result = kNoAudioErr;
    }
    
    if ( result == noErr ) {
        for ( int tableIndex = 0; tableIndex < THIS->_inputCallbackCount; tableIndex++ ) {
            input_callback_table_t *table = &THIS->_inputCallbacks[tableIndex];
            
            if ( !table->audioBufferList || table->callbacks.count == 0 ) continue;
            
            input_producer_arg_t arg = {
                .THIS = (__bridge void*)THIS,
                .table = table,
                .inTimeStamp = timestamp,
                .ioActionFlags = 0,
                .nextFilterIndex = 0
            };
            
            for ( int i=0; i<table->audioBufferList->mNumberBuffers; i++ ) {
                table->audioBufferList->mBuffers[i].mDataByteSize = inNumberFrames * table->audioDescription.mBytesPerFrame;
            }
            
            result = inputAudioProducer((void*)&arg, table->audioBufferList, &inNumberFrames);
            
            // Pass audio to callbacks
            for ( int i=0; i<table->callbacks.count; i++ ) {
                callback_t *callback = &table->callbacks.callbacks[i];
                if ( !(callback->flags & kReceiverFlag) ) continue;
                
                ((AEAudioReceiverCallback)callback->callback)((__bridge id)callback->userInfo, THIS, AEAudioSourceInput, &timestamp, inNumberFrames, table->audioBufferList);
            }
        }
        
        // Perform input metering
        if ( THIS->_inputLevelMonitorData.monitoringEnabled ) {
            performLevelMonitoring(&THIS->_inputLevelMonitorData, THIS->_inputAudioBufferList, inNumberFrames);
        }
    }
    
    // Only do the pending messages here if our output isn't enabled
    if ( !THIS->_outputEnabled ) {
        AEMessageQueueProcessMessagesOnRealtimeThread(THIS->_messageQueue);
    }
    
#ifdef DEBUG
    uint64_t renderEndTime = AECurrentTimeInHostTicks();
    THIS->_renderDuration[1] = renderEndTime - THIS->_renderStartTime[1];
#endif
}

#ifdef DEBUG

// Performance monitoring in debug mode
static OSStatus ioUnitRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    __unsafe_unretained AEAudioController * THIS = (__bridge AEAudioController*)inRefCon;
    
    if ( inBusNumber == 0 && *ioActionFlags & kAudioUnitRenderAction_PreRender ) {
        // Remember the time we started rendering
        if ( !THIS->_firstRenderTime ) THIS->_firstRenderTime = AECurrentTimeInHostTicks();
        THIS->_renderStartTime[0] = AECurrentTimeInHostTicks();
        
    } else if ( inBusNumber == 0 && *ioActionFlags & kAudioUnitRenderAction_PostRender ) {
        // Calculate total render duration
        uint64_t renderEndTime = AECurrentTimeInHostTicks();
        THIS->_renderDuration[0] = renderEndTime - THIS->_renderStartTime[MIN(1, inBusNumber)];
        
        if ( THIS->_renderDuration[0] && (!THIS->_inputEnabled || THIS->_renderDuration[1]) ) {
            // Got render duration for all buses
            uint64_t duration = THIS->_renderDuration[0] + THIS->_renderDuration[1];
            THIS->_renderDuration[0] = THIS->_renderDuration[1] = THIS->_renderStartTime[0] = THIS->_renderStartTime[1] = 0;
            // Warn if total render takes longer than 50% of buffer duration (gives us a bit of headroom)
            NSTimeInterval threshold = THIS->_currentBufferDuration * 0.5;
            if ( duration >= AEHostTicksFromSeconds(threshold)
                    && (renderEndTime-THIS->_firstRenderTime) > AEHostTicksFromSeconds(10.0)
                    && (renderEndTime-THIS->_lastReportTime) > AEHostTicksFromSeconds(30.0) ) {
                NSTimeInterval durationSeconds = AESecondsFromHostTicks(duration);
                NSLog(@"TAAE: Warning: render took too long (%lfs, %0.2lf%% of budget). Expect glitches.",
                      durationSeconds, (durationSeconds/THIS->_currentBufferDuration) * 100.0);
                THIS->_lastReportTime = renderEndTime;
            }
        
#ifdef TAAE_REPORT_RENDER_TIME
            // Define the above symbol to report ongoing (max) render time every second
            static uint64_t max = 0;
            static uint64_t lastReport = 0;
            if ( duration > max ) {
                max = duration;
            }
            if ( renderEndTime > lastReport + AEHostTicksFromSeconds(1.0) ) {
                NSTimeInterval value = AESecondsFromHostTicks(max);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"TAAE: Render time %lfs, %0.2lf%% of budget)", value, (value/THIS->_currentBufferDuration)*100.0);
                });
                lastReport = renderEndTime;
                max = 0;
            }
#endif
        }
    }
    
    return noErr;
}

#endif

#pragma mark - Setup and start/stop

+ (AudioStreamBasicDescription)interleaved16BitStereoAudioDescription {
    return AEAudioStreamBasicDescriptionInterleaved16BitStereo;
}

+ (AudioStreamBasicDescription)nonInterleaved16BitStereoAudioDescription {
    return AEAudioStreamBasicDescriptionNonInterleaved16BitStereo;
}

+ (AudioStreamBasicDescription)nonInterleavedFloatStereoAudioDescription {
    return AEAudioStreamBasicDescriptionNonInterleavedFloatStereo;
}

+ (BOOL)voiceProcessingAvailable {
    // Determine platform name
    static NSString *platform = nil;
    if ( !platform ) {
        size_t size;
        sysctlbyname("hw.machine", NULL, &size, NULL, 0);
        char *machine = malloc(size);
        sysctlbyname("hw.machine", machine, &size, NULL, 0);
        platform = @(machine);
        free(machine);
    }
    
    // These devices aren't fast enough to do voice processing effectively
    NSArray *badDevices = @[@"iPhone1,1", @"iPhone1,2", @"iPhone2,1", @"iPod1,1", @"iPod2,1", @"iPod3,1"];
    return ![badDevices containsObject:platform];
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription {
    return [self initWithAudioDescription:audioDescription options:AEAudioControllerOptionDefaults];
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput {
    return [self initWithAudioDescription:audioDescription
                                  options:AEAudioControllerOptionDefaults
                                            | (enableInput ? AEAudioControllerOptionEnableInput : 0)];
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput useVoiceProcessing:(BOOL)useVoiceProcessing {
    return [self initWithAudioDescription:audioDescription
                                  options:AEAudioControllerOptionDefaults
                                            | (enableInput ? AEAudioControllerOptionEnableInput : 0)
                                            | (useVoiceProcessing ? AEAudioControllerOptionUseVoiceProcessing : 0)];
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput useVoiceProcessing:(BOOL)useVoiceProcessing outputEnabled:(BOOL)enableOutput {
    return [self initWithAudioDescription:audioDescription options:
        enableInput?           AEAudioControllerOptionEnableInput:0|
        useVoiceProcessing?    AEAudioControllerOptionUseVoiceProcessing:0|
        enableOutput?          AEAudioControllerOptionEnableOutput:0|
        enableOutput?          AEAudioControllerOptionAllowMixingWithOtherApps:0
    ];
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription options:(AEAudioControllerOptions)options {
    if ( !(self = [super init]) ) return nil;

    NSAssert([NSThread isMainThread], @"Should be initialized on the main thread");
    NSAssert(!__AEAllocated, @"You may only use one TAAE instance at a time");
    __AEAllocated = YES;
    
    NSAssert(audioDescription.mFormatID == kAudioFormatLinearPCM, @"Only linear PCM supported");

    BOOL enableInput            = options & AEAudioControllerOptionEnableInput;
    BOOL enableOutput           = options & AEAudioControllerOptionEnableOutput;
    
#if TARGET_OS_IPHONE
    _audioSessionCategory = enableInput ? (enableOutput ? AVAudioSessionCategoryPlayAndRecord : AVAudioSessionCategoryRecord) : AVAudioSessionCategoryPlayback;
    _allowMixingWithOtherApps = options & AEAudioControllerOptionAllowMixingWithOtherApps;
    _enableBluetoothInput = options & AEAudioControllerOptionEnableBluetoothInput;
    _voiceProcessingEnabled = options & AEAudioControllerOptionUseVoiceProcessing;
    _avoidMeasurementModeForBuiltInSpeaker = YES;
    _boostBuiltInMicGainInMeasurementMode = YES;
    _automaticLatencyManagement = YES;
#endif
    _audioDescription = audioDescription;
    _inputEnabled = enableInput;
    _outputEnabled = enableOutput;
    _masterOutputVolume = 1.0;
    _useHardwareSampleRate = options & AEAudioControllerOptionUseHardwareSampleRate;
    _inputMode = AEInputModeFixedAudioFormat;
    _voiceProcessingOnlyForSpeakerAndMicrophone = YES;
    _inputCallbacks = (input_callback_table_t*)calloc(sizeof(input_callback_table_t), 1);
    _inputCallbackCount = 1;
    
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
#endif
    
    if ( ABConnectionsChangedNotification ) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audiobusConnectionsChanged:) name:ABConnectionsChangedNotification object:nil];
    }

    _messageQueue = [[AEAudioControllerMessageQueue alloc] initWithMessageBufferLength:kMessageBufferLength];
    ((AEAudioControllerMessageQueue*)_messageQueue).audioController = self;

#if TARGET_OS_IPHONE
    // Register for notifications
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(interruptionNotification:) name:AVAudioSessionInterruptionNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioRouteChangeNotification:) name:AVAudioSessionRouteChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaServiceResetNotification:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    
    // Start housekeeping timer
    self.housekeepingTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:[[AEAudioControllerProxy alloc] initWithAudioController:self] selector:@selector(housekeeping) userInfo:nil repeats:YES];
#endif
    
    if ( ![self initAudioSession] || ![self setup] ) {
        _audioGraph = NULL;
    }
    
    return self;
}

- (BOOL)setAudioDescription:(AudioStreamBasicDescription)audioDescription error:(NSError**)error {
    
    if ( !memcmp(&_audioDescription, &audioDescription, sizeof(audioDescription))
#if TARGET_OS_IPHONE
        // if we only want to change preferredSampleRate, go through even if _audioDescription actually didn't change
        && (!_useHardwareSampleRate || audioDescription.mSampleRate == [AVAudioSession sharedInstance].preferredSampleRate)
#endif
        ) {
        return YES;
    }
    
    NSAssert([NSThread isMainThread], @"Should be executed on the main thread");
    
    return [self reinitializeWithChanges:^{
        [self willChangeValueForKey:@"audioDescription"];
        _audioDescription = audioDescription;
        [self didChangeValueForKey:@"audioDescription"];
    } error:error];
}

- (BOOL)setInputEnabled:(BOOL)inputEnabled error:(NSError**)error {
    if ( _inputEnabled == inputEnabled ) return YES;
    
    NSAssert([NSThread isMainThread], @"Should be executed on the main thread");
    
    return [self reinitializeWithChanges:^{
        self.inputEnabled = inputEnabled;
        
#if TARGET_OS_IPHONE
        [self setAudioSessionCategory:_inputEnabled
            ? (_outputEnabled ? AVAudioSessionCategoryPlayAndRecord : AVAudioSessionCategoryRecord)
            : AVAudioSessionCategoryPlayback];
#endif
        
    } error:error];
}

- (BOOL)setOutputEnabled:(BOOL)outputEnabled error:(NSError**)error {
    if ( _outputEnabled == outputEnabled ) return YES;
    
    NSAssert([NSThread isMainThread], @"Should be executed on the main thread");
    
    return [self reinitializeWithChanges:^{
        self.outputEnabled = outputEnabled;
        
#if TARGET_OS_IPHONE
        [self setAudioSessionCategory:_inputEnabled
            ? (_outputEnabled ? AVAudioSessionCategoryPlayAndRecord : AVAudioSessionCategoryRecord)
            : AVAudioSessionCategoryPlayback];
#endif
        
    } error:error];
}

- (BOOL)setAudioDescription:(AudioStreamBasicDescription)audioDescription
               inputEnabled:(BOOL)inputEnabled
              outputEnabled:(BOOL)outputEnabled
                      error:(NSError**)error {
    
    if ( !memcmp(&_audioDescription, &audioDescription, sizeof(audioDescription)) &&
        _inputEnabled == inputEnabled && _outputEnabled == outputEnabled ) return YES;
    
    NSAssert([NSThread isMainThread], @"Should be executed on the main thread");
    
    return [self reinitializeWithChanges:^{
        if ( memcmp(&_audioDescription, &audioDescription, sizeof(audioDescription)) ) {
            [self willChangeValueForKey:@"audioDescription"];
            _audioDescription = audioDescription;
            [self didChangeValueForKey:@"audioDescription"];
        }
        if ( _inputEnabled != inputEnabled ) {
            self.inputEnabled = inputEnabled;
        }
        if ( _outputEnabled != outputEnabled ) {
            self.outputEnabled = outputEnabled;
        }
        
#if TARGET_OS_IPHONE
        [self setAudioSessionCategory:_inputEnabled
            ? (_outputEnabled ? AVAudioSessionCategoryPlayAndRecord : AVAudioSessionCategoryRecord)
            : AVAudioSessionCategoryPlayback];
#endif
        
    } error:error];
    
}

- (void)dealloc {
    __AEAllocated = NO;
    
#if TARGET_OS_IPHONE
    [_housekeepingTimer invalidate];
    self.housekeepingTimer = nil;
#endif
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self stop];
    [self teardown];
    
    [self releaseResourcesForChannel:_topChannel];

    if ( _inputLevelMonitorData.scratchBuffer ) {
        AEAudioBufferListFree(_inputLevelMonitorData.scratchBuffer);
    }
    
    if ( _inputLevelMonitorData.floatConverter ) {
        CFBridgingRelease(_inputLevelMonitorData.floatConverter);
    }
    
    if ( _inputAudioBufferList ) {
        AEAudioBufferListFree(_inputAudioBufferList);
    }
    
#if TARGET_OS_IPHONE
    if ( _inputAudioScratchBufferList ) {
        AEAudioBufferListFree(_inputAudioScratchBufferList);
    }
#endif
    
    for ( int i=0; i<_inputCallbackCount; i++ ) {
        if ( _inputCallbacks[i].channelMap ) {
            CFBridgingRelease(_inputCallbacks[i].channelMap);
        }
    }
    free(_inputCallbacks);
    
    if ( _audiobusMonitorBuffer ) AEAudioBufferListFree(_audiobusMonitorBuffer);
}

-(BOOL)start:(NSError **)error {
    return [self start:error recoveringFromErrors:YES];
}

-(BOOL)start:(NSError**)error recoveringFromErrors:(BOOL)recoverFromErrors {
    OSStatus status;
    
    NSLog(@"TAAE: Starting Engine");
    
    if ( !_audioGraph ) {
        if ( error ) *error = _lastError;
        self.lastError = nil;
        return NO;
    }
    
#if TARGET_OS_IPHONE
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    if ( ![audioSession setActive:YES error:error] ) {
        return NO;
    }
    
    NSTimeInterval bufferDuration = audioSession.IOBufferDuration;
    if ( _currentBufferDuration != bufferDuration ) self.currentBufferDuration = bufferDuration;
    
    if ( _inputEnabled ) {
        __cachedInputLatency = audioSession.inputLatency;
    }
    if ( _outputEnabled ) {
        __cachedOutputLatency = audioSession.outputLatency;
    }
#else
    UInt32 bufferFrameSize;
    UInt32 sizeParam = sizeof(UInt32);
    AudioUnitGetProperty(_ioAudioUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &bufferFrameSize, &sizeParam);
    NSTimeInterval bufferDuration = (double)bufferFrameSize / (double)self.audioDescription.mSampleRate;
    if ( _currentBufferDuration != bufferDuration ) self.currentBufferDuration = bufferDuration;
#endif
    
    _interrupted = NO;
    
    [_messageQueue startPolling];
    
    __audioThread = NULL;
    
    @synchronized ( self ) {
        status = AUGraphStart(_audioGraph);
#if !TARGET_OS_IPHONE
        if (_inputEnabled) {
            AECheckOSStatus(AudioOutputUnitStart(_iAudioUnit), "AudioOutputUnitStart (OSX input)");
        }
#endif
    }
    
    // Start things up
    if ( !AECheckOSStatus(status, "AUGraphStart") ) {
        if ( !recoverFromErrors || ![self attemptRecoveryFromSystemError:error thenStart:YES] ) {
            NSError *startError = [NSError audioControllerErrorWithMessage:@"Couldn't start audio engine" OSStatus:status];
            if ( error && !*error ) *error = startError;
            [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerErrorOccurredNotification object:self userInfo:@{ AEAudioControllerErrorKey: startError}];
            return NO;
        }
    }
    
    if ( !self.running ) {
        @synchronized ( self ) {
            // Ensure top IO unit is running (AUGraphStart may fail to start it)
            AECheckOSStatus(AudioOutputUnitStart(_ioAudioUnit), "AudioOutputUnitStart");
        }
    }

#if TARGET_OS_IPHONE && !TARGET_OS_TV
    if ( _inputEnabled ) {
        if ( [audioSession respondsToSelector:@selector(requestRecordPermission:)] ) {
            [audioSession requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ( granted ) {
                        [self updateInputDeviceStatus];
                    } else {
                        [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerErrorOccurredNotification
                                                                            object:self
                                                                          userInfo:@{ AEAudioControllerErrorKey: [NSError errorWithDomain:AEAudioControllerErrorDomain
                                                                                                                                     code:AEAudioControllerErrorInputAccessDenied
                                                                                                                                 userInfo:nil]}];
                    }
                });
            }];
        } else {
            [self updateInputDeviceStatus];
        }
    }
#endif

    
    _started = YES;
    
    return YES;
}

- (void)stop {
    [self stopInternal];
    _started = NO;
}

- (void)stopInternal {
    NSLog(@"TAAE: Stopping Engine");
    
    AECheckOSStatus(AUGraphStop(_audioGraph), "AUGraphStop");
#if !TARGET_OS_IPHONE
    if ( _inputEnabled ) {
        AECheckOSStatus(AudioOutputUnitStop(_iAudioUnit), "AudioOutputUnitStop (OSX input)");
    }
#endif
    
    if ( self.running ) {
        // Ensure top IO unit is stopped (AUGraphStop may fail to stop it)
        AECheckOSStatus(AudioOutputUnitStop(_ioAudioUnit), "AudioOutputUnitStop");
    }
    
#if TARGET_OS_IPHONE
    if ( !_interrupted ) {
        NSError *error = nil;
        if ( ![((AVAudioSession*)[AVAudioSession sharedInstance]) setActive:NO error:&error] ) {
            NSLog(@"TAAE: Couldn't deactivate audio session: %@", error);
        }
    }
#endif
    
    AEMessageQueueProcessMessagesOnRealtimeThread(_messageQueue);
    [_messageQueue stopPolling];
}

#pragma mark - Channel and channel group management

- (void)addChannels:(NSArray*)channels {
    [self addChannels:channels toChannelGroup:_topGroup];
}

- (void)addChannels:(NSArray*)channels toChannelGroup:(AEChannelGroupRef)group {
    // Remove the channels from the system, if they're already added
    [self removeChannels:channels];
    
    // Add to group's channel array
    for ( id<AEAudioPlayable> channel in channels ) {
        if ( group->channelCount == kMaximumChannelsPerGroup ) {
            NSLog(@"TAAE: Warning: Channel limit reached");
            break;
        }
        
        if ( [channel respondsToSelector:@selector(setupWithAudioController:)] ) {
            [channel setupWithAudioController:self];
        }
        
        for ( NSString *property in @[@"volume", @"pan", @"channelIsPlaying", @"channelIsMuted", @"audioDescription"] ) {
            [(NSObject*)channel addObserver:self forKeyPath:property options:0 context:kChannelPropertyChanged];
        }
        
        AEChannelRef channelElement = (AEChannelRef)calloc(1, sizeof(channel_t));
        channelElement->type        = kChannelTypeChannel;
        channelElement->ptr         = channel.renderCallback;
        channelElement->object      = (__bridge_retained void*)channel;
        channelElement->parentGroup = group;
        channelElement->playing     = [channel respondsToSelector:@selector(channelIsPlaying)] ? channel.channelIsPlaying : YES;
        channelElement->volume      = [channel respondsToSelector:@selector(volume)] ? channel.volume : 1.0;
        channelElement->pan         = [channel respondsToSelector:@selector(pan)] ? channel.pan : 0.0;
        channelElement->muted       = [channel respondsToSelector:@selector(channelIsMuted)] ? channel.channelIsMuted : NO;
        if ( [channel respondsToSelector:@selector(audioDescription)] && channel.audioDescription.mSampleRate ) {
            channelElement->audioDescription = channel.audioDescription;
        }
        memset(&channelElement->timeStamp, 0, sizeof(channelElement->timeStamp));
        channelElement->audioController = (__bridge void*)self;
        
        group->channels[group->channelCount++] = channelElement;
    }

    // Configure each channel
    [self configureChannelsInRange:NSMakeRange(group->channelCount - channels.count, channels.count) forGroup:group];
    
    AECheckOSStatus([self updateGraph], "Update graph");
}

- (void)removeChannels:(NSArray *)channels {
    // Find parent groups of each channel, and remove channels (in batches, if possible)
    NSMutableArray *siblings = [NSMutableArray array];
    AEChannelGroupRef lastGroup = NULL;
    for ( id<AEAudioPlayable> channel in channels ) {
        AEChannelGroupRef group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:(__bridge void*)channel index:NULL];
        
        if ( group == NULL ) continue;
        
        if ( group != lastGroup ) {
            if ( lastGroup != NULL ) {
                [self removeChannels:siblings fromChannelGroup:lastGroup];
            }
            [siblings removeAllObjects];
            lastGroup = group;
        }
        
        [siblings addObject:channel];
    }
    
    if ( [siblings count] > 0 ) {
        [self removeChannels:siblings fromChannelGroup:lastGroup];
    }
}

- (void)removeChannels:(NSArray*)channels fromChannelGroup:(AEChannelGroupRef)group {
    
    // Remove the channels from the tables, on the core audio thread
    int count = (int)[channels count];
    
    if ( count == 0 ) return;
    
    void** ptrMatchArray = malloc(count * sizeof(void*));
    void** objectMatchArray = malloc(count * sizeof(void*));
    for ( int i=0; i<count; i++ ) {
        ptrMatchArray[i] = ((id<AEAudioPlayable>)channels[i]).renderCallback;
        objectMatchArray[i] = (__bridge void *)(channels[i]);
    }
    AEChannelRef removedChannels[count];
    memset(removedChannels, 0, sizeof(removedChannels));
    AEChannelRef *removedChannels_p = removedChannels;
    int priorCount = group->channelCount;
    [self performSynchronousMessageExchangeWithBlock:^{
        removeChannelsFromGroup(self, group, ptrMatchArray, objectMatchArray, removedChannels_p, count);
    }];
    free(ptrMatchArray);
    free(objectMatchArray);
    
    [self configureChannelsInRange:NSMakeRange(0, priorCount) forGroup:group];
    
    AECheckOSStatus([self updateGraph], "Update graph");
    
    // Set new bus count of group
    UInt32 busCount = group->channelCount;
    if ( !AECheckOSStatus(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)),
                      "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;

    
    // Release channel resources
    for ( int i=0; i<count; i++ ) {
        if ( removedChannels[i] ) {
            [self releaseResourcesForChannel:removedChannels[i]];
        }
    }
}

- (void)removeChannelGroup:(AEChannelGroupRef)group {
    
    // Find group's parent
    int index;
    AEChannelGroupRef parentGroup = (group == _topGroup ? NULL : [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index]);
    NSAssert(group == _topGroup || parentGroup != NULL, @"Channel group not found");
    
    if ( parentGroup ) {
        // Remove the group from the parent group's table, on the core audio thread
        [self performSynchronousMessageExchangeWithBlock:^{
            removeChannelsFromGroup(self, parentGroup, (void*[1]){ group }, (void*[1]){ NULL }, NULL, 1);
        }];
        [self configureChannelsInRange:NSMakeRange(0, parentGroup->channelCount) forGroup:parentGroup];
        
        AECheckOSStatus([self updateGraph], "Update graph");
    }
    
    [self releaseResourcesForChannel:group->channel];
}

-(NSArray *)channels {
    NSMutableArray *channels = [NSMutableArray array];
    [self gatherChannelsFromGroup:_topGroup intoArray:channels];
    return channels;
}

- (NSArray*)channelsInChannelGroup:(AEChannelGroupRef)group {
    NSMutableArray *channels = [NSMutableArray array];
    for ( int i=0; i<group->channelCount; i++ ) {
        if ( group->channels[i] && group->channels[i]->type == kChannelTypeChannel ) {
            [channels addObject:(__bridge id)group->channels[i]->object];
        }
    }
    return channels;
}


- (AEChannelGroupRef)createChannelGroup {
    return [self createChannelGroupWithinChannelGroup:_topGroup];
}

- (AEChannelGroupRef)createChannelGroupWithinChannelGroup:(AEChannelGroupRef)parentGroup {
    if ( parentGroup->channelCount == kMaximumChannelsPerGroup ) {
        NSLog(@"TAAE: Maximum channels reached in group %p\n", parentGroup);
        return NULL;
    }
    
    // Allocate group
    AEChannelGroupRef group = (AEChannelGroupRef)calloc(1, sizeof(channel_group_t));
    
    // Add group as a channel to the parent group
    int groupIndex = parentGroup->channelCount;
    
    AEChannelRef channel = (AEChannelRef)calloc(1, sizeof(channel_t));
    
    channel->type    = kChannelTypeGroup;
    channel->ptr     = group;
    channel->parentGroup = parentGroup;
    channel->playing = YES;
    channel->volume  = 1.0;
    channel->pan     = 0.0;
    channel->muted   = NO;
    channel->audioController = (__bridge void *)self;
    
    parentGroup->channels[groupIndex] = channel;
    group->channel   = channel;
    
    parentGroup->channelCount++;
    
    // Set bus count
    UInt32 busCount = parentGroup->channelCount;
    OSStatus result = AudioUnitSetProperty(parentGroup->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return NULL;

    [self configureChannelsInRange:NSMakeRange(groupIndex, 1) forGroup:parentGroup];
    AECheckOSStatus([self updateGraph], "Update graph");
    
    return group;
}

- (NSArray*)topLevelChannelGroups {
    return [self channelGroupsInChannelGroup:_topGroup];
}

- (NSArray*)channelGroupsInChannelGroup:(AEChannelGroupRef)group {
    NSMutableArray *groups = [NSMutableArray array];
    for ( int i=0; i<group->channelCount; i++ ) {
        if ( group->channels[i] && group->channels[i]->type == kChannelTypeGroup ) {
            [groups addObject:[NSValue valueWithPointer:group->channels[i]->ptr]];
        }
    }
    return groups;
}

- (void)setVolume:(float)volume forChannelGroup:(AEChannelGroupRef)group {
    int index;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AudioUnitParameterValue value = group->channel->volume = volume;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0);
    AECheckOSStatus(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
}

-(float)volumeForChannelGroup:(AEChannelGroupRef)group {
    return group->channel->volume;
}

- (void)setPan:(float)pan forChannelGroup:(AEChannelGroupRef)group {
    int index;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AudioUnitParameterValue value = group->channel->pan = pan;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0);
    AECheckOSStatus(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
}

-(float)panForChannelGroup:(AEChannelGroupRef)group {
    return group->channel->pan;
}

- (void)setPlaying:(BOOL)playing forChannelGroup:(AEChannelGroupRef)group {
    int index;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    group->channel->playing = playing;
    AudioUnitParameterValue value = group->channel->playing;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
    AECheckOSStatus(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
}

-(BOOL)channelGroupIsPlaying:(AEChannelGroupRef)group {
    return group->channel->playing;
}

- (void)setMuted:(BOOL)muted forChannelGroup:(AEChannelGroupRef)group {
    int index;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    group->channel->muted = muted;
    AudioUnitParameterValue value = muted ? 0.0 : group->channel->volume;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0);
    AECheckOSStatus(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
}

-(BOOL)channelGroupIsMuted:(AEChannelGroupRef)group {
    return group->channel->muted;
}

#pragma mark - Filters

- (void)addFilter:(id<AEAudioFilter>)filter {
    if ( [filter respondsToSelector:@selector(setupWithAudioController:)] ) {
        [filter setupWithAudioController:self];
    }
    if ( [self addCallback:filter.filterCallback userInfo:(__bridge void *)filter flags:kFilterFlag forChannelGroup:_topGroup] ) {
        CFBridgingRetain(filter);
    }
}

- (void)addFilter:(id<AEAudioFilter>)filter toChannel:(id<AEAudioPlayable>)channel {
    if ( [filter respondsToSelector:@selector(setupWithAudioController:)] ) {
        [filter setupWithAudioController:self];
    }
    if ( [self addCallback:filter.filterCallback userInfo:(__bridge void *)filter flags:kFilterFlag forChannel:channel] ) {
        CFBridgingRetain(filter);
    }
}

- (void)addFilter:(id<AEAudioFilter>)filter toChannelGroup:(AEChannelGroupRef)group {
    if ( [filter respondsToSelector:@selector(setupWithAudioController:)] ) {
        [filter setupWithAudioController:self];
    }
    if ( [self addCallback:filter.filterCallback userInfo:(__bridge void *)filter flags:kFilterFlag forChannelGroup:group] ) {
        CFBridgingRetain(filter);
    }
}

- (void)addInputFilter:(id<AEAudioFilter>)filter {
    [self addInputFilter:filter forChannels:nil];
}

- (void)addInputFilter:(id<AEAudioFilter>)filter forChannels:(NSArray *)channels {
    if ( [filter respondsToSelector:@selector(setupWithAudioController:)] ) {
        [filter setupWithAudioController:self];
    }
    void *callback = filter.filterCallback;
    if ( [self addCallback:callback userInfo:(__bridge void *)filter flags:kFilterFlag forInputChannels:channels] ) {
        CFBridgingRetain(filter);
    }
}

- (void)removeFilter:(id<AEAudioFilter>)filter {
    if ( [self removeCallback:filter.filterCallback userInfo:(__bridge void *)filter fromChannelGroup:_topGroup] ) {
        if ( [filter respondsToSelector:@selector(teardown)] ) {
            [filter teardown];
        }
        CFBridgingRelease((__bridge CFTypeRef)filter);
    }
}

- (void)removeFilter:(id<AEAudioFilter>)filter fromChannel:(id<AEAudioPlayable>)channel {
    if ( [self removeCallback:filter.filterCallback userInfo:(__bridge void *)filter fromChannel:channel] ) {
        if ( [filter respondsToSelector:@selector(teardown)] ) {
            [filter teardown];
        }
        CFBridgingRelease((__bridge CFTypeRef)filter);
    }
}

- (void)removeFilter:(id<AEAudioFilter>)filter fromChannelGroup:(AEChannelGroupRef)group {
    if ( [self removeCallback:filter.filterCallback userInfo:(__bridge void *)filter fromChannelGroup:group] ) {
        if ( [filter respondsToSelector:@selector(teardown)] ) {
            [filter teardown];
        }
        CFBridgingRelease((__bridge CFTypeRef)filter);
    }
}

- (void)removeInputFilter:(id<AEAudioFilter>)filter {
    void *callback = filter.filterCallback;
    __block BOOL found = NO;
    [self performSynchronousMessageExchangeWithBlock:^{
        for ( int i=0; i<_inputCallbackCount; i++ ) {
            removeCallbackFromTable(self, &_inputCallbacks[i].callbacks, callback, (__bridge void *)filter, &found);
        }
    }];
    
    if ( found ) {
        if ( [filter respondsToSelector:@selector(teardown)] ) {
            [filter teardown];
        }
        CFBridgingRelease((__bridge CFTypeRef)filter);
    }
}

- (NSArray*)filters {
    return [self associatedObjectsWithFlags:kFilterFlag];
}

- (NSArray*)filtersForChannel:(id<AEAudioPlayable>)channel {
    return [self associatedObjectsWithFlags:kFilterFlag forChannel:channel];
}

- (NSArray*)filtersForChannelGroup:(AEChannelGroupRef)group {
    return [self associatedObjectsWithFlags:kFilterFlag forChannelGroup:group];
}

-(NSArray *)inputFilters {
    NSMutableArray *result = [NSMutableArray array];
    for ( int i=0; i<_inputCallbackCount; i++ ) {
        [result addObjectsFromArray:[self associatedObjectsFromTable:&_inputCallbacks[i].callbacks matchingFlag:kFilterFlag]];
    }
    return result;
}

#pragma mark - Output receivers

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver {
    if ( [receiver respondsToSelector:@selector(setupWithAudioController:)] ) {
        [receiver setupWithAudioController:self];
    }
    if ( [self addCallback:receiver.receiverCallback userInfo:(__bridge void *)receiver flags:kReceiverFlag forChannelGroup:_topGroup] ) {
        CFBridgingRetain(receiver);
    }
}

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannel:(id<AEAudioPlayable>)channel {
    if ( [receiver respondsToSelector:@selector(setupWithAudioController:)] ) {
        [receiver setupWithAudioController:self];
    }
    if ( [self addCallback:receiver.receiverCallback userInfo:(__bridge void *)receiver flags:kReceiverFlag forChannel:channel] ) {
        CFBridgingRetain(receiver);
    }
}

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannelGroup:(AEChannelGroupRef)group {
    if ( [receiver respondsToSelector:@selector(setupWithAudioController:)] ) {
        [receiver setupWithAudioController:self];
    }
    if ( [self addCallback:receiver.receiverCallback userInfo:(__bridge void *)receiver flags:kReceiverFlag forChannelGroup:group] ) {
        CFBridgingRetain(receiver);
    }
}

- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver {
    if ( [self removeCallback:receiver.receiverCallback userInfo:(__bridge void *)receiver fromChannelGroup:_topGroup] ) {
        CFBridgingRelease((__bridge CFTypeRef)receiver);
    }
    if ( [receiver respondsToSelector:@selector(teardown)] ) {
        [receiver teardown];
    }
}

- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver fromChannel:(id<AEAudioPlayable>)channel {
    if ( [self removeCallback:receiver.receiverCallback userInfo:(__bridge void *)receiver fromChannel:channel] ) {
        CFBridgingRelease((__bridge CFTypeRef)receiver);
    }
    if ( [receiver respondsToSelector:@selector(teardown)] ) {
        [receiver teardown];
    }
}

- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver fromChannelGroup:(AEChannelGroupRef)group {
    if ( [self removeCallback:receiver.receiverCallback userInfo:(__bridge void *)receiver fromChannelGroup:group] ) {
        CFBridgingRelease((__bridge CFTypeRef)receiver);
    }
    if ( [receiver respondsToSelector:@selector(teardown)] ) {
        [receiver teardown];
    }
}

- (NSArray*)outputReceivers {
    return [self associatedObjectsWithFlags:kReceiverFlag];
}

- (NSArray*)outputReceiversForChannel:(id<AEAudioPlayable>)channel {
    return [self associatedObjectsWithFlags:kReceiverFlag forChannel:channel];
}

- (NSArray*)outputReceiversForChannelGroup:(AEChannelGroupRef)group {
    return [self associatedObjectsWithFlags:kReceiverFlag forChannelGroup:group];
}

#pragma mark - Input receivers

- (void)addInputReceiver:(id<AEAudioReceiver>)receiver {
    [self addInputReceiver:receiver forChannels:nil];
}

- (void)addInputReceiver:(id<AEAudioReceiver>)receiver forChannels:(NSArray *)channels {
    if ( [receiver respondsToSelector:@selector(setupWithAudioController:)] ) {
        [receiver setupWithAudioController:self];
    }
    
    void *callback = receiver.receiverCallback;
    
    if ( [self addCallback:callback userInfo:(__bridge void *)receiver flags:kReceiverFlag forInputChannels:channels] ) {
        CFBridgingRetain(receiver);
    }
}

- (void)removeInputReceiver:(id<AEAudioReceiver>)receiver {
    void *callback = receiver.receiverCallback;
    __block int instanceCount = 0;
    [self performSynchronousMessageExchangeWithBlock:^{
        for ( int i=0; i<_inputCallbackCount; i++ ) {
            BOOL found = NO;
            removeCallbackFromTable(self, &_inputCallbacks[i].callbacks, callback, (__bridge void *)receiver, &found);
            if ( found ) instanceCount++;
        }
    }];
    
    if ( instanceCount > 0 && [receiver respondsToSelector:@selector(teardown)] ) {
        [receiver teardown];
    }
    
    for ( int i=0; i<instanceCount; i++ ) {
        CFBridgingRelease((__bridge CFTypeRef)receiver);
    }
}

- (void)removeInputReceiver:(id<AEAudioReceiver>)receiver fromChannels:(NSArray *)channels {
    void *callback = receiver.receiverCallback;
    for ( int i=0; i<_inputCallbackCount; i++ ) {
        // Compare channel maps to find a matching entry
        if ( (_inputCallbacks[i].channelMap && [(__bridge NSArray*)_inputCallbacks[i].channelMap isEqualToArray:channels]) ||
            (i == 0 && !_inputCallbacks[i].channelMap && [self.inputChannelSelection isEqualToArray:channels]) ) {
            
            __block BOOL found = NO;
            
            [self performSynchronousMessageExchangeWithBlock:^{
                removeCallbackFromTable(self, &_inputCallbacks[i].callbacks, callback, (__bridge void *)receiver, &found);
            }];

            if ( found ) {
                if ( [receiver respondsToSelector:@selector(teardown)] ) {
                    [receiver teardown];
                }
                CFBridgingRelease((__bridge CFTypeRef)receiver);
            }
            
            break;
        }
    }
}

-(NSArray *)inputReceivers {
    NSMutableArray *result = [NSMutableArray array];
    for ( int i=0; i<_inputCallbackCount; i++ ) {
        [result addObjectsFromArray:[self associatedObjectsFromTable:&_inputCallbacks[i].callbacks matchingFlag:kReceiverFlag]];
    }
    return result;
}

#pragma mark - Timing receivers

- (void)addTimingReceiver:(id<AEAudioTimingReceiver>)receiver {
    if ( _timingCallbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"TAAE: Warning: Maximum number of callbacks reached");
        return;
    }
    
    CFBridgingRetain(receiver);
    
    void *callback = receiver.timingReceiverCallback;
    [self performSynchronousMessageExchangeWithBlock:^{
        addCallbackToTable(self, &_timingCallbacks, callback, (__bridge void *)receiver, 0);
    }];
}

- (void)removeTimingReceiver:(id<AEAudioTimingReceiver>)receiver {
    void *callback = receiver.timingReceiverCallback;
    __block BOOL found = NO;
    [self performSynchronousMessageExchangeWithBlock:^{
        removeCallbackFromTable(self, &_timingCallbacks, callback, (__bridge void *)receiver, &found);
    }];
    
    if ( found ) {
        CFBridgingRelease((__bridge CFTypeRef)receiver);
    }
}

-(NSArray *)timingReceivers {
    return [self associatedObjectsFromTable:&_timingCallbacks matchingFlag:0];
}

#pragma mark - Main thread-realtime thread message sending

- (void)performAsynchronousMessageExchangeWithBlock:(void (^)())block responseBlock:(void (^)())responseBlock {
    [_messageQueue performAsynchronousMessageExchangeWithBlock:block responseBlock:responseBlock];
}

- (BOOL)performSynchronousMessageExchangeWithBlock:(void (^)())block {
    return [_messageQueue performSynchronousMessageExchangeWithBlock:block];
}

void AEAudioControllerSendAsynchronousMessageToMainThread(__unsafe_unretained AEAudioController *THIS,
                                                          AEMessageQueueMessageHandler           handler,
                                                          void                                  *userInfo,
                                                          int                                    userInfoLength) {
    AEMessageQueueSendMessageToMainThread(THIS->_messageQueue, handler, userInfo, userInfoLength);
}

#pragma mark - Metering

- (void)outputAveragePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel {
    return [self averagePowerLevel:averagePower peakHoldLevel:peakLevel forGroup:_topGroup];
}

- (void)outputAveragePowerLevels:(Float32*)averagePowers peakHoldLevels:(Float32*)peakLevels channelCount:(UInt32)count {
    return [self averagePowerLevels:averagePowers peakHoldLevels:peakLevels forGroup:_topGroup channelCount:count];
}

- (void)averagePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel forGroup:(AEChannelGroupRef)group {
    if ( !group->level_monitor_data.monitoringEnabled ) {
        if ( ![NSThread isMainThread] ) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self averagePowerLevel:NULL peakHoldLevel:NULL forGroup:group]; });
        } else {
            AEFloatConverter *floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:group->channel->audioDescription];
            group->level_monitor_data.channels = group->channel->audioDescription.mChannelsPerFrame;
            group->level_monitor_data.floatConverter = (__bridge_retained void*)floatConverter;
            group->level_monitor_data.scratchBuffer = AEAudioBufferListCreate(floatConverter.floatingPointAudioDescription, kLevelMonitorScratchBufferSize);
            OSMemoryBarrier();
            group->level_monitor_data.monitoringEnabled = YES;
            
            AEChannelGroupRef parentGroup = NULL;
            int index=0;
            if ( group != _topGroup ) {
                parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
                NSAssert(parentGroup != NULL, @"Channel group not found");
            }
            
            [self configureChannelsInRange:NSMakeRange(index, 1) forGroup:parentGroup];
            AECheckOSStatus([self updateGraph], "Update graph");
        }
    }
    
    if ( averagePower ) *averagePower = 20.0f * log10f(group->level_monitor_data.average);
    if ( peakLevel ) *peakLevel = 20.0f * log10f(group->level_monitor_data.peak);
    
    group->level_monitor_data.reset = YES;
}

- (void)averagePowerLevels:(Float32*)averagePowers peakHoldLevels:(Float32*)peakLevels forGroup:(AEChannelGroupRef)group channelCount:(UInt32)count {
    if ( !group->level_monitor_data.monitoringEnabled ) {
        if ( ![NSThread isMainThread] ) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self averagePowerLevels:NULL peakHoldLevels:NULL forGroup:group channelCount:0]; });
        } else {
            AEFloatConverter *floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:group->channel->audioDescription];
            group->level_monitor_data.channels = group->channel->audioDescription.mChannelsPerFrame;
            group->level_monitor_data.floatConverter = (__bridge_retained void*)floatConverter;
            group->level_monitor_data.scratchBuffer = AEAudioBufferListCreate(floatConverter.floatingPointAudioDescription, kLevelMonitorScratchBufferSize);
            OSMemoryBarrier();
            group->level_monitor_data.monitoringEnabled = YES;

            AEChannelGroupRef parentGroup = NULL;
            int index=0;
            if ( group != _topGroup ) {
                parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
                NSAssert(parentGroup != NULL, @"Channel group not found");
            }

            [self configureChannelsInRange:NSMakeRange(index, 1) forGroup:parentGroup];
            AECheckOSStatus([self updateGraph], "Update graph");
        }
    }

    if ( averagePowers && count > 0) {
        for (UInt32 i=0; i < count && i < kMaximumMonitoringChannels; ++i) {
            averagePowers[i] = 20.0f * log10f(group->level_monitor_data.chanAverage[i]);
        }
    }
    if ( peakLevels && count > 0) {
        for (UInt32 i=0; i < count && i < kMaximumMonitoringChannels; ++i) {
            peakLevels[i] = 20.0f * log10f(group->level_monitor_data.chanPeak[i]);
        }
    }

    group->level_monitor_data.reset = YES;
}

- (void)inputAveragePowerLevels:(Float32*)averagePowers peakHoldLevels:(Float32*)peakLevels channelCount:(UInt32)count {
    if ( !_inputLevelMonitorData.monitoringEnabled ) {
        AEFloatConverter *floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:_rawInputAudioDescription];
        _inputLevelMonitorData.channels = _rawInputAudioDescription.mChannelsPerFrame;
        _inputLevelMonitorData.floatConverter = (__bridge_retained void*)floatConverter;
        _inputLevelMonitorData.scratchBuffer = AEAudioBufferListCreate(floatConverter.floatingPointAudioDescription, kLevelMonitorScratchBufferSize);
        OSMemoryBarrier();
        _inputLevelMonitorData.monitoringEnabled = YES;
    }

    if ( averagePowers && count > 0) {
        for (UInt32 i=0; i < count && i < kMaximumMonitoringChannels; ++i) {
            averagePowers[i] = 20.0f * log10f(_inputLevelMonitorData.chanAverage[i]);
        }
    }

    if ( peakLevels && count > 0) {
        for (UInt32 i=0; i < count && i < kMaximumMonitoringChannels; ++i) {
            peakLevels[i] = 20.0f * log10f(_inputLevelMonitorData.chanPeak[i]);
        }
    }

    _inputLevelMonitorData.reset = YES;
}

- (void)inputAveragePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel {
    if ( !_inputLevelMonitorData.monitoringEnabled ) {
        AEFloatConverter *floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:_rawInputAudioDescription];
        _inputLevelMonitorData.channels = _rawInputAudioDescription.mChannelsPerFrame;
        _inputLevelMonitorData.floatConverter = (__bridge_retained void*)floatConverter;
        _inputLevelMonitorData.scratchBuffer = AEAudioBufferListCreate(floatConverter.floatingPointAudioDescription, kLevelMonitorScratchBufferSize);
        OSMemoryBarrier();
        _inputLevelMonitorData.monitoringEnabled = YES;
    }
    
    if ( averagePower ) *averagePower = 20.0f * log10f(_inputLevelMonitorData.average);
    if ( peakLevel ) *peakLevel = 20.0f * log10f(_inputLevelMonitorData.peak);
    
    _inputLevelMonitorData.reset = YES;
}

#pragma mark - Utilities

AudioStreamBasicDescription *AEAudioControllerAudioDescription(__unsafe_unretained AEAudioController *THIS) {
    return &THIS->_audioDescription;
}

AudioStreamBasicDescription *AEAudioControllerInputAudioDescription(__unsafe_unretained AEAudioController *THIS) {
    return &THIS->_inputCallbacks[0].audioDescription;
}

long AEConvertSecondsToFrames(__unsafe_unretained AEAudioController *THIS, NSTimeInterval seconds) {
    return round(seconds * THIS->_audioDescription.mSampleRate);
}

NSTimeInterval AEConvertFramesToSeconds(__unsafe_unretained AEAudioController *THIS, long frames) {
    return (double)frames / THIS->_audioDescription.mSampleRate;
}

BOOL AECurrentThreadIsAudioThread(void) {
    return __audioThread == pthread_self();
}

#pragma mark - Setters, getters

#if TARGET_OS_IPHONE
-(void)setAudioSessionCategory:(NSString *)audioSessionCategory {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    if ( ![audioSession.category isEqualToString:audioSessionCategory] ) {
        NSLog(@"TAAE: Setting audio session category to %@", audioSessionCategory);
    }
    
    _audioSessionCategory = audioSessionCategory;
    
    if ( !_audioInputAvailable && ([_audioSessionCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord] || [_audioSessionCategory isEqualToString:AVAudioSessionCategoryRecord]) ) {
        NSLog(@"TAAE: No input available. Using AVAudioSessionCategoryPlayback category instead.");
        _audioSessionCategory = AVAudioSessionCategoryPlayback;
    }
    
    int options = 0;

#if !TARGET_OS_TV
    if ( [_audioSessionCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord] ) {
        options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
    }
    options |= _enableBluetoothInput ? AVAudioSessionCategoryOptionAllowBluetooth : 0;
#endif
    
    if ( [_audioSessionCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord] || [_audioSessionCategory isEqualToString:AVAudioSessionCategoryPlayback] ) {
        options |= _allowMixingWithOtherApps ? AVAudioSessionCategoryOptionMixWithOthers : 0;
    }
    
    NSError *error = nil;
    if ( ![audioSession setCategory:_audioSessionCategory withOptions:options error:&error] ) {
        NSLog(@"TAAE: Error setting audio session category: %@", error);
    }
}

-(NSString *)audioSessionCategory {
    return ( !_audioInputAvailable && ([_audioSessionCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord] || [_audioSessionCategory isEqualToString:AVAudioSessionCategoryRecord]) )
                ? AVAudioSessionCategoryPlayback
                : _audioSessionCategory;
}

-(void)setAllowMixingWithOtherApps:(BOOL)allowMixingWithOtherApps {
    _allowMixingWithOtherApps = allowMixingWithOtherApps;
    
    [self setAudioSessionCategory:_audioSessionCategory];
}

-(void)setUseMeasurementMode:(BOOL)useMeasurementMode {
    _useMeasurementMode = useMeasurementMode;
    
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    NSError *error = nil;
    if ( ![audioSession setMode:_useMeasurementMode && (!_avoidMeasurementModeForBuiltInSpeaker || !_playingThroughDeviceSpeaker)
                                    ? AVAudioSessionModeMeasurement : AVAudioSessionModeDefault
                          error:&error] ) {
        NSLog(@"TAAE: Couldn't set audio session mode: %@", error);
    } else {
        if ( ![audioSession setPreferredIOBufferDuration:_preferredBufferDuration error:&error] ) {
            NSLog(@"TAAE: Couldn't set preferred IO buffer duration: %@", error);
        }
    }
    
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
}

- (void)setBoostBuiltInMicGainInMeasurementMode:(BOOL)boostBuiltInMicGainInMeasurementMode {
    _boostBuiltInMicGainInMeasurementMode = boostBuiltInMicGainInMeasurementMode;
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
}
#endif

-(void)setMasterOutputVolume:(float)masterOutputVolume {
    _masterOutputVolume = masterOutputVolume;
    
    AudioUnitParameterValue value = _masterOutputVolume;
    OSStatus result = AudioUnitSetParameter(_topGroup->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, value, 0);
    AECheckOSStatus(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
}

- (BOOL)running {
    Boolean topAudioUnitIsRunning;
    UInt32 size = sizeof(topAudioUnitIsRunning);
    if ( AECheckOSStatus(AudioUnitGetProperty(_ioAudioUnit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &topAudioUnitIsRunning, &size), "kAudioOutputUnitProperty_IsRunning") ) {
        return topAudioUnitIsRunning;
    } else {
        return NO;
    }
}

#if TARGET_OS_IPHONE
-(void)setEnableBluetoothInput:(BOOL)enableBluetoothInput {
    _enableBluetoothInput = enableBluetoothInput;

    [self setAudioSessionCategory:_audioSessionCategory];
}

-(BOOL)inputGainAvailable {
    return [((AVAudioSession*)[AVAudioSession sharedInstance]) isInputGainSettable];
}

-(float)inputGain {
    return [((AVAudioSession*)[AVAudioSession sharedInstance]) inputGain];
}
#endif

-(AudioStreamBasicDescription)inputAudioDescription {
    return _inputCallbacks[0].audioDescription;
}

#if TARGET_OS_IPHONE
-(void)setInputGain:(float)inputGain {
    NSError *error = NULL;
    if ( ![((AVAudioSession*)[AVAudioSession sharedInstance]) setInputGain:inputGain error:&error] ) {
        NSLog(@"TAAE: Couldn't set input gain: %@", error);
    }
}
#endif

-(void)setInputMode:(AEInputMode)inputMode {
    _inputMode = inputMode;
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
}

-(NSArray *)inputChannelSelection {
    if ( _inputCallbacks[0].channelMap ) return (__bridge NSArray *)_inputCallbacks[0].channelMap;
    NSMutableArray *selection = [NSMutableArray array];
    for ( int i=0; i<MIN(_numberOfInputChannels, _inputCallbacks[0].audioDescription.mChannelsPerFrame); i++ ) {
        [selection addObject:@(i)];
    }
    return selection;
}

-(void)setInputChannelSelection:(NSArray *)inputChannelSelection {
    if ( (!inputChannelSelection && !_inputCallbacks[0].channelMap) || [inputChannelSelection isEqualToArray:(__bridge NSArray *)_inputCallbacks[0].channelMap] ) return;
    
    CFBridgingRelease(_inputCallbacks[0].channelMap);
    _inputCallbacks[0].channelMap = (__bridge_retained void*)inputChannelSelection;
    
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
}

#if TARGET_OS_IPHONE
-(void)setPreferredBufferDuration:(NSTimeInterval)preferredBufferDuration {
    if ( _preferredBufferDuration == preferredBufferDuration ) return;
    
    _preferredBufferDuration = preferredBufferDuration;
    
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if ( ![audioSession setPreferredIOBufferDuration:_preferredBufferDuration error:&error] ) {
        NSLog(@"TAAE: Couldn't set preferred IO buffer duration: %@", error);
    }

    NSTimeInterval grantedBufferSize = audioSession.IOBufferDuration;

    if ( _currentBufferDuration != grantedBufferSize ) self.currentBufferDuration = grantedBufferSize;
    
    NSLog(@"TAAE: Buffer duration %0.2g, %d frames (requested %0.2gs, %d frames)",
          grantedBufferSize, (int)round(grantedBufferSize*_audioDescription.mSampleRate),
          _preferredBufferDuration, (int)round(_preferredBufferDuration*_audioDescription.mSampleRate));
}

-(NSTimeInterval)inputLatency {
    return AEAudioControllerInputLatency(self);
}

NSTimeInterval AEAudioControllerInputLatency(__unsafe_unretained AEAudioController *THIS) {
    if ( !THIS->_inputEnabled ) return 0.0;
    
    if ( (THIS->_audiobusReceiverPort && ABReceiverPortIsConnected(THIS->_audiobusReceiverPort))
        || (THIS->_audiobusFilterPort && ABFilterPortIsConnected(THIS->_audiobusFilterPort)) ) {
        return 0.0;
    }
    
    if ( __cachedInputLatency == kNoValue ) {
        __cachedInputLatency = [((AVAudioSession*)[AVAudioSession sharedInstance]) inputLatency];
    }
    return __cachedInputLatency;
}

-(NSTimeInterval)outputLatency {
    return AEAudioControllerOutputLatency(self);
}

NSTimeInterval AEAudioControllerOutputLatency(__unsafe_unretained AEAudioController *THIS) {
    
    if ( AECurrentThreadIsAudioThread() ) {
        AEChannelRef channelBeingRendered = THIS->_channelBeingRendered;
        if ( !channelBeingRendered ) channelBeingRendered = THIS->_topChannel;
        
        __unsafe_unretained ABSenderPort * upstreamSenderPort = (__bridge ABSenderPort*)firstUpstreamAudiobusSenderPort(channelBeingRendered);
        if ( upstreamSenderPort && ABSenderPortIsMuted(upstreamSenderPort) ) {
            // We're sending via the sender port, and the receiver plays live - offset the timestamp by the reported latency
            return ABSenderPortGetAverageLatency(upstreamSenderPort);
        }
    }
    
    if ( __cachedOutputLatency == kNoValue) {
        if ( THIS->_outputEnabled ) {
            __cachedOutputLatency = [((AVAudioSession*)[AVAudioSession sharedInstance]) outputLatency];
        }
        else {
            __cachedOutputLatency = 0.0;
        }
    }
    return __cachedOutputLatency;
}
#endif

AudioTimeStamp AEAudioControllerCurrentAudioTimestamp(__unsafe_unretained AEAudioController *THIS) {
    return THIS->_lastInputOrOutputBusTimeStamp;
}

-(void)setVoiceProcessingEnabled:(BOOL)voiceProcessingEnabled {
    if ( _voiceProcessingEnabled == voiceProcessingEnabled ) return;
    
    _voiceProcessingEnabled = voiceProcessingEnabled;
    if ( [self mustUpdateVoiceProcessingSettings] ) {
        [self replaceIONode];
    }
}

-(void)setVoiceProcessingOnlyForSpeakerAndMicrophone:(BOOL)voiceProcessingOnlyForSpeakerAndMicrophone {
    _voiceProcessingOnlyForSpeakerAndMicrophone = voiceProcessingOnlyForSpeakerAndMicrophone;
    if ( [self mustUpdateVoiceProcessingSettings] ) {
        [self replaceIONode];
    }
}

#pragma mark - Audiobus

-(void)setAudiobusReceiverPort:(ABReceiverPort *)audiobusReceiverPort {
    _audiobusReceiverPort = audiobusReceiverPort;
    
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
}

-(void)setAudiobusFilterPort:(ABFilterPort *)audiobusFilterPort {
    _audiobusFilterPort = audiobusFilterPort;
    
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
}

-(void)setAudiobusSenderPort:(ABSenderPort *)audiobusSenderPort {
    if ( _topChannel->audiobusSenderPort == (__bridge void *)audiobusSenderPort ) return;
    
    if ( [(id<AEAudiobusForwardDeclarationsProtocol>)audiobusSenderPort audioUnit] == _ioAudioUnit ) {
        NSLog(@"TAAE: You cannot use ABSenderPort's audio unit initialiser with TAAE.\n"
               "Either (a) use ABSenderPort's audio unit initialiser, and don't use the audiobusSenderPort property or "
               "(b) use the audio unit initialiser but don't use the audiobusSenderProperty, but not both.\n");
        abort();
    }
    
    [self setAudiobusSenderPort:audiobusSenderPort forChannelElement:_topChannel];
}

- (ABSenderPort*)audiobusSenderPort {
    return (__bridge ABSenderPort *)(_topChannel->audiobusSenderPort);
}

-(void)setAudiobusSenderPort:(ABSenderPort *)audiobusSenderPort forChannelElement:(AEChannelRef)channelElement {
    if ( channelElement->audiobusSenderPort == (__bridge void*)audiobusSenderPort ) return;
    
    if ( [(id<AEAudiobusForwardDeclarationsProtocol>)audiobusSenderPort audioUnit] == _ioAudioUnit ) {
        NSLog(@"TAAE: You cannot use ABSenderPort's audio unit initialiser with TAAE.");
        abort();
    }
    
    if ( [self hasAudiobusSenderForUpstreamChannels:channelElement] && !_audiobusMonitorChannel ) {
        _audiobusMonitorBuffer = AEAudioBufferListCreate(AEAudioStreamBasicDescriptionNonInterleavedFloatStereo, kMaxFramesPerSlice);
        AudioBufferList *monitorBuffer = _audiobusMonitorBuffer;
        _audiobusMonitorChannel = [AEBlockChannel channelWithBlock:^(const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
            for ( int i=0; i<MIN(audio->mNumberBuffers, monitorBuffer->mNumberBuffers); i++ ) {
                memcpy(audio->mBuffers[i].mData, monitorBuffer->mBuffers[i].mData, MIN(monitorBuffer->mBuffers[i].mDataByteSize, audio->mBuffers[i].mDataByteSize));
                memset(monitorBuffer->mBuffers[i].mData, 0, monitorBuffer->mBuffers[i].mDataByteSize);
            }
        }];
        _audiobusMonitorChannel.audioDescription = AEAudioStreamBasicDescriptionNonInterleavedFloatStereo;
        [self addChannels:@[_audiobusMonitorChannel]];
    }
    
    if ( audiobusSenderPort == nil ) {
        [self performSynchronousMessageExchangeWithBlock:^{
            channelElement->audiobusSenderPort = nil;
        }];
        AEAudioBufferListFree(channelElement->audiobusScratchBuffer);
        channelElement->audiobusScratchBuffer = NULL;
        CFBridgingRelease(channelElement->audiobusFloatConverter);
        channelElement->audiobusFloatConverter = nil;
    } else {
        if ( !channelElement->audiobusFloatConverter ) {
            channelElement->audiobusFloatConverter = (__bridge_retained void*)[[AEFloatConverter alloc] initWithSourceFormat:channelElement->audioDescription.mSampleRate ? channelElement->audioDescription : _audioDescription];
        }
        if ( !channelElement->audiobusScratchBuffer ) {
            channelElement->audiobusScratchBuffer = AEAudioBufferListCreate(((__bridge AEFloatConverter*)channelElement->audiobusFloatConverter).floatingPointAudioDescription, kScratchBufferFrames);
        }
        [(id<AEAudiobusForwardDeclarationsProtocol>)audiobusSenderPort setClientFormat:((__bridge AEFloatConverter*)channelElement->audiobusFloatConverter).floatingPointAudioDescription];
        
        OSMemoryBarrier();
        
        channelElement->audiobusSenderPort = (__bridge_retained void*)audiobusSenderPort;
        
        if ( channelElement->type == kChannelTypeGroup ) {
            AEChannelGroupRef parentGroup = NULL;
            int index=0;
            if ( channelElement != _topChannel ) {
                parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelElement->ptr userInfo:NULL index:&index];
                NSAssert(parentGroup != NULL, @"Channel group not found");
            }
            
            [self configureChannelsInRange:NSMakeRange(index, 1) forGroup:parentGroup];
            AECheckOSStatus([self updateGraph], "Update graph");
        }
    }
}

-(void)setAudiobusSenderPort:(ABSenderPort *)senderPort forChannel:(id<AEAudioPlayable>)channel {
    int index;
    AEChannelGroupRef group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:(__bridge void*)channel index:&index];
    if ( !group ) return;
    [self setAudiobusSenderPort:senderPort forChannelElement:group->channels[index]];
}

-(void)setAudiobusSenderPort:(ABSenderPort *)senderPort forChannelGroup:(AEChannelGroupRef)channelGroup {
    [self setAudiobusSenderPort:senderPort forChannelElement:channelGroup->channel];
}

#pragma mark - Events

-(void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ( context == kChannelPropertyChanged ) {
        id<AEAudioPlayable> channel = (id<AEAudioPlayable>)object;
        
        int index;
        AEChannelGroupRef group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:(__bridge void*)channel index:&index];
        if ( !group ) return;
        
        AEChannelRef channelElement = group->channels[index];
        
        if ( [keyPath isEqualToString:@"volume"] ) {
            channelElement->volume = channel.volume;
            
            if ( group->mixerAudioUnit ) {
                AudioUnitParameterValue value = channelElement->muted ? 0.0 : channelElement->volume;
                OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0);
                AECheckOSStatus(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
            }
            
        } else if ( [keyPath isEqualToString:@"pan"] ) {
            channelElement->pan = channel.pan;
            
            if ( group->mixerAudioUnit ) {
                AudioUnitParameterValue value = channelElement->pan;
                OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0);
                AECheckOSStatus(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
            }

        } else if ( [keyPath isEqualToString:@"channelIsPlaying"] ) {
            channelElement->playing = channel.channelIsPlaying;
            AudioUnitParameterValue value = channel.channelIsPlaying;
            
            if ( group->mixerAudioUnit ) {
                OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
                AECheckOSStatus(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
            }
            
            group->channels[index]->playing = value;
            
        }  else if ( [keyPath isEqualToString:@"channelIsMuted"] ) {
            channelElement->muted = channel.channelIsMuted;
            
            if ( group->mixerAudioUnit ) {
                AudioUnitParameterValue value = channelElement->muted ? 0.0 : channelElement->volume;
                OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0);
                AECheckOSStatus(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
            }
            
        } else if ( [keyPath isEqualToString:@"audioDescription"] ) {
            channelElement->audioDescription = channel.audioDescription;
            
            if ( group->mixerAudioUnit ) {
                OSStatus result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, index, &channelElement->audioDescription, sizeof(AudioStreamBasicDescription));
                AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
            }
            
            if ( channelElement->audiobusFloatConverter ) {
                void *newFloatConverter = (__bridge_retained void*)[[AEFloatConverter alloc] initWithSourceFormat:channel.audioDescription];
                void *oldFloatConverter = channelElement->audiobusFloatConverter;
                [self performSynchronousMessageExchangeWithBlock:^{ channelElement->audiobusFloatConverter = newFloatConverter; }];
                CFBridgingRelease(oldFloatConverter);
            }
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#if TARGET_OS_IPHONE
- (void)applicationWillEnterForeground:(NSNotification*)notification {
    NSError *error = nil;
    if ( ![((AVAudioSession*)[AVAudioSession sharedInstance]) setActive:YES error:&error] ) {
        NSLog(@"TAAE: Couldn't activate audio session: %@", error);
    }
    
    if ( _interrupted ) {
        _interrupted = NO;
        
        if ( _started && !self.running ) {
            [self start:NULL];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerSessionInterruptionEndedNotification object:self];
    }
    
    if ( _hasSystemError ) [self attemptRecoveryFromSystemError:NULL thenStart:YES];
}
#endif

-(void)audiobusConnectionsChanged:(NSNotification*)notification {
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
    if ( [(id<AEAudiobusForwardDeclarationsProtocol>)notification.object connected] && !self.running ) {
        [self start:NULL];
    }
}

#if TARGET_OS_IPHONE
- (void)interruptionNotification:(NSNotification*)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ( [notification.userInfo[AVAudioSessionInterruptionTypeKey] intValue] == AVAudioSessionInterruptionTypeEnded ) {
            NSLog(@"TAAE: Audio session interruption ended");
            _interrupted = NO;
            
            if ( [[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground || _started ) {
                // make sure we are again the active session
                NSError *error = nil;
                if ( ![((AVAudioSession*)[AVAudioSession sharedInstance]) setActive:YES error:&error] ) {
                    NSLog(@"TAAE: Couldn't activate audio session: %@", error);
                }
            }
            
            if ( _started && !self.running ) {
                [self start:NULL];
            }
            
            [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerSessionInterruptionEndedNotification object:self];
        } else if ( [notification.userInfo[AVAudioSessionInterruptionTypeKey] intValue] == AVAudioSessionInterruptionTypeBegan ) {
            if ( _interrupted ) return;
            
            NSLog(@"TAAE: Audio session interrupted");
            _interrupted = YES;
            
            [self stopInternal];

            UInt32 iaaConnected;
            UInt32 size = sizeof(iaaConnected);
            AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_IsInterAppConnected, kAudioUnitScope_Global, 0, &iaaConnected, &size);
            if ( iaaConnected ) {
                NSLog(@"TAAE: Audio session interrupted while connected to IAA, restarting");
                [self start:NULL];
                return;
            }
            
            [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerSessionInterruptionBeganNotification object:self];
        }
    });
}

- (void)audioRouteChangeNotification:(NSNotification*)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ( _interrupted || !self.running ) return;
        
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        AVAudioSessionRouteDescription *currentRoute = audioSession.currentRoute;
        NSLog(@"TAAE: Changed audio route to %@", [self stringFromRouteDescription:currentRoute]);
        
        Float64 currentSampleRate = audioSession.sampleRate;
        if ( _useHardwareSampleRate && currentSampleRate != _audioDescription.mSampleRate ) {
            NSError *error = nil;
            NSLog(@"TAAE: Changing sample rate to %g", currentSampleRate);
            if ( ![self reinitializeWithChanges:^{
                [self willChangeValueForKey:@"audioDescription"];
                _audioDescription.mSampleRate = currentSampleRate;
                [self didChangeValueForKey:@"audioDescription"];
            } error:&error] ) {
                NSLog(@"TAAE: Couldn't change sample rate: %@", error);
            }
        }

        BOOL playingThroughSpeaker;
        if ( [currentRoute.outputs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"portType = %@", AVAudioSessionPortBuiltInSpeaker]].count > 0 ) {
            playingThroughSpeaker = YES;
        } else {
            playingThroughSpeaker = NO;
        }
        
        BOOL updatedVP = NO;
        if ( _playingThroughDeviceSpeaker != playingThroughSpeaker ) {
            [self willChangeValueForKey:@"playingThroughDeviceSpeaker"];
            _playingThroughDeviceSpeaker = playingThroughSpeaker;
            [self didChangeValueForKey:@"playingThroughDeviceSpeaker"];
            
            if ( _voiceProcessingEnabled && _voiceProcessingOnlyForSpeakerAndMicrophone ) {
                if ( [self mustUpdateVoiceProcessingSettings] ) {
                    [self replaceIONode];
                    updatedVP = YES;
                }
            }
            
            if ( _useMeasurementMode && _avoidMeasurementModeForBuiltInSpeaker ) {
                NSError *error = nil;
                if ( ![audioSession setMode:!_playingThroughDeviceSpeaker ? AVAudioSessionModeMeasurement : AVAudioSessionModeDefault
                                      error:&error] ) {
                    NSLog(@"TAAE: Couldn't set audio session mode: %@", error);
                } else {
                    if ( ![audioSession setPreferredIOBufferDuration:_preferredBufferDuration error:&error] ) {
                        NSLog(@"TAAE: Couldn't set preferred IO buffer duration: %@", error);
                    }
                }
            }
        }
        
        BOOL recordingThroughMic;
        if ( [currentRoute.inputs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"portType = %@", AVAudioSessionPortBuiltInMic]].count > 0 ) {
            recordingThroughMic = YES;
        } else {
            recordingThroughMic = NO;
        }
        if ( _recordingThroughDeviceMicrophone != recordingThroughMic ) {
            [self willChangeValueForKey:@"recordingThroughDeviceMicrophone"];
            _recordingThroughDeviceMicrophone = recordingThroughMic;
            [self didChangeValueForKey:@"recordingThroughDeviceMicrophone"];
        }
        
        if ( _inputEnabled ) {
            __cachedInputLatency = audioSession.inputLatency;
        }
        if (_outputEnabled) {
            __cachedOutputLatency = audioSession.outputLatency;
        }
        
        int reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] intValue];
        if ( !updatedVP && (reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable || reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) && _inputEnabled ) {
            [self updateInputDeviceStatus];
        }
        
        [self willChangeValueForKey:@"inputGainAvailable"];
        [self didChangeValueForKey:@"inputGainAvailable"];
        
        [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerSessionRouteChangeNotification
                                                            object:self
                                                          userInfo:notification.userInfo];
    });
}
#endif

- (void)mediaServiceResetNotification:(NSNotification*)notification {
    NSError * error = nil;
    if ( ![self attemptRecoveryFromSystemError:&error thenStart:YES] ) {
        NSLog(@"TAAE: Unable to recover from system media services reset: %@", error);
        _interrupted = YES;
    }
}

#if TARGET_OS_IPHONE
static void interAppConnectedChangeCallback(void *inRefCon, AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AEAudioController *THIS = (__bridge AEAudioController*)inRefCon;
        
        UInt32 iaaConnected;
        UInt32 size = sizeof(iaaConnected);
        AudioUnitGetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_IsInterAppConnected, kAudioUnitScope_Global, 0, &iaaConnected, &size);
        
        if ( !iaaConnected ) {
            if ( [[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground ) {
                THIS->_interrupted = YES;
            } else {
                [THIS start:NULL];
            }
        }
        
        if ( THIS->_inputEnabled ) {
            [THIS updateInputDeviceStatus];
        }
    });
}
#endif

#pragma mark - Graph and audio session configuration

- (BOOL)initAudioSession {
#if TARGET_OS_IPHONE

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSMutableString *extraInfo = [NSMutableString string];
    NSError *error = nil;
    
    // See if input's available
    BOOL inputAvailable = audioSession.inputAvailable;
    if ( inputAvailable ) [extraInfo appendFormat:@", input available"];
    _audioInputAvailable = _hardwareInputAvailable = inputAvailable;
    
    // Set category
    [self setAudioSessionCategory:_audioSessionCategory];
    
    // Start session
    if ( ![audioSession setActive:YES error:&error] ) {
        NSLog(@"TAAE: Couldn't activate audio session: %@", error);
    }
    
    // Set sample rate
    Float64 sampleRate = _audioDescription.mSampleRate;
    
    if ( ![audioSession setPreferredSampleRate:sampleRate error:&error] ) {
        NSLog(@"TAAE: Couldn't set preferred sample rate: %@", error);
    }
    
    // Fetch sample rate, in case we didn't get quite what we requested
    Float64 achievedSampleRate = audioSession.sampleRate;
    if ( achievedSampleRate != sampleRate ) {
        if ( _useHardwareSampleRate ) {
            _audioDescription.mSampleRate = achievedSampleRate;
            NSLog(@"TAAE: Using hardware sample rate instead: %g", achievedSampleRate);
        } else {
            NSLog(@"TAAE: Hardware sample rate is %g, converting.", achievedSampleRate);
        }
    }

    // Determine audio route
    AVAudioSessionRouteDescription *currentRoute = audioSession.currentRoute;
    [extraInfo appendFormat:@", audio route '%@'", [self stringFromRouteDescription:currentRoute]];
    
    if ( [currentRoute.outputs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"portType = %@", AVAudioSessionPortBuiltInSpeaker]].count > 0 ) {
        _playingThroughDeviceSpeaker = YES;
    } else {
        _playingThroughDeviceSpeaker = NO;
    }

    if ( [currentRoute.inputs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"portType = %@", AVAudioSessionPortBuiltInMic]].count > 0 ) {
        _recordingThroughDeviceMicrophone = YES;
    } else {
        _recordingThroughDeviceMicrophone = NO;
    }
    
    // Determine IO buffer duration
    Float32 bufferDuration = audioSession.IOBufferDuration;
    if ( _currentBufferDuration != bufferDuration ) self.currentBufferDuration = bufferDuration;
    
    NSLog(@"TAAE: Audio session initialized (%@) HW samplerate: %g", [extraInfo stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]], achievedSampleRate);
#endif
    
    return YES;
}

- (BOOL)setup {
    // Create a new AUGraph
    OSStatus result = NewAUGraph(&_audioGraph);
    if ( !AECheckOSStatus(result, "NewAUGraph") ) return NO;
    
    BOOL useVoiceProcessing = [self usingVPIO];
    
    OSType componentSubType;
    if ( useVoiceProcessing ) {
        componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    } else {
#if TARGET_OS_IPHONE
        componentSubType = kAudioUnitSubType_RemoteIO;
#else
        componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
    }
    
    // Input/output unit description
    AudioComponentDescription io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = componentSubType,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    // Create a node in the graph that is an AudioUnit, using the supplied AudioComponentDescription to find and open that unit
    result = AUGraphAddNode(_audioGraph, &io_desc, &_ioNode);
    if ( !AECheckOSStatus(result, "AUGraphAddNode io") ) return NO;
    
    // Open the graph - AudioUnits are open but not initialized (no resource allocation occurs here)
    result = AUGraphOpen(_audioGraph);
    if ( !AECheckOSStatus(result, "AUGraphOpen") ) return NO;
    
    // Get reference to IO audio unit
    result = AUGraphNodeInfo(_audioGraph, _ioNode, NULL, &_ioAudioUnit);
    if ( !AECheckOSStatus(result, "AUGraphNodeInfo") ) return NO;

#ifdef DEBUG
    // Add a render notify to the top audio unit, for the purposes of performance profiling
    AECheckOSStatus(AudioUnitAddRenderNotify(_ioAudioUnit, &ioUnitRenderNotifyCallback, (__bridge void*)self), "AudioUnitAddRenderNotify");
#endif
    
#if !TARGET_OS_IPHONE
    if ( _inputEnabled ) {
        // Initialize the audio unit for OSX input
        AudioComponentDescription i_desc = {
            .componentType = kAudioUnitType_Output,
            .componentSubType = kAudioUnitSubType_HALOutput,
            .componentManufacturer = kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0
        };
        
        AudioComponent inputComponent = AudioComponentFindNext(NULL, &i_desc);
        AECheckOSStatus(AudioComponentInstanceNew(inputComponent, &_iAudioUnit), "AudioComponentInstanceNew");
    }
#endif
    
    [self configureAudioUnit];
    
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }

    if ( !_topGroup ) {
        // Allocate top-level group
        _topChannel = (AEChannelRef)calloc(1, sizeof(channel_t));
        _topGroup = (AEChannelGroupRef)calloc(1, sizeof(channel_group_t));
        _topChannel->type     = kChannelTypeGroup;
        _topChannel->ptr      = _topGroup;
        _topChannel->object = AEAudioSourceMainOutput;
        _topChannel->playing  = YES;
        _topChannel->volume   = 1.0;
        _topChannel->pan      = 0.0;
        _topChannel->muted    = NO;
        _topChannel->audioController = (__bridge void *)self;
        _topGroup->channel   = _topChannel;
        
        UInt32 size = sizeof(_topChannel->audioDescription);
        AECheckOSStatus(AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_topChannel->audioDescription, &size),
                   "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output)");
    }
    
    // Initialise group
    [self configureChannelsInRange:NSMakeRange(0, 1) forGroup:NULL];
    
    // Register a callback to be notified when the main mixer unit renders
    AECheckOSStatus(AudioUnitAddRenderNotify(_topGroup->mixerAudioUnit, &topRenderNotifyCallback, (__bridge void*)self), "AudioUnitAddRenderNotify");
    
    // Set the master volume
    AudioUnitParameterValue value = _masterOutputVolume;
    AECheckOSStatus(AudioUnitSetParameter(_topGroup->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, value, 0), "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
    
    // Initialize the graph
    result = AUGraphInitialize(_audioGraph);
    if ( !AECheckOSStatus(result, "AUGraphInitialize") ) {
        self.lastError = [NSError audioControllerErrorWithMessage:@"Couldn't create audio graph" OSStatus:result];
        [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerErrorOccurredNotification object:self userInfo:@{ AEAudioControllerErrorKey: _lastError}];
        _hasSystemError = YES;
        return NO;
    }
    
    NSLog(@"TAAE: Engine setup");
    
    return YES;
}

- (BOOL)reinitializeWithChanges:(void(^)())block error:(NSError**)error {
    BOOL wasStarted = _started;
    if ( _started ) {
        [self stopInternal];
    }
    [self teardown];
    
    block();
    
    if ( ![self initAudioSession] || ![self setup] ) {
        NSLog(@"TAAE: error setting up audio session");
        _audioGraph = NULL;
        return NO;
    }
    
    [self sendSetupToObjects];
    [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerDidRecreateGraphNotification object:self];
    
    if ( wasStarted ) {
        if ( ![self start:error] ) {
            NSLog(@"TAAE: Error restarting controller");
            return NO;
        }
    }
    
    return YES;
}

- (void)replaceIONode {
    if ( !_topChannel ) return;
    BOOL useVoiceProcessing = [self usingVPIO];

    OSType componentSubType;
    if ( useVoiceProcessing ) {
        componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    } else {
#if TARGET_OS_IPHONE
        componentSubType = kAudioUnitSubType_RemoteIO;
#else
        componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
    }
    
    AudioComponentDescription io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = componentSubType,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    BOOL wasRunning = self.running;
    
    if ( !AECheckOSStatus(AUGraphStop(_audioGraph), "AUGraphStop") // Stop graph
            || !AECheckOSStatus(AUGraphRemoveNode(_audioGraph, _ioNode), "AUGraphRemoveNode") // Remove the old IO node
            || !AECheckOSStatus(AUGraphAddNode(_audioGraph, &io_desc, &_ioNode), "AUGraphAddNode io") // Create new IO node
            || !AECheckOSStatus(AUGraphNodeInfo(_audioGraph, _ioNode, NULL, &_ioAudioUnit), "AUGraphNodeInfo") ) { // Get reference to input audio unit
        [self attemptRecoveryFromSystemError:NULL thenStart:YES];
        return;
    }
    
    [self configureAudioUnit];
    
    OSStatus result = AUGraphUpdate(_audioGraph, NULL);
    if ( result != kAUGraphErr_NodeNotFound /* Ignore this error */ && !AECheckOSStatus(result, "AUGraphUpdate") ) {
        [self attemptRecoveryFromSystemError:NULL thenStart:YES];
        return;
    }

    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
    
    
    [self configureChannelsInRange:NSMakeRange(0, 1) forGroup:NULL];
    
    AECheckOSStatus([self updateGraph], "Update graph");
    
    __audioThread = NULL;
    
    if ( wasRunning ) {
        @synchronized ( self ) {
            AECheckOSStatus(AUGraphStart(_audioGraph), "AUGraphStart");
        }
    }
}

- (void)configureAudioUnit {
#if TARGET_OS_IPHONE
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    if ( _inputEnabled ) {
        // Enable input
        UInt32 enableInputFlag = 1;
        OSStatus result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInputFlag, sizeof(enableInputFlag));
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)");
        
        // Register a callback to receive audio
        AURenderCallbackStruct inRenderProc;
        inRenderProc.inputProc = &inputAvailableCallback;
        inRenderProc.inputProcRefCon = (__bridge void *)self;
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inRenderProc, sizeof(inRenderProc));
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_SetInputCallback)");
    } else {
        // Disable input
        UInt32 enableInputFlag = 0;
        OSStatus result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInputFlag, sizeof(enableInputFlag));
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)");
    }
#else
    if ( _inputEnabled ) {
        // Enable input for OSX
        UInt32 enableFlag = 1;
        UInt32 disableFlag = 0;
        AudioUnitScope outputBus = 0;
        AudioUnitScope inputBus = 1;
        
        OSStatus result;
        
        // Enable input and disable output on the audio unit
        result = AudioUnitSetProperty(_iAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, &enableFlag, sizeof(enableFlag));
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)");
        
        result = AudioUnitSetProperty(_iAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputBus, &disableFlag, sizeof(disableFlag));
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)");
        
        // Get the system's default input device
        AudioDeviceID defaultDevice = kAudioDeviceUnknown;
        UInt32 propertySize = sizeof(defaultDevice);
        AudioObjectPropertyAddress defaultDeviceProperty = {
            .mSelector = kAudioHardwarePropertyDefaultInputDevice,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMaster
        };
        result = AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultDeviceProperty, 0, NULL, &propertySize, &defaultDevice);
        AECheckOSStatus(result, "AudioObjectGetPropertyData(kAudioObjectSystemObject)");
        
        // Set the sample rate of the input device to the output samplerate (if possible)
        AudioValueRange inputSampleRate;
        inputSampleRate.mMinimum = _audioDescription.mSampleRate;
        inputSampleRate.mMaximum = _audioDescription.mSampleRate;
        defaultDeviceProperty.mSelector = kAudioDevicePropertyNominalSampleRate;
        result = AudioObjectSetPropertyData(defaultDevice, &defaultDeviceProperty, 0, NULL, sizeof(inputSampleRate), &inputSampleRate);
        
        BOOL matchingSampleRates = ( result != kAudioCodecUnsupportedFormatError );
        AECheckOSStatus(result, "AudioObjectSetPropertyData(kAudioDevicePropertyNominalSampleRate)");
        
        // Set the input device to the system's default input device
        result = AudioUnitSetProperty(_iAudioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, outputBus, &defaultDevice, sizeof(defaultDevice));
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)");
    
        // Set input unit ASBD output to match the hardware input ASBD
        propertySize = sizeof(AudioStreamBasicDescription);
        result = AudioUnitGetProperty(_iAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &_rawInputAudioDescription, &propertySize);
        AECheckOSStatus(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
        
        if ( matchingSampleRates ) {
            _rawInputAudioDescription.mSampleRate = _audioDescription.mSampleRate;
        } else {
            defaultDeviceProperty.mSelector = kAudioDevicePropertyNominalSampleRate;
            UInt32 deviceSampleRateSize = sizeof(Float64);
            Float64 deviceSampleRate;
            result = AudioObjectGetPropertyData(defaultDevice, &defaultDeviceProperty, 0, NULL, &deviceSampleRateSize, &deviceSampleRate);
            AECheckOSStatus(result, "AudioObjectGetPropertyData(kAudioDevicePropertyNominalSampleRate)");
            
            _rawInputAudioDescription.mSampleRate = deviceSampleRate;
            
            NSLog(@"TAAE: Warning: could not set hardware input sample rate (%.f Hz) to same sample rate as output (%.f Hz). Performing on-the-fly sample rate conversion.", deviceSampleRate, _audioDescription.mSampleRate);
        }
        
        propertySize = sizeof(AudioStreamBasicDescription);
        result = AudioUnitSetProperty(_iAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &_rawInputAudioDescription, propertySize);
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        
        // Register a callback to receive audio
        AURenderCallbackStruct inRenderProc;
        inRenderProc.inputProc = &inputAvailableCallback;
        inRenderProc.inputProcRefCon = (__bridge void *)self;
        result = AudioUnitSetProperty(_iAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inRenderProc, sizeof(inRenderProc));
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_SetInputCallback)");
        
        // Initialize the input audio unit
        result = AudioUnitInitialize(_iAudioUnit);
        AECheckOSStatus(result, "AudioUnitInitialize");
    }
#endif

    if (!_outputEnabled) {
        // disable output
        UInt32 enableOutputFlag = 0;
        OSStatus result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOutputFlag, sizeof(enableOutputFlag));
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO) OUTPUT");
    }

#if TARGET_OS_IPHONE
    if ( [self usingVPIO] ) {
        if ( _preferredBufferDuration ) {
            // If we're using voice processing, clamp the buffer duration
            Float32 preferredBufferSize = MAX(kMaxBufferDurationWithVPIO, _preferredBufferDuration);
            NSError *error = nil;
            if ( ![audioSession setPreferredIOBufferDuration:preferredBufferSize error:&error] ) {
                NSLog(@"TAAE: Couldn't set preferred IO buffer duration: %@", error);
            }
        }
    } else {
        if ( _preferredBufferDuration ) {
            // Set the buffer duration
            NSError *error = nil;
            if ( ![audioSession setPreferredIOBufferDuration:_preferredBufferDuration error:&error] ) {
                NSLog(@"TAAE: Couldn't set preferred IO buffer duration: %@", error);
            }
        }
    }
#endif
    
    // Set the audio unit to handle up to 4096 frames per slice to keep rendering during screen lock
    AECheckOSStatus(AudioUnitSetProperty(_ioAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &kMaxFramesPerSlice, sizeof(kMaxFramesPerSlice)),
                "AudioUnitSetProperty(kAudioUnitProperty_MaximumFramesPerSlice)");

#if !TARGET_OS_IPHONE
    if ( _inputEnabled ) {
        AECheckOSStatus(AudioUnitSetProperty(_iAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &kMaxFramesPerSlice, sizeof(kMaxFramesPerSlice)),
                    "AudioUnitSetProperty(kAudioUnitProperty_MaximumFramesPerSlice)");
    }
#endif
    
#if TARGET_OS_IPHONE
    AECheckOSStatus(AudioUnitAddPropertyListener(_ioAudioUnit, kAudioUnitProperty_IsInterAppConnected, interAppConnectedChangeCallback, (__bridge void*)self),
                "AudioUnitAddPropertyListener(kAudioUnitProperty_IsInterAppConnected)");
#endif
}

- (void)teardown {
    
    for ( int i=0; i<_inputCallbackCount; i++ ) {
        if ( _inputCallbacks[i].audioConverter ) {
            AudioConverterDispose(_inputCallbacks[i].audioConverter);
            _inputCallbacks[i].audioConverter = NULL;
        }
        
        if ( _inputCallbacks[i].audioBufferList ) {
            AEAudioBufferListFree(_inputCallbacks[i].audioBufferList);
            _inputCallbacks[i].audioBufferList = NULL;
        }
    }
    
    if ( _topGroup ) {
        _topChannel->setRenderNotification = NO;
        [self markGroupTorndown:_topGroup];
    }
    
    [self sendTeardownToObjects];
    
    AECheckOSStatus(AUGraphClose(_audioGraph), "AUGraphClose");
    AECheckOSStatus(DisposeAUGraph(_audioGraph), "DisposeAUGraph");
    _audioGraph = NULL;
    _ioAudioUnit = NULL;
#if !TARGET_OS_IPHONE
    if ( _inputEnabled ) {
        AECheckOSStatus(AudioUnitUninitialize(_iAudioUnit), "AudioUnitUninitialize");
        AECheckOSStatus(AudioComponentInstanceDispose(_iAudioUnit), "AudioComponentInstanceDispose");
        _iAudioUnit = NULL;
    }
#endif
}

- (OSStatus)updateGraph {
    // Retry a few times (as sometimes the graph will be in the wrong state to update)
    OSStatus err = 0;
    for ( int retry=0; retry<6; retry++ ) {
        err = AUGraphUpdate(_audioGraph, NULL);
        if ( err != kAUGraphErr_CannotDoInCurrentContext ) break;
        [NSThread sleepForTimeInterval:0.01];
    }
    
    return err;
}

- (BOOL)mustUpdateVoiceProcessingSettings {
    if ( !_audioGraph ) return NO;
    BOOL useVoiceProcessing = [self usingVPIO];

    OSType componentSubType;
    if ( useVoiceProcessing ) {
        componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    } else {
#if TARGET_OS_IPHONE
        componentSubType = kAudioUnitSubType_RemoteIO;
#else
        componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
    }
    
    AudioComponentDescription target_io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = componentSubType,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    AudioComponentDescription io_desc;
    if ( !AECheckOSStatus(AUGraphNodeInfo(_audioGraph, _ioNode, &io_desc, NULL), "AUGraphNodeInfo(ioNode)") )
        return NO;
    
    if ( io_desc.componentSubType != target_io_desc.componentSubType ) {
        
        if ( useVoiceProcessing ) {
            NSLog(@"TAAE: Restarting audio system to use VPIO");
        } else {
            NSLog(@"TAAE: Restarting audio system to use normal input unit");
        }
        
        return YES;
    }
    
    return NO;
}

- (BOOL)updateInputDeviceStatus {
    if ( !_audioGraph ) return NO;
    NSAssert(_inputEnabled, @"Input must be enabled");
    
    BOOL success = YES;
    BOOL inputAvailable = YES;
    BOOL hardwareInputAvailable = NO;
#if TARGET_OS_IPHONE
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    inputAvailable          = audioSession.inputAvailable;
    hardwareInputAvailable  = inputAvailable;
    UInt32 usingIAA              = NO;
#endif
    int numberOfInputChannels    = _audioDescription.mChannelsPerFrame;
    BOOL usingAudiobus           = NO;
    BOOL usingAudiobusReceiver   = NO;

#if TARGET_OS_IPHONE
    UInt32 size = sizeof(usingIAA);
    AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_IsInterAppConnected, kAudioUnitScope_Global, 0, &usingIAA, &size);

    // Determine if audio input is available, and the number of input channels available
    if ( (_audiobusReceiverPort && ABReceiverPortIsConnected(_audiobusReceiverPort)) || (_audiobusFilterPort && ABFilterPortIsConnected(_audiobusFilterPort)) ) {
        inputAvailable          = YES;
        numberOfInputChannels   = 2;
        usingAudiobus           = YES;
        usingAudiobusReceiver   = _audiobusReceiverPort && ABReceiverPortIsConnected(_audiobusReceiverPort);
    } else if ( usingIAA ) {
        AudioStreamBasicDescription inputDescription;
        UInt32 size = sizeof(inputDescription);
        AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &inputDescription, &size);
        numberOfInputChannels   = inputDescription.mChannelsPerFrame;
        inputAvailable          = numberOfInputChannels > 0;
    } else {
        numberOfInputChannels = 0;
        if ( inputAvailable ) {
            // Check channels on input
            BOOL hasChannelCount = NO;
            NSInteger channels = audioSession.inputNumberOfChannels;
            hasChannelCount = channels < 128 && channels > 0;
            if ( channels == AVAudioSessionErrorCodeIncompatibleCategory ) {
                // Attempt to force category, and try again
                NSString * originalCategory = _audioSessionCategory;
                NSString * testCategory = _outputEnabled ?  AVAudioSessionCategoryPlayAndRecord : AVAudioSessionCategoryRecord;
                self.audioSessionCategory = testCategory;
                channels = audioSession.inputNumberOfChannels;
                hasChannelCount = channels < 128 && channels >= 0;
                if ( !hasChannelCount ) {
                    NSLog(@"TAAE: Audio session error (rdar://13022588). Power-cycling audio session.");
                    [audioSession setActive:NO error:NULL];
                    [audioSession setActive:YES error:NULL];
                    channels = audioSession.inputNumberOfChannels;
                    hasChannelCount = channels < 128 && channels >= 0;
                }
                
                if ( ![originalCategory isEqualToString:testCategory] ) {
                    self.audioSessionCategory = originalCategory;
                }
            }
            
            if ( hasChannelCount ) {
                numberOfInputChannels = (int)channels;
            } else {
                if ( !_lastError ) {
                    self.lastError = [NSError audioControllerErrorWithMessage:@"Audio system error while determining input channel count" OSStatus:(OSStatus)channels];
                    [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerErrorOccurredNotification object:self userInfo:@{ AEAudioControllerErrorKey: _lastError}];
                }
                success = NO;
                inputAvailable = NO;
            }
        }
    }
#endif
    
    AudioStreamBasicDescription rawAudioDescription = _rawInputAudioDescription;
    AudioBufferList *inputAudioBufferList           = _inputAudioBufferList;
    audio_level_monitor_t inputLevelMonitorData     = _inputLevelMonitorData;
#if TARGET_OS_IPHONE
    AudioBufferList *inputAudioScratchBufferList    = _inputAudioScratchBufferList;
    AEFloatConverter *inputAudioFloatConverter      = _inputAudioFloatConverter;
#endif
    
    BOOL inputChannelsChanged = _numberOfInputChannels != numberOfInputChannels;
    BOOL inputDescriptionChanged = inputChannelsChanged;
    BOOL inputAvailableChanged = _audioInputAvailable != inputAvailable;
    
    int inputCallbackCount = _inputCallbackCount;
    input_callback_table_t *inputCallbacks = (input_callback_table_t*)malloc(sizeof(input_callback_table_t) * inputCallbackCount);
    memcpy(inputCallbacks, _inputCallbacks, sizeof(input_callback_table_t) * inputCallbackCount);

    if ( inputAvailable ) {
#if TARGET_OS_IPHONE
        rawAudioDescription = _audioDescription;
#else
        rawAudioDescription = _rawInputAudioDescription;
#endif
        AEAudioStreamBasicDescriptionSetChannelsPerFrame(&rawAudioDescription, numberOfInputChannels);
        
        BOOL iOS4ConversionRequired = NO;
        
        // Configure input tables
        for ( int entryIndex = 0; entryIndex < inputCallbackCount; entryIndex++ ) {
            input_callback_table_t *entry = &inputCallbacks[entryIndex];
            
            AudioStreamBasicDescription audioDescription = _audioDescription;
            
            if ( _inputMode == AEInputModeVariableAudioFormat ) {
                audioDescription = rawAudioDescription;
                
                if ( [(__bridge NSArray*)_inputCallbacks[entryIndex].channelMap count] > 0 ) {
                    // Set the target input audio description channels to the number of selected channels
                    AEAudioStreamBasicDescriptionSetChannelsPerFrame(&audioDescription, (int)[(__bridge NSArray*)_inputCallbacks[entryIndex].channelMap count]);
                }
            }
            
            if ( !entry->audioBufferList || memcmp(&audioDescription, &entry->audioDescription, sizeof(audioDescription)) != 0 ) {
                if ( entryIndex == 0 ) {
                    inputDescriptionChanged = YES;
                }
                entry->audioDescription = audioDescription;
                entry->audioBufferList = AEAudioBufferListCreate(entry->audioDescription, kInputAudioBufferFrames);
            }
            
            // Determine if conversion is required
            
#if TARGET_OS_IPHONE
            BOOL sampleRateConverterRequired = NO;
#else
            BOOL sampleRateConverterRequired = entry->audioDescription.mSampleRate != _rawInputAudioDescription.mSampleRate;
#endif
            
            BOOL converterRequired = iOS4ConversionRequired
                                            || sampleRateConverterRequired
                                            || entry->audioDescription.mChannelsPerFrame != numberOfInputChannels
                                            || (entry->channelMap && [(__bridge NSArray*)entry->channelMap count] != entry->audioDescription.mChannelsPerFrame);
            if ( !converterRequired && entry->channelMap ) {
                for ( int i=0; i<[(__bridge NSArray*)entry->channelMap count]; i++ ) {
                    id channelEntry = ((__bridge NSArray*)entry->channelMap)[i];
                    if ( ([channelEntry isKindOfClass:[NSArray class]] && ([channelEntry count] > 1 || [channelEntry[0] intValue] != i)) || ([channelEntry isKindOfClass:[NSNumber class]] && [channelEntry intValue] != i) ) {
                        converterRequired = YES;
                        break;
                    }
                }
            }
            
            if ( entryIndex == 0 /* Default input entry */ ) {
                
                if ( !converterRequired ) {
                    // Just change the audio unit's input stream format
                    rawAudioDescription = entry->audioDescription;
                }
                
#if TARGET_OS_IPHONE
                BOOL useVoiceProcessing = [self usingVPIO];
                if ( useVoiceProcessing && (_audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) && [[[UIDevice currentDevice] systemVersion] floatValue] < 5.0 ) {
                    // iOS 4 cannot handle non-interleaved audio and voice processing. Use interleaved audio and a converter.
                    iOS4ConversionRequired = converterRequired = YES;
                    
                    rawAudioDescription.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved;
                    rawAudioDescription.mBytesPerFrame *= rawAudioDescription.mChannelsPerFrame;
                    rawAudioDescription.mBytesPerPacket *= rawAudioDescription.mChannelsPerFrame;
                }
#endif
                
                if ( inputLevelMonitorData.monitoringEnabled && memcmp(&_rawInputAudioDescription, &rawAudioDescription, sizeof(_rawInputAudioDescription)) != 0 ) {
                    inputLevelMonitorData.channels = rawAudioDescription.mChannelsPerFrame;
                    inputLevelMonitorData.floatConverter = (__bridge_retained void*)[[AEFloatConverter alloc] initWithSourceFormat:rawAudioDescription];
                    inputLevelMonitorData.scratchBuffer = AEAudioBufferListCreate(((__bridge AEFloatConverter*)inputLevelMonitorData.floatConverter).floatingPointAudioDescription, kLevelMonitorScratchBufferSize);
                }
            }
            
            if ( converterRequired ) {
                // Set up conversion
                
                UInt32 channelMapSize = sizeof(SInt32) * entry->audioDescription.mChannelsPerFrame;
                SInt32 *channelMap = (SInt32*)malloc(channelMapSize);
                
                for ( int i=0; i<entry->audioDescription.mChannelsPerFrame; i++ ) {
                    if ( [(__bridge NSArray*)entry->channelMap count] > 0 ) {
                        channelMap[i] = min(numberOfInputChannels-1,
                                               [(__bridge NSArray*)entry->channelMap count] > i
                                               ? [((__bridge NSArray*)entry->channelMap)[i] intValue]
                                               : [[(__bridge NSArray*)entry->channelMap lastObject] intValue]);
                    } else {
                        channelMap[i] = min(numberOfInputChannels-1, i);
                    }
                }

                AudioStreamBasicDescription converterInputFormat;
                AudioStreamBasicDescription converterOutputFormat;
                UInt32 formatSize = sizeof(converterOutputFormat);
                UInt32 currentMappingSize = 0;
                
                if ( entry->audioConverter ) {
                    AECheckOSStatus(AudioConverterGetPropertyInfo(entry->audioConverter, kAudioConverterChannelMap, &currentMappingSize, NULL),
                                "AudioConverterGetPropertyInfo(kAudioConverterChannelMap)");
                }
                SInt32 *currentMapping = (SInt32*)(currentMappingSize != 0 ? malloc(currentMappingSize) : NULL);
                
                if ( entry->audioConverter ) {
                    AECheckOSStatus(AudioConverterGetProperty(entry->audioConverter, kAudioConverterCurrentInputStreamDescription, &formatSize, &converterInputFormat),
                                "AudioConverterGetProperty(kAudioConverterCurrentInputStreamDescription)");
                    AECheckOSStatus(AudioConverterGetProperty(entry->audioConverter, kAudioConverterCurrentOutputStreamDescription, &formatSize, &converterOutputFormat),
                                "AudioConverterGetProperty(kAudioConverterCurrentOutputStreamDescription)");
                    if ( currentMapping ) {
                        AECheckOSStatus(AudioConverterGetProperty(entry->audioConverter, kAudioConverterChannelMap, &currentMappingSize, currentMapping),
                                    "AudioConverterGetProperty(kAudioConverterChannelMap)");
                    }
                }
                
                if ( !entry->audioConverter
                        || memcmp(&converterInputFormat, &rawAudioDescription, sizeof(AudioStreamBasicDescription)) != 0
                        || memcmp(&converterOutputFormat, &entry->audioDescription, sizeof(AudioStreamBasicDescription)) != 0
                        || (currentMappingSize != channelMapSize || memcmp(currentMapping, channelMap, channelMapSize) != 0) ) {
                    
                    AECheckOSStatus(AudioConverterNew(&rawAudioDescription, &entry->audioDescription, &entry->audioConverter), "AudioConverterNew");
                    AECheckOSStatus(AudioConverterSetProperty(entry->audioConverter, kAudioConverterChannelMap, channelMapSize, channelMap), "AudioConverterSetProperty(kAudioConverterChannelMap");
                    
                    if ( sampleRateConverterRequired ) {
                        UInt32 primeMethod;
                        primeMethod = kConverterPrimeMethod_None;
                        AECheckOSStatus(AudioConverterSetProperty(entry->audioConverter, kAudioConverterPrimeMethod, sizeof(primeMethod), &primeMethod), "AudioConverterSetProperty(kAudioConverterPrimeMethod)");

                        UInt32 quality = kAudioConverterQuality_Max;
                        AECheckOSStatus(AudioConverterSetProperty(entry->audioConverter, kAudioConverterSampleRateConverterQuality, sizeof(quality), &quality), "AudioConverterSetProperty(kAudioConverterSampleRateConverterQuality)");

                        UInt32 complexity = kAudioConverterSampleRateConverterComplexity_Mastering;
                        AECheckOSStatus(AudioConverterSetProperty(entry->audioConverter, kAudioConverterSampleRateConverterComplexity, sizeof(complexity), &complexity), "AudioConverterSetProperty(kAudioConverterSampleRateConverterComplexity)");
                    }
                }
                
                if ( currentMapping ) free(currentMapping);
                free(channelMap);
                channelMap = NULL;
            } else {
                // No converter/channel map required
                entry->audioConverter = NULL;
            }
        }
        
        BOOL rawInputAudioDescriptionChanged = memcmp(&_rawInputAudioDescription, &rawAudioDescription, sizeof(_rawInputAudioDescription)) != 0;
        if ( !inputAudioBufferList || rawInputAudioDescriptionChanged ) {
            inputAudioBufferList = AEAudioBufferListCreate(rawAudioDescription, kInputAudioBufferFrames);
        }
        
#if TARGET_OS_IPHONE
        if ( _useMeasurementMode && _boostBuiltInMicGainInMeasurementMode ) {
            if ( !inputAudioScratchBufferList || rawInputAudioDescriptionChanged ) {
                inputAudioScratchBufferList = AEAudioBufferListCreate(rawAudioDescription, kInputAudioBufferFrames);
            }
            if ( !inputAudioFloatConverter || rawInputAudioDescriptionChanged ) {
                inputAudioFloatConverter = [[AEFloatConverter alloc] initWithSourceFormat:rawAudioDescription];
            }
        } else {
            inputAudioScratchBufferList = NULL;
            inputAudioFloatConverter = nil;
        }
#endif
        
    } else if ( !inputAvailable ) {
#if TARGET_OS_IPHONE
        if ( [_audioSessionCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord] || [_audioSessionCategory isEqualToString:AVAudioSessionCategoryRecord] ) {
            // Update audio session as appropriate (will select a non-recording category for us)
            self.audioSessionCategory = _audioSessionCategory;
        }
#endif
        
        inputAudioBufferList = NULL;
        
        // Configure input tables
        for ( int entryIndex = 0; entryIndex < inputCallbackCount; entryIndex++ ) {
            input_callback_table_t *entry = &inputCallbacks[entryIndex];
            entry->audioConverter = NULL;
            entry->audioBufferList = NULL;
        }
    }
    
    if ( inputChannelsChanged ) {
        [self willChangeValueForKey:@"numberOfInputChannels"];
    }
    
    if ( inputDescriptionChanged ) {
        [self willChangeValueForKey:@"inputAudioDescription"];
    }
    
    if ( inputAvailableChanged ) {
        [self willChangeValueForKey:@"audioInputAvailable"];
    }
    
    AudioBufferList *oldInputBuffer     = _inputAudioBufferList;
    
#if TARGET_OS_IPHONE
    AudioBufferList *oldInputScratchBuffer = _inputAudioScratchBufferList;
#endif
    
    input_callback_table_t *oldInputCallbacks = _inputCallbacks;
    int oldInputCallbackCount = _inputCallbackCount;
    audio_level_monitor_t oldInputLevelMonitorData = _inputLevelMonitorData;
    
    if ( usingAudiobusReceiver) {
        AudioStreamBasicDescription clientFormat = [(id<AEAudiobusForwardDeclarationsProtocol>)_audiobusReceiverPort clientFormat];
        if ( memcmp(&clientFormat, &rawAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
            [(id<AEAudiobusForwardDeclarationsProtocol>)_audiobusReceiverPort setClientFormat:rawAudioDescription];
        }
    }
    
    // Set input stream format and update the properties, on the realtime thread
    [self performSynchronousMessageExchangeWithBlock:^{
        _numberOfInputChannels    = numberOfInputChannels;
        _rawInputAudioDescription = rawAudioDescription;
        _inputAudioBufferList     = inputAudioBufferList;
#if TARGET_OS_IPHONE
        _inputAudioScratchBufferList = inputAudioScratchBufferList;
        _inputAudioFloatConverter = inputAudioFloatConverter;
#endif
        _audioInputAvailable      = inputAvailable;
        _hardwareInputAvailable   = hardwareInputAvailable;
        _inputCallbacks           = inputCallbacks;
        _inputCallbackCount       = inputCallbackCount;
        _usingAudiobusInput       = usingAudiobusReceiver;
        _inputLevelMonitorData    = inputLevelMonitorData;
    }];

#if TARGET_OS_IPHONE
    if ( inputAvailable && (!_audiobusReceiverPort || !ABReceiverPortIsConnected(_audiobusReceiverPort)) ) {
        AudioStreamBasicDescription currentAudioDescription;
        UInt32 size = sizeof(currentAudioDescription);
        OSStatus result = AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &currentAudioDescription, &size);
        AECheckOSStatus(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
        
        if ( memcmp(&currentAudioDescription, &rawAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
            result = AudioUnitSetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &rawAudioDescription, sizeof(AudioStreamBasicDescription));
            AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        }
    }
#endif
    
    if ( oldInputBuffer && oldInputBuffer != inputAudioBufferList ) {
        AEAudioBufferListFree(oldInputBuffer);
    }
    
#if TARGET_OS_IPHONE
    if ( oldInputScratchBuffer && oldInputScratchBuffer != inputAudioScratchBufferList ) {
        AEAudioBufferListFree(oldInputScratchBuffer);
    }
#endif
    
    if ( oldInputCallbacks != inputCallbacks ) {
        for ( int entryIndex = 0; entryIndex < oldInputCallbackCount; entryIndex++ ) {
            input_callback_table_t *oldEntry = &oldInputCallbacks[entryIndex];
            input_callback_table_t *entry = entryIndex < inputCallbackCount ? &inputCallbacks[entryIndex] : NULL;
            
            if ( oldEntry->audioConverter && (!entry || oldEntry->audioConverter != entry->audioConverter) ) {
                AudioConverterDispose(oldEntry->audioConverter);
            }
            if ( oldEntry->audioBufferList && (!entry || oldEntry->audioBufferList != entry->audioBufferList) ) {
                AEAudioBufferListFree(oldEntry->audioBufferList);
            }
        }
        free(oldInputCallbacks);
    }
    
    if ( oldInputLevelMonitorData.floatConverter != inputLevelMonitorData.floatConverter ) {
        CFBridgingRelease(oldInputLevelMonitorData.floatConverter);
    }
    if ( oldInputLevelMonitorData.scratchBuffer != inputLevelMonitorData.scratchBuffer ) {
        AEAudioBufferListFree(oldInputLevelMonitorData.scratchBuffer);
    }
    
    if ( inputChannelsChanged ) {
        [self didChangeValueForKey:@"numberOfInputChannels"];
    }
    
    if ( inputDescriptionChanged ) {
        [self didChangeValueForKey:@"inputAudioDescription"];
    }
    
    if ( inputAvailableChanged ) {
        [self didChangeValueForKey:@"audioInputAvailable"];
    }
    
    if ( inputChannelsChanged || inputAvailableChanged || inputDescriptionChanged ) {
        if ( inputAvailable ) {
            NSLog(@"TAAE: Input status updated (%u channel, %@%@%@%@)",
                  (unsigned int)numberOfInputChannels,
                  usingAudiobus ? @"using Audiobus, " : @"",
                  rawAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? @"non-interleaved" : @"interleaved",
                  [self usingVPIO] ? @", using voice processing" : @"",
                  inputCallbacks[0].audioConverter ? @", with converter" : @"");
        } else {
            NSLog(@"TAAE: Input status updated: No input avaliable");
        }
    }
    
    return success;
}

- (void)configureChannelsInRange:(NSRange)range forGroup:(AEChannelGroupRef)group {
    
    if ( group ) {
        // Ensure that we have enough input buses in the mixer
        UInt32 busCount = group->channelCount;
        AECheckOSStatus(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)), "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)");
    }
    
    // Load existing interactions
    UInt32 numInteractions = kMaximumChannelsPerGroup*2;
    AUNodeInteraction interactions[numInteractions];
    AECheckOSStatus(AUGraphGetNodeInteractions(_audioGraph, group ? group->mixerNode : _ioNode, &numInteractions, interactions), "AUGraphGetNodeInteractions");
    
    for ( int i = (int)range.location; i < range.location+range.length; i++ ) {
        AEChannelRef channel = group ? group->channels[i] : _topChannel;
        
        // Find the existing upstream connection
        BOOL hasUpstreamInteraction = NO;
        AUNodeInteraction upstreamInteraction;
        for ( int j=0; j<numInteractions; j++ ) {
            if ( (interactions[j].nodeInteractionType == kAUNodeInteraction_Connection && interactions[j].nodeInteraction.connection.destNode == (group ? group->mixerNode : _ioNode) && interactions[j].nodeInteraction.connection.destInputNumber == i) ||
                (interactions[j].nodeInteractionType == kAUNodeInteraction_InputCallback && interactions[j].nodeInteraction.inputCallback.destNode == (group ? group->mixerNode : _ioNode) && interactions[j].nodeInteraction.inputCallback.destInputNumber == i) ) {
                upstreamInteraction = interactions[j];
                hasUpstreamInteraction = YES;
                break;
            }
        }
        
        AUNode targetNode = group ? group->mixerNode : _ioNode;
        AudioUnit targetUnit = group ? group->mixerAudioUnit : _ioAudioUnit;
        int targetBus = i;
        
        if ( !channel ) {
            // Removed channel - unset the input callback if necessary
            if ( hasUpstreamInteraction ) {
                AECheckOSStatus(AUGraphDisconnectNodeInput(_audioGraph, targetNode, targetBus), "AUGraphDisconnectNodeInput");
            }
            continue;
        }
        
        if ( channel->type == kChannelTypeChannel ) {
            // Setup render callback struct
            AURenderCallbackStruct rcbs = { .inputProc = &renderCallback, .inputProcRefCon = channel };
            if ( hasUpstreamInteraction ) {
                AECheckOSStatus(AUGraphDisconnectNodeInput(_audioGraph, targetNode, targetBus), "AUGraphDisconnectNodeInput");
            }
            AECheckOSStatus(AUGraphSetNodeInputCallback(_audioGraph, targetNode, targetBus, &rcbs), "AUGraphSetNodeInputCallback");
            upstreamInteraction.nodeInteractionType = kAUNodeInteraction_InputCallback;
            
        } else if ( channel->type == kChannelTypeGroup ) {
            AEChannelGroupRef subgroup = (AEChannelGroupRef)channel->ptr;
            
            // Determine if we have filters or receivers
            BOOL hasReceivers=NO, hasFilters=NO;
            for ( int i=0; i<channel->callbacks.count && (!hasReceivers || !hasFilters); i++ ) {
                if ( channel->callbacks.callbacks[i].flags & kFilterFlag ) {
                    hasFilters = YES;
                } else if ( channel->callbacks.callbacks[i].flags & kReceiverFlag ) {
                    hasReceivers = YES;
                }
            }
            
            if ( !subgroup->mixerNode ) {
                // Create mixer node if necessary
                AudioComponentDescription mixer_desc = {
                    .componentType = kAudioUnitType_Mixer,
                    .componentSubType = kAudioUnitSubType_MultiChannelMixer,
                    .componentManufacturer = kAudioUnitManufacturer_Apple,
                    .componentFlags = 0,
                    .componentFlagsMask = 0
                };
                
                // Add mixer node to graph
                if ( !AECheckOSStatus(AUGraphAddNode(_audioGraph, &mixer_desc, &subgroup->mixerNode), "AUGraphAddNode mixer") ||
                     !AECheckOSStatus(AUGraphNodeInfo(_audioGraph, subgroup->mixerNode, NULL, &subgroup->mixerAudioUnit), "AUGraphNodeInfo") ) {
                    continue;
                }
                
                // Set the mixer unit to handle up to 4096 frames per slice to keep rendering during screen lock
                AudioUnitSetProperty(subgroup->mixerAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &kMaxFramesPerSlice, sizeof(kMaxFramesPerSlice));

#if !TARGET_OS_IPHONE
                // Set output volume
                // see http://stackoverflow.com/questions/9904369/silence-when-adding-kaudiounitsubtype-multichannelmixer-to-augraph
                AECheckOSStatus(AudioUnitSetParameter(subgroup->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, 1, 0),
                    "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
#endif
            }
            
            // Set bus count
            UInt32 busCount = subgroup->channelCount;
            if ( !AECheckOSStatus(AudioUnitSetProperty(subgroup->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)), "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) continue;

            // Get current mixer's output format
            AudioStreamBasicDescription currentMixerOutputDescription;
            UInt32 size = sizeof(currentMixerOutputDescription);
            AECheckOSStatus(AudioUnitGetProperty(subgroup->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &currentMixerOutputDescription, &size), "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
            
            // Determine what the output format should be (use TAAE's audio description if client code will see the audio)
            AudioStreamBasicDescription mixerOutputDescription = !subgroup->converterNode ? _audioDescription : currentMixerOutputDescription;
            mixerOutputDescription.mSampleRate = _audioDescription.mSampleRate;
            
            if ( memcmp(&currentMixerOutputDescription, &mixerOutputDescription, sizeof(mixerOutputDescription)) != 0 ) {
                // Assign the output format if necessary
                OSStatus result = AudioUnitSetProperty(subgroup->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mixerOutputDescription, sizeof(mixerOutputDescription));
                
                if ( hasUpstreamInteraction ) {
                    // Disconnect node to force reconnection, in order to apply new audio format
                    AECheckOSStatus(AUGraphDisconnectNodeInput(_audioGraph, targetNode, targetBus), "AUGraphDisconnectNodeInput");
                    hasUpstreamInteraction = NO;
                }
                
                if ( !subgroup->converterNode && result == kAudioUnitErr_FormatNotSupported ) {
                    // The mixer only supports a subset of formats. If it doesn't support this one, then we'll add an audio converter
                    currentMixerOutputDescription.mSampleRate = mixerOutputDescription.mSampleRate;
                    AEAudioStreamBasicDescriptionSetChannelsPerFrame(&currentMixerOutputDescription, mixerOutputDescription.mChannelsPerFrame);
                    
                    if ( !AECheckOSStatus(result=AudioUnitSetProperty(subgroup->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &currentMixerOutputDescription, size), "AudioUnitSetProperty") ) {
                        AUGraphRemoveNode(_audioGraph, subgroup->mixerNode);
                        subgroup->mixerNode = 0;
                        hasFilters = hasReceivers = NO;
                    } else {
                        AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
                        if ( !AECheckOSStatus(AUGraphAddNode(_audioGraph, &audioConverterDescription, &subgroup->converterNode), "AUGraphAddNode") ||
                             !AECheckOSStatus(AUGraphNodeInfo(_audioGraph, subgroup->converterNode, NULL, &subgroup->converterUnit), "AUGraphNodeInfo") ) {
                            AUGraphRemoveNode(_audioGraph, subgroup->converterNode);
                            subgroup->converterNode = 0;
                            subgroup->converterUnit = NULL;
                            hasFilters = hasReceivers = NO;
                        }
                        
                        // Set the audio unit to handle up to 4096 frames per slice to keep rendering during screen lock
                        AECheckOSStatus(AudioUnitSetProperty(subgroup->converterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &kMaxFramesPerSlice, sizeof(kMaxFramesPerSlice)),
                                    "AudioUnitSetProperty(kAudioUnitProperty_MaximumFramesPerSlice)");
                        
                        if ( channel->setRenderNotification ) {
                            AECheckOSStatus(AudioUnitRemoveRenderNotify(subgroup->mixerAudioUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify");
                            channel->setRenderNotification = NO;
                        }
                        
                        AECheckOSStatus(AUGraphConnectNodeInput(_audioGraph, subgroup->mixerNode, 0, subgroup->converterNode, 0), "AUGraphConnectNodeInput");
                    }
                } else {
                    AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
                }
            }
            
            if ( subgroup->converterNode ) {
                // Set the audio converter stream format
                AECheckOSStatus(AudioUnitSetProperty(subgroup->converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &currentMixerOutputDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
                AECheckOSStatus(AudioUnitSetProperty(subgroup->converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
                channel->audioDescription = _audioDescription;
            } else {
                channel->audioDescription = mixerOutputDescription;
            }
            
            if ( channel->audiobusFloatConverter ) {
                // Update Audiobus output converter to reflect new audio format
                AudioStreamBasicDescription converterFormat = ((__bridge AEFloatConverter*)channel->audiobusFloatConverter).sourceFormat;
                if ( memcmp(&converterFormat, &channel->audioDescription, sizeof(channel->audioDescription)) != 0 ) {
                    void *newFloatConverter = (__bridge_retained void*)[[AEFloatConverter alloc] initWithSourceFormat:channel->audioDescription];
                    void *oldFloatConverter = channel->audiobusFloatConverter;
                    [self performAsynchronousMessageExchangeWithBlock:^{ channel->audiobusFloatConverter = newFloatConverter; }
                                                        responseBlock:^{ CFBridgingRelease(oldFloatConverter); }];
                }
            }
            
            if ( subgroup->level_monitor_data.monitoringEnabled ) {
                // Update level monitoring converter to reflect new audio format
                AudioStreamBasicDescription converterFormat = ((__bridge AEFloatConverter*)subgroup->level_monitor_data.floatConverter).sourceFormat;
                if ( memcmp(&converterFormat, &channel->audioDescription, sizeof(channel->audioDescription)) != 0 ) {
                    void *newFloatConverter = (__bridge_retained void*)[[AEFloatConverter alloc] initWithSourceFormat:channel->audioDescription];
                    void *oldFloatConverter = subgroup->level_monitor_data.floatConverter;
                    [self performAsynchronousMessageExchangeWithBlock:^{ subgroup->level_monitor_data.floatConverter = newFloatConverter; }
                                                        responseBlock:^{ CFBridgingRelease(oldFloatConverter); }];
                }
            }
            
            AUNode sourceNode = subgroup->converterNode ? subgroup->converterNode : subgroup->mixerNode;
            AudioUnit sourceUnit = subgroup->converterUnit ? subgroup->converterUnit : subgroup->mixerAudioUnit;
            
            if ( hasFilters || channel->audiobusSenderPort ) {
                // We need to use our own render callback, because we're either filtering, or sending via Audiobus (and we may need to adjust timestamp)
                
                if ( channel->setRenderNotification ) {
                    // Remove render notification if there was one set
                    AECheckOSStatus(AudioUnitRemoveRenderNotify(sourceUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify");
                    channel->setRenderNotification = NO;
                }
                
                // Set input format for callback
                AECheckOSStatus(AudioUnitSetProperty(targetUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, targetBus, &channel->audioDescription, sizeof(channel->audioDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
                
                // Set render callback
                AURenderCallbackStruct rcbs;
                rcbs.inputProc = &renderCallback;
                rcbs.inputProcRefCon = channel;
                if ( !hasUpstreamInteraction || upstreamInteraction.nodeInteractionType != kAUNodeInteraction_InputCallback || memcmp(&upstreamInteraction.nodeInteraction.inputCallback.cback, &rcbs, sizeof(rcbs)) != 0 ) {
                    if ( hasUpstreamInteraction ) {
                        AECheckOSStatus(AUGraphDisconnectNodeInput(_audioGraph, targetNode, targetBus), "AUGraphDisconnectNodeInput");
                    }
                    AECheckOSStatus(AUGraphSetNodeInputCallback(_audioGraph, targetNode, targetBus, &rcbs), "AUGraphSetNodeInputCallback");
                    upstreamInteraction.nodeInteractionType = kAUNodeInteraction_InputCallback;
                }
                
            } else {
                // Connect output of mixer/converter directly to the upstream node
                if ( !hasUpstreamInteraction || upstreamInteraction.nodeInteractionType != kAUNodeInteraction_Connection || upstreamInteraction.nodeInteraction.connection.sourceNode != sourceNode ) {
                    if ( hasUpstreamInteraction ) {
                        AECheckOSStatus(AUGraphDisconnectNodeInput(_audioGraph, targetNode, targetBus), "AUGraphDisconnectNodeInput");
                    }
                    AECheckOSStatus(AUGraphConnectNodeInput(_audioGraph, sourceNode, 0, targetNode, targetBus), "AUGraphConnectNodeInput");
                    upstreamInteraction.nodeInteractionType = kAUNodeInteraction_Connection;
                }
                
                if ( hasReceivers || subgroup->level_monitor_data.monitoringEnabled ) {
                    if ( !channel->setRenderNotification ) {
                        // We need to register a callback to be notified when the mixer renders, to pass on the audio
                        AECheckOSStatus(AudioUnitAddRenderNotify(sourceUnit, &groupRenderNotifyCallback, channel), "AudioUnitAddRenderNotify");
                        channel->setRenderNotification = YES;
                    }
                } else {
                    if ( channel->setRenderNotification ) {
                        // Remove render notification callback
                        AECheckOSStatus(AudioUnitRemoveRenderNotify(sourceUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify");
                        channel->setRenderNotification = NO;
                    }
                }
            }
            
            [self configureChannelsInRange:NSMakeRange(0, busCount) forGroup:subgroup];
        }
        
        
        if ( group ) {
            // Set volume
            AudioUnitParameterValue volumeValue = channel->muted ? 0.0 : channel->volume;
            AECheckOSStatus(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, i, volumeValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
            
            // Set pan
            AudioUnitParameterValue panValue = channel->pan;
            AECheckOSStatus(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, i, panValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
            
            // Set enabled
            AudioUnitParameterValue enabledValue = channel->playing;
            AECheckOSStatus(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, i, enabledValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
            
            if ( upstreamInteraction.nodeInteractionType == kAUNodeInteraction_InputCallback ) {
                // Set audio description
                AudioStreamBasicDescription audioDescription = channel->audioDescription.mSampleRate ? channel->audioDescription : _audioDescription;
                AECheckOSStatus(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &audioDescription, sizeof(audioDescription)),
                            "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
            }
        }
    }
}

static void removeChannelsFromGroup(__unsafe_unretained AEAudioController *THIS, AEChannelGroupRef group, void **ptrs, void **objects, AEChannelRef *outChannelReferences, int count) {
    // Disable matching channels first
    for ( int i=0; i < count; i++ ) {
        // Find the channel in our fixed array
        int index = 0;
        for ( index=0; index < group->channelCount; index++ ) {
            if ( group->channels[index] && group->channels[index]->ptr == ptrs[i] && group->channels[index]->object == objects[i] ) {
                // Disable this channel until we update the graph
                AudioUnitParameterValue enabledValue = 0;
                AECheckOSStatus(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, enabledValue, 0),
                            "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
            }
        }
    }
    
    // Now remove the matching channels from the array
    int outChannelReferencesCount = 0;
    for ( int i=0; i < count; i++ ) {
        
        // Find the channel in our channel array
        int index = 0;
        for ( index=0; index < group->channelCount; index++ ) {
            if ( group->channels[index] && group->channels[index]->ptr == ptrs[i] && group->channels[index]->object == objects[i] ) {
                if ( outChannelReferences && outChannelReferencesCount < count ) {
                    outChannelReferences[outChannelReferencesCount++] = group->channels[index];
                }
                
                // Shuffle the later elements backwards one space
                for ( int j=index; j<group->channelCount-1; j++ ) {
                    group->channels[j] = group->channels[j+1];
                }
                
                group->channels[group->channelCount-1] = NULL;
                group->channelCount--;
            }
        }
    }
}

- (void)gatherChannelsFromGroup:(AEChannelGroupRef)group intoArray:(NSMutableArray*)array {
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = group->channels[i];
        if ( !channel ) continue;
        if ( channel->type == kChannelTypeGroup ) {
            [self gatherChannelsFromGroup:(AEChannelGroupRef)channel->ptr intoArray:array];
        } else {
            [array addObject:(__bridge id)channel->object];
        }
    }
}

- (AEChannelGroupRef)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo withinGroup:(AEChannelGroupRef)group index:(int*)index {
    // Find the matching channel in the table for the given group
    for ( int i=0; i < group->channelCount; i++ ) {
        AEChannelRef channel = group->channels[i];
        if ( !channel ) continue;
        if ( channel->ptr == ptr && channel->object == userInfo ) {
            if ( index ) *index = i;
            return group;
        }
        if ( channel->type == kChannelTypeGroup ) {
            AEChannelGroupRef match = [self searchForGroupContainingChannelMatchingPtr:ptr userInfo:userInfo withinGroup:channel->ptr index:index];
            if ( match ) return match;
        }
    }
    
    return NULL;
}

- (AEChannelGroupRef)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo index:(int*)index {
    return [self searchForGroupContainingChannelMatchingPtr:ptr userInfo:userInfo withinGroup:_topGroup index:(int*)index];
}

- (void)iterateChannelsBeneathGroup:(AEChannelGroupRef)group block:(void(^)(AEChannelRef channel))block {
    block(group->channel);
    for ( int i=0; i<group->channelCount; i++ ) {
        if ( group->channels[i] ) {
            if ( group->channels[i]->type == kChannelTypeChannel ) {
                block(group->channels[i]);
            } else if ( group->channels[i]->type == kChannelTypeGroup ) {
                [self iterateChannelsBeneathGroup:(AEChannelGroupRef)group->channels[i]->ptr block:block];
            }
        }
    }
}

- (void)sendTeardownToObjects {
    [self iterateChannelsBeneathGroup:_topGroup block:^(AEChannelRef channel) {
        for ( id object in [self associatedObjectsFromTable:&channel->callbacks matchingFlag:0] ) {
            if ( [object respondsToSelector:@selector(teardown)] ) {
                [object teardown];
            }
        }
        if ( channel->type == kChannelTypeChannel && [(__bridge id<AEAudioPlayable>)channel->object respondsToSelector:@selector(teardown)] ) {
            [(__bridge id<AEAudioPlayable>)channel->object teardown];
        }
    }];
    for ( int i=0; i<_inputCallbackCount; i++ ) {
        for ( id object in [self associatedObjectsFromTable:&_inputCallbacks[i].callbacks matchingFlag:0] ) {
            if ( [object respondsToSelector:@selector(teardown)] ) {
                [object teardown];
            }
        }
    }
}

- (void)sendSetupToObjects {
    [self iterateChannelsBeneathGroup:_topGroup block:^(AEChannelRef channel) {
        for ( id object in [self associatedObjectsFromTable:&channel->callbacks matchingFlag:0] ) {
            if ( [object respondsToSelector:@selector(setupWithAudioController:)] ) {
                [object setupWithAudioController:self];
            }
        }
        if ( channel->type == kChannelTypeChannel && [(__bridge id<AEAudioPlayable>)channel->object respondsToSelector:@selector(setupWithAudioController:)] ) {
            [(__bridge id<AEAudioPlayable>)channel->object setupWithAudioController:self];
        }
    }];
    for ( int i=0; i<_inputCallbackCount; i++ ) {
        for ( id object in [self associatedObjectsFromTable:&_inputCallbacks[i].callbacks matchingFlag:0] ) {
            if ( [object respondsToSelector:@selector(setupWithAudioController:)] ) {
                [object setupWithAudioController:self];
            }
        }
    }
}

- (void)releaseResourcesForChannel:(AEChannelRef)channel {
    for ( id object in [self associatedObjectsFromTable:&channel->callbacks matchingFlag:0] ) {
        if ( [object respondsToSelector:@selector(teardown)] ) {
            [object teardown];
        }
        CFBridgingRelease((__bridge CFTypeRef)object);
    }
    
    if ( channel->audiobusSenderPort ) {
        CFBridgingRelease(channel->audiobusSenderPort);
        channel->audiobusSenderPort = NULL;
        AEAudioBufferListFree(channel->audiobusScratchBuffer);
        channel->audiobusScratchBuffer = NULL;
        CFBridgingRelease(channel->audiobusFloatConverter);
        channel->audiobusFloatConverter = NULL;
    }
    
    if ( channel->type == kChannelTypeGroup ) {
        [self releaseResourcesForGroup:(AEChannelGroupRef)channel->ptr];
    } else if ( channel->type == kChannelTypeChannel ) {
        for ( NSString *property in @[@"volume", @"pan", @"channelIsPlaying", @"channelIsMuted", @"audioDescription"] ) {
            [(__bridge NSObject*)channel->object removeObserver:self forKeyPath:property];
        }
        if ( [(__bridge id<AEAudioPlayable>)channel->object respondsToSelector:@selector(teardown)] ) {
            [(__bridge id<AEAudioPlayable>)channel->object teardown];
        }
        CFBridgingRelease(channel->object);
    }
    
    free(channel);
}

- (void)releaseResourcesForGroup:(AEChannelGroupRef)group {
    if ( group->mixerNode ) {
        AECheckOSStatus(AUGraphRemoveNode(_audioGraph, group->mixerNode), "AUGraphRemoveNode");
        group->mixerNode = 0;
        group->mixerAudioUnit = NULL;
    }

    if ( group->converterNode ) {
        AECheckOSStatus(AUGraphRemoveNode(_audioGraph, group->converterNode), "AUGraphRemoveNode");
        group->converterNode = 0;
        group->converterUnit = NULL;
    }
    
    // Release channel resources too
    for ( int i=0; i<group->channelCount; i++ ) {
        if ( group->channels[i] ) {
            [self releaseResourcesForChannel:group->channels[i]];
        }
    }
    
    free(group);
}

- (void)markGroupTorndown:(AEChannelGroupRef)group {
    group->mixerNode = 0;
    group->mixerAudioUnit = NULL;
    group->converterUnit = NULL;
    group->converterNode = 0;
    memset(&group->channel->audioDescription, 0, sizeof(AudioStreamBasicDescription));
    if ( group->level_monitor_data.scratchBuffer ) {
        AEAudioBufferListFree(group->level_monitor_data.scratchBuffer);
    }
    if ( group->level_monitor_data.floatConverter ) {
        CFBridgingRelease(group->level_monitor_data.floatConverter);
    }
    memset(&group->level_monitor_data, 0, sizeof(audio_level_monitor_t));
    
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = group->channels[i];
        if ( !channel ) continue;
        channel->setRenderNotification = NO;
        if ( channel->type == kChannelTypeGroup ) {
            [self markGroupTorndown:(AEChannelGroupRef)channel->ptr];
        }
    }
}

- (BOOL)usingVPIO {
    return _voiceProcessingEnabled && _inputEnabled && (!_voiceProcessingOnlyForSpeakerAndMicrophone || _playingThroughDeviceSpeaker);
}

- (BOOL)attemptRecoveryFromSystemError:(NSError**)error thenStart:(BOOL)start {
    int retries = 3;
    while ( retries > 0 ) {
        NSLog(@"TAAE: Trying to recover from system error (%d retries remain)", retries);
        retries--;
        
        [self stopInternal];
        [self sendTeardownToObjects];
        [self teardown];
        
        [NSThread sleepForTimeInterval:0.5];

        if ( [self initAudioSession] && [self setup] ) {
            [self sendSetupToObjects];
            [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerDidRecreateGraphNotification object:self];
            
            if ( !start || [self start:error recoveringFromErrors:NO] ) {
                NSLog(@"TAAE: Successfully recovered from system error");
                _hasSystemError = NO;
                return YES;
            }
        }
    }
    
    NSLog(@"TAAE: Could not recover from system error.");
    if ( error ) *error = self.lastError;
    _hasSystemError = YES;
    return NO;
}

#pragma mark - Callback management

static callback_t *addCallbackToTable(__unsafe_unretained AEAudioController *THIS, callback_table_t *table, void *callback, void *userInfo, int flags) {
    callback_t *callback_struct = &table->callbacks[table->count];
    callback_struct->callback = callback;
    callback_struct->userInfo = userInfo;
    callback_struct->flags = flags;
    table->count++;
    return callback_struct;
}

static void removeCallbackFromTable(__unsafe_unretained AEAudioController *THIS, callback_table_t *table, void *callback, void *userInfo, BOOL *found_p) {
    BOOL found = NO;
    
    // Find the item in our fixed array
    int index = 0;
    for ( index=0; index<table->count; index++ ) {
        if ( table->callbacks[index].callback == callback && table->callbacks[index].userInfo == userInfo ) {
            found = YES;
            break;
        }
    }
    if ( found ) {
        // Now shuffle the later elements backwards one space
        table->count--;
        for ( int i=index; i<table->count; i++ ) {
            table->callbacks[i] = table->callbacks[i+1];
        }
    }
    
    if ( found_p ) *found_p = found;
}

- (NSArray *)associatedObjectsFromTable:(callback_table_t*)table matchingFlag:(uint8_t)flag {
    // Construct NSArray response
    NSMutableArray *result = [NSMutableArray array];
    for ( int i=0; i<table->count; i++ ) {
        if ( flag && !(table->callbacks[i].flags & flag) ) continue;
        
        [result addObject:(__bridge id)table->callbacks[i].userInfo];
    }
    
    return result;
}

- (BOOL)addCallback:(void*)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:(__bridge void*)channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = parentGroup->channels[index];
    
    if ( channel->callbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"TAAE: Warning: Maximum number of callbacks reached");
        return NO;
    }
    
    [self performSynchronousMessageExchangeWithBlock:^{
        addCallbackToTable(self, &channel->callbacks, callback, userInfo, flags);
    }];
    
    return YES;
}

- (BOOL)addCallback:(void*)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group {
    if ( group->channel->callbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"TAAE: Warning: Maximum number of callbacks reached");
        return NO;
    }
    
    [self performSynchronousMessageExchangeWithBlock:^{
        addCallbackToTable(self, &group->channel->callbacks, callback, userInfo, flags);
    }];

    AEChannelGroupRef parentGroup = NULL;
    int index=0;
    if ( group != _topGroup ) {
        parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
        NSAssert(parentGroup != NULL, @"Channel group not found");
    }
    
    [self configureChannelsInRange:NSMakeRange(index, 1) forGroup:parentGroup];
    AECheckOSStatus([self updateGraph], "Update graph");
    
    return YES;
}

- (BOOL)addCallback:(void*)callback userInfo:(void*)userInfo flags:(uint8_t)flags forInputChannels:(NSArray*)channels {
    callback_table_t *callbackTable = NULL;
    input_callback_table_t *inputCallbacks = NULL;
    int inputCallbackCount = _inputCallbackCount;
    input_callback_table_t *oldMultichannelInputCallbacks = _inputCallbacks;
    
    if ( !channels ) {
        callbackTable = &_inputCallbacks[0].callbacks;
    } else {
        for ( int i=0; i<_inputCallbackCount; i++ ) {
            // Compare channel maps to find a match
            if ( (_inputCallbacks[i].channelMap && [(__bridge NSArray*)_inputCallbacks[i].channelMap isEqualToArray:channels]) ||
                    (i == 0 && !_inputCallbacks[i].channelMap && [self.inputChannelSelection isEqualToArray:channels]) ) {
                callbackTable = &_inputCallbacks[i].callbacks;
                break;
            }
        }
        
        if ( !callbackTable ) {
            // Create new callback entry
            inputCallbacks = malloc(sizeof(input_callback_table_t) * (_inputCallbackCount+1));
            memcpy(inputCallbacks, _inputCallbacks, _inputCallbackCount * sizeof(input_callback_table_t));
            input_callback_table_t *newCallbackTable = &inputCallbacks[_inputCallbackCount];
            memset(newCallbackTable, 0, sizeof(input_callback_table_t));
            
            newCallbackTable->channelMap = (__bridge_retained void*)[channels copy];
            
            callbackTable = &newCallbackTable->callbacks;
            
            inputCallbackCount = _inputCallbackCount+1;
        }
    }
    
    if ( callbackTable->count == kMaximumCallbacksPerSource ) {
        NSLog(@"TAAE: Warning: Maximum number of callbacks reached");
        return NO;
    }
    [self performSynchronousMessageExchangeWithBlock:^{
        if ( inputCallbacks ) {
            _inputCallbacks = inputCallbacks;
            _inputCallbackCount = inputCallbackCount;
        }
        
        addCallbackToTable(self, callbackTable, callback, userInfo, flags);
    }];
    
    if ( inputCallbacks ) {
        free(oldMultichannelInputCallbacks);
        if ( _inputEnabled ) {
            [self updateInputDeviceStatus];
        }
    }
    
    return YES;
}

- (BOOL)removeCallback:(void*)callback userInfo:(void*)userInfo fromChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:(__bridge void*)channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = parentGroup->channels[index];
    
    __block BOOL found = NO;
    [self performSynchronousMessageExchangeWithBlock:^{
        removeCallbackFromTable(self, &channel->callbacks, callback, userInfo, &found);
    }];
    
    return found;
}

- (BOOL)removeCallback:(void*)callback userInfo:(void*)userInfo fromChannelGroup:(AEChannelGroupRef)group {
    __block BOOL found = NO;
    [self performSynchronousMessageExchangeWithBlock:^{
        removeCallbackFromTable(self, &group->channel->callbacks, callback, userInfo, &found);
    }];
    
    if ( !found ) return NO;
    
    AEChannelGroupRef parentGroup = NULL;
    int index=0;
    if ( group != _topGroup ) {
        parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
        NSAssert(parentGroup != NULL, @"Channel group not found");
    }
    
    [self configureChannelsInRange:NSMakeRange(index, 1) forGroup:parentGroup];
    AECheckOSStatus([self updateGraph], "Update graph");
    
    return YES;
}

- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags {
    return [self associatedObjectsFromTable:&_topChannel->callbacks matchingFlag:flags];
}

- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:(__bridge void*)channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = parentGroup->channels[index];
    
    return [self associatedObjectsFromTable:&channel->callbacks matchingFlag:flags];
}

- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group {
    if ( !group->channel ) return @[];
    return [self associatedObjectsFromTable:&group->channel->callbacks matchingFlag:flags];
}

static void handleCallbacksForChannel(AEChannelRef channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    // Pass audio to output callbacks
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kReceiverFlag ) {
            ((AEAudioReceiverCallback)callback->callback)((__bridge id)callback->userInfo, (__bridge AEAudioController*)channel->audioController, channel->ptr, inTimeStamp, inNumberFrames, ioData);
        }
    }
}

#pragma mark - Assorted helpers

static void performLevelMonitoring(audio_level_monitor_t* monitor, AudioBufferList *buffer, UInt32 numberFrames) {
    if ( !monitor->floatConverter || !monitor->scratchBuffer ) return;
    
    if ( monitor->reset ) {
        monitor->reset  = NO;
        monitor->meanBlockCount  = 0;
        monitor->chanMeanBlockCount  = 0;
        monitor->meanAccumulator = 0;
        monitor->average         = 0;
        monitor->peak            = 0;
        for (int i=0; i < kMaximumMonitoringChannels; ++i) {
            monitor->chanMeanAccumulator[i] = 0;
            monitor->chanAverage[i]         = 0;
            monitor->chanPeak[i]            = 0;
        }
    }
    
    UInt32 monitorFrames = min(numberFrames, kLevelMonitorScratchBufferSize);
    AEFloatConverterToFloatBufferList((__bridge AEFloatConverter *)monitor->floatConverter, buffer, monitor->scratchBuffer, monitorFrames);

    for ( int i=0; i<monitor->scratchBuffer->mNumberBuffers && i < kMaximumMonitoringChannels; i++ ) {
        float peak = 0.0;
        vDSP_maxmgv((float*)monitor->scratchBuffer->mBuffers[i].mData, 1, &peak, monitorFrames);
        if ( peak > monitor->chanPeak[i] ) monitor->chanPeak[i] = peak;
        if ( peak > monitor->peak ) monitor->peak = peak;
        
        float avg = 0.0;
        vDSP_meamgv((float*)monitor->scratchBuffer->mBuffers[i].mData, 1, &avg, monitorFrames);
        monitor->chanMeanAccumulator[i] += avg;
        if ( i == 0 ) monitor->chanMeanBlockCount++;
        monitor->meanAccumulator += avg;
        monitor->meanBlockCount++;
        
        monitor->chanAverage[i] = monitor->chanMeanAccumulator[i] / (double)monitor->chanMeanBlockCount;
        monitor->average = monitor->meanAccumulator / (double)monitor->meanBlockCount;
    }
}

- (BOOL)hasAudiobusSenderForUpstreamChannels:(AEChannelRef)channel {
    if ( !channel->parentGroup ) return NO;
    
    AEChannelRef parentGroupChannel = channel->parentGroup->channel;
    if ( parentGroupChannel->audiobusSenderPort ) {
        return YES;
    }
    
    return [self hasAudiobusSenderForUpstreamChannels:parentGroupChannel];
}

static BOOL upstreamChannelsMutedByAudiobus(AEChannelRef channel) {
    if ( !channel->parentGroup ) return NO;
    
    AEChannelRef parentGroupChannel = channel->parentGroup->channel;
    if ( parentGroupChannel->audiobusSenderPort && ABSenderPortIsMuted((__bridge id)parentGroupChannel->audiobusSenderPort) ) {
        return YES;
    }
    
    return upstreamChannelsMutedByAudiobus(parentGroupChannel);
}

static BOOL upstreamChannelsConnectedToAudiobus(AEChannelRef channel) {
    if ( !channel->parentGroup ) return NO;
    
    AEChannelRef parentGroupChannel = channel->parentGroup->channel;
    if ( parentGroupChannel->audiobusSenderPort && ABSenderPortIsConnected((__bridge id)parentGroupChannel->audiobusSenderPort) ) {
        return YES;
    }
    
    return upstreamChannelsConnectedToAudiobus(parentGroupChannel);
}

#if TARGET_OS_IPHONE
static void * firstUpstreamAudiobusSenderPort(AEChannelRef channel) {
    if ( channel->audiobusSenderPort ) {
        return channel->audiobusSenderPort;
    }
    
    if ( !channel->parentGroup ) return nil;
    
    return firstUpstreamAudiobusSenderPort(channel->parentGroup->channel);
}
#endif

#if TARGET_OS_IPHONE
- (void)housekeeping {
    Float32 bufferDuration = [((AVAudioSession*)[AVAudioSession sharedInstance]) IOBufferDuration];
    if ( _currentBufferDuration != bufferDuration ) self.currentBufferDuration = bufferDuration;
}

- (NSString*)stringFromRouteDescription:(AVAudioSessionRouteDescription*)routeDescription {
    
    NSMutableString *inputsString = [NSMutableString string];
    for ( AVAudioSessionPortDescription *port in routeDescription.inputs ) {
        [inputsString appendFormat:@"%@%@", inputsString.length > 0 ? @", " : @"", port.portName];
    }
    NSMutableString *outputsString = [NSMutableString string];
    for ( AVAudioSessionPortDescription *port in routeDescription.outputs ) {
        [outputsString appendFormat:@"%@%@", outputsString.length > 0 ? @", " : @"", port.portName];
    }
    
    return [NSString stringWithFormat:@"%@%@%@", inputsString, inputsString.length > 0 && outputsString.length > 0 ? @" and " : @"", outputsString];
}
#endif

@end

#pragma mark -

@implementation AEAudioControllerProxy
- (id)initWithAudioController:(AEAudioController *)audioController {
    _audioController = audioController;
    return self;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_audioController methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation setTarget:_audioController];
    [invocation invoke];
}
@end

@implementation AEAudioControllerMessageQueue

- (void)performAsynchronousMessageExchangeWithBlock:(void (^)())block responseBlock:(void (^)())responseBlock {
    if ( _audioController.running ) {
        [super performAsynchronousMessageExchangeWithBlock:block responseBlock:responseBlock];
    } else {
        if ( block ) block();
        if ( responseBlock ) responseBlock();
    }
}

- (BOOL)performSynchronousMessageExchangeWithBlock:(void (^)())block {
    if ( _audioController.running ) {
        return [super performSynchronousMessageExchangeWithBlock:block];
    } else if ( block ) {
        block();
    }
    return YES;
}

@end
