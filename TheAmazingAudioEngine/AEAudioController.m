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
#import <UIKit/UIKit.h>
#import <libkern/OSAtomic.h>
#import "TPCircularBuffer.h"
#include <sys/types.h>
#include <sys/sysctl.h>
#import <Accelerate/Accelerate.h>
#import "AEAudioController+Audiobus.h"
#import "AEAudioController+AudiobusStub.h"
#import "AEFloatConverter.h"
#import <mach/mach_time.h>
#import <pthread.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

static const int kMaximumChannelsPerGroup              = 100;
static const int kMaximumCallbacksPerSource            = 15;
static const int kMessageBufferLength                  = 8192;
static const int kMaxMessageDataSize                   = 2048;
static const NSTimeInterval kIdleMessagingPollDuration = 0.1;
static const int kScratchBufferFrames                  = 4096;
static const int kInputAudioBufferFrames               = 4096;
static const int kLevelMonitorScratchBufferSize        = 4096;
static const NSTimeInterval kMaxBufferDurationWithVPIO = 0.01;
static const Float32 kNoValue                          = -1.0;
#define kNoAudioErr                            -2222

static Float32 __cachedInputLatency = kNoValue;
static Float32 __cachedOutputLatency = kNoValue;

NSString * const AEAudioControllerSessionInterruptionBeganNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionBeganNotification";
NSString * const AEAudioControllerSessionInterruptionEndedNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionEndedNotification";
NSString * const AEAudioControllerDidRecreateGraphNotification = @"com.theamazingaudioengine.AEAudioControllerDidRecreateGraphNotification";

const NSString *kAEAudioControllerCallbackKey = @"callback";
const NSString *kAEAudioControllerUserInfoKey = @"userinfo";

static inline int min(int a, int b) { return a>b ? b : a; }

static inline void AEAudioControllerError(OSStatus result, const char *operation, const char* file, int line) {
    int fourCC = CFSwapInt32HostToBig(result);
    @autoreleasepool {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&fourCC);
    }
}

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        static uint64_t lastMessage = 0;
        static int messageCount=0;
        uint64_t now = mach_absolute_time();
        if ( (now-lastMessage)*__hostTicksToSeconds > 2 ) {
            messageCount = 0;
        }
        lastMessage = now;
        if ( ++messageCount >= 10 ) {
            if ( messageCount == 10 ) {
                @autoreleasepool {
                    NSLog(@"Suppressing some messages");
                }
            }
            if ( messageCount%500 != 0 ) {
                return NO;
            }
        }
        AEAudioControllerError(result, operation, file, line);
        return NO;
    }
    return YES;
}

@interface NSError (AEAudioControllerAdditions)
+ (NSError*)audioControllerErrorWithMessage:(NSString*)message OSStatus:(OSStatus)status;
@end
@implementation NSError (AEAudioControllerAdditions)
+ (NSError*)audioControllerErrorWithMessage:(NSString*)message OSStatus:(OSStatus)status {
    int fourCC = CFSwapInt32HostToBig(status);
    return [NSError errorWithDomain:NSOSStatusErrorDomain
                               code:status
                           userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"%@ (error %d/%4.4s)", message, (int)status, (char*)&fourCC]
                                                                forKey:NSLocalizedDescriptionKey]];
}
@end

#pragma mark - Core types

enum {
    kFilterFlag               = 1<<0,
    kReceiverFlag             = 1<<1,
    kAudiobusOutputPortFlag   = 1<<3
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
    NSArray            *channelMap;
    AudioStreamBasicDescription audioDescription;
    AudioBufferList    *audioBufferList;
    AudioConverterRef   audioConverter;
} input_callback_table_t;


/*!
 * Audio level monitoring data
 */
typedef struct __audio_level_monitor_t {
    BOOL                monitoringEnabled;
    float               meanAccumulator;
    int                 meanBlockCount;
    Float32             peak;
    Float32             average;
    AEFloatConverter   *floatConverter;
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
    BOOL             playing;
    float            volume;
    float            pan;
    BOOL             muted;
    AudioStreamBasicDescription audioDescription;
    callback_table_t callbacks;
    AudioTimeStamp   timeStamp;
    
    BOOL             setRenderNotification;
    
    AEAudioController *audioController;
    ABOutputPort    *audiobusOutputPort;
    AEFloatConverter *audiobusFloatConverter;
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

#pragma mark Messaging

/*!
 * Message 
 */
typedef struct {
    void                            (^block)();
    void                            (^responseBlock)();
    AEAudioControllerMainThreadMessageHandler handler;
    void                           *userInfoByReference;
    int                             userInfoLength;
    pthread_t                       sourceThread;
} message_t;


#pragma mark -

@interface AEAudioControllerProxy : NSProxy {
    AEAudioController *_audioController;
}
- (id)initWithAudioController:(AEAudioController*)audioController;
@end

@interface AEAudioControllerMessagePollThread : NSThread
- (id)initWithAudioController:(AEAudioController*)audioController;
@property (nonatomic, assign) NSTimeInterval pollInterval;
@end

@interface AEAudioController () {
    AUGraph             _audioGraph;
    AUNode              _ioNode;
    AudioUnit           _ioAudioUnit;
    BOOL                _interrupted;
    BOOL                _inputEnabled;
    BOOL                _hardwareInputAvailable;
    BOOL                _running;
    BOOL                _runningPriorToInterruption;
    BOOL                _hasSystemError;
    
    AEChannelGroupRef   _topGroup;
    AEChannelRef        _topChannel;
    
    callback_table_t    _timingCallbacks;
    
    input_callback_table_t *_inputCallbacks;
    int                 _inputCallbackCount;
    AudioStreamBasicDescription _rawInputAudioDescription;
    AudioBufferList    *_inputAudioBufferList;
    
    TPCircularBuffer    _realtimeThreadMessageBuffer;
    TPCircularBuffer    _mainThreadMessageBuffer;
    AEAudioControllerMessagePollThread *_pollThread;
    int                 _pendingResponses;
    
    audio_level_monitor_t _inputLevelMonitorData;
    BOOL                _usingAudiobusInput;
}

- (BOOL)mustUpdateVoiceProcessingSettings;
- (void)replaceIONode;
- (BOOL)updateInputDeviceStatus;
static void processPendingMessagesOnRealtimeThread(AEAudioController *THIS);
static void handleCallbacksForChannel(AEChannelRef channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData);
static void performLevelMonitoring(audio_level_monitor_t* monitor, AudioBufferList *buffer, UInt32 numberFrames);

@property (nonatomic, retain, readwrite) NSString *audioRoute;
@property (nonatomic, assign, readwrite) float currentBufferDuration;
@property (nonatomic, retain) NSError *lastError;
@property (nonatomic, assign) NSTimer *housekeepingTimer;
@property (nonatomic, retain) ABInputPort *audiobusInputPort;
@property (nonatomic, retain) ABOutputPort *audiobusOutputPort;
@end

@implementation AEAudioController
@synthesize audioSessionCategory        = _audioSessionCategory,
            audioInputAvailable         = _audioInputAvailable,
            numberOfInputChannels       = _numberOfInputChannels, 
            muteOutput                  = _muteOutput,
            enableBluetoothInput        = _enableBluetoothInput,
            voiceProcessingEnabled      = _voiceProcessingEnabled,
            voiceProcessingOnlyForSpeakerAndMicrophone = _voiceProcessingOnlyForSpeakerAndMicrophone,
            playingThroughDeviceSpeaker = _playingThroughDeviceSpeaker,
            preferredBufferDuration     = _preferredBufferDuration, 
            inputMode                   = _inputMode, 
            audioUnit                   = _ioAudioUnit,
            audioGraph                  = _audioGraph,
            audioDescription            = _audioDescription,
            audioRoute                  = _audioRoute,
            audiobusInputPort           = _audiobusInputPort;

@dynamic    running, inputGainAvailable, inputGain, audiobusOutputPort, inputAudioDescription, inputChannelSelection;

#pragma mark - Audio session callbacks

static AEAudioController * __interruptionListenerSelf = nil;

static void interruptionListener(void *inClientData, UInt32 inInterruption) {
    if ( !__interruptionListenerSelf ) return;
    
    AEAudioController *THIS = __interruptionListenerSelf;
    
    if (inInterruption == kAudioSessionEndInterruption) {
        NSLog(@"TAAE: Audio session interruption ended");
        THIS->_interrupted = NO;
        
        if ( [[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground || THIS->_runningPriorToInterruption ) {
            // make sure we are again the active session
            checkResult(AudioSessionSetActive(true), "AudioSessionSetActive");
        }
        
        if ( THIS->_runningPriorToInterruption && ![THIS running] ) {
            [THIS start:NULL];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerSessionInterruptionEndedNotification object:THIS];
    } else if (inInterruption == kAudioSessionBeginInterruption) {
        NSLog(@"TAAE: Audio session interrupted");
        THIS->_runningPriorToInterruption = THIS->_running;
        
        THIS->_interrupted = YES;
        
        if ( THIS->_runningPriorToInterruption ) {
            [THIS stop];
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerSessionInterruptionBeganNotification object:THIS];
        
        processPendingMessagesOnRealtimeThread(THIS);
    }
}

static void audioSessionPropertyListener(void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void *inData) {
    AEAudioController *THIS = (AEAudioController *)inClientData;
    
    __cachedInputLatency = kNoValue;
    __cachedOutputLatency = kNoValue;
    
    if (inID == kAudioSessionProperty_AudioRouteChange) {
        int reason = [[(NSDictionary*)inData objectForKey:[NSString stringWithCString:kAudioSession_AudioRouteChangeKey_Reason encoding:NSUTF8StringEncoding]] intValue];
        
        CFStringRef route = NULL;
        UInt32 size = sizeof(route);
        if ( !checkResult(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route), "AudioSessionGetProperty(kAudioSessionProperty_AudioRoute)") ) return;
        
        THIS.audioRoute = [NSString stringWithString:(NSString*)route];
        
        NSLog(@"TAAE: Changed audio route to %@", THIS.audioRoute);
        
        BOOL playingThroughSpeaker;
        if ( [(NSString*)route isEqualToString:@"SpeakerAndMicrophone"] || [(NSString*)route isEqualToString:@"Speaker"] ) {
            playingThroughSpeaker = YES;
        } else {
            playingThroughSpeaker = NO;
        }
        
        CFRelease(route);
        
        BOOL updatedVP = NO;
        if ( THIS->_playingThroughDeviceSpeaker != playingThroughSpeaker ) {
            [THIS willChangeValueForKey:@"playingThroughDeviceSpeaker"];
            THIS->_playingThroughDeviceSpeaker = playingThroughSpeaker;
            [THIS didChangeValueForKey:@"playingThroughDeviceSpeaker"];
            
            if ( THIS->_voiceProcessingEnabled && THIS->_voiceProcessingOnlyForSpeakerAndMicrophone ) {
                if ( [THIS mustUpdateVoiceProcessingSettings] ) {
                    [THIS replaceIONode];
                    updatedVP = YES;
                }
            }
        }
        
        if ( !updatedVP && (reason == kAudioSessionRouteChangeReason_NewDeviceAvailable || reason == kAudioSessionRouteChangeReason_OldDeviceUnavailable) && THIS->_inputEnabled ) {
            [THIS updateInputDeviceStatus];
        }
        
    } else if ( inID == kAudioSessionProperty_AudioInputAvailable && THIS->_inputEnabled ) {
        [THIS updateInputDeviceStatus];
    }
}

#pragma mark -
#pragma mark Input and render callbacks

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

typedef struct __channel_producer_arg_t {
    AEChannelRef channel;
    AudioTimeStamp inTimeStamp;
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
                return ((AEAudioControllerFilterCallback)callback->callback)(callback->userInfo, channel->audioController, &channelAudioProducer, (void*)&filterArg, &arg->inTimeStamp, *frames, audio);
            }
            filterIndex++;
        }
    }
    
    if ( channel->type == kChannelTypeChannel ) {
        AEAudioControllerRenderCallback callback = (AEAudioControllerRenderCallback) channel->ptr;
        id<AEAudioPlayable> channelObj = (id<AEAudioPlayable>) channel->object;
        
        for ( int i=0; i<audio->mNumberBuffers; i++ ) {
            memset(audio->mBuffers[i].mData, 0, audio->mBuffers[i].mDataByteSize);
        }
        
        status = callback(channelObj, channel->audioController, &channel->timeStamp, *frames, audio);
        channel->timeStamp.mSampleTime += *frames;
        
    } else if ( channel->type == kChannelTypeGroup ) {
        AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
        
        // Tell mixer/mixer's converter unit to render into audio
        status = AudioUnitRender(group->converterUnit ? group->converterUnit : group->mixerAudioUnit, arg->ioActionFlags, &arg->inTimeStamp, 0, *frames, audio);
        if ( !checkResult(status, "AudioUnitRender") ) return status;
        
        if ( group->level_monitor_data.monitoringEnabled ) {
            performLevelMonitoring(&group->level_monitor_data, audio, *frames);
        }
        
        // Advance the sample time, to make sure we continue to render if we're called again with the same arguments
        arg->inTimeStamp.mSampleTime += *frames;
    }
    
    return status;
}

static OSStatus renderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEChannelRef channel = (AEChannelRef)inRefCon;
    
    if ( channel == NULL || channel->ptr == NULL || !channel->playing ) {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    
    AudioTimeStamp timestamp = *inTimeStamp;
    
    if ( channel->audiobusOutputPort && ABOutputPortGetConnectedPortAttributes(channel->audiobusOutputPort) & ABInputPortAttributePlaysLiveAudio ) {
        // We're sending via the output port, and the receiver plays live - offset the timestamp by the reported latency
        timestamp.mHostTime += ABOutputPortGetAverageLatency(channel->audiobusOutputPort)*__secondsToHostTicks;
    } else {
        // Adjust timestamp to factor in hardware output latency
        timestamp.mHostTime += AEAudioControllerOutputLatency(channel->audioController)*__secondsToHostTicks;
    }
    
    if ( channel->timeStamp.mFlags == 0 ) {
        channel->timeStamp = *inTimeStamp;
    } else {
        channel->timeStamp.mHostTime = inTimeStamp->mHostTime;
    }
    
    channel_producer_arg_t arg = {
        .channel = channel,
        .inTimeStamp = timestamp,
        .ioActionFlags = ioActionFlags,
        .nextFilterIndex = 0
    };
    
    OSStatus result = channelAudioProducer((void*)&arg, ioData, &inNumberFrames);
    
    handleCallbacksForChannel(channel, &timestamp, inNumberFrames, ioData);
    
    if ( channel->audiobusOutputPort && ABOutputPortIsConnected(channel->audiobusOutputPort) && channel->audiobusFloatConverter ) {
        // Convert the audio to float, and apply volume/pan if necessary
        if ( AEFloatConverterToFloatBufferList(channel->audiobusFloatConverter, ioData, channel->audiobusScratchBuffer, inNumberFrames) ) {
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
        ABOutputPortSendAudio(channel->audiobusOutputPort, channel->audiobusScratchBuffer, inNumberFrames, &timestamp, NULL);
        if ( ABOutputPortGetConnectedPortAttributes(channel->audiobusOutputPort) & ABInputPortAttributePlaysLiveAudio ) {
            // Silence output after sending
            for ( int i=0; i<ioData->mNumberBuffers; i++ ) memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
    }
    
    return result;
}

typedef struct __input_producer_arg_t {
    AEAudioController *THIS;
    input_callback_table_t *table;
    AudioTimeStamp inTimeStamp;
    AudioUnitRenderActionFlags *ioActionFlags;
    int nextFilterIndex;
} input_producer_arg_t;

static OSStatus inputAudioProducer(void *userInfo, AudioBufferList *audio, UInt32 *frames) {
    input_producer_arg_t *arg = (input_producer_arg_t*)userInfo;
    AEAudioController *THIS = arg->THIS;
    
    // See if there's another filter
    for ( int i=arg->table->callbacks.count-1, filterIndex=0; i>=0; i-- ) {
        callback_t *callback = &arg->table->callbacks.callbacks[i];
        if ( callback->flags & kFilterFlag ) {
            if ( filterIndex == arg->nextFilterIndex ) {
                // Run this filter
                input_producer_arg_t filterArg = *arg;
                filterArg.nextFilterIndex = filterIndex+1;
                return ((AEAudioControllerFilterCallback)callback->callback)(callback->userInfo, THIS, &inputAudioProducer, (void*)&filterArg, &arg->inTimeStamp, *frames, audio);
            }
            filterIndex++;
        }
    }
    
    if ( arg->table->audioConverter ) {
        // Perform conversion
        assert(THIS->_inputAudioBufferList->mBuffers[0].mData && THIS->_inputAudioBufferList->mBuffers[0].mDataByteSize > 0);
        assert(audio->mBuffers[0].mData && audio->mBuffers[0].mDataByteSize > 0);
        
        OSStatus result = AudioConverterFillComplexBuffer(arg->table->audioConverter,
                                                          fillComplexBufferInputProc,
                                                          &(struct fillComplexBufferInputProc_t) { .bufferList = THIS->_inputAudioBufferList, .frames = *frames },
                                                          frames,
                                                          audio,
                                                          NULL);
        checkResult(result, "AudioConverterConvertComplexBuffer");
    } else {
        for ( int i=0; i<audio->mNumberBuffers; i++ ) {
            audio->mBuffers[i].mDataByteSize = MIN(audio->mBuffers[i].mDataByteSize, THIS->_inputAudioBufferList->mBuffers[i].mDataByteSize);
            memcpy(audio->mBuffers[i].mData, THIS->_inputAudioBufferList->mBuffers[i].mData, audio->mBuffers[i].mDataByteSize);
        }
    }

    return noErr;
}

static OSStatus inputAvailableCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEAudioController *THIS = (AEAudioController *)inRefCon;
    
    if ( !THIS->_inputAudioBufferList ) return noErr;
    
    AudioTimeStamp timestamp = *inTimeStamp;
    
    BOOL useAudiobus = THIS->_audiobusInputPort && THIS->_usingAudiobusInput;
    
    if ( useAudiobus ) {
        // If Audiobus is connected, then serve Audiobus queue rather than serving system input queue
        static Float64 __sampleTime = 0;
        ABInputPortReceiveLive(THIS->_audiobusInputPort, THIS->_inputAudioBufferList, inNumberFrames, &timestamp);
        timestamp.mSampleTime = __sampleTime;
        __sampleTime += inNumberFrames;
    } else {
        // Adjust timestamp to factor in hardware input latency
        timestamp.mHostTime += AEAudioControllerInputLatency(THIS)*__secondsToHostTicks;
    }

    for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
        callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
        ((AEAudioControllerTimingCallback)callback->callback)(callback->userInfo, THIS, &timestamp, inNumberFrames, AEAudioTimingContextInput);
    }
    
    for ( int i=0; i<THIS->_inputAudioBufferList->mNumberBuffers; i++ ) {
        THIS->_inputAudioBufferList->mBuffers[i].mDataByteSize = kInputAudioBufferFrames * THIS->_rawInputAudioDescription.mBytesPerFrame;
    }
    
    // Render audio into buffer
    if ( !useAudiobus ) {
        for ( int i=0; i<THIS->_inputAudioBufferList->mNumberBuffers; i++ ) {
            THIS->_inputAudioBufferList->mBuffers[i].mDataByteSize = inNumberFrames * THIS->_rawInputAudioDescription.mBytesPerFrame;
        }
        OSStatus err = AudioUnitRender(THIS->_ioAudioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, THIS->_inputAudioBufferList);
        if ( !checkResult(err, "AudioUnitRender") ) {
            return err;
        }
    }
    
    if ( inNumberFrames == 0 ) return kNoAudioErr;
    
    OSStatus result = noErr;
    
    for ( int tableIndex = 0; tableIndex < THIS->_inputCallbackCount; tableIndex++ ) {
        input_callback_table_t *table = &THIS->_inputCallbacks[tableIndex];
        
        if ( !table->audioBufferList ) continue;
        
        input_producer_arg_t arg = {
            .THIS = THIS,
            .table = table,
            .inTimeStamp = timestamp,
            .ioActionFlags = ioActionFlags,
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
            
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, THIS, AEAudioSourceInput, &timestamp, inNumberFrames, table->audioBufferList);
        }
    }
    
    // Perform input metering
    if ( THIS->_inputLevelMonitorData.monitoringEnabled ) {
        performLevelMonitoring(&THIS->_inputLevelMonitorData, THIS->_inputAudioBufferList, inNumberFrames);
    }
    
    return result;
}

static OSStatus groupRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEChannelRef channel = (AEChannelRef)inRefCon;
    AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
    
    if ( !(*ioActionFlags & kAudioUnitRenderAction_PreRender) ) {
        // After render
        handleCallbacksForChannel(channel, inTimeStamp, inNumberFrames, ioData);
        
        if ( group->level_monitor_data.monitoringEnabled ) {
            performLevelMonitoring(&group->level_monitor_data, ioData, inNumberFrames);
        }
    }
    
    return noErr;
}

static OSStatus topRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    AEAudioController *THIS = (AEAudioController *)inRefCon;

    if ( *ioActionFlags & kAudioUnitRenderAction_PreRender ) {
        // Before render: Perform timing callbacks
        for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
            callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
            ((AEAudioControllerTimingCallback)callback->callback)(callback->userInfo, THIS, inTimeStamp, inNumberFrames, AEAudioTimingContextOutput);
        }
    } else {
        // After render
        if ( THIS->_muteOutput ) {
            for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
                memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
            }
        }
        
        processPendingMessagesOnRealtimeThread(THIS);
    }
    
    return noErr;
}

#pragma mark - Setup and start/stop

+(void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    __hostTicksToSeconds = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
    __secondsToHostTicks = 1.0 / __hostTicksToSeconds;
}


+ (AudioStreamBasicDescription)interleaved16BitStereoAudioDescription {
    AudioStreamBasicDescription audioDescription;
    memset(&audioDescription, 0, sizeof(audioDescription));
    audioDescription.mFormatID          = kAudioFormatLinearPCM;
    audioDescription.mFormatFlags       = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    audioDescription.mChannelsPerFrame  = 2;
    audioDescription.mBytesPerPacket    = sizeof(SInt16)*audioDescription.mChannelsPerFrame;
    audioDescription.mFramesPerPacket   = 1;
    audioDescription.mBytesPerFrame     = sizeof(SInt16)*audioDescription.mChannelsPerFrame;
    audioDescription.mBitsPerChannel    = 8 * sizeof(SInt16);
    audioDescription.mSampleRate        = 44100.0;
    return audioDescription;
}

+ (AudioStreamBasicDescription)nonInterleaved16BitStereoAudioDescription {
    AudioStreamBasicDescription audioDescription;
    memset(&audioDescription, 0, sizeof(audioDescription));
    audioDescription.mFormatID          = kAudioFormatLinearPCM;
    audioDescription.mFormatFlags       = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsNonInterleaved;
    audioDescription.mChannelsPerFrame  = 2;
    audioDescription.mBytesPerPacket    = sizeof(SInt16);
    audioDescription.mFramesPerPacket   = 1;
    audioDescription.mBytesPerFrame     = sizeof(SInt16);
    audioDescription.mBitsPerChannel    = 8 * sizeof(SInt16);
    audioDescription.mSampleRate        = 44100.0;
    return audioDescription;
}

+ (AudioStreamBasicDescription)nonInterleavedFloatStereoAudioDescription {
    AudioStreamBasicDescription audioDescription;
    memset(&audioDescription, 0, sizeof(audioDescription));
    audioDescription.mFormatID          = kAudioFormatLinearPCM;
    audioDescription.mFormatFlags       = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    audioDescription.mChannelsPerFrame  = 2;
    audioDescription.mBytesPerPacket    = sizeof(float);
    audioDescription.mFramesPerPacket   = 1;
    audioDescription.mBytesPerFrame     = sizeof(float);
    audioDescription.mBitsPerChannel    = 8 * sizeof(float);
    audioDescription.mSampleRate        = 44100.0;
    return audioDescription;
}

+ (AudioStreamBasicDescription)audioUnitCanonicalAudioDescription {
    AudioStreamBasicDescription audioDescription;
    memset(&audioDescription, 0, sizeof(audioDescription));
    audioDescription.mFormatID          = kAudioFormatLinearPCM;
    audioDescription.mFormatFlags       = kAudioFormatFlagsAudioUnitCanonical;
    audioDescription.mChannelsPerFrame  = 2;
    audioDescription.mBytesPerPacket    = sizeof(AudioUnitSampleType);
    audioDescription.mFramesPerPacket   = 1;
    audioDescription.mBytesPerFrame     = sizeof(AudioUnitSampleType);
    audioDescription.mBitsPerChannel    = 8 * sizeof(AudioUnitSampleType);
    audioDescription.mSampleRate        = 44100.0;
    return audioDescription;
}

+ (BOOL)voiceProcessingAvailable {
    // Determine platform name
    static NSString *platform = nil;
    if ( !platform ) {
        size_t size;
        sysctlbyname("hw.machine", NULL, &size, NULL, 0);
        char *machine = malloc(size);
        sysctlbyname("hw.machine", machine, &size, NULL, 0);
        platform = [[NSString stringWithCString:machine encoding:NSUTF8StringEncoding] retain];
        free(machine);
    }
    
    // These devices aren't fast enough to do voice processing effectively
    NSArray *badDevices = [NSArray arrayWithObjects:@"iPhone1,1", @"iPhone1,2", @"iPhone2,1", @"iPod1,1", @"iPod2,1", @"iPod3,1", nil];
    return ![badDevices containsObject:platform];
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription {
    return [self initWithAudioDescription:audioDescription inputEnabled:NO useVoiceProcessing:NO];
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput {
    return [self initWithAudioDescription:audioDescription inputEnabled:enableInput useVoiceProcessing:NO];
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput useVoiceProcessing:(BOOL)useVoiceProcessing {
    if ( !(self = [super init]) ) return nil;
    
    NSAssert(audioDescription.mFormatID == kAudioFormatLinearPCM, @"Only linear PCM supported");

    __interruptionListenerSelf = self;
    
    _audioSessionCategory = enableInput ? kAudioSessionCategory_PlayAndRecord : kAudioSessionCategory_MediaPlayback;
    _allowMixingWithOtherApps = YES;
    _audioDescription = audioDescription;
    _inputEnabled = enableInput;
    _masterOutputVolume = 1.0;
    _voiceProcessingEnabled = useVoiceProcessing;
    _inputMode = AEInputModeFixedAudioFormat;
    _voiceProcessingOnlyForSpeakerAndMicrophone = YES;
    _inputCallbacks = (input_callback_table_t*)calloc(sizeof(input_callback_table_t), 1);
    _inputCallbackCount = 1;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    
    if ( ABConnectionsChangedNotification ) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audiobusConnectionsChanged:) name:ABConnectionsChangedNotification object:nil];
    }
    
    TPCircularBufferInit(&_realtimeThreadMessageBuffer, kMessageBufferLength);
    TPCircularBufferInit(&_mainThreadMessageBuffer, kMessageBufferLength);
    
    if ( ![self initAudioSession] || ![self setup] ) {
        _audioGraph = NULL;
    }
    
    self.housekeepingTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:[[[AEAudioControllerProxy alloc] initWithAudioController:self] autorelease] selector:@selector(housekeeping) userInfo:nil repeats:YES];
    
    return self;
}

- (void)dealloc {
    __interruptionListenerSelf = nil;
    
    [_housekeepingTimer invalidate];
    self.housekeepingTimer = nil;
    
    self.lastError = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self stop];
    [self teardown];
    
    if ( _topChannel->audiobusOutputPort ) {
        [_topChannel->audiobusOutputPort removeObserver:self forKeyPath:@"destinations"];
        [_topChannel->audiobusOutputPort removeObserver:self forKeyPath:@"connectedPortAttributes"];
    }
    
    [self releaseResourcesForChannel:_topChannel];
    
    OSStatus result = AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, self);
    checkResult(result, "AudioSessionRemovePropertyListenerWithUserData");
    
    result = AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioInputAvailable, audioSessionPropertyListener, self);
    checkResult(result, "AudioSessionRemovePropertyListenerWithUserData");
    
    self.audioRoute = nil;
    
    if ( _audiobusInputPort ) [_audiobusInputPort release];
    
    TPCircularBufferCleanup(&_realtimeThreadMessageBuffer);
    TPCircularBufferCleanup(&_mainThreadMessageBuffer);
    
    if ( _inputLevelMonitorData.scratchBuffer ) {
        AEFreeAudioBufferList(_inputLevelMonitorData.scratchBuffer);
    }
    
    if ( _inputLevelMonitorData.floatConverter ) {
        [_inputLevelMonitorData.floatConverter release];
    }
    
    if ( _inputAudioBufferList ) {
        AEFreeAudioBufferList(_inputAudioBufferList);
    }
    
    for ( int i=0; i<_inputCallbackCount; i++ ) {
        if ( _inputCallbacks[i].channelMap ) {
            [_inputCallbacks[i].channelMap release];
        }
    }
    free(_inputCallbacks);
    
    [super dealloc];
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
    
    if ( !checkResult(status=AudioSessionSetActive(true), "AudioSessionSetActive") ) {
        if ( error ) *error = [NSError audioControllerErrorWithMessage:@"Couldn't activate audio session" OSStatus:status];
        return NO;
    }
    
    Float32 bufferDuration;
    UInt32 bufferDurationSize = sizeof(bufferDuration);
    OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareIOBufferDuration, &bufferDurationSize, &bufferDuration);
    checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareIOBufferDuration)");
    if ( _currentBufferDuration != bufferDuration ) self.currentBufferDuration = bufferDuration;
    
    BOOL hasError = NO;
    
    _interrupted = NO;
    
    if ( _inputEnabled ) {
        // Determine if audio input is available, and the number of input channels available
        if ( ![self updateInputDeviceStatus] ) {
            if ( error ) *error = self.lastError;
            self.lastError = nil;
            hasError = YES;
        }
    }
    
    if ( !_pollThread ) {
        // Start messaging poll thread
        _pollThread = [[AEAudioControllerMessagePollThread alloc] initWithAudioController:self];
        _pollThread.pollInterval = kIdleMessagingPollDuration;
        OSMemoryBarrier();
        [_pollThread start];
    }
    
    if ( !self.running ) {
        // Start things up
        if ( checkResult(status=AUGraphStart(_audioGraph), "AUGraphStart") ) {
            _running = YES;
        } else {
            if ( !recoverFromErrors || ![self attemptRecoveryFromSystemError:error] ) {
                if ( error && !*error ) *error = [NSError audioControllerErrorWithMessage:@"Couldn't start audio engine" OSStatus:status];
                return NO;
            }
        }
    }
    
    return !hasError;
}

- (void)stop {
    NSLog(@"TAAE: Stopping Engine");
    
    if ( _running ) {
        checkResult(AUGraphStop(_audioGraph), "AUGraphStop");
        
        _running = NO;
        
        if ( !_interrupted ) {
            AudioSessionSetActive(false);
        }
        
        processPendingMessagesOnRealtimeThread(self);
    }
    
    if ( _pollThread ) {
        [_pollThread cancel];
        while ( [_pollThread isExecuting] ) {
            [NSThread sleepForTimeInterval:0.01];
        }
        [_pollThread release];
        _pollThread = nil;
    }
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
            NSLog(@"Warning: Channel limit reached");
            break;
        }
        
        [channel retain];
        
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"channelIsPlaying", @"channelIsMuted", @"audioDescription", nil] ) {
            [(NSObject*)channel addObserver:self forKeyPath:property options:0 context:NULL];
        }
        
        AEChannelRef channelElement = (AEChannelRef)calloc(1, sizeof(channel_t));
        channelElement->type        = kChannelTypeChannel;
        channelElement->ptr         = channel.renderCallback;
        channelElement->object      = channel;
        channelElement->playing     = [channel respondsToSelector:@selector(channelIsPlaying)] ? channel.channelIsPlaying : YES;
        channelElement->volume      = [channel respondsToSelector:@selector(volume)] ? channel.volume : 1.0;
        channelElement->pan         = [channel respondsToSelector:@selector(pan)] ? channel.pan : 0.0;
        channelElement->muted       = [channel respondsToSelector:@selector(channelIsMuted)] ? channel.channelIsMuted : NO;
        channelElement->audioDescription = [channel respondsToSelector:@selector(audioDescription)] && channel.audioDescription.mSampleRate ? channel.audioDescription : _audioDescription;
        memset(&channelElement->timeStamp, 0, sizeof(channelElement->timeStamp));
        channelElement->audioController = self;
        
        group->channels[group->channelCount++] = channelElement;
    }

    int channelCount = (int)[channels count];
    
    // Set bus count
    UInt32 busCount = group->channelCount;
    OSStatus result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // Configure each channel
    [self configureChannelsInRange:NSMakeRange(group->channelCount - channelCount, channelCount) forGroup:group];
    
    checkResult([self updateGraph], "Update graph");
}

- (void)removeChannels:(NSArray *)channels {
    // Find parent groups of each channel, and remove channels (in batches, if possible)
    NSMutableArray *siblings = [NSMutableArray array];
    AEChannelGroupRef lastGroup = NULL;
    for ( id<AEAudioPlayable> channel in channels ) {
        AEChannelGroupRef group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:channel index:NULL];
        
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
        ptrMatchArray[i] = ((id<AEAudioPlayable>)[channels objectAtIndex:i]).renderCallback;
        objectMatchArray[i] = [channels objectAtIndex:i];
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
    
    checkResult([self updateGraph], "Update graph");
    
    // Set new bus count of group
    UInt32 busCount = group->channelCount;
    if ( !checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)),
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
        
        checkResult([self updateGraph], "Update graph");
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
            [channels addObject:(id)group->channels[i]->object];
        }
    }
    return channels;
}


- (AEChannelGroupRef)createChannelGroup {
    return [self createChannelGroupWithinChannelGroup:_topGroup];
}

- (AEChannelGroupRef)createChannelGroupWithinChannelGroup:(AEChannelGroupRef)parentGroup {
    if ( parentGroup->channelCount == kMaximumChannelsPerGroup ) {
        NSLog(@"Maximum channels reached in group %p\n", parentGroup);
        return NULL;
    }
    
    // Allocate group
    AEChannelGroupRef group = (AEChannelGroupRef)calloc(1, sizeof(channel_group_t));
    
    // Add group as a channel to the parent group
    int groupIndex = parentGroup->channelCount;
    
    AEChannelRef channel = (AEChannelRef)calloc(1, sizeof(channel_t));
    
    channel->type    = kChannelTypeGroup;
    channel->ptr     = group;
    channel->playing = YES;
    channel->volume  = 1.0;
    channel->pan     = 0.0;
    channel->muted   = NO;
    channel->audioController = self;
    
    parentGroup->channels[groupIndex] = channel;
    group->channel   = channel;
    
    parentGroup->channelCount++;

    [self configureChannelsInRange:NSMakeRange(groupIndex, 1) forGroup:parentGroup];
    checkResult([self updateGraph], "Update graph");
    
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
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
}

-(float)volumeForChannelGroup:(AEChannelGroupRef)group {
    return group->channel->volume;
}

- (void)setPan:(float)pan forChannelGroup:(AEChannelGroupRef)group {
    int index;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AudioUnitParameterValue value = group->channel->pan = pan;
    if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
    if ( value == 1.0 ) value = 0.999;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
}

-(float)panForChannelGroup:(AEChannelGroupRef)group {
    return group->channel->pan;
}

- (void)setMuted:(BOOL)muted forChannelGroup:(AEChannelGroupRef)group {
    int index;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    group->channel->muted = muted;
    AudioUnitParameterValue value = !muted && group->channel->playing;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
}

-(BOOL)channelGroupIsMuted:(AEChannelGroupRef)group {
    return group->channel->muted;
}

#pragma mark - Filters

- (void)addFilter:(id<AEAudioFilter>)filter {
    if ( [self addCallback:filter.filterCallback userInfo:filter flags:kFilterFlag forChannelGroup:_topGroup] ) {
        [filter retain];
    }
}

- (void)addFilter:(id<AEAudioFilter>)filter toChannel:(id<AEAudioPlayable>)channel {
    if ( [self addCallback:filter.filterCallback userInfo:filter flags:kFilterFlag forChannel:channel] ) {
        [filter retain];
    }
}

- (void)addFilter:(id<AEAudioFilter>)filter toChannelGroup:(AEChannelGroupRef)group {
    if ( [self addCallback:filter.filterCallback userInfo:filter flags:kFilterFlag forChannelGroup:group] ) {
        [filter retain];
    }
}

- (void)addInputFilter:(id<AEAudioFilter>)filter {
    [self addInputFilter:filter forChannels:nil];
}

- (void)addInputFilter:(id<AEAudioFilter>)filter forChannels:(NSArray *)channels {
    void *callback = filter.filterCallback;
    if ( [self addCallback:callback userInfo:filter flags:kFilterFlag forInputChannels:channels] ) {
        [filter retain];
    }
}

- (void)removeFilter:(id<AEAudioFilter>)filter {
    if ( [self removeCallback:filter.filterCallback userInfo:filter fromChannelGroup:_topGroup] ) {
        [filter release];
    }
}

- (void)removeFilter:(id<AEAudioFilter>)filter fromChannel:(id<AEAudioPlayable>)channel {
    if ( [self removeCallback:filter.filterCallback userInfo:filter fromChannel:channel] ) {
        [filter release];
    }
}

- (void)removeFilter:(id<AEAudioFilter>)filter fromChannelGroup:(AEChannelGroupRef)group {
    if ( [self removeCallback:filter.filterCallback userInfo:filter fromChannelGroup:group] ) {
        [filter release];
    }
}

- (void)removeInputFilter:(id<AEAudioFilter>)filter {
    void *callback = filter.filterCallback;
    __block BOOL found = NO;
    [self performSynchronousMessageExchangeWithBlock:^{
        for ( int i=0; i<_inputCallbackCount; i++ ) {
            removeCallbackFromTable(self, &_inputCallbacks[i].callbacks, callback, filter, &found);
        }
    }];
    
    if ( found ) {
        [filter release];
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
    if ( [self addCallback:receiver.receiverCallback userInfo:receiver flags:kReceiverFlag forChannelGroup:_topGroup] ) {
        [receiver retain];
    }
}

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannel:(id<AEAudioPlayable>)channel {
    if ( [self addCallback:receiver.receiverCallback userInfo:receiver flags:kReceiverFlag forChannel:channel] ) {
        [receiver retain];
    }
}

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannelGroup:(AEChannelGroupRef)group {
    if ( [self addCallback:receiver.receiverCallback userInfo:receiver flags:kReceiverFlag forChannelGroup:group] ) {
        [receiver retain];
    }
}

- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver {
    if ( [self removeCallback:receiver.receiverCallback userInfo:receiver fromChannelGroup:_topGroup] ) {
        [receiver release];
    }
}

- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver fromChannel:(id<AEAudioPlayable>)channel {
    if ( [self removeCallback:receiver.receiverCallback userInfo:receiver fromChannel:channel] ) {
        [receiver release];
    }
}

- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver fromChannelGroup:(AEChannelGroupRef)group {
    if ( [self removeCallback:receiver.receiverCallback userInfo:receiver fromChannelGroup:group] ) {
        [receiver release];
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
    void *callback = receiver.receiverCallback;
    
    if ( [self addCallback:callback userInfo:receiver flags:kReceiverFlag forInputChannels:channels] ) {
        [receiver retain];
    }
}

- (void)removeInputReceiver:(id<AEAudioReceiver>)receiver {
    void *callback = receiver.receiverCallback;
    __block BOOL found = NO;
    [self performSynchronousMessageExchangeWithBlock:^{
        for ( int i=0; i<_inputCallbackCount; i++ ) {
            removeCallbackFromTable(self, &_inputCallbacks[i].callbacks, callback, receiver, &found);
        }
    }];
    
    if ( found ) {
        [receiver release];
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
        NSLog(@"Warning: Maximum number of callbacks reached");
        return;
    }
    
    [receiver retain];
    
    void *callback = receiver.timingReceiverCallback;
    [self performSynchronousMessageExchangeWithBlock:^{
        addCallbackToTable(self, &_timingCallbacks, callback, receiver, 0);
    }];
}

- (void)removeTimingReceiver:(id<AEAudioTimingReceiver>)receiver {
    void *callback = receiver.timingReceiverCallback;
    __block BOOL found = NO;
    [self performSynchronousMessageExchangeWithBlock:^{
        removeCallbackFromTable(self, &_timingCallbacks, callback, receiver, &found);
    }];
    
    if ( found ) {
        [receiver release];
    }
}

-(NSArray *)timingReceivers {
    return [self associatedObjectsFromTable:&_timingCallbacks matchingFlag:0];
}

#pragma mark - Main thread-realtime thread message sending

static void processPendingMessagesOnRealtimeThread(AEAudioController *THIS) {
    // Only call this from the Core Audio thread, or the main thread if audio system is not yet running
    int32_t availableBytes;
    message_t *messagePtr = TPCircularBufferTail(&THIS->_realtimeThreadMessageBuffer, &availableBytes);
    void *end = (char*)messagePtr + availableBytes;
    
    message_t message;
    while ( (void*)messagePtr < (void*)end ) {
        memcpy(&message, messagePtr, sizeof(message));
        TPCircularBufferConsume(&THIS->_realtimeThreadMessageBuffer, sizeof(message_t));
        
        if ( message.block ) {
#ifdef DEBUG
            uint64_t start = mach_absolute_time();
#endif
            message.block();
#ifdef DEBUG
            uint64_t end = mach_absolute_time();
            if ( (end-start)*__hostTicksToSeconds >= (THIS->_preferredBufferDuration ? THIS->_preferredBufferDuration : 0.01) ) {
                printf("Warning: Block perform on realtime thread took too long (%0.4lfs)\n", (end-start)*__hostTicksToSeconds);
            }
#endif
        }

        if ( message.responseBlock ) {
            int32_t availableBytes;
            message_t *reply = TPCircularBufferHead(&THIS->_mainThreadMessageBuffer, &availableBytes);
            assert(availableBytes >= sizeof(message_t));
            memcpy(reply, &message, sizeof(message_t));
            TPCircularBufferProduce(&THIS->_mainThreadMessageBuffer, sizeof(message_t));
        }
        
        messagePtr++;
    }
}

-(void)pollForMessageResponses {
    pthread_t thread = pthread_self();
    while ( 1 ) {
        message_t *message = NULL;
        @synchronized ( self ) {
            int32_t availableBytes;
            message_t *buffer = TPCircularBufferTail(&_mainThreadMessageBuffer, &availableBytes);
            if ( !buffer ) break;
            
            if ( buffer->sourceThread && buffer->sourceThread != thread ) break;
            
            int messageLength = sizeof(message_t) + (buffer->userInfoLength && !buffer->userInfoByReference ? buffer->userInfoLength : 0);
            message = malloc(messageLength);
            memcpy(message, buffer, messageLength);
            
            TPCircularBufferConsume(&_mainThreadMessageBuffer, messageLength);
            
            _pendingResponses--;
            
            if ( _pollThread && _pendingResponses == 0 ) {
                _pollThread.pollInterval = kIdleMessagingPollDuration;
            }
        }
        
        if ( message->responseBlock ) {
            message->responseBlock();
            [message->responseBlock release];
        } else if ( message->handler ) {
            message->handler(self, 
                             message->userInfoLength > 0
                             ? (message->userInfoByReference ? message->userInfoByReference : message+1) 
                             : NULL, 
                             message->userInfoLength);
        }
        
        if ( message->block ) {
            [message->block release];
        }
        
        free(message);
    }
}

- (void)performAsynchronousMessageExchangeWithBlock:(void (^)())block
                                      responseBlock:(void (^)())responseBlock
                                       sourceThread:(pthread_t)sourceThread {
    @synchronized ( self ) {
        if ( block ) {
            block = [block copy];
        }
        if ( responseBlock ) {
            responseBlock = [responseBlock copy];
            _pendingResponses++;
            
            if ( self.running && _pollThread.pollInterval == kIdleMessagingPollDuration ) {
                // Perform more rapid active polling while we expect a response
                _pollThread.pollInterval = _preferredBufferDuration ? _preferredBufferDuration : 0.01;
            }
        }
        
        int32_t availableBytes;
        message_t *message = TPCircularBufferHead(&_realtimeThreadMessageBuffer, &availableBytes);
        assert(availableBytes >= sizeof(message_t));
        memset(message, 0, sizeof(message_t));
        message->block         = block;
        message->responseBlock = responseBlock;
        message->sourceThread  = sourceThread;
        
        TPCircularBufferProduce(&_realtimeThreadMessageBuffer, sizeof(message_t));
        
        if ( !self.running ) {
            if ( [NSThread isMainThread] ) {
                processPendingMessagesOnRealtimeThread(self);
                [self pollForMessageResponses];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    processPendingMessagesOnRealtimeThread(self);
                    [self pollForMessageResponses];
                });
            }
        }
    }
}

- (void)performAsynchronousMessageExchangeWithBlock:(void (^)())block responseBlock:(void (^)())responseBlock {
    [self performAsynchronousMessageExchangeWithBlock:block responseBlock:responseBlock sourceThread:NULL];
}

- (void)performSynchronousMessageExchangeWithBlock:(void (^)())block {
    __block BOOL finished = NO;
    [self performAsynchronousMessageExchangeWithBlock:block
                                        responseBlock:^{ finished = YES; }
                                         sourceThread:pthread_self()];
    
    // Wait for response
    uint64_t giveUpTime = mach_absolute_time() + (1.0 * __secondsToHostTicks);
    while ( !finished && mach_absolute_time() < giveUpTime ) {
        if ( [NSThread isMainThread] ) {
            [self pollForMessageResponses];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self pollForMessageResponses];
            });
        }
        if ( finished ) break;
        [NSThread sleepForTimeInterval:_preferredBufferDuration ? _preferredBufferDuration : 0.01];
    }
    
    if ( !finished ) {
        NSLog(@"TAAE: Timed out while performing message exchange");
        @synchronized ( self ) {
            processPendingMessagesOnRealtimeThread(self);
            [self pollForMessageResponses];
        }
    }
}

void AEAudioControllerSendAsynchronousMessageToMainThread(AEAudioController                 *THIS, 
                                                          AEAudioControllerMainThreadMessageHandler    handler, 
                                                          void                              *userInfo,
                                                          int                                userInfoLength) {
    
    int32_t availableBytes;
    message_t *message = TPCircularBufferHead(&THIS->_mainThreadMessageBuffer, &availableBytes);
    assert(availableBytes >= sizeof(message_t) + userInfoLength);
    memset(message, 0, sizeof(message_t));
    message->handler                = handler;
    message->userInfoLength         = userInfoLength;
    
    if ( userInfoLength > 0 ) {
        memcpy((message+1), userInfo, userInfoLength);
    }
    
    TPCircularBufferProduce(&THIS->_mainThreadMessageBuffer, sizeof(message_t) + userInfoLength);
}

static BOOL AEAudioControllerHasPendingMainThreadMessages(AEAudioController *THIS) {
    int32_t ignore;
    return TPCircularBufferTail(&THIS->_mainThreadMessageBuffer, &ignore) != NULL;
}

#pragma mark - Metering

- (void)outputAveragePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel {
    return [self averagePowerLevel:averagePower peakHoldLevel:peakLevel forGroup:_topGroup];
}

- (void)averagePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel forGroup:(AEChannelGroupRef)group {
    if ( !group->level_monitor_data.monitoringEnabled ) {
        if ( ![NSThread isMainThread] ) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self averagePowerLevel:NULL peakHoldLevel:NULL forGroup:group]; });
        } else {
            group->level_monitor_data.channels = group->channel->audioDescription.mChannelsPerFrame;
            group->level_monitor_data.floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:group->channel->audioDescription];
            group->level_monitor_data.scratchBuffer = AEAllocateAndInitAudioBufferList(group->level_monitor_data.floatConverter.floatingPointAudioDescription, kLevelMonitorScratchBufferSize);
            OSMemoryBarrier();
            group->level_monitor_data.monitoringEnabled = YES;
            
            AEChannelGroupRef parentGroup = NULL;
            int index=0;
            if ( group != _topGroup ) {
                parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
                NSAssert(parentGroup != NULL, @"Channel group not found");
            }
            
            [self configureChannelsInRange:NSMakeRange(index, 1) forGroup:parentGroup];
            checkResult([self updateGraph], "Update graph");
        }
    }
    
    if ( averagePower ) *averagePower = 10.0 * log10((double)group->level_monitor_data.average);
    if ( peakLevel ) *peakLevel = 10.0 * log10((double)group->level_monitor_data.peak);
    
    group->level_monitor_data.reset = YES;
}

- (void)inputAveragePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel {
    if ( !_inputLevelMonitorData.monitoringEnabled ) {
        _inputLevelMonitorData.channels = _rawInputAudioDescription.mChannelsPerFrame;
        _inputLevelMonitorData.floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:_rawInputAudioDescription];
        _inputLevelMonitorData.scratchBuffer = AEAllocateAndInitAudioBufferList(_inputLevelMonitorData.floatConverter.floatingPointAudioDescription, kLevelMonitorScratchBufferSize);
        OSMemoryBarrier();
        _inputLevelMonitorData.monitoringEnabled = YES;
    }
    
    if ( averagePower ) *averagePower = 10.0 * log10((double)_inputLevelMonitorData.average);
    if ( peakLevel ) *peakLevel = 10.0 * log10((double)_inputLevelMonitorData.peak);
    
    _inputLevelMonitorData.reset = YES;
}

#pragma mark - Utilities

AudioStreamBasicDescription *AEAudioControllerAudioDescription(AEAudioController *THIS) {
    return &THIS->_audioDescription;
}

AudioStreamBasicDescription *AEAudioControllerInputAudioDescription(AEAudioController *THIS) {
    return &THIS->_inputCallbacks[0].audioDescription;
}

long AEConvertSecondsToFrames(AEAudioController *THIS, NSTimeInterval seconds) {
    return round(seconds * THIS->_audioDescription.mSampleRate);
}

NSTimeInterval AEConvertFramesToSeconds(AEAudioController *THIS, long frames) {
    return (double)frames / THIS->_audioDescription.mSampleRate;
}

#pragma mark - Setters, getters

-(void)setAudioSessionCategory:(UInt32)audioSessionCategory {
    NSLog(@"TAAE: Setting audio session category to %@",
          audioSessionCategory == kAudioSessionCategory_MediaPlayback ? @"MediaPlayback":
          audioSessionCategory == kAudioSessionCategory_PlayAndRecord ? @"PlayAndRecord":
          audioSessionCategory == kAudioSessionCategory_LiveAudio ? @"LiveAudio":
          audioSessionCategory == kAudioSessionCategory_RecordAudio ? @"RecordAudio":
          audioSessionCategory == kAudioSessionCategory_AmbientSound ? @"AmbientSound":
          audioSessionCategory == kAudioSessionCategory_SoloAmbientSound ? @"SoloAmbientSound":
          @"(other)");
    
    _audioSessionCategory = audioSessionCategory;
    UInt32 category = _audioSessionCategory;
    
    if ( !_audioInputAvailable && (category == kAudioSessionCategory_PlayAndRecord || category == kAudioSessionCategory_RecordAudio) ) {
        NSLog(@"TAAE: No input available. Using MediaPlayback category instead.");
        category = kAudioSessionCategory_MediaPlayback;
    }
    
    checkResult(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(category), &category),
                "AudioSessionSetProperty(kAudioSessionProperty_AudioCategory)");
    
    if ( category == kAudioSessionCategory_PlayAndRecord ) {
        UInt32 toSpeaker = YES;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker, sizeof (toSpeaker), &toSpeaker), "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker)");
    }
    
    UInt32 allowBluetoothInput = _enableBluetoothInput;
    OSStatus result = AudioSessionSetProperty (kAudioSessionProperty_OverrideCategoryEnableBluetoothInput, sizeof (allowBluetoothInput), &allowBluetoothInput);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput)");
    
    if ( category == kAudioSessionCategory_MediaPlayback || category == kAudioSessionCategory_PlayAndRecord ) {
        UInt32 allowMixing = _allowMixingWithOtherApps;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                    "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    }
}

-(UInt32)audioSessionCategory {
    return ( !_audioInputAvailable && (_audioSessionCategory == kAudioSessionCategory_PlayAndRecord || _audioSessionCategory == kAudioSessionCategory_RecordAudio) )
                ? kAudioSessionCategory_MediaPlayback
                : _audioSessionCategory;
}

-(void)setAllowMixingWithOtherApps:(BOOL)allowMixingWithOtherApps {
    _allowMixingWithOtherApps = allowMixingWithOtherApps;
    
    UInt32 allowMixing = _allowMixingWithOtherApps;
    checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
}

-(void)setMasterOutputVolume:(float)masterOutputVolume {
    _masterOutputVolume = masterOutputVolume;
    
    AudioUnitParameterValue value = _masterOutputVolume;
    OSStatus result = AudioUnitSetParameter(_topGroup->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
}

- (BOOL)running {
    if ( !_audioGraph ) return NO;
    
    if ( _interrupted ) return NO;
    
    return _running;
}

-(void)setEnableBluetoothInput:(BOOL)enableBluetoothInput {
    _enableBluetoothInput = enableBluetoothInput;

    // Enable/disable bluetooth
    UInt32 allowBluetoothInput = _enableBluetoothInput;
    OSStatus result = AudioSessionSetProperty (kAudioSessionProperty_OverrideCategoryEnableBluetoothInput, sizeof (allowBluetoothInput), &allowBluetoothInput);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput)");
    
    if ( _audioSessionCategory == kAudioSessionCategory_MediaPlayback || _audioSessionCategory == kAudioSessionCategory_PlayAndRecord ) {
        UInt32 allowMixing = _allowMixingWithOtherApps;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                    "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    }
}

-(NSString*)audioRoute {
    if ( _topChannel && _topChannel->audiobusOutputPort && ABOutputPortGetConnectedPortAttributes(_topChannel->audiobusOutputPort) & ABInputPortAttributePlaysLiveAudio ) {
        return @"Audiobus";
    } else {
        return _audioRoute;
    }
}

-(BOOL)playingThroughDeviceSpeaker {
    if ( _topChannel && _topChannel->audiobusOutputPort && ABOutputPortGetConnectedPortAttributes(_topChannel->audiobusOutputPort) & ABInputPortAttributePlaysLiveAudio ) {
        return NO;
    } else {
        return _playingThroughDeviceSpeaker;
    }
}

-(BOOL)inputGainAvailable {
    UInt32 inputGainAvailable = NO;
    UInt32 size = sizeof(inputGainAvailable);
    OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_InputGainAvailable, &size, &inputGainAvailable);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_InputGainAvailable)");
    return inputGainAvailable;
}

-(float)inputGain {
    Float32 inputGain = NO;
    UInt32 size = sizeof(inputGain);
    OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_InputGainScalar, &size, &inputGain);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_InputGainScalar)");
    return inputGain;
}

-(AudioStreamBasicDescription)inputAudioDescription {
    return _inputCallbacks[0].audioDescription;
}

-(void)setInputGain:(float)inputGain {
    Float32 inputGainScaler = inputGain;
    OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_InputGainScalar, sizeof(inputGainScaler), &inputGainScaler);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_InputGainScalar)");
}

-(void)setInputMode:(AEInputMode)inputMode {
    _inputMode = inputMode;
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
}

-(NSArray *)inputChannelSelection {
    if ( _inputCallbacks[0].channelMap ) return _inputCallbacks[0].channelMap;
    NSMutableArray *selection = [NSMutableArray array];
    for ( int i=0; i<MIN(_numberOfInputChannels, _inputCallbacks[0].audioDescription.mChannelsPerFrame); i++ ) {
        [selection addObject:[NSNumber numberWithInt:i]];
    }
    return selection;
}

-(void)setInputChannelSelection:(NSArray *)inputChannelSelection {
    if ( (!inputChannelSelection && !_inputCallbacks[0].channelMap) || [inputChannelSelection isEqualToArray:_inputCallbacks[0].channelMap] ) return;
    
    [inputChannelSelection retain];
    [_inputCallbacks[0].channelMap release];
    _inputCallbacks[0].channelMap = inputChannelSelection;
    
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
}

-(void)setPreferredBufferDuration:(float)preferredBufferDuration {
    if ( _preferredBufferDuration == preferredBufferDuration ) return;
    
    _preferredBufferDuration = preferredBufferDuration;

    Float32 preferredBufferSize = [self usingVPIO] ? MAX(kMaxBufferDurationWithVPIO, _preferredBufferDuration) : _preferredBufferDuration;
    OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    
    Float32 grantedBufferSize;
    UInt32 grantedBufferSizeSize = sizeof(grantedBufferSize);
    result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareIOBufferDuration, &grantedBufferSizeSize, &grantedBufferSize);
    checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareIOBufferDuration)");
    if ( _currentBufferDuration != grantedBufferSize ) self.currentBufferDuration = grantedBufferSize;
    
    NSLog(@"Buffer duration %0.2g, %d frames (requested %0.2gs, %d frames)",
          grantedBufferSize, (int)round(grantedBufferSize*_audioDescription.mSampleRate),
          preferredBufferSize, (int)round(preferredBufferSize*_audioDescription.mSampleRate));
}

-(NSTimeInterval)inputLatency {
    return AEAudioControllerInputLatency(self);
}

NSTimeInterval AEAudioControllerInputLatency(AEAudioController *controller) {
    if ( __cachedInputLatency == kNoValue ) {
        UInt32 size = sizeof(__cachedInputLatency);
        if ( !checkResult(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputLatency, &size, &__cachedInputLatency),
                          "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputLatency)") ) {
            __cachedInputLatency = 0;
        }
    }
    return __cachedInputLatency;
}

-(NSTimeInterval)outputLatency {
    return AEAudioControllerOutputLatency(self);
}

NSTimeInterval AEAudioControllerOutputLatency(AEAudioController *controller) {
    if ( __cachedOutputLatency == kNoValue ) {
        UInt32 size = sizeof(__cachedOutputLatency);
        if ( !checkResult(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputLatency, &size, &__cachedOutputLatency),
                          "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputLatency)") ) {
            __cachedOutputLatency = 0;
        }
    }
    return __cachedOutputLatency;
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

-(void)setAudiobusInputPort:(ABInputPort *)audiobusInputPort {
    if ( _audiobusInputPort ) {
        [_audiobusInputPort setAudioInputBlock:nil];
    }
    
    [audiobusInputPort retain];
    [_audiobusInputPort release];
    _audiobusInputPort = audiobusInputPort;

    if ( _audiobusInputPort && [_audiobusInputPort respondsToSelector:@selector(setMuteLiveAudioInputWhenConnectedToSelf:)] ) {
        // Don't mute live audio input when we're connected to ourselves, as AEPlaythroughChannel will handle this case correctly
        [_audiobusInputPort setMuteLiveAudioInputWhenConnectedToSelf:NO];
    }
    
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
}

-(void)setAudiobusOutputPort:(ABOutputPort *)audiobusOutputPort {
    if ( _topChannel->audiobusOutputPort == audiobusOutputPort ) return;
    
    if ( _topChannel->audiobusOutputPort ) {
        [_topChannel->audiobusOutputPort removeObserver:self forKeyPath:@"destinations"];
        [_topChannel->audiobusOutputPort removeObserver:self forKeyPath:@"connectedPortAttributes"];
    }
    
    [self willChangeValueForKey:@"audioRoute"];
    [self willChangeValueForKey:@"playingThroughDeviceSpeaker"];
    [self setAudiobusOutputPort:audiobusOutputPort forChannelElement:_topChannel];
    [self didChangeValueForKey:@"audioRoute"];
    [self didChangeValueForKey:@"playingThroughDeviceSpeaker"];
    
    
    if ( _topChannel->audiobusOutputPort ) {
        [_topChannel->audiobusOutputPort addObserver:self forKeyPath:@"destinations" options:NSKeyValueObservingOptionPrior context:NULL];
        [_topChannel->audiobusOutputPort addObserver:self forKeyPath:@"connectedPortAttributes" options:NSKeyValueObservingOptionPrior context:NULL];
    }
}

- (ABOutputPort*)audiobusOutputPort {
    return _topChannel->audiobusOutputPort;
}

-(void)setAudiobusOutputPort:(ABOutputPort *)audiobusOutputPort forChannelElement:(AEChannelRef)channelElement {
    if ( channelElement->audiobusOutputPort == audiobusOutputPort ) return;
    
    if ( channelElement->audiobusOutputPort ) {
        [channelElement->audiobusOutputPort autorelease];
    }
    
    if ( audiobusOutputPort == nil ) {
        [self performSynchronousMessageExchangeWithBlock:^{
            channelElement->audiobusOutputPort = nil;
        }];
        AEFreeAudioBufferList(channelElement->audiobusScratchBuffer);
        channelElement->audiobusScratchBuffer = NULL;
        [channelElement->audiobusFloatConverter release];
        channelElement->audiobusFloatConverter = nil;
    } else {
        channelElement->audiobusOutputPort = [audiobusOutputPort retain];
        if ( !channelElement->audiobusFloatConverter ) {
            channelElement->audiobusFloatConverter = [[AEFloatConverter alloc] initWithSourceFormat:channelElement->audioDescription];
        }
        if ( !channelElement->audiobusScratchBuffer ) {
            channelElement->audiobusScratchBuffer = AEAllocateAndInitAudioBufferList(channelElement->audiobusFloatConverter.floatingPointAudioDescription, kScratchBufferFrames);
        }
        [audiobusOutputPort setClientFormat:channelElement->audiobusFloatConverter.floatingPointAudioDescription];
        if ( channelElement->type == kChannelTypeGroup ) {
            AEChannelGroupRef parentGroup = NULL;
            int index=0;
            if ( channelElement != _topChannel ) {
                parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelElement->ptr userInfo:NULL index:&index];
                NSAssert(parentGroup != NULL, @"Channel group not found");
            }
            
            [self configureChannelsInRange:NSMakeRange(index, 1) forGroup:parentGroup];
            checkResult([self updateGraph], "Update graph");
        }
    }
}

-(void)setAudiobusOutputPort:(ABOutputPort *)outputPort forChannel:(id<AEAudioPlayable>)channel {
    int index;
    AEChannelGroupRef group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:channel index:&index];
    if ( !group ) return;
    [self setAudiobusOutputPort:outputPort forChannelElement:group->channels[index]];
}

-(void)setAudiobusOutputPort:(ABOutputPort *)outputPort forChannelGroup:(AEChannelGroupRef)channelGroup {
    [self setAudiobusOutputPort:outputPort forChannelElement:channelGroup->channel];
}

#pragma mark - Events

-(void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {

    if ( object == _topChannel->audiobusOutputPort ) {
        if ( [change objectForKey:NSKeyValueChangeNotificationIsPriorKey] ) {
            [self willChangeValueForKey:@"audioRoute"];
            [self willChangeValueForKey:@"playingThroughDeviceSpeaker"];
        } else {
            [self didChangeValueForKey:@"audioRoute"];
            [self didChangeValueForKey:@"playingThroughDeviceSpeaker"];
        }
        return;
    }
    
    id<AEAudioPlayable> channel = (id<AEAudioPlayable>)object;
    
    int index;
    AEChannelGroupRef group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:channel index:&index];
    if ( !group ) return;
    
    AEChannelRef channelElement = group->channels[index];
    
    if ( [keyPath isEqualToString:@"volume"] ) {
        channelElement->volume = channel.volume;
        
        if ( group->mixerAudioUnit ) {
            AudioUnitParameterValue value = channelElement->volume;
            OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0);
            checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
        }
        
    } else if ( [keyPath isEqualToString:@"pan"] ) {
        channelElement->pan = channel.pan;
        
        if ( group->mixerAudioUnit ) {
            AudioUnitParameterValue value = channelElement->pan;
            if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
            if ( value == 1.0 ) value = 0.999;
            OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0);
            checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
        }

    } else if ( [keyPath isEqualToString:@"channelIsPlaying"] ) {
        channelElement->playing = channel.channelIsPlaying;
        AudioUnitParameterValue value = channel.channelIsPlaying && (![channel respondsToSelector:@selector(channelIsMuted)] || !channel.channelIsMuted);
        
        if ( group->mixerAudioUnit ) {
            OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
            checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
        }
        
        group->channels[index]->playing = value;
        
    }  else if ( [keyPath isEqualToString:@"channelIsMuted"] ) {
        channelElement->muted = channel.channelIsMuted;
        
        if ( group->mixerAudioUnit ) {
            AudioUnitParameterValue value = ([channel respondsToSelector:@selector(channelIsPlaying)] ? channel.channelIsPlaying : YES) && !channel.channelIsMuted;
            OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
            checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
        }
        
    } else if ( [keyPath isEqualToString:@"audioDescription"] ) {
        channelElement->audioDescription = channel.audioDescription;
        
        if ( group->mixerAudioUnit ) {
            OSStatus result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, index, &channelElement->audioDescription, sizeof(AudioStreamBasicDescription));
            checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        }
        
        if ( channelElement->audiobusFloatConverter ) {
            AEFloatConverter *newFloatConverter = [[AEFloatConverter alloc] initWithSourceFormat:channel.audioDescription];
            AEFloatConverter *oldFloatConverter = channelElement->audiobusFloatConverter;
            [self performSynchronousMessageExchangeWithBlock:^{ channelElement->audiobusFloatConverter = newFloatConverter; }];
            [oldFloatConverter release];
        }
    }
}

- (void)applicationWillEnterForeground:(NSNotification*)notification {
    OSStatus status = AudioSessionSetActive(true);
    checkResult(status, "AudioSessionSetActive");
    
    if ( _interrupted ) {
        _interrupted = NO;
        
        if ( _runningPriorToInterruption && ![self running] ) {
            [self start:NULL];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerSessionInterruptionEndedNotification object:self];
    }
    
    if ( _hasSystemError ) [self attemptRecoveryFromSystemError:NULL];
}

-(void)audiobusConnectionsChanged:(NSNotification*)notification {
    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
    if ( !self.running ) {
        [self start:NULL];
    }
}

#pragma mark - Graph and audio session configuration

- (BOOL)initAudioSession {
    NSMutableString *extraInfo = [NSMutableString string];
    
    // Initialise the audio session
    OSStatus result = AudioSessionInitialize(NULL, NULL, interruptionListener, NULL);
    if ( result != kAudioSessionAlreadyInitialized && !checkResult(result, "AudioSessionInitialize") ) {
        self.lastError = [NSError audioControllerErrorWithMessage:@"Couldn't initialize audio session" OSStatus:result];
        _hasSystemError = YES;
        return NO;
    }
    
    // Register property listeners
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioInputAvailable, audioSessionPropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    // Set sample rate
    Float64 sampleRate = _audioDescription.mSampleRate;
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate, sizeof(sampleRate), &sampleRate);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate)");
    
    UInt32 inputAvailable = NO;
    if ( _inputEnabled ) {
        // See if input's available
        UInt32 size = sizeof(inputAvailable);
        OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &size, &inputAvailable);
        checkResult(result, "AudioSessionGetProperty");
        if ( inputAvailable ) [extraInfo appendFormat:@", input available"];
    }
    _audioInputAvailable = _hardwareInputAvailable = inputAvailable;
    
    // Set category
    [self setAudioSessionCategory:_audioSessionCategory];
    
    // Start session
    checkResult(AudioSessionSetActive(true), "AudioSessionSetActive");
    
    // Fetch sample rate, in case we didn't get quite what we requested
    Float64 achievedSampleRate;
    UInt32 size = sizeof(achievedSampleRate);
    result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &achievedSampleRate);
    checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate)");
    if ( achievedSampleRate != sampleRate ) {
        NSLog(@"Hardware sample rate is %f", achievedSampleRate);
    }

    // Determine audio route
    CFStringRef route;
    size = sizeof(route);
    if ( checkResult(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route),
                     "AudioSessionGetProperty(kAudioSessionProperty_AudioRoute)") ) {
        
        self.audioRoute = [[(NSString*)route copy] autorelease];
        [extraInfo appendFormat:@", audio route '%@'", _audioRoute];
        
        if ( [(NSString*)route isEqualToString:@"SpeakerAndMicrophone"] || [(NSString*)route isEqualToString:@"Speaker"] ) {
            _playingThroughDeviceSpeaker = YES;
        } else {
            _playingThroughDeviceSpeaker = NO;
        }
    }
    
    CFRelease(route);
    
    // Determine IO buffer duration
    Float32 bufferDuration;
    UInt32 bufferDurationSize = sizeof(bufferDuration);
    result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareIOBufferDuration, &bufferDurationSize, &bufferDuration);
    checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareIOBufferDuration)");
    if ( _currentBufferDuration != bufferDuration ) self.currentBufferDuration = bufferDuration;
    
    NSLog(@"TAAE: Audio session initialized (%@)", [extraInfo stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]]);
    return YES;
}

- (BOOL)setup {
    // Create a new AUGraph
    OSStatus result = NewAUGraph(&_audioGraph);
    if ( !checkResult(result, "NewAUGraph") ) return NO;
    
    BOOL useVoiceProcessing = [self usingVPIO];
    
    // Input/output unit description
    AudioComponentDescription io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = useVoiceProcessing ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    // Create a node in the graph that is an AudioUnit, using the supplied AudioComponentDescription to find and open that unit
    result = AUGraphAddNode(_audioGraph, &io_desc, &_ioNode);
    if ( !checkResult(result, "AUGraphAddNode io") ) return NO;
    
    // Open the graph - AudioUnits are open but not initialized (no resource allocation occurs here)
    result = AUGraphOpen(_audioGraph);
    if ( !checkResult(result, "AUGraphOpen") ) return NO;
    
    // Get reference to IO audio unit
    result = AUGraphNodeInfo(_audioGraph, _ioNode, NULL, &_ioAudioUnit);
    if ( !checkResult(result, "AUGraphNodeInfo") ) return NO;

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
        _topChannel->audioController = self;
        _topGroup->channel   = _topChannel;
        
        UInt32 size = sizeof(_topChannel->audioDescription);
        checkResult(AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_topChannel->audioDescription, &size),
                   "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output)");
    }
    
    // Initialise group
    [self configureChannelsInRange:NSMakeRange(0, 1) forGroup:NULL];
    
    // Register a callback to be notified when the main mixer unit renders
    checkResult(AudioUnitAddRenderNotify(_topGroup->mixerAudioUnit, &topRenderNotifyCallback, self), "AudioUnitAddRenderNotify");
    
    // Set the master volume
    AudioUnitParameterValue value = _masterOutputVolume;
    checkResult(AudioUnitSetParameter(_topGroup->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, value, 0), "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
    
    // Initialize the graph
    result = AUGraphInitialize(_audioGraph);
    if ( !checkResult(result, "AUGraphInitialize") ) {
        self.lastError = [NSError audioControllerErrorWithMessage:@"Couldn't create audio graph" OSStatus:result];
        _hasSystemError = YES;
        return NO;
    }
    
    NSLog(@"TAAE: Engine setup");
    
    return YES;
}

- (void)replaceIONode {
    if ( !_topChannel ) return;
    BOOL useVoiceProcessing = [self usingVPIO];
    
    AudioComponentDescription io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = useVoiceProcessing ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    BOOL wasRunning = _running;
    _running = NO;
    
    if ( !checkResult(AUGraphStop(_audioGraph), "AUGraphStop") // Stop graph
            || !checkResult(AUGraphRemoveNode(_audioGraph, _ioNode), "AUGraphRemoveNode") // Remove the old IO node
            || !checkResult(AUGraphAddNode(_audioGraph, &io_desc, &_ioNode), "AUGraphAddNode io") // Create new IO node
            || !checkResult(AUGraphNodeInfo(_audioGraph, _ioNode, NULL, &_ioAudioUnit), "AUGraphNodeInfo") ) { // Get reference to input audio unit
        [self attemptRecoveryFromSystemError:NULL];
        return;
    }
    
    [self configureAudioUnit];
    
    OSStatus result = AUGraphUpdate(_audioGraph, NULL);
    if ( result != kAUGraphErr_NodeNotFound /* Ignore this error */ && !checkResult(result, "AUGraphUpdate") ) {
        [self attemptRecoveryFromSystemError:NULL];
        return;
    }

    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
    
    
    [self configureChannelsInRange:NSMakeRange(0, 1) forGroup:NULL];
    
    checkResult([self updateGraph], "Update graph");
    
    if ( wasRunning ) {
        if ( checkResult(AUGraphStart(_audioGraph), "AUGraphStart") ) {
            _running = YES;
        }
    }
}

- (void)configureAudioUnit {
    if ( _inputEnabled ) {
        // Enable input
        UInt32 enableInputFlag = 1;
        OSStatus result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInputFlag, sizeof(enableInputFlag));
        checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)");
        
        // Register a callback to receive audio
        AURenderCallbackStruct inRenderProc;
        inRenderProc.inputProc = &inputAvailableCallback;
        inRenderProc.inputProcRefCon = self;
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inRenderProc, sizeof(inRenderProc));
        checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_SetInputCallback)");
    } else {
        // Disable input
        UInt32 enableInputFlag = 0;
        OSStatus result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInputFlag, sizeof(enableInputFlag));
        checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)");
    }
    
    if ( [self usingVPIO] ) {
        // Set quality
        UInt32 quality = 127;
        OSStatus result = AudioUnitSetProperty(_ioAudioUnit, kAUVoiceIOProperty_VoiceProcessingQuality, kAudioUnitScope_Global, 0, &quality, sizeof(quality));
        checkResult(result, "AudioUnitSetProperty(kAUVoiceIOProperty_VoiceProcessingQuality)");
        
        if ( _preferredBufferDuration ) {
            // If we're using voice processing, clamp the buffer duration
            Float32 preferredBufferSize = MAX(kMaxBufferDurationWithVPIO, _preferredBufferDuration);
            result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
            checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
        }
    } else {
        if ( _preferredBufferDuration ) {
            // Set the buffer duration
            Float32 preferredBufferSize = _preferredBufferDuration;
            OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
            checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
        }
    }
    
    // Set the audio unit to handle up to 4096 frames per slice to keep rendering during screen lock
    UInt32 maxFPS = 4096;
    checkResult(AudioUnitSetProperty(_ioAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS)),
                "AudioUnitSetProperty(kAudioUnitProperty_MaximumFramesPerSlice)");
}

- (void)teardown {
    checkResult(AUGraphClose(_audioGraph), "AUGraphClose");
    checkResult(DisposeAUGraph(_audioGraph), "DisposeAUGraph");
    _audioGraph = NULL;
    _ioAudioUnit = NULL;
    
    for ( int i=0; i<_inputCallbackCount; i++ ) {
        if ( _inputCallbacks[i].audioConverter ) {
            AudioConverterDispose(_inputCallbacks[i].audioConverter);
            _inputCallbacks[i].audioConverter = NULL;
        }
        
        if ( _inputCallbacks[i].audioBufferList ) {
            AEFreeAudioBufferList(_inputCallbacks[i].audioBufferList);
            _inputCallbacks[i].audioBufferList = NULL;
        }
    }
    
    if ( _topGroup ) {
        [self markGroupTorndown:_topGroup];
    }
}

- (OSStatus)updateGraph {
    // Only update if graph is running
    if ( _running ) {
        // Retry a few times (as sometimes the graph will be in the wrong state to update)
        OSStatus err;
        for ( int retry=0; retry<6; retry++ ) {
            err = AUGraphUpdate(_audioGraph, NULL);
            if ( err != kAUGraphErr_CannotDoInCurrentContext ) break;
            [NSThread sleepForTimeInterval:0.01];
        }
        
        return err;
    }
    return noErr;
}

- (BOOL)mustUpdateVoiceProcessingSettings {
    if ( !_audioGraph ) return NO;
    BOOL useVoiceProcessing = [self usingVPIO];

    AudioComponentDescription target_io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = useVoiceProcessing ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    AudioComponentDescription io_desc;
    if ( !checkResult(AUGraphNodeInfo(_audioGraph, _ioNode, &io_desc, NULL), "AUGraphNodeInfo(ioNode)") )
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
    
    UInt32 inputAvailable        = 0;
    BOOL hardwareInputAvailable  = NO;
    UInt32 numberOfInputChannels = _audioDescription.mChannelsPerFrame;
    BOOL usingAudiobus           = NO;
    
    UInt32 size = sizeof(inputAvailable);
    OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &size, &inputAvailable);
    checkResult(result, "AudioSessionGetProperty");
    hardwareInputAvailable = inputAvailable;
    
    // Determine if audio input is available, and the number of input channels available
    if ( _audiobusInputPort && ABInputPortIsConnected(_audiobusInputPort) ) {
        inputAvailable          = YES;
        numberOfInputChannels   = 2;
        usingAudiobus           = YES;
    } else {
        size = sizeof(numberOfInputChannels);
        if ( inputAvailable ) {
            // Check channels on input
            UInt32 channels;
            OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels, &size, &channels);
            if ( result == kAudioSessionIncompatibleCategory ) {
                // Attempt to force category, and try again
                UInt32 originalCategory = _audioSessionCategory;
                self.audioSessionCategory = kAudioSessionCategory_PlayAndRecord;
                result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels, &size, &channels);
                if ( result == noErr ) {
                    numberOfInputChannels = channels;
                } else {
                    NSLog(@"TAAE: Audio session error (rdar://13022588). Power-cycling audio session.");
                    AudioSessionSetActive(false);
                    AudioSessionSetActive(true);
                    result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels, &size, &channels);
                }
                
                if ( originalCategory != kAudioSessionCategory_PlayAndRecord ) {
                    self.audioSessionCategory = originalCategory;
                }
            }
            
            if ( result == noErr ) {
                numberOfInputChannels = channels;
            } else {
                if ( !_lastError ) self.lastError = [NSError audioControllerErrorWithMessage:@"Audio system error while determining input channel count" OSStatus:result];
                success = NO;
            }
        }
    }
    
    AudioStreamBasicDescription rawAudioDescription = _rawInputAudioDescription;
    AudioBufferList *inputAudioBufferList           = _inputAudioBufferList;
    audio_level_monitor_t inputLevelMonitorData     = _inputLevelMonitorData;
    
    BOOL inputChannelsChanged = _numberOfInputChannels != numberOfInputChannels;
    BOOL inputDescriptionChanged = inputChannelsChanged;
    BOOL inputAvailableChanged = _audioInputAvailable != inputAvailable;
    
    int inputCallbackCount = _inputCallbackCount;
    input_callback_table_t *inputCallbacks = (input_callback_table_t*)malloc(sizeof(input_callback_table_t) * inputCallbackCount);
    memcpy(inputCallbacks, _inputCallbacks, sizeof(input_callback_table_t) * inputCallbackCount);

    if ( inputAvailable ) {
        rawAudioDescription = _audioDescription;
        AEAudioStreamBasicDescriptionSetChannelsPerFrame(&rawAudioDescription, numberOfInputChannels);
        
        BOOL iOS4ConversionRequired = NO;
        
        // Configure input tables
        for ( int entryIndex = 0; entryIndex < inputCallbackCount; entryIndex++ ) {
            input_callback_table_t *entry = &inputCallbacks[entryIndex];
            
            AudioStreamBasicDescription audioDescription = _audioDescription;
            
            if ( _inputMode == AEInputModeVariableAudioFormat ) {
                audioDescription = rawAudioDescription;
                
                if ( [_inputCallbacks[entryIndex].channelMap count] > 0 ) {
                    // Set the target input audio description channels to the number of selected channels
                    AEAudioStreamBasicDescriptionSetChannelsPerFrame(&audioDescription, (int)[_inputCallbacks[entryIndex].channelMap count]);
                }
            }
            
            if ( !entry->audioBufferList || memcmp(&audioDescription, &entry->audioDescription, sizeof(audioDescription)) != 0 ) {
                if ( entryIndex == 0 ) {
                    inputDescriptionChanged = YES;
                }
                entry->audioDescription = audioDescription;
                entry->audioBufferList = AEAllocateAndInitAudioBufferList(entry->audioDescription, kInputAudioBufferFrames);
            }
            
            // Determine if conversion is required
            BOOL converterRequired = iOS4ConversionRequired
                                            || entry->audioDescription.mChannelsPerFrame != numberOfInputChannels
                                            || (entry->channelMap && [entry->channelMap count] != entry->audioDescription.mChannelsPerFrame);
            if ( !converterRequired && entry->channelMap ) {
                for ( int i=0; i<[entry->channelMap count]; i++ ) {
                    if ( [[entry->channelMap objectAtIndex:i] intValue] != i ) {
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
                
                BOOL useVoiceProcessing = [self usingVPIO];
                if ( useVoiceProcessing && (_audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) && [[[UIDevice currentDevice] systemVersion] floatValue] < 5.0 ) {
                    // iOS 4 cannot handle non-interleaved audio and voice processing. Use interleaved audio and a converter.
                    iOS4ConversionRequired = converterRequired = YES;
                    
                    rawAudioDescription.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved;
                    rawAudioDescription.mBytesPerFrame *= rawAudioDescription.mChannelsPerFrame;
                    rawAudioDescription.mBytesPerPacket *= rawAudioDescription.mChannelsPerFrame;
                }
                
                if ( inputLevelMonitorData.monitoringEnabled && memcmp(&_rawInputAudioDescription, &rawAudioDescription, sizeof(_rawInputAudioDescription)) != 0 ) {
                    inputLevelMonitorData.channels = rawAudioDescription.mChannelsPerFrame;
                    inputLevelMonitorData.floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:rawAudioDescription];
                    inputLevelMonitorData.scratchBuffer = AEAllocateAndInitAudioBufferList(inputLevelMonitorData.floatConverter.floatingPointAudioDescription, kLevelMonitorScratchBufferSize);
                }
            }
            
            if ( converterRequired ) {
                // Set up conversion
                
                UInt32 channelMapSize = sizeof(SInt32) * entry->audioDescription.mChannelsPerFrame;
                SInt32 *channelMap = (SInt32*)malloc(channelMapSize);
                
                for ( int i=0; i<entry->audioDescription.mChannelsPerFrame; i++ ) {
                    if ( [entry->channelMap count] > 0 ) {
                        channelMap[i] = min(numberOfInputChannels-1,
                                               [entry->channelMap count] > i
                                               ? [[entry->channelMap objectAtIndex:i] intValue]
                                               : [[entry->channelMap lastObject] intValue]);
                    } else {
                        channelMap[i] = min(numberOfInputChannels-1, i);
                    }
                }

                AudioStreamBasicDescription converterInputFormat;
                AudioStreamBasicDescription converterOutputFormat;
                UInt32 formatSize = sizeof(converterOutputFormat);
                UInt32 currentMappingSize = 0;
                
                if ( entry->audioConverter ) {
                    checkResult(AudioConverterGetPropertyInfo(entry->audioConverter, kAudioConverterChannelMap, &currentMappingSize, NULL),
                                "AudioConverterGetPropertyInfo(kAudioConverterChannelMap)");
                }
                SInt32 *currentMapping = (SInt32*)(currentMappingSize != 0 ? malloc(currentMappingSize) : NULL);
                
                if ( entry->audioConverter ) {
                    checkResult(AudioConverterGetProperty(entry->audioConverter, kAudioConverterCurrentInputStreamDescription, &formatSize, &converterInputFormat),
                                "AudioConverterGetProperty(kAudioConverterCurrentInputStreamDescription)");
                    checkResult(AudioConverterGetProperty(entry->audioConverter, kAudioConverterCurrentOutputStreamDescription, &formatSize, &converterOutputFormat),
                                "AudioConverterGetProperty(kAudioConverterCurrentOutputStreamDescription)");
                    if ( currentMapping ) {
                        checkResult(AudioConverterGetProperty(entry->audioConverter, kAudioConverterChannelMap, &currentMappingSize, currentMapping),
                                    "AudioConverterGetProperty(kAudioConverterChannelMap)");
                    }
                }
                
                if ( !entry->audioConverter
                        || memcmp(&converterInputFormat, &rawAudioDescription, sizeof(AudioStreamBasicDescription)) != 0
                        || memcmp(&converterOutputFormat, &entry->audioDescription, sizeof(AudioStreamBasicDescription)) != 0
                        || (currentMappingSize != channelMapSize || memcmp(currentMapping, channelMap, channelMapSize) != 0) ) {
                    
                    checkResult(AudioConverterNew(&rawAudioDescription, &entry->audioDescription, &entry->audioConverter), "AudioConverterNew");
                    checkResult(AudioConverterSetProperty(entry->audioConverter, kAudioConverterChannelMap, channelMapSize, channelMap), "AudioConverterSetProperty(kAudioConverterChannelMap");
                }
                
                if ( currentMapping ) free(currentMapping);
                free(channelMap);
                channelMap = NULL;
            } else {
                // No converter/channel map required
                entry->audioConverter = NULL;
            }
        }
        
        if ( !inputAudioBufferList || memcmp(&_rawInputAudioDescription, &rawAudioDescription, sizeof(_rawInputAudioDescription)) != 0 ) {
            inputAudioBufferList = AEAllocateAndInitAudioBufferList(rawAudioDescription, kInputAudioBufferFrames);
        }
        
    } else if ( !inputAvailable ) {
        if ( _audioSessionCategory == kAudioSessionCategory_PlayAndRecord || _audioSessionCategory == kAudioSessionCategory_RecordAudio ) {
            // Update audio session as appropriate (will select a non-recording category for us)
            self.audioSessionCategory = _audioSessionCategory;
        }
        
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
    
    input_callback_table_t *oldInputCallbacks = _inputCallbacks;
    int oldInputCallbackCount = _inputCallbackCount;
    audio_level_monitor_t oldInputLevelMonitorData = _inputLevelMonitorData;
    
    if ( _audiobusInputPort && usingAudiobus ) {
        AudioStreamBasicDescription clientFormat = [_audiobusInputPort clientFormat];
        if ( memcmp(&clientFormat, &rawAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
            [_audiobusInputPort setClientFormat:rawAudioDescription];
        }
    }
    
    // Set input stream format and update the properties, on the realtime thread
    [self performSynchronousMessageExchangeWithBlock:^{
        _numberOfInputChannels    = numberOfInputChannels;
        _rawInputAudioDescription = rawAudioDescription;
        _inputAudioBufferList     = inputAudioBufferList;
        _audioInputAvailable      = inputAvailable;
        _hardwareInputAvailable   = hardwareInputAvailable;
        _inputCallbacks           = inputCallbacks;
        _inputCallbackCount       = inputCallbackCount;
        _usingAudiobusInput       = usingAudiobus;
        _inputLevelMonitorData    = inputLevelMonitorData;
    }];
    
    if ( inputAvailable && (!_audiobusInputPort || !ABInputPortIsConnected(_audiobusInputPort)) ) {
        AudioStreamBasicDescription currentAudioDescription;
        UInt32 size = sizeof(currentAudioDescription);
        OSStatus result = AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &currentAudioDescription, &size);
        checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
        
        if ( memcmp(&currentAudioDescription, &rawAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
            result = AudioUnitSetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &rawAudioDescription, sizeof(AudioStreamBasicDescription));
            checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        }
    }
    
    if ( _audiobusInputPort && !usingAudiobus ) {
        AudioStreamBasicDescription clientFormat = [_audiobusInputPort clientFormat];
        if ( memcmp(&clientFormat, &rawAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
            [_audiobusInputPort setClientFormat:rawAudioDescription];
        }
    }
    
    if ( oldInputBuffer && oldInputBuffer != inputAudioBufferList ) {
        AEFreeAudioBufferList(oldInputBuffer);
    }
    
    if ( oldInputCallbacks != inputCallbacks ) {
        for ( int entryIndex = 0; entryIndex < oldInputCallbackCount; entryIndex++ ) {
            input_callback_table_t *oldEntry = &oldInputCallbacks[entryIndex];
            input_callback_table_t *entry = entryIndex < inputCallbackCount ? &inputCallbacks[entryIndex] : NULL;
            
            if ( oldEntry->audioConverter && (!entry || oldEntry->audioConverter != entry->audioConverter) ) {
                AudioConverterDispose(oldEntry->audioConverter);
            }
            if ( oldEntry->audioBufferList && (!entry || oldEntry->audioBufferList != entry->audioBufferList) ) {
                AEFreeAudioBufferList(oldEntry->audioBufferList);
            }
        }
        free(oldInputCallbacks);
    }
    
    if ( oldInputLevelMonitorData.floatConverter != inputLevelMonitorData.floatConverter ) {
        [oldInputLevelMonitorData.floatConverter release];
    }
    if ( oldInputLevelMonitorData.scratchBuffer != inputLevelMonitorData.scratchBuffer ) {
        AEFreeAudioBufferList(oldInputLevelMonitorData.scratchBuffer);
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
    UInt32 numInteractions = kMaximumChannelsPerGroup*2;
    AUNodeInteraction interactions[numInteractions];
    
    checkResult(AUGraphGetNodeInteractions(_audioGraph, group ? group->mixerNode : _ioNode, &numInteractions, interactions), "AUGraphGetNodeInteractions");
    
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
                checkResult(AUGraphDisconnectNodeInput(_audioGraph, targetNode, targetBus), "AUGraphDisconnectNodeInput");
            }
            continue;
        }
        
        if ( channel->type == kChannelTypeChannel ) {
            // Setup render callback struct, if necessary
            AURenderCallbackStruct rcbs = { .inputProc = &renderCallback, .inputProcRefCon = channel };
            if ( 1 /* workaround for graph bug: http://wiki.theamazingaudioengine.com/graph-node-input-callback-bug */
                    || !hasUpstreamInteraction || upstreamInteraction.nodeInteractionType != kAUNodeInteraction_InputCallback || memcmp(&upstreamInteraction.nodeInteraction.inputCallback.cback, &rcbs, sizeof(rcbs)) != 0 ) {
                if ( hasUpstreamInteraction ) {
                    checkResult(AUGraphDisconnectNodeInput(_audioGraph, targetNode, targetBus), "AUGraphDisconnectNodeInput");
                }
                checkResult(AUGraphSetNodeInputCallback(_audioGraph, targetNode, targetBus, &rcbs), "AUGraphSetNodeInputCallback");
                upstreamInteraction.nodeInteractionType = kAUNodeInteraction_InputCallback;
            }
            
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
                if ( !checkResult(AUGraphAddNode(_audioGraph, &mixer_desc, &subgroup->mixerNode), "AUGraphAddNode mixer") ||
                     !checkResult(AUGraphNodeInfo(_audioGraph, subgroup->mixerNode, NULL, &subgroup->mixerAudioUnit), "AUGraphNodeInfo") ) {
                    continue;
                }
                
                // Set the mixer unit to handle up to 4096 frames per slice to keep rendering during screen lock
                UInt32 maxFPS = 4096;
                AudioUnitSetProperty(subgroup->mixerAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
            }
            
            // Set bus count
            UInt32 busCount = subgroup->channelCount;
            if ( !checkResult(AudioUnitSetProperty(subgroup->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)), "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) continue;

            // Get current mixer's output format
            AudioStreamBasicDescription currentMixerOutputDescription;
            UInt32 size = sizeof(currentMixerOutputDescription);
            checkResult(AudioUnitGetProperty(subgroup->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &currentMixerOutputDescription, &size), "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
            
            // Determine what the output format should be (use TAAE's audio description if client code will see the audio)
            AudioStreamBasicDescription mixerOutputDescription = !subgroup->converterNode ? _audioDescription : currentMixerOutputDescription;
            mixerOutputDescription.mSampleRate = _audioDescription.mSampleRate;
            
            if ( memcmp(&currentMixerOutputDescription, &mixerOutputDescription, sizeof(mixerOutputDescription)) != 0 ) {
                // Assign the output format if necessary
                OSStatus result = AudioUnitSetProperty(subgroup->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mixerOutputDescription, sizeof(mixerOutputDescription));
                
                if ( hasUpstreamInteraction ) {
                    // Disconnect node to force reconnection, in order to apply new audio format
                    checkResult(AUGraphDisconnectNodeInput(_audioGraph, targetNode, targetBus), "AUGraphDisconnectNodeInput");
                    hasUpstreamInteraction = NO;
                }
                
                if ( !subgroup->converterNode && result == kAudioUnitErr_FormatNotSupported ) {
                    // The mixer only supports a subset of formats. If it doesn't support this one, then we'll add an audio converter
                    currentMixerOutputDescription.mSampleRate = mixerOutputDescription.mSampleRate;
                    AEAudioStreamBasicDescriptionSetChannelsPerFrame(&currentMixerOutputDescription, mixerOutputDescription.mChannelsPerFrame);
                    
                    if ( !checkResult(result=AudioUnitSetProperty(subgroup->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &currentMixerOutputDescription, size), "AudioUnitSetProperty") ) {
                        AUGraphRemoveNode(_audioGraph, subgroup->mixerNode);
                        subgroup->mixerNode = 0;
                        hasFilters = hasReceivers = NO;
                    } else {
                        AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
                        if ( !checkResult(AUGraphAddNode(_audioGraph, &audioConverterDescription, &subgroup->converterNode), "AUGraphAddNode") ||
                             !checkResult(AUGraphNodeInfo(_audioGraph, subgroup->converterNode, NULL, &subgroup->converterUnit), "AUGraphNodeInfo") ) {
                            AUGraphRemoveNode(_audioGraph, subgroup->converterNode);
                            subgroup->converterNode = 0;
                            subgroup->converterUnit = NULL;
                            hasFilters = hasReceivers = NO;
                        }
                        
                        if ( channel->setRenderNotification ) {
                            checkResult(AudioUnitRemoveRenderNotify(subgroup->mixerAudioUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify");
                            channel->setRenderNotification = NO;
                        }
                        
                        checkResult(AUGraphConnectNodeInput(_audioGraph, subgroup->mixerNode, 0, subgroup->converterNode, 0), "AUGraphConnectNodeInput");
                    }
                } else {
                    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
                }
            }
            
            if ( subgroup->converterNode ) {
                // Set the audio converter stream format
                checkResult(AudioUnitSetProperty(subgroup->converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &currentMixerOutputDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
                checkResult(AudioUnitSetProperty(subgroup->converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
                channel->audioDescription = _audioDescription;
            } else {
                channel->audioDescription = mixerOutputDescription;
            }
            
            if ( channel->audiobusFloatConverter ) {
                // Update Audiobus output converter to reflect new audio format
                AudioStreamBasicDescription converterFormat = channel->audiobusFloatConverter.sourceFormat;
                if ( memcmp(&converterFormat, &channel->audioDescription, sizeof(channel->audioDescription)) != 0 ) {
                    AEFloatConverter *newFloatConverter = [[AEFloatConverter alloc] initWithSourceFormat:channel->audioDescription];
                    AEFloatConverter *oldFloatConverter = channel->audiobusFloatConverter;
                    [self performAsynchronousMessageExchangeWithBlock:^{ channel->audiobusFloatConverter = newFloatConverter; }
                                                        responseBlock:^{ [oldFloatConverter release]; }];
                }
            }
            
            if ( subgroup->level_monitor_data.monitoringEnabled ) {
                // Update level monitoring converter to reflect new audio format
                AudioStreamBasicDescription converterFormat = subgroup->level_monitor_data.floatConverter.sourceFormat;
                if ( memcmp(&converterFormat, &channel->audioDescription, sizeof(channel->audioDescription)) != 0 ) {
                    AEFloatConverter *newFloatConverter = [[AEFloatConverter alloc] initWithSourceFormat:channel->audioDescription];
                    AEFloatConverter *oldFloatConverter = subgroup->level_monitor_data.floatConverter;
                    [self performAsynchronousMessageExchangeWithBlock:^{ subgroup->level_monitor_data.floatConverter = newFloatConverter; }
                                                        responseBlock:^{ [oldFloatConverter release]; }];
                }
            }
            
            AUNode sourceNode = subgroup->converterNode ? subgroup->converterNode : subgroup->mixerNode;
            AudioUnit sourceUnit = subgroup->converterUnit ? subgroup->converterUnit : subgroup->mixerAudioUnit;
            
            if ( hasFilters || channel->audiobusOutputPort ) {
                // We need to use our own render callback, because we're either filtering, or sending via Audiobus (and we may need to adjust timestamp)
                
                if ( channel->setRenderNotification ) {
                    // Remove render notification if there was one set
                    checkResult(AudioUnitRemoveRenderNotify(sourceUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify");
                    channel->setRenderNotification = NO;
                }
                
                // Set input format for callback
                checkResult(AudioUnitSetProperty(targetUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, targetBus, &channel->audioDescription, sizeof(channel->audioDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
                
                // Set render callback
                AURenderCallbackStruct rcbs;
                rcbs.inputProc = &renderCallback;
                rcbs.inputProcRefCon = channel;
                if ( !hasUpstreamInteraction || upstreamInteraction.nodeInteractionType != kAUNodeInteraction_InputCallback || memcmp(&upstreamInteraction.nodeInteraction.inputCallback.cback, &rcbs, sizeof(rcbs)) != 0 ) {
                    if ( hasUpstreamInteraction ) {
                        checkResult(AUGraphDisconnectNodeInput(_audioGraph, targetNode, targetBus), "AUGraphDisconnectNodeInput");
                    }
                    checkResult(AUGraphSetNodeInputCallback(_audioGraph, targetNode, targetBus, &rcbs), "AUGraphSetNodeInputCallback");
                    upstreamInteraction.nodeInteractionType = kAUNodeInteraction_InputCallback;
                }
                
            } else {
                // Connect output of mixer/converter directly to the upstream node
                if ( !hasUpstreamInteraction || upstreamInteraction.nodeInteractionType != kAUNodeInteraction_Connection || upstreamInteraction.nodeInteraction.connection.sourceNode != sourceNode ) {
                    if ( hasUpstreamInteraction ) {
                        checkResult(AUGraphDisconnectNodeInput(_audioGraph, targetNode, targetBus), "AUGraphDisconnectNodeInput");
                    }
                    checkResult(AUGraphConnectNodeInput(_audioGraph, sourceNode, 0, targetNode, targetBus), "AUGraphConnectNodeInput");
                    upstreamInteraction.nodeInteractionType = kAUNodeInteraction_Connection;
                }
                
                if ( hasReceivers || subgroup->level_monitor_data.monitoringEnabled ) {
                    if ( !channel->setRenderNotification ) {
                        // We need to register a callback to be notified when the mixer renders, to pass on the audio
                        checkResult(AudioUnitAddRenderNotify(sourceUnit, &groupRenderNotifyCallback, channel), "AudioUnitAddRenderNotify");
                        channel->setRenderNotification = YES;
                    }
                } else {
                    if ( channel->setRenderNotification ) {
                        // Remove render notification callback
                        checkResult(AudioUnitRemoveRenderNotify(sourceUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify");
                        channel->setRenderNotification = NO;
                    }
                }
            }
            
            [self configureChannelsInRange:NSMakeRange(0, busCount) forGroup:subgroup];
        }
        
        
        if ( group ) {
            // Set volume
            AudioUnitParameterValue volumeValue = channel->volume;
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, i, volumeValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
            
            // Set pan
            AudioUnitParameterValue panValue = channel->pan;
            if ( panValue == -1.0 ) panValue = -0.999; // Workaround for pan limits bug
            if ( panValue == 1.0 ) panValue = 0.999;
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, i, panValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
            
            // Set enabled
            AudioUnitParameterValue enabledValue = channel->playing && !channel->muted;
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, i, enabledValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
            
            if ( upstreamInteraction.nodeInteractionType == kAUNodeInteraction_InputCallback ) {
                // Set audio description
                checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &channel->audioDescription, sizeof(channel->audioDescription)),
                            "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
            }
        }
    }
}

static void removeChannelsFromGroup(AEAudioController *THIS, AEChannelGroupRef group, void **ptrs, void **objects, AEChannelRef *outChannelReferences, int count) {
    // Disable matching channels first
    for ( int i=0; i < count; i++ ) {
        // Find the channel in our fixed array
        int index = 0;
        for ( index=0; index < group->channelCount; index++ ) {
            if ( group->channels[index] && group->channels[index]->ptr == ptrs[i] && group->channels[index]->object == objects[i] ) {
                // Disable this channel until we update the graph
                AudioUnitParameterValue enabledValue = 0;
                checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, enabledValue, 0),
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
            [array addObject:(id)channel->object];
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

- (void)releaseResourcesForChannel:(AEChannelRef)channel {
    NSArray *objects = [self associatedObjectsFromTable:&channel->callbacks matchingFlag:0];
    [objects makeObjectsPerformSelector:@selector(release)];
    
    if ( channel->audiobusOutputPort ) {
        [channel->audiobusOutputPort release];
        channel->audiobusOutputPort = NULL;
        AEFreeAudioBufferList(channel->audiobusScratchBuffer);
        channel->audiobusScratchBuffer = NULL;
        [channel->audiobusFloatConverter release];
        channel->audiobusFloatConverter = nil;
    }
    
    if ( channel->type == kChannelTypeGroup ) {
        [self releaseResourcesForGroup:(AEChannelGroupRef)channel->ptr];
    } else if ( channel->type == kChannelTypeChannel ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"channelIsPlaying", @"channelIsMuted", @"audioDescription", nil] ) {
            [(NSObject*)channel->object removeObserver:self forKeyPath:property];
        }
        [(NSObject*)channel->object release];
    }
    
    free(channel);
}

- (void)releaseResourcesForGroup:(AEChannelGroupRef)group {
    if ( group->mixerNode ) {
        checkResult(AUGraphRemoveNode(_audioGraph, group->mixerNode), "AUGraphRemoveNode");
        group->mixerNode = 0;
        group->mixerAudioUnit = NULL;
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
        AEFreeAudioBufferList(group->level_monitor_data.scratchBuffer);
    }
    if ( group->level_monitor_data.floatConverter ) {
        [group->level_monitor_data.floatConverter release];
    }
    memset(&group->level_monitor_data, 0, sizeof(audio_level_monitor_t));
    
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = group->channels[i];
        if ( !channel ) continue;
        if ( channel->type == kChannelTypeGroup ) {
            [self markGroupTorndown:(AEChannelGroupRef)channel->ptr];
        }
    }
}

- (BOOL)usingVPIO {
    return _voiceProcessingEnabled && _inputEnabled && (!_voiceProcessingOnlyForSpeakerAndMicrophone || _playingThroughDeviceSpeaker);
}

- (BOOL)attemptRecoveryFromSystemError:(NSError**)error {
    int retries = 3;
    while ( retries > 0 ) {
        NSLog(@"TAAE: Trying to recover from system error (%d retries remain)", retries);
        retries--;
        
        [self stop];
        [self teardown];
        
        [NSThread sleepForTimeInterval:0.5];
        
        checkResult(AudioSessionSetActive(true), "AudioSessionSetActive");
        
        if ( [self setup] && [self start:error recoveringFromErrors:NO] ) {
            [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerDidRecreateGraphNotification object:self];
            NSLog(@"TAAE: Successfully recovered from system error");
            _hasSystemError = NO;
            return YES;
        }
    }
    
    NSLog(@"TAAE: Could not recover from system error.");
    if ( error ) *error = self.lastError;
    _hasSystemError = YES;
    return NO;
}

#pragma mark - Callback management

static callback_t *addCallbackToTable(AEAudioController *THIS, callback_table_t *table, void *callback, void *userInfo, int flags) {
    callback_t *callback_struct = &table->callbacks[table->count];
    callback_struct->callback = callback;
    callback_struct->userInfo = userInfo;
    callback_struct->flags = flags;
    table->count++;
    return callback_struct;
}

static void removeCallbackFromTable(AEAudioController *THIS, callback_table_t *table, void *callback, void *userInfo, BOOL *found_p) {
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
        
        [result addObject:(id)table->callbacks[i].userInfo];
    }
    
    return result;
}

- (BOOL)addCallback:(void*)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = parentGroup->channels[index];
    
    if ( channel->callbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"Warning: Maximum number of callbacks reached");
        return NO;
    }
    
    [self performSynchronousMessageExchangeWithBlock:^{
        addCallbackToTable(self, &channel->callbacks, callback, userInfo, flags);
    }];
    
    return YES;
}

- (BOOL)addCallback:(void*)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group {
    if ( group->channel->callbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"Warning: Maximum number of callbacks reached");
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
    checkResult([self updateGraph], "Update graph");
    
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
        for ( int i=1; i<_inputCallbackCount; i++ ) {
            // Compare channel maps to find a match
            if ( [_inputCallbacks[i].channelMap isEqualToArray:channels] ) {
                callbackTable = &_inputCallbacks[i].callbacks;
            }
        }
        
        if ( !callbackTable ) {
            // Create new callback entry
            inputCallbacks = malloc(sizeof(input_callback_table_t) * (_inputCallbackCount+1));
            memcpy(inputCallbacks, _inputCallbacks, _inputCallbackCount * sizeof(input_callback_table_t));
            input_callback_table_t *newCallbackTable = &inputCallbacks[_inputCallbackCount];
            memset(newCallbackTable, 0, sizeof(input_callback_table_t));
            
            newCallbackTable->channelMap = [channels copy];
            
            callbackTable = &newCallbackTable->callbacks;
            
            inputCallbackCount = _inputCallbackCount+1;
        }
    }
    
    if ( callbackTable->count == kMaximumCallbacksPerSource ) {
        NSLog(@"Warning: Maximum number of callbacks reached");
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
        
        [self updateInputDeviceStatus];
    }
    
    return YES;
}

- (BOOL)removeCallback:(void*)callback userInfo:(void*)userInfo fromChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
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
    checkResult([self updateGraph], "Update graph");
    
    return YES;
}

- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags {
    return [self associatedObjectsFromTable:&_topChannel->callbacks matchingFlag:flags];
}

- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = parentGroup->channels[index];
    
    return [self associatedObjectsFromTable:&channel->callbacks matchingFlag:flags];
}

- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group {
    if ( !group->channel ) return [NSArray array];
    return [self associatedObjectsFromTable:&group->channel->callbacks matchingFlag:flags];
}

static void handleCallbacksForChannel(AEChannelRef channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    // Pass audio to output callbacks
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kReceiverFlag ) {
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, channel->audioController, channel->ptr, inTimeStamp, inNumberFrames, ioData);
        }
    }
}

#pragma mark - Assorted helpers

static void performLevelMonitoring(audio_level_monitor_t* monitor, AudioBufferList *buffer, UInt32 numberFrames) {
    if ( !monitor->floatConverter || !monitor->scratchBuffer ) return;
    
    if ( monitor->reset ) {
        monitor->reset  = NO;
        monitor->meanAccumulator = 0;
        monitor->meanBlockCount  = 0;
        monitor->average         = 0;
        monitor->peak            = 0;
    }
    
    UInt32 monitorFrames = min(numberFrames, kLevelMonitorScratchBufferSize);
    AEFloatConverterToFloatBufferList(monitor->floatConverter, buffer, monitor->scratchBuffer, monitorFrames);

    for ( int i=0; i<monitor->scratchBuffer->mNumberBuffers; i++ ) {
        float peak = 0.0;
        vDSP_maxmgv((float*)monitor->scratchBuffer->mBuffers[i].mData, 1, &peak, monitorFrames);
        if ( peak > monitor->peak ) monitor->peak = peak;
        float avg = 0.0;
        vDSP_meamgv((float*)monitor->scratchBuffer->mBuffers[i].mData, 1, &avg, monitorFrames);
        monitor->meanAccumulator += avg;
        monitor->meanBlockCount++;
        monitor->average = monitor->meanAccumulator / monitor->meanBlockCount;
    }
}

- (void)housekeeping {
    Float32 bufferDuration;
    UInt32 bufferDurationSize = sizeof(bufferDuration);
    OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareIOBufferDuration, &bufferDurationSize, &bufferDuration);
    if ( result == noErr && _currentBufferDuration != bufferDuration ) self.currentBufferDuration = bufferDuration;
}

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

@interface AEAudioControllerMessagePollThread () {
    AEAudioController *_audioController;
}
@end
@implementation AEAudioControllerMessagePollThread
@synthesize pollInterval = _pollInterval;
- (id)initWithAudioController:(AEAudioController *)audioController {
    if ( !(self = [super init]) ) return nil;
    _audioController = audioController;
    return self;
}
-(void)main {
    pthread_setname_np("com.theamazingaudioengine.AEAudioControllerMessagePollThread");
    while ( ![self isCancelled] ) {
        if ( AEAudioControllerHasPendingMainThreadMessages(_audioController) ) {
            [_audioController performSelectorOnMainThread:@selector(pollForMessageResponses) withObject:nil waitUntilDone:NO];
        }
        usleep(_pollInterval*1.0e6);
    }
}
@end