//
//  AEAudioController.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 25/11/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
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
#import <mach/mach_time.h>
#import <pthread.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

const int kMaximumChannelsPerGroup              = 100;
const int kMaximumCallbacksPerSource            = 15;
const int kMessageBufferLength                  = 8192;
const int kMaxMessageDataSize                   = 2048;
const NSTimeInterval kIdleMessagingPollDuration = 0.1;
const int kRenderConversionScratchBufferSize    = 16384;
const int kInputAudioBufferFrames               = 4096;
const int kLevelMonitorScratchBufferSize        = 8192;
const int kAudiobusSourceFlag                   = 1<<12;
const NSTimeInterval kMaxBufferDurationWithVPIO = 0.01;

NSString * AEAudioControllerSessionInterruptionBeganNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionBeganNotification";
NSString * AEAudioControllerSessionInterruptionEndedNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionEndedNotification";

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
    kVariableSpeedFilterFlag  = 1<<2,
    kAudiobusOutputPortFlag   = 1<<3
};

/*!
 * Callback
 */
typedef struct {
    void *callback;
    void *userInfo;
    uint8_t flags;
} callback_t;

/*!
 * Callback table
 */
typedef struct {
    int count;
    callback_t callbacks[kMaximumCallbacksPerSource];
} callback_table_t;

/*!
 * Audio level monitoring data
 */
typedef struct {
    BOOL                monitoringEnabled;
    float               meanAccumulator;
    int                 meanBlockCount;
    Float32             peak;
    Float32             average;
    float              *scratchBuffer;
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
 * Group graph state
 */
enum {
    kGraphStateUninitialized         = 0,
    kGraphStateNodeConnected         = 1<<0,
    kGraphStateRenderNotificationSet = 1<<1,
    kGraphStateRenderCallbackSet     = 1<<2
};

/*!
 * Channel
 */
typedef struct {
    ChannelType      type;
    void            *ptr;
    void            *userInfo;
    BOOL             playing;
    float            volume;
    float            pan;
    BOOL             muted;
    AudioStreamBasicDescription audioDescription;
    callback_table_t callbacks;
    int              graphState;
    AEAudioController *audioController;
    ABOutputPort    *audiobusOutputPort;
} channel_t, *AEChannelRef;

/*!
 * Channel group
 */
typedef struct _channel_group_t {
    AEChannelRef        channel;
    AUNode              mixerNode;
    AudioUnit           mixerAudioUnit;
    channel_t           channels[kMaximumChannelsPerGroup];
    int                 channelCount;
    AudioConverterRef   audioConverter;
    BOOL                converterRequired;
    char               *audioConverterScratchBuffer;
    AudioStreamBasicDescription audioConverterTargetFormat;
    AudioStreamBasicDescription audioConverterSourceFormat;
    audio_level_monitor_t level_monitor_data;
} channel_group_t;

/*!
 * Channel producer argument
 */
typedef struct {
    AEChannelRef channel;
    AudioTimeStamp inTimeStamp;
    AudioUnitRenderActionFlags *ioActionFlags;
} channel_producer_arg_t;

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
    channel_t           _topChannel;
    
    callback_table_t    _inputCallbacks;
    callback_table_t    _timingCallbacks;
    
    TPCircularBuffer    _realtimeThreadMessageBuffer;
    TPCircularBuffer    _mainThreadMessageBuffer;
    AEAudioControllerMessagePollThread *_pollThread;
    int                 _pendingResponses;
    
    char               *_renderConversionScratchBuffer;
    AudioBufferList    *_inputAudioBufferList;
    BOOL                _inputAudioBufferListBuffersAreAllocated;
    AudioConverterRef   _inputAudioConverter;
    AudioBufferList    *_inputAudioScratchBufferList;
    audio_level_monitor_t _inputLevelMonitorData;
    BOOL                _usingAudiobusInput;
}

- (void)pollForMessageResponses;
static void processPendingMessagesOnRealtimeThread(AEAudioController *THIS);

- (BOOL)initAudioSession;
- (BOOL)setup;
- (void)teardown;
- (OSStatus)updateGraph;
- (BOOL)mustUpdateVoiceProcessingSettings;
- (void)replaceIONode;
- (BOOL)updateInputDeviceStatus;

static BOOL initialiseGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index, BOOL *updateRequired);
static OSStatus configureGraphStateOfGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index, BOOL *updateRequired);
static void configureChannelsInRangeForGroup(AEAudioController *THIS, NSRange range, AEChannelGroupRef group, BOOL *updateRequired);

static void removeChannelsFromGroup(AEAudioController *THIS, AEChannelGroupRef group, void **ptrs, void **userInfos, int count);

- (void)gatherChannelsFromGroup:(AEChannelGroupRef)group intoArray:(NSMutableArray*)array;
- (AEChannelGroupRef)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo index:(int*)index;
- (void)releaseResourcesForGroup:(AEChannelGroupRef)group;
- (void)markGroupTorndown:(AEChannelGroupRef)group;

static void addCallbackToTable(AEAudioController *THIS, callback_table_t *table, void *callback, void *userInfo, int flags);
static void removeCallbackFromTable(AEAudioController *THIS, callback_table_t *table, void *callback, void *userInfo, BOOL *found);
- (NSArray *)associatedObjectsFromTable:(callback_table_t*)table matchingFlag:(uint8_t)flag;
- (void)addCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj;
- (void)addCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group;
- (BOOL)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannel:(id<AEAudioPlayable>)channelObj;
- (BOOL)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannelGroup:(AEChannelGroupRef)group;
- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags;
- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj;
- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group;
- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter forChannelStruct:(AEChannelRef)channel;
static void handleCallbacksForChannel(AEChannelRef channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData);

static void performLevelMonitoring(audio_level_monitor_t* monitor, AudioBufferList *buffer, UInt32 numberFrames, AudioStreamBasicDescription *audioDescription);
static void serveAudiobusInputQueue(AEAudioController *THIS);

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
            inputChannelSelection       = _inputChannelSelection,
            audioUnit                   = _ioAudioUnit,
            audioDescription            = _audioDescription,
            audioRoute                  = _audioRoute,
            inputAudioDescription       = _inputAudioDescription,
            audiobusInputPort           = _audiobusInputPort;

@dynamic    running, inputGainAvailable, inputGain, audiobusOutputPort;

#pragma mark - Audio session callbacks

static void interruptionListener(void *inClientData, UInt32 inInterruption) {
	AEAudioController *THIS = (AEAudioController *)inClientData;
    
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
    
    if (inID == kAudioSessionProperty_AudioRouteChange) {
        int reason = [[(NSDictionary*)inData objectForKey:[NSString stringWithCString:kAudioSession_AudioRouteChangeKey_Reason encoding:NSUTF8StringEncoding]] intValue];
        
        CFStringRef route = NULL;
        UInt32 size = sizeof(route);
        if ( !checkResult(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route), "AudioSessionGetProperty(kAudioSessionProperty_AudioRoute)") ) return;
        
        THIS.audioRoute = [NSString stringWithString:(NSString*)route];
        
        NSLog(@"TAAE: Changed audio route to %@", THIS.audioRoute);
        
        BOOL playingThroughSpeaker;
        if ( [(NSString*)route isEqualToString:@"ReceiverAndMicrophone"] ) {
            checkResult(AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, THIS), "AudioSessionRemovePropertyListenerWithUserData");
            
            // Re-route audio to the speaker (not the receiver)
            UInt32 newRoute = kAudioSessionOverrideAudioRoute_Speaker;
            checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute,  sizeof(route), &newRoute), "AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute)");
            
            if ( THIS.audioSessionCategory == kAudioSessionCategory_MediaPlayback || THIS.audioSessionCategory == kAudioSessionCategory_PlayAndRecord ) {
                UInt32 allowMixing = YES;
                checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                            "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
            }
            
            checkResult(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, THIS), "AudioSessionAddPropertyListener");
            
            playingThroughSpeaker = YES;
        } else if ( [(NSString*)route isEqualToString:@"SpeakerAndMicrophone"] || [(NSString*)route isEqualToString:@"Speaker"] ) {
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

static OSStatus channelAudioProducer(void *userInfo, AudioBufferList *audio, UInt32 frames) {
    channel_producer_arg_t *arg = (channel_producer_arg_t*)userInfo;
    AEChannelRef channel = arg->channel;
    
    OSStatus status = noErr;
    
    if ( channel->audiobusOutputPort && ABOutputPortGetConnectedPortAttributes(channel->audiobusOutputPort) & ABInputPortAttributePlaysLiveAudio ) {
        // We're sending via the output port, and the receiver plays live - offset the timestamp by the reported latency
        arg->inTimeStamp.mHostTime += ABOutputPortGetAverageLatency(channel->audiobusOutputPort)*__secondsToHostTicks;
    }
    
    if ( channel->type == kChannelTypeChannel ) {
        AEAudioControllerRenderCallback callback = (AEAudioControllerRenderCallback) channel->ptr;
        id<AEAudioPlayable> channelObj = (id<AEAudioPlayable>) channel->userInfo;
        
        for ( int i=0; i<audio->mNumberBuffers; i++ ) {
            memset(audio->mBuffers[i].mData, 0, audio->mBuffers[i].mDataByteSize);
        }
        
        status = callback(channelObj, channel->audioController, &arg->inTimeStamp, frames, audio);
        
    } else if ( channel->type == kChannelTypeGroup ) {
        AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
        
        AudioBufferList *bufferList = audio;
        
        int bufferCount = group->converterRequired ? ((group->audioConverterSourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? group->audioConverterSourceFormat.mChannelsPerFrame : 1) : 1;
        char audioBufferListSpace[sizeof(AudioBufferList)+(bufferCount-1)*sizeof(AudioBuffer)];

        if ( group->converterRequired ) {
            // Initialise output buffer
            bufferList = (AudioBufferList*)audioBufferListSpace;
            bufferList->mNumberBuffers = bufferCount;
            for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
                bufferList->mBuffers[i].mNumberChannels = (group->audioConverterSourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : group->audioConverterSourceFormat.mChannelsPerFrame;
                bufferList->mBuffers[i].mData           = group->audioConverterScratchBuffer + (i * kRenderConversionScratchBufferSize/bufferList->mNumberBuffers);
                bufferList->mBuffers[i].mDataByteSize   = group->audioConverterSourceFormat.mBytesPerFrame * frames;
            }
        }
        
        // Tell mixer to render into bufferList
        OSStatus status = AudioUnitRender(group->mixerAudioUnit, arg->ioActionFlags, &arg->inTimeStamp, 0, frames, bufferList);
        if ( !checkResult(status, "AudioUnitRender") ) return status;
        
        if ( group->converterRequired ) {
            // Perform conversion
            status = AudioConverterFillComplexBuffer(group->audioConverter, 
                                                     fillComplexBufferInputProc, 
                                                     &(struct fillComplexBufferInputProc_t) { .bufferList = bufferList, .frames = frames }, 
                                                     &frames, 
                                                     audio, 
                                                     NULL);
            checkResult(status, "AudioConverterFillComplexBuffer");
        }
        
        if ( group->level_monitor_data.monitoringEnabled ) {
            performLevelMonitoring(&group->level_monitor_data, audio, frames, &channel->audioDescription);
        }
    }
    
    if ( channel->audiobusOutputPort ) {
        // Send via Audiobus
        ABOutputPortSendAudio(channel->audiobusOutputPort, audio, frames, &arg->inTimeStamp, NULL);
        if ( ABOutputPortGetConnectedPortAttributes(channel->audiobusOutputPort) & ABInputPortAttributePlaysLiveAudio ) {
            // Silence output after sending
            for ( int i=0; i<audio->mNumberBuffers; i++ ) memset(audio->mBuffers[i].mData, 0, audio->mBuffers[i].mDataByteSize);
        }
    }
    
    // Advance the sample time, to make sure we continue to render if we're called again with the same arguments
    arg->inTimeStamp.mSampleTime += frames;
    
    return status;
}

static OSStatus renderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEChannelRef channel = (AEChannelRef)inRefCon;
    
    if ( channel->ptr == NULL || !channel->playing ) {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    
    channel_producer_arg_t arg = { .channel = channel, .inTimeStamp = *inTimeStamp, .ioActionFlags = ioActionFlags };
    
    // Use variable speed filter, if there is one
    AEAudioControllerVariableSpeedFilterCallback varispeedFilter = NULL;
    void * varispeedFilterUserinfo = NULL;
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kVariableSpeedFilterFlag ) {
            varispeedFilter = callback->callback;
            varispeedFilterUserinfo = callback->userInfo;
        }
    }
    
    OSStatus result = noErr;
    if ( varispeedFilter ) {
        // Run variable speed filter
        varispeedFilter(varispeedFilterUserinfo, channel->audioController, &channelAudioProducer, (void*)&arg, inTimeStamp, inNumberFrames, ioData);
    } else {
        // Take audio directly from channel
        result = channelAudioProducer((void*)&arg, ioData, inNumberFrames);
    }
    
    handleCallbacksForChannel(channel, inTimeStamp, inNumberFrames, ioData);
    
    return result;
}

static OSStatus inputAvailableCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEAudioController *THIS = (AEAudioController *)inRefCon;
    
    if ( THIS->_audiobusInputPort && !(*ioActionFlags & kAudiobusSourceFlag) && THIS->_usingAudiobusInput ) {
        // If Audiobus is connected, then serve Audiobus queue rather than serving system input queue
        serveAudiobusInputQueue(THIS);
        return noErr;
    }

    for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
        callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
        ((AEAudioControllerTimingCallback)callback->callback)(callback->userInfo, THIS, inTimeStamp, AEAudioTimingContextInput);
    }
    
    if ( THIS->_inputAudioConverter ) {
        for ( int i=0; i<THIS->_inputAudioScratchBufferList->mNumberBuffers; i++ ) {
            THIS->_inputAudioScratchBufferList->mBuffers[i].mData = NULL;
            THIS->_inputAudioScratchBufferList->mBuffers[i].mDataByteSize = 0;
        }
    }
    
    if ( THIS->_inputAudioBufferListBuffersAreAllocated ) {
        for ( int i=0; i<THIS->_inputAudioBufferList->mNumberBuffers; i++ ) {
            THIS->_inputAudioBufferList->mBuffers[i].mDataByteSize = kInputAudioBufferFrames * THIS->_inputAudioDescription.mBytesPerFrame;
        }
    } else {
        if ( !THIS->_inputAudioBufferList ) return noErr;
        
        for ( int i=0; i<THIS->_inputAudioBufferList->mNumberBuffers; i++ ) {
            THIS->_inputAudioBufferList->mBuffers[i].mData = NULL;
            THIS->_inputAudioBufferList->mBuffers[i].mDataByteSize = 0;
        }
    }
    
    // Render audio into buffer
    if ( *ioActionFlags & kAudiobusSourceFlag && ABInputPortReceive != NULL ) {
        ABInputPortReceive(THIS->_audiobusInputPort, nil, THIS->_inputAudioBufferList, &inNumberFrames, NULL, NULL);
    } else {
        OSStatus err = AudioUnitRender(THIS->_ioAudioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, THIS->_inputAudioConverter ? THIS->_inputAudioScratchBufferList : THIS->_inputAudioBufferList);
        if ( !checkResult(err, "AudioUnitRender") ) { 
            return err; 
        }
        
        if ( THIS->_inputAudioConverter ) {
            // Perform conversion
            assert(THIS->_inputAudioScratchBufferList->mBuffers[0].mData && THIS->_inputAudioScratchBufferList->mBuffers[0].mDataByteSize > 0);
            assert(THIS->_inputAudioBufferList->mBuffers[0].mData && THIS->_inputAudioBufferList->mBuffers[0].mDataByteSize > 0);
            
            OSStatus result = AudioConverterFillComplexBuffer(THIS->_inputAudioConverter, 
                                                              fillComplexBufferInputProc, 
                                                              &(struct fillComplexBufferInputProc_t) { .bufferList = THIS->_inputAudioScratchBufferList, .frames = inNumberFrames }, 
                                                              &inNumberFrames, 
                                                              THIS->_inputAudioBufferList, 
                                                              NULL);
            checkResult(result, "AudioConverterConvertComplexBuffer");
        }
    }
    
    // Pass audio to input filters, then callbacks
    for ( int type=kFilterFlag; ; type = kReceiverFlag ) {
        for ( int i=0; i<THIS->_inputCallbacks.count; i++ ) {
            callback_t *callback = &THIS->_inputCallbacks.callbacks[i];
            if ( !(callback->flags & type) ) continue;
            
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, THIS, AEAudioSourceInput, inTimeStamp, inNumberFrames, THIS->_inputAudioBufferList);
        }
        if ( type == kReceiverFlag ) break;
    }
    
    // Perform input metering
    if ( THIS->_inputLevelMonitorData.monitoringEnabled && THIS->_inputAudioDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger ) {
        performLevelMonitoring(&THIS->_inputLevelMonitorData, THIS->_inputAudioBufferList, inNumberFrames, &THIS->_inputAudioDescription);
    }
    
    return noErr;
}

static OSStatus groupRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEChannelRef channel = (AEChannelRef)inRefCon;
    AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
    
    if ( !(*ioActionFlags & kAudioUnitRenderAction_PreRender) ) {
        // After render
        AudioBufferList *bufferList;
        
        int bufferCount = group->converterRequired ? ((group->audioConverterTargetFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? group->audioConverterTargetFormat.mChannelsPerFrame : 1) : 1;
        char audioBufferListSpace[sizeof(AudioBufferList)+(bufferCount-1)*sizeof(AudioBuffer)];
        
        if ( group->converterRequired ) {
            // Initialise output buffer
            bufferList = (AudioBufferList*)audioBufferListSpace;
            bufferList->mNumberBuffers = bufferCount;
            for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
                bufferList->mBuffers[i].mNumberChannels = (group->audioConverterTargetFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : group->audioConverterTargetFormat.mChannelsPerFrame;
                bufferList->mBuffers[i].mData           = group->audioConverterScratchBuffer + (i * kRenderConversionScratchBufferSize/bufferList->mNumberBuffers);
                bufferList->mBuffers[i].mDataByteSize   = group->audioConverterTargetFormat.mBytesPerFrame * inNumberFrames;
            }
            
            // Perform conversion
            OSStatus result = AudioConverterFillComplexBuffer(group->audioConverter, 
                                                              fillComplexBufferInputProc, 
                                                              &(struct fillComplexBufferInputProc_t) { .bufferList = ioData, .frames = inNumberFrames }, 
                                                              &inNumberFrames, 
                                                              bufferList, 
                                                              NULL);
            if ( !checkResult(result, "AudioConverterConvertComplexBuffer") ) {
                return noErr;
            }
            
        } else {
            // We can pull audio out directly, as it's in the right format
            bufferList = ioData;
        }
        
        handleCallbacksForChannel(channel, inTimeStamp, inNumberFrames, bufferList);
        
        if ( group->level_monitor_data.monitoringEnabled ) {
            performLevelMonitoring(&group->level_monitor_data, bufferList, inNumberFrames, &channel->audioDescription);
        }
    }
    
    return noErr;
}

static OSStatus topRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    AEAudioController *THIS = (AEAudioController *)inRefCon;
        
    if ( *ioActionFlags & kAudioUnitRenderAction_PreRender ) {
        
        if ( !THIS->_hardwareInputAvailable && THIS->_audiobusInputPort && !(*ioActionFlags & kAudiobusSourceFlag) && THIS->_usingAudiobusInput ) {
            // If Audiobus is connected, then serve Audiobus queue (here, rather than the input queue as hardware is stopped)
            serveAudiobusInputQueue(THIS);
            return noErr;
        }
        
        // Before render: Perform timing callbacks
        for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
            callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
            ((AEAudioControllerTimingCallback)callback->callback)(callback->userInfo, THIS, inTimeStamp, AEAudioTimingContextOutput);
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
    
    NSAssert(audioDescription.mChannelsPerFrame <= 2, @"Only mono or stereo audio supported");
    NSAssert(audioDescription.mFormatID == kAudioFormatLinearPCM, @"Only linear PCM supported");

    _audioSessionCategory = enableInput ? kAudioSessionCategory_PlayAndRecord : kAudioSessionCategory_MediaPlayback;
    _audioDescription = audioDescription;
    _inputAudioDescription = audioDescription;
    _inputEnabled = enableInput;
    _voiceProcessingEnabled = useVoiceProcessing;
    _inputMode = AEInputModeFixedAudioFormat;
    _voiceProcessingOnlyForSpeakerAndMicrophone = YES;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    
    if ( ABConnectionsChangedNotification ) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audiobusConnectionsChanged:) name:ABConnectionsChangedNotification object:nil];
    }
    
    TPCircularBufferInit(&_realtimeThreadMessageBuffer, kMessageBufferLength);
    TPCircularBufferInit(&_mainThreadMessageBuffer, kMessageBufferLength);
    
    if ( ![self initAudioSession] || ![self setup] ) {
        _audioGraph = NULL;
    }
    
    self.housekeepingTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(housekeeping) userInfo:nil repeats:YES];
    
    return self;
}

- (void)dealloc {
    [_housekeepingTimer invalidate];
    self.housekeepingTimer = nil;
    
    self.lastError = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stop];
    [self teardown];
    
    OSStatus result = AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, self);
    checkResult(result, "AudioSessionRemovePropertyListenerWithUserData");
    
    result = AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioInputAvailable, audioSessionPropertyListener, self);
    checkResult(result, "AudioSessionRemovePropertyListenerWithUserData");
    
    self.audioRoute = nil;
    
    if ( _audiobusInputPort ) [_audiobusInputPort release];
    if ( _topChannel.audiobusOutputPort ) [_topChannel.audiobusOutputPort release];
    if ( _inputChannelSelection ) [_inputChannelSelection release];
    
    NSArray *channels = [self channels];
    for ( NSObject *channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"channelIsPlaying", @"channelIsMuted", @"audioDescription", nil] ) {
            [channel removeObserver:self forKeyPath:property];
        }
    }
    [channels makeObjectsPerformSelector:@selector(release)];
    
    if ( _renderConversionScratchBuffer ) {
        free(_renderConversionScratchBuffer);
        _renderConversionScratchBuffer = NULL;
    }
    
    [self removeChannelGroup:_topGroup];
    
    TPCircularBufferCleanup(&_realtimeThreadMessageBuffer);
    TPCircularBufferCleanup(&_mainThreadMessageBuffer);
    
    if ( _inputLevelMonitorData.scratchBuffer ) {
        free(_inputLevelMonitorData.scratchBuffer);
    }
    
    [super dealloc];
}

-(BOOL)start:(NSError **)error {
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
            if ( error ) *error = [NSError audioControllerErrorWithMessage:@"Couldn't start audio engine" OSStatus:status];
            return NO;
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
        
        AEChannelRef channelElement = &group->channels[group->channelCount++];
        
        channelElement->type        = kChannelTypeChannel;
        channelElement->ptr         = channel.renderCallback;
        channelElement->userInfo    = channel;
        channelElement->playing     = [channel respondsToSelector:@selector(channelIsPlaying)] ? channel.channelIsPlaying : YES;
        channelElement->volume      = [channel respondsToSelector:@selector(volume)] ? channel.volume : 1.0;
        channelElement->pan         = [channel respondsToSelector:@selector(pan)] ? channel.pan : 0.0;
        channelElement->muted       = [channel respondsToSelector:@selector(channelIsMuted)] ? channel.channelIsMuted : NO;
        channelElement->audioDescription = [channel respondsToSelector:@selector(audioDescription)] && channel.audioDescription.mSampleRate ? channel.audioDescription : _audioDescription;
        channelElement->audioController = self;
    }
    
    // Set bus count
    UInt32 busCount = group->channelCount;
    OSStatus result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // Configure each channel
    BOOL updateRequired = NO;
    configureChannelsInRangeForGroup(self, NSMakeRange(group->channelCount - [channels count], [channels count]), group, &updateRequired);
    
    if ( updateRequired ) {
        checkResult([self updateGraph], "Update graph");
    }
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
    // Get a list of all the associated objects for these channels
    NSMutableArray *associatedObjects = [NSMutableArray array];
    for ( id<AEAudioPlayable> channel in channels ) {
        NSArray *objects = [self associatedObjectsWithFlags:0 forChannel:channel];
        [associatedObjects addObjectsFromArray:objects];
    }
    
    // Remove the channels from the tables, on the core audio thread
    int count = [channels count];
    void** ptrMatchArray = malloc(count * sizeof(void*));
    void** userInfoMatchArray = malloc(count * sizeof(void*));
    for ( int i=0; i<count; i++ ) {
        ptrMatchArray[i] = ((id<AEAudioPlayable>)[channels objectAtIndex:i]).renderCallback;
        userInfoMatchArray[i] = [channels objectAtIndex:i];
    }
    [self performSynchronousMessageExchangeWithBlock:^{
        removeChannelsFromGroup(self, group, ptrMatchArray, userInfoMatchArray, count);
    }];
    free(ptrMatchArray);
    free(userInfoMatchArray);
    
    // Finally, stop observing and release channels
    for ( NSObject *channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"channelIsPlaying", @"channelIsMuted", @"audioDescription", nil] ) {
            [(NSObject*)channel removeObserver:self forKeyPath:property];
        }
    }
    [channels makeObjectsPerformSelector:@selector(release)];
    
    // Release the associated callback objects
    [associatedObjects makeObjectsPerformSelector:@selector(release)];
}


- (void)removeChannelGroup:(AEChannelGroupRef)group {
    
    // Find group's parent
    AEChannelGroupRef parentGroup = (group == _topGroup ? NULL : [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:NULL]);
    NSAssert(group == _topGroup || parentGroup != NULL, @"Channel group not found");
    
    // Get a list of contained channels
    NSMutableArray *channelsWithinGroup = [NSMutableArray array];
    [self gatherChannelsFromGroup:group intoArray:channelsWithinGroup];
    
    // Get a list of all the associated objects for these channels
    NSMutableArray *channelObjects = [NSMutableArray array];
    for ( id<AEAudioPlayable> channel in channelsWithinGroup ) {
        NSArray *objects = [self associatedObjectsWithFlags:0 forChannel:channel];
        [channelObjects addObjectsFromArray:objects];
    }
    
    // Get a list of associated objects for this group
    NSArray *groupObjects = [self associatedObjectsWithFlags:0 forChannelGroup:group];
    
    if ( parentGroup ) {
        // Remove the group from the parent group's table, on the core audio thread
        [self performSynchronousMessageExchangeWithBlock:^{
            removeChannelsFromGroup(self, parentGroup, (void*[1]){ group }, (void*[1]){ NULL }, 1);
        }];
    }
    
    // Release channel resources
    [channelsWithinGroup makeObjectsPerformSelector:@selector(release)];
    [channelObjects makeObjectsPerformSelector:@selector(release)];
    
    // Release group resources
    [groupObjects makeObjectsPerformSelector:@selector(release)];
    
    // Release subgroup resources
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self releaseResourcesForGroup:(AEChannelGroupRef)channel->ptr];
            channel->ptr = NULL;
        }
    }
    
    free(group);
}

-(NSArray *)channels {
    NSMutableArray *channels = [NSMutableArray array];
    [self gatherChannelsFromGroup:_topGroup intoArray:channels];
    return channels;
}

- (NSArray*)channelsInChannelGroup:(AEChannelGroupRef)group {
    NSMutableArray *channels = [NSMutableArray array];
    for ( int i=0; i<group->channelCount; i++ ) {
        if ( group->channels[i].type == kChannelTypeChannel ) {
            [channels addObject:(id)group->channels[i].userInfo];
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
    
    AEChannelRef channel = &parentGroup->channels[groupIndex];
    memset(channel, 0, sizeof(channel_t));
    channel->type    = kChannelTypeGroup;
    channel->ptr     = group;
    channel->playing = YES;
    channel->volume  = 1.0;
    channel->pan     = 0.0;
    channel->muted   = NO;
    channel->audioController = self;
    
    group->channel   = channel;
    
    parentGroup->channelCount++;    

    // Initialise group
    BOOL updateRequired = NO;
    initialiseGroupChannel(self, channel, parentGroup, groupIndex, &updateRequired);

    if ( updateRequired ) {
        checkResult([self updateGraph], "Update graph");
    }
    
    return group;
}

- (NSArray*)topLevelChannelGroups {
    return [self channelGroupsInChannelGroup:_topGroup];
}

- (NSArray*)channelGroupsInChannelGroup:(AEChannelGroupRef)group {
    NSMutableArray *groups = [NSMutableArray array];
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [groups addObject:[NSValue valueWithPointer:channel->ptr]];
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

- (void)setMuted:(BOOL)muted forChannelGroup:(AEChannelGroupRef)group {
    int index;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AudioUnitParameterValue value = group->channel->muted = muted;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
}

#pragma mark - Filters

- (void)addFilter:(id<AEAudioFilter>)filter {
    [filter retain];
    [self addCallback:filter.filterCallback userInfo:filter flags:kFilterFlag forChannelGroup:_topGroup];
}

- (void)addFilter:(id<AEAudioFilter>)filter toChannel:(id<AEAudioPlayable>)channel {
    [filter retain];
    [self addCallback:filter.filterCallback userInfo:filter flags:kFilterFlag forChannel:channel];
}

- (void)addFilter:(id<AEAudioFilter>)filter toChannelGroup:(AEChannelGroupRef)group {
    [filter retain];
    [self addCallback:filter.filterCallback userInfo:filter flags:kFilterFlag forChannelGroup:group];
}

- (void)addInputFilter:(id<AEAudioFilter>)filter {
    [filter retain];
    void *callback = filter.filterCallback;
    [self performSynchronousMessageExchangeWithBlock:^{
        addCallbackToTable(self, &_inputCallbacks, callback, filter, kFilterFlag);
    }];
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
        removeCallbackFromTable(self, &_inputCallbacks, callback, filter, &found);
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
    return [self associatedObjectsFromTable:&_inputCallbacks matchingFlag:kFilterFlag];
}

- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter {
    [self setVariableSpeedFilter:filter forChannelGroup:_topGroup];
}

- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter forChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = &parentGroup->channels[index];
    
    [self setVariableSpeedFilter:filter forChannelStruct:channel];
}

- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter forChannelGroup:(AEChannelGroupRef)group {
    [self setVariableSpeedFilter:filter forChannelStruct:group->channel];
    
    AEChannelGroupRef parentGroup = NULL;
    int index=0;
    if ( group != _topGroup ) {
        parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
        NSAssert(parentGroup != NULL, @"Channel group not found");
    }
    
    BOOL updateRequired = NO;
    configureGraphStateOfGroupChannel(self, group->channel, parentGroup, index, &updateRequired);
    if ( updateRequired ) {
        checkResult([self updateGraph], "AUGraphUpdate");
    }
}

#pragma mark - Output receivers

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver {
    [receiver retain];
    [self addCallback:receiver.receiverCallback userInfo:receiver flags:kReceiverFlag forChannelGroup:_topGroup];
}

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannel:(id<AEAudioPlayable>)channel {
    [receiver retain];
    [self addCallback:receiver.receiverCallback userInfo:receiver flags:kReceiverFlag forChannel:channel];
}

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannelGroup:(AEChannelGroupRef)group {
    [receiver retain];
    [self addCallback:receiver.receiverCallback userInfo:receiver flags:kReceiverFlag forChannelGroup:group];
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
    if ( _inputCallbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"Warning: Maximum number of callbacks reached");
        return;
    }
    
    [receiver retain];
    
    void *callback = receiver.receiverCallback;
    [self performSynchronousMessageExchangeWithBlock:^{
        addCallbackToTable(self, &_inputCallbacks, callback, receiver, kReceiverFlag);
    }];
}

- (void)removeInputReceiver:(id<AEAudioReceiver>)receiver {
    void *callback = receiver.receiverCallback;
    __block BOOL found = NO;
    [self performSynchronousMessageExchangeWithBlock:^{
        removeCallbackFromTable(self, &_inputCallbacks, callback, receiver, &found);
    }];
    
    if ( found ) {
        [receiver release];
    }
}

-(NSArray *)inputReceivers {
    return [self associatedObjectsFromTable:&_inputCallbacks matchingFlag:kReceiverFlag];
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
            group->level_monitor_data.scratchBuffer = malloc(kLevelMonitorScratchBufferSize);
            OSMemoryBarrier();
            group->level_monitor_data.monitoringEnabled = YES;
            
            AEChannelGroupRef parentGroup = NULL;
            int index=0;
            if ( group != _topGroup ) {
                parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
                NSAssert(parentGroup != NULL, @"Channel group not found");
            }
            
            BOOL updateRequired = NO;
            configureGraphStateOfGroupChannel(self, group->channel, parentGroup, index, &updateRequired);
            if ( updateRequired ) {
                checkResult([self updateGraph], "AUGraphUpdate");
            }
        }
    }
    
    if ( averagePower ) *averagePower = 10.0 * log10((double)group->level_monitor_data.average / (group->channel->audioDescription.mBitsPerChannel == 16 ? INT16_MAX : INT32_MAX));
    if ( peakLevel ) *peakLevel = 10.0 * log10((double)group->level_monitor_data.peak / (group->channel->audioDescription.mBitsPerChannel == 16 ? INT16_MAX : INT32_MAX));;
    
    group->level_monitor_data.reset = YES;
}

- (void)inputAveragePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel {
    if ( !_inputLevelMonitorData.monitoringEnabled ) {
        _inputLevelMonitorData.scratchBuffer = malloc(kLevelMonitorScratchBufferSize);
        OSMemoryBarrier();
        _inputLevelMonitorData.monitoringEnabled = YES;
    }
    
    if ( averagePower ) *averagePower = 10.0 * log10((double)_inputLevelMonitorData.average / (_inputAudioDescription.mBitsPerChannel == 16 ? INT16_MAX : INT32_MAX));
    if ( peakLevel ) *peakLevel = 10.0 * log10((double)_inputLevelMonitorData.peak / (_inputAudioDescription.mBitsPerChannel == 16 ? INT16_MAX : INT32_MAX));;
    
    _inputLevelMonitorData.reset = YES;
}

#pragma mark - Utilities

AudioStreamBasicDescription *AEAudioControllerAudioDescription(AEAudioController *THIS) {
    return &THIS->_audioDescription;
}

AudioStreamBasicDescription *AEAudioControllerInputAudioDescription(AEAudioController *THIS) {
    return &THIS->_inputAudioDescription;
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
    
    if ( category == kAudioSessionCategory_PlayAndRecord || category == kAudioSessionCategory_RecordAudio ) {
        UInt32 allowBluetoothInput = _enableBluetoothInput;
        OSStatus result = AudioSessionSetProperty (kAudioSessionProperty_OverrideCategoryEnableBluetoothInput, sizeof (allowBluetoothInput), &allowBluetoothInput);
        checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput)");
    }
    
    if ( category == kAudioSessionCategory_MediaPlayback || category == kAudioSessionCategory_PlayAndRecord ) {
        UInt32 allowMixing = YES;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                    "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    }
}

-(UInt32)audioSessionCategory {
    return ( !_audioInputAvailable && (_audioSessionCategory == kAudioSessionCategory_PlayAndRecord || _audioSessionCategory == kAudioSessionCategory_RecordAudio) )
                ? kAudioSessionCategory_MediaPlayback
                : _audioSessionCategory;
}

- (BOOL)running {
    if ( !_audioGraph ) return NO;
    
    if ( _interrupted ) return NO;
    
    return _running;
}

-(void)setEnableBluetoothInput:(BOOL)enableBluetoothInput {
    _enableBluetoothInput = enableBluetoothInput;

    if ( _audioSessionCategory == kAudioSessionCategory_PlayAndRecord || _audioSessionCategory == kAudioSessionCategory_RecordAudio ) {
        // Enable/disable bluetooth input
        UInt32 allowBluetoothInput = _enableBluetoothInput;
        OSStatus result = AudioSessionSetProperty (kAudioSessionProperty_OverrideCategoryEnableBluetoothInput, sizeof (allowBluetoothInput), &allowBluetoothInput);
        checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput)");
    }
    
    if ( _audioSessionCategory == kAudioSessionCategory_MediaPlayback || _audioSessionCategory == kAudioSessionCategory_PlayAndRecord ) {
        UInt32 allowMixing = YES;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                    "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    }
}

-(NSString*)audioRoute {
    if ( _topChannel.audiobusOutputPort && ABOutputPortGetConnectedPortAttributes(_topChannel.audiobusOutputPort) & ABInputPortAttributePlaysLiveAudio ) {
        return @"Audiobus";
    } else {
        return _audioRoute;
    }
}

-(BOOL)playingThroughDeviceSpeaker {
    if ( _topChannel.audiobusOutputPort && ABOutputPortGetConnectedPortAttributes(_topChannel.audiobusOutputPort) & ABInputPortAttributePlaysLiveAudio ) {
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
    if ( _inputMode == AEInputModeFixedAudioFormat || (_numberOfInputChannels != 0 && _inputAudioDescription.mChannelsPerFrame == _numberOfInputChannels) ) {
        return _inputAudioDescription;
    }
    
    if ( _numberOfInputChannels == 0 ) {
        return _inputAudioDescription;
    }
    
    if ( !(_inputAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ) {
        _inputAudioDescription.mBytesPerFrame *= (float)_numberOfInputChannels / _inputAudioDescription.mChannelsPerFrame;
        _inputAudioDescription.mBytesPerPacket *= (float)_numberOfInputChannels / _inputAudioDescription.mChannelsPerFrame;
    }
    _inputAudioDescription.mChannelsPerFrame = _numberOfInputChannels;
    return _inputAudioDescription;
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

-(void)setInputChannelSelection:(NSArray *)inputChannelSelection {
    [inputChannelSelection retain];
    [_inputChannelSelection release];
    _inputChannelSelection = inputChannelSelection;
    
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

    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
}

-(void)setAudiobusOutputPort:(ABOutputPort *)audiobusOutputPort {
    if ( _topChannel.audiobusOutputPort == audiobusOutputPort ) return;
    
    if ( _topChannel.audiobusOutputPort ) {
        [_topChannel.audiobusOutputPort removeObserver:self forKeyPath:@"destinations"];
        [_topChannel.audiobusOutputPort removeObserver:self forKeyPath:@"connectedPortAttributes"];
    }
    
    [self willChangeValueForKey:@"audioRoute"];
    [self willChangeValueForKey:@"playingThroughDeviceSpeaker"];
    [self setAudiobusOutputPort:audiobusOutputPort forChannelElement:&_topChannel];
    [self didChangeValueForKey:@"audioRoute"];
    [self didChangeValueForKey:@"playingThroughDeviceSpeaker"];
    
    
    if ( _topChannel.audiobusOutputPort ) {
        [_topChannel.audiobusOutputPort addObserver:self forKeyPath:@"destinations" options:NSKeyValueObservingOptionPrior context:NULL];
        [_topChannel.audiobusOutputPort addObserver:self forKeyPath:@"connectedPortAttributes" options:NSKeyValueObservingOptionPrior context:NULL];
    }
}

- (ABOutputPort*)audiobusOutputPort {
    return _topChannel.audiobusOutputPort;
}

static void removeAudiobusOutputPortFromChannelElement(AEAudioController *THIS, void *userInfo, int length) {
    (*((AEChannelRef*)userInfo))->audiobusOutputPort = nil;
}

-(void)setAudiobusOutputPort:(ABOutputPort *)audiobusOutputPort forChannelElement:(AEChannelRef)channelElement {
    if ( channelElement->audiobusOutputPort == audiobusOutputPort ) return;
    if ( channelElement->audiobusOutputPort ) [channelElement->audiobusOutputPort autorelease];
    
    if ( audiobusOutputPort == nil ) {
        [self performSynchronousMessageExchangeWithBlock:^{
            channelElement->audiobusOutputPort = nil;
        }];
    } else {
        [audiobusOutputPort setClientFormat:channelElement->audioDescription];
        channelElement->audiobusOutputPort = [audiobusOutputPort retain];
        
        if ( channelElement->type == kChannelTypeGroup ) {
            AEChannelGroupRef parentGroup = NULL;
            int index=0;
            if ( channelElement->ptr != _topGroup ) {
                parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelElement->ptr userInfo:NULL index:&index];
                NSAssert(parentGroup != NULL, @"Channel group not found");
            }
            
            BOOL updateRequired = NO;
            configureGraphStateOfGroupChannel(self, channelElement, parentGroup, index, &updateRequired);
            if ( updateRequired ) {
                checkResult([self updateGraph], "AUGraphUpdate");
            }
        }
    }
}

-(void)setAudiobusOutputPort:(ABOutputPort *)outputPort forChannel:(id<AEAudioPlayable>)channel {
    int index;
    AEChannelGroupRef group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:channel index:&index];
    if ( !group ) return;
    [self setAudiobusOutputPort:outputPort forChannelElement:&group->channels[index]];
}

-(void)setAudiobusOutputPort:(ABOutputPort *)outputPort forChannelGroup:(AEChannelGroupRef)channelGroup {
    [self setAudiobusOutputPort:outputPort forChannelElement:channelGroup->channel];
}

#pragma mark - Events

-(void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {

    if ( object == _topChannel.audiobusOutputPort ) {
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
    AEChannelRef channelElement = &group->channels[index];
    
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
        
        group->channels[index].playing = value;
        
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
        
        if ( channelElement->audiobusOutputPort ) {
            [channelElement->audiobusOutputPort setClientFormat:channel.audioDescription];
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
    
    if ( _hasSystemError ) [self attemptRecoveryFromSystemError];
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
    OSStatus result = AudioSessionInitialize(NULL, NULL, interruptionListener, self);
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
    
    // Fetch sample rate, in case we didn't get quite what we requested
    Float64 achievedSampleRate;
    UInt32 size = sizeof(achievedSampleRate);
    result = AudioSessionGetProperty(kAudioSessionProperty_PreferredHardwareSampleRate, &size, &achievedSampleRate);
    checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_PreferredHardwareSampleRate)");
    if ( achievedSampleRate != sampleRate ) {
        NSLog(@"Warning: Delivered sample rate is %f", achievedSampleRate);
        _audioDescription.mSampleRate = achievedSampleRate;
        [extraInfo appendFormat:@", sample rate %0.2g", achievedSampleRate];
    }
    
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
    
    // Determine audio route
    CFStringRef route;
    size = sizeof(route);
    if ( checkResult(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route),
                     "AudioSessionGetProperty(kAudioSessionProperty_AudioRoute)") ) {
        
        self.audioRoute = [[(NSString*)route copy] autorelease];
        [extraInfo appendFormat:@", audio route '%@'", _audioRoute];
        if ( [(NSString*)route isEqualToString:@"ReceiverAndMicrophone"] ) {
            checkResult(AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, self), 
                        "AudioSessionRemovePropertyListenerWithUserData");
            
            // Re-route audio to the speaker (not the receiver)
            UInt32 newRoute = kAudioSessionOverrideAudioRoute_Speaker;
            checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute,  sizeof(route), &newRoute), 
                        "AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute)");
            
            if ( self.audioSessionCategory == kAudioSessionCategory_MediaPlayback || self.audioSessionCategory == kAudioSessionCategory_PlayAndRecord ) {
                UInt32 allowMixing = YES;
                checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                            "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
            }
            
            checkResult(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, self),
                        "AudioSessionAddPropertyListener");
            
            _playingThroughDeviceSpeaker = YES;
        } else if ( [(NSString*)route isEqualToString:@"SpeakerAndMicrophone"] || [(NSString*)route isEqualToString:@"Speaker"] ) {
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
    
    NSLog(@"TAAE: Audio session initialized (%@)", extraInfo);
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
        _topGroup = (AEChannelGroupRef)calloc(1, sizeof(channel_group_t));
        memset(&_topChannel, 0, sizeof(channel_t));
        _topChannel.type     = kChannelTypeGroup;
        _topChannel.ptr      = _topGroup;
        _topChannel.userInfo = AEAudioSourceMainOutput;
        _topChannel.playing  = YES;
        _topChannel.volume   = 1.0;
        _topChannel.pan      = 0.0;
        _topChannel.muted    = NO;
        _topChannel.audioController = self;
        _topGroup->channel   = &_topChannel;
        
        UInt32 size = sizeof(_topChannel.audioDescription);
        checkResult(AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_topChannel.audioDescription, &size),
                   "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output)");
    }
    
    // Initialise group
    BOOL unused;
    initialiseGroupChannel(self, &_topChannel, NULL, 0, &unused);
    
    // Register a callback to be notified when the main mixer unit renders
    checkResult(AudioUnitAddRenderNotify(_topGroup->mixerAudioUnit, &topRenderNotifyCallback, self), "AudioUnitAddRenderNotify");
    
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
    BOOL useVoiceProcessing = [self usingVPIO];
    
    AudioComponentDescription io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = useVoiceProcessing ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    _running = NO;
    
    if ( !checkResult(AUGraphStop(_audioGraph), "AUGraphStop") // Stop graph
            || !checkResult(AUGraphRemoveNode(_audioGraph, _ioNode), "AUGraphRemoveNode") // Remove the old IO node
            || !checkResult(AUGraphAddNode(_audioGraph, &io_desc, &_ioNode), "AUGraphAddNode io") // Create new IO node
            || !checkResult(AUGraphNodeInfo(_audioGraph, _ioNode, NULL, &_ioAudioUnit), "AUGraphNodeInfo") ) { // Get reference to input audio unit
        [self attemptRecoveryFromSystemError];
        return;
    }
    
    [self configureAudioUnit];
    
    OSStatus result = AUGraphUpdate(_audioGraph, NULL);
    if ( result != kAUGraphErr_NodeNotFound /* Ignore this error */ && !checkResult(result, "AUGraphUpdate") ) {
        [self attemptRecoveryFromSystemError];
        return;
    }

    if ( _inputEnabled ) {
        [self updateInputDeviceStatus];
    }
    
    _topChannel.graphState &= ~(kGraphStateNodeConnected | kGraphStateRenderCallbackSet);
    BOOL unused;
    if ( configureGraphStateOfGroupChannel(self, &_topChannel, NULL, 0, &unused) == noErr
            || !checkResult(AUGraphStart(_audioGraph), "AUGraphStart") ) {
        [self attemptRecoveryFromSystemError];
        return;
    }
    
    _running = YES;
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
}

- (void)teardown {
    checkResult(AUGraphClose(_audioGraph), "AUGraphClose");
    checkResult(DisposeAUGraph(_audioGraph), "AUGraphClose");
    _audioGraph = NULL;
    _ioAudioUnit = NULL;
    
    if ( _inputAudioConverter ) {
        AudioConverterDispose(_inputAudioConverter);
        free(_inputAudioScratchBufferList);
        _inputAudioConverter = NULL;
        _inputAudioScratchBufferList = NULL;
    }
    
    if ( _inputAudioBufferList ) {
        if ( _inputAudioBufferListBuffersAreAllocated ) {
            _inputAudioBufferListBuffersAreAllocated = NO;
            AEFreeAudioBufferList(_inputAudioBufferList);
        } else {
            free(_inputAudioBufferList);
        }
        _inputAudioBufferList = NULL;
    }
    
    [self markGroupTorndown:_topGroup];
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
                if ( checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels)") ) {
                    numberOfInputChannels = channels;
                }
                if ( originalCategory != kAudioSessionCategory_PlayAndRecord ) {
                    self.audioSessionCategory = originalCategory;
                }
            }

            if ( !checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels)") ) {
                NSLog(@"Unexpected audio system error while determining channel count");
                if ( !_lastError ) self.lastError = [NSError audioControllerErrorWithMessage:@"Audio system error while determining input channel count" OSStatus:result];
                success = NO;
            } else {
                numberOfInputChannels = channels;
            }
        }
    }
    
    AudioStreamBasicDescription rawAudioDescription   = _audioDescription;
    AudioStreamBasicDescription inputAudioDescription = _audioDescription;
    AudioBufferList *inputBufferList = _inputAudioBufferList;
    BOOL bufferIsAllocated           = _inputAudioBufferListBuffersAreAllocated;
    AudioConverterRef converter      = _inputAudioConverter;
    AudioBufferList *scratchBuffer   = _inputAudioScratchBufferList;
    
    BOOL inputChannelsChanged = NO;
    BOOL inputAvailableChanged = NO;
    
    if ( inputAvailable ) {
        if ( !(rawAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ) {
            rawAudioDescription.mBytesPerFrame *= (float)numberOfInputChannels / rawAudioDescription.mChannelsPerFrame;
            rawAudioDescription.mBytesPerPacket *= (float)numberOfInputChannels / rawAudioDescription.mChannelsPerFrame;
        }
        rawAudioDescription.mChannelsPerFrame = numberOfInputChannels;
        
        if ( _inputMode == AEInputModeVariableAudioFormat ) {
            inputAudioDescription = rawAudioDescription;
        
            if ( [_inputChannelSelection count] > 0 ) {
                // Set the target input audio description channels to the number of selected channels
                int channels = MIN(2, [_inputChannelSelection count]);
                if ( !(inputAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ) {
                    inputAudioDescription.mBytesPerFrame *= (float)channels / inputAudioDescription.mChannelsPerFrame;
                    inputAudioDescription.mBytesPerPacket *= (float)channels / inputAudioDescription.mChannelsPerFrame;
                }
                inputAudioDescription.mChannelsPerFrame = channels;
            }
        }
        
        // Determine if conversion is required
        BOOL channelMapRequired = inputAudioDescription.mChannelsPerFrame != numberOfInputChannels
                                        || (_inputChannelSelection && [_inputChannelSelection count] != inputAudioDescription.mChannelsPerFrame);
        if ( !channelMapRequired && _inputChannelSelection ) {
            for ( int i=0; i<[_inputChannelSelection count]; i++ ) {
                if ( [[_inputChannelSelection objectAtIndex:i] intValue] != i ) {
                    channelMapRequired = YES;
                    break;
                }
            }
        }
        
        if ( !channelMapRequired ) {
            // Just change the audio unit's input stream format
            rawAudioDescription = inputAudioDescription;
        }
        
        BOOL useVoiceProcessing = [self usingVPIO];
        BOOL converterForiOS4Required = NO;
        if ( useVoiceProcessing && (_audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) && [[[UIDevice currentDevice] systemVersion] floatValue] < 5.0 ) {
            // iOS 4 cannot handle non-interleaved audio and voice processing. Use interleaved audio and a converter.
            converterForiOS4Required = YES;
        }
        
        if ( channelMapRequired || converterForiOS4Required ) {
            if ( converterForiOS4Required ) {
                rawAudioDescription.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved;
                rawAudioDescription.mBytesPerFrame *= rawAudioDescription.mChannelsPerFrame;
                rawAudioDescription.mBytesPerPacket *= rawAudioDescription.mChannelsPerFrame;
            }
            
            AudioStreamBasicDescription converterInputFormat;
            AudioStreamBasicDescription converterOutputFormat;
            UInt32 formatSize = sizeof(converterOutputFormat);
            UInt32 mappingSize = 0;
            
            if ( converter ) {
                checkResult(AudioConverterGetPropertyInfo(converter, kAudioConverterChannelMap, &mappingSize, NULL),
                            "AudioConverterGetPropertyInfo(kAudioConverterChannelMap)");
            }
            SInt32 *mapping = (SInt32*)(mappingSize != 0 ? malloc(mappingSize) : NULL);
            
            if ( converter ) {
                checkResult(AudioConverterGetProperty(converter, kAudioConverterCurrentInputStreamDescription, &formatSize, &converterInputFormat),
                            "AudioConverterGetProperty(kAudioConverterCurrentInputStreamDescription)");
                checkResult(AudioConverterGetProperty(converter, kAudioConverterCurrentOutputStreamDescription, &formatSize, &converterOutputFormat),
                            "AudioConverterGetProperty(kAudioConverterCurrentOutputStreamDescription)");
                checkResult(AudioConverterGetProperty(converter, kAudioConverterChannelMap, &mappingSize, mapping),
                            "AudioConverterGetProperty(kAudioConverterChannelMap)");
            }
            
            UInt32 targetMappingSize = sizeof(SInt32) * inputAudioDescription.mChannelsPerFrame;
            SInt32 *targetMapping = (SInt32*)malloc(targetMappingSize);
            
            for ( int i=0; i<inputAudioDescription.mChannelsPerFrame; i++ ) {
                if ( [_inputChannelSelection count] > 0 ) {
                    targetMapping[i] = min(numberOfInputChannels-1,
                                           [_inputChannelSelection count] > i
                                           ? [[_inputChannelSelection objectAtIndex:i] intValue]
                                           : [[_inputChannelSelection lastObject] intValue]);
                } else {
                    targetMapping[i] = min(numberOfInputChannels-1, i);
                }
            }
            
            if ( !converter
                    || memcmp(&converterInputFormat, &rawAudioDescription, sizeof(AudioStreamBasicDescription)) != 0
                    || memcmp(&converterOutputFormat, &inputAudioDescription, sizeof(AudioStreamBasicDescription)) != 0
                    || (mappingSize != targetMappingSize || memcmp(mapping, targetMapping, targetMappingSize)) ) {
                checkResult(AudioConverterNew(&rawAudioDescription, &inputAudioDescription, &converter), "AudioConverterNew");
                scratchBuffer = AEAllocateAndInitAudioBufferList(rawAudioDescription, 0);
                inputBufferList = AEAllocateAndInitAudioBufferList(inputAudioDescription, kInputAudioBufferFrames);
                bufferIsAllocated = YES;
                
                checkResult(AudioConverterSetProperty(converter, kAudioConverterChannelMap, targetMappingSize, targetMapping), "AudioConverterSetProperty(kAudioConverterChannelMap");
            }
            
            if ( targetMapping) free(targetMapping);
            if ( mapping ) free(mapping);
        } else {
            // No converter/channel map required
            converter = NULL;
            scratchBuffer = NULL;
        }
        
        if ( !_inputAudioBufferList || memcmp(&inputAudioDescription, &_inputAudioDescription, sizeof(inputAudioDescription)) != 0 ) {
            if ( !converter ) {
                inputBufferList = AEAllocateAndInitAudioBufferList(inputAudioDescription, 0);
                bufferIsAllocated = NO;
            }
            inputChannelsChanged = YES;
        }
    } else if ( !inputAvailable ) {
        if ( _audioSessionCategory == kAudioSessionCategory_PlayAndRecord || _audioSessionCategory == kAudioSessionCategory_RecordAudio ) {
            // Update audio session as appropriate (will select a non-recording category for us)
            self.audioSessionCategory = _audioSessionCategory;
        }
        
        converter = NULL;
        scratchBuffer = NULL;
        inputBufferList = NULL;
        bufferIsAllocated = NO;
        converter = NULL;
        scratchBuffer = NULL;
    }
    
    inputChannelsChanged |= _numberOfInputChannels != numberOfInputChannels;
    inputAvailableChanged |= _audioInputAvailable != inputAvailable;
    
    if ( inputChannelsChanged ) {
        [self willChangeValueForKey:@"numberOfInputChannels"];
        [self willChangeValueForKey:@"inputAudioDescription"];
    }
    
    if ( inputAvailableChanged ) {
        [self willChangeValueForKey:@"audioInputAvailable"];
    }
    
    AudioBufferList *oldInputBuffer     = _inputAudioBufferList;
    BOOL existingBufferWasAllocated     = _inputAudioBufferListBuffersAreAllocated;
    AudioConverterRef oldConverter      = _inputAudioConverter;
    AudioBufferList *oldScratchBuffer   = _inputAudioScratchBufferList;
    
    if ( _audiobusInputPort ) {
        AudioStreamBasicDescription clientFormat = [_audiobusInputPort clientFormat];
        if ( memcmp(&clientFormat, &inputAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
            [_audiobusInputPort setClientFormat:inputAudioDescription];
        }
    }
    
    // Set input stream format and update the properties, on the realtime thread
    [self performSynchronousMessageExchangeWithBlock:^{
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
        
        _numberOfInputChannels    = numberOfInputChannels;
        _inputAudioDescription    = inputAudioDescription;
        _audioInputAvailable      = inputAvailable;
        _hardwareInputAvailable   = hardwareInputAvailable;
        _inputAudioBufferList     = inputBufferList;
        _inputAudioBufferListBuffersAreAllocated = bufferIsAllocated;
        _inputAudioConverter      = converter;
        _inputAudioScratchBufferList = scratchBuffer;
        _usingAudiobusInput       = usingAudiobus;
    }];
    
    if ( oldInputBuffer && oldInputBuffer != inputBufferList ) {
        if ( existingBufferWasAllocated ) {
            AEFreeAudioBufferList(oldInputBuffer);
        } else {
            free(oldInputBuffer);
        }
    }
    if ( oldConverter && oldConverter != converter ) {
        AudioConverterDispose(oldConverter);
    }
    if ( oldScratchBuffer && oldScratchBuffer != scratchBuffer ) {
        free(oldScratchBuffer);
    }
    
    if ( inputChannelsChanged ) {
        [self didChangeValueForKey:@"inputAudioDescription"];
        [self didChangeValueForKey:@"numberOfInputChannels"];
    }
    
    if ( inputAvailableChanged ) {
        [self didChangeValueForKey:@"audioInputAvailable"];
    }
    
    if ( inputChannelsChanged || inputAvailableChanged || oldConverter != converter || (oldInputBuffer && oldInputBuffer != _inputAudioBufferList) || (oldScratchBuffer && oldScratchBuffer != scratchBuffer) ) {
        if ( inputAvailable ) {
            NSLog(@"TAAE: Input status updated (%lu channel, %@%@%@%@)",
                  numberOfInputChannels,
                  usingAudiobus ? @"using Audiobus, " : @"",
                  inputAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? @"non-interleaved" : @"interleaved",
                  [self usingVPIO] ? @", using voice processing" : @"",
                  converter ? @", with converter" : @"");
        } else {
            NSLog(@"TAAE: Input status updated: No input avaliable");
        }
    }
    
    return success;
}

static BOOL initialiseGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index, BOOL *updateRequired) {
    AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
    
    OSStatus result;
    
    if ( !group->mixerNode ) {
        // multichannel mixer unit
        AudioComponentDescription mixer_desc = {
            .componentType = kAudioUnitType_Mixer,
            .componentSubType = kAudioUnitSubType_MultiChannelMixer,
            .componentManufacturer = kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0
        };
        
        // Add mixer node to graph
        result = AUGraphAddNode(THIS->_audioGraph, &mixer_desc, &group->mixerNode );
        if ( !checkResult(result, "AUGraphAddNode mixer") ) return NO;
        
        // Get reference to the audio unit
        result = AUGraphNodeInfo(THIS->_audioGraph, group->mixerNode, NULL, &group->mixerAudioUnit);
        if ( !checkResult(result, "AUGraphNodeInfo") ) return NO;
        
        // Try to set mixer's output stream format
        group->converterRequired = NO;
        channel->audioDescription = THIS->_audioDescription;
        result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &THIS->_audioDescription, sizeof(THIS->_audioDescription));
        
        if ( result == kAudioUnitErr_FormatNotSupported ) {
            // The mixer only supports a subset of formats. If it doesn't support this one, then we'll convert manually
            
            // Indicate that an audio converter will be required
            group->converterRequired = YES;
            
            // Get the existing format, and apply just the sample rate
            AudioStreamBasicDescription mixerFormat;
            UInt32 size = sizeof(mixerFormat);
            checkResult(AudioUnitGetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mixerFormat, &size),
                        "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
            mixerFormat.mSampleRate = THIS->_audioDescription.mSampleRate;
            
            checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mixerFormat, sizeof(mixerFormat)), 
                        "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat");            
            
        } else {
            checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        }
        
        // Set mixer's input stream format
        result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &THIS->_audioDescription, sizeof(THIS->_audioDescription));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) return NO;
        
        // Set the mixer unit to handle up to 4096 frames per slice to keep rendering during screen lock
        UInt32 maxFPS = 4096;
        AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
        
        *updateRequired = YES;
    }
    
    // Set bus count
	UInt32 busCount = group->channelCount;
    result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return NO;
    
    // Configure graph state
    configureGraphStateOfGroupChannel(THIS, channel, parentGroup, index, updateRequired);
    
    // Configure inputs
    configureChannelsInRangeForGroup(THIS, NSMakeRange(0, busCount), group, updateRequired);
    
    return YES;
}

static OSStatus configureGraphStateOfGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index, BOOL *updateRequired) {
    AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
    OSStatus result;
    
    BOOL outputCallbacks=NO, filters=NO;
    for ( int i=0; i<channel->callbacks.count && (!outputCallbacks || !filters); i++ ) {
        if ( channel->callbacks.callbacks[i].flags & (kFilterFlag | kVariableSpeedFilterFlag) ) {
            filters = YES;
        } else if ( channel->callbacks.callbacks[i].flags & kReceiverFlag ) {
            outputCallbacks = YES;
        }
    }
    
    if ( (outputCallbacks || filters || group->level_monitor_data.monitoringEnabled || channel->audiobusOutputPort) && group->converterRequired && !group->audioConverter ) {
        // Initialise audio converter if necessary
        
        // Get mixer's output stream format
        AudioStreamBasicDescription mixerFormat;
        UInt32 size = sizeof(mixerFormat);
        result = AudioUnitGetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mixerFormat, &size);
        if ( !checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") ) return result;
        
        group->audioConverterTargetFormat = channel->audioDescription;
        group->audioConverterSourceFormat = mixerFormat;
        
        // Create audio converter
        result = AudioConverterNew(&group->audioConverterSourceFormat, &group->audioConverterTargetFormat, &group->audioConverter);
        if ( !checkResult(result, "AudioConverterNew") ) return result;
        
        if ( !THIS->_renderConversionScratchBuffer ) {
            // Allocate temporary conversion buffer
            THIS->_renderConversionScratchBuffer = (char*)malloc(kRenderConversionScratchBufferSize);
        }
        group->audioConverterScratchBuffer = THIS->_renderConversionScratchBuffer;
    }
    
    if ( filters || channel->audiobusOutputPort ) {
        // We need to use our own render callback, because we're either filtering, or sending via Audiobus (and we may need to adjust timestamp)
        if ( channel->graphState & kGraphStateNodeConnected ) {
            // Remove the node connection
            result = AUGraphDisconnectNodeInput(THIS->_audioGraph, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0);
            if ( !checkResult(result, "AUGraphDisconnectNodeInput") ) return result;
            channel->graphState &= ~kGraphStateNodeConnected;
            result = AUGraphUpdate(THIS->_audioGraph, NULL);
            checkResult(result, "AUGraphUpdate");
        }
        
        if ( channel->graphState & kGraphStateRenderNotificationSet ) {
            // Remove render notification callback
            result = AudioUnitRemoveRenderNotify(group->mixerAudioUnit, &groupRenderNotifyCallback, channel);
            if ( !checkResult(result, "AudioUnitRemoveRenderNotify") ) return result;
            channel->graphState &= ~kGraphStateRenderNotificationSet;
        }

        // Set stream format for callback
        result = AudioUnitSetProperty(parentGroup ? parentGroup->mixerAudioUnit : THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, parentGroup ? index : 0, &THIS->_audioDescription, sizeof(THIS->_audioDescription));
        checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        
        if ( !(channel->graphState & kGraphStateRenderCallbackSet) ) {
            // Add the render callback
            AURenderCallbackStruct rcbs;
            rcbs.inputProc = &renderCallback;
            rcbs.inputProcRefCon = channel;
            result = AUGraphSetNodeInputCallback(THIS->_audioGraph, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0, &rcbs);
            if ( checkResult(result, "AUGraphSetNodeInputCallback") ) {
                channel->graphState |= kGraphStateRenderCallbackSet;
            }
            *updateRequired = YES;
        }
        
    } else {
        if ( channel->graphState & kGraphStateRenderCallbackSet ) {
            // Remove the render callback
            result = AUGraphDisconnectNodeInput(THIS->_audioGraph, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0);
            if ( !checkResult(result, "AUGraphDisconnectNodeInput") ) return result;
            channel->graphState &= ~kGraphStateRenderCallbackSet;
            result = AUGraphUpdate(THIS->_audioGraph, NULL);
            if ( !checkResult(result, "AUGraphUpdate") ) return result;
        }
        
        if ( !(channel->graphState & kGraphStateNodeConnected) ) {
            // Connect output of mixer directly to the parent mixer
            result = AUGraphConnectNodeInput(THIS->_audioGraph, group->mixerNode, 0, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0);
            if ( !checkResult(result, "AUGraphConnectNodeInput") ) return result;
            channel->graphState |= kGraphStateNodeConnected;
            *updateRequired = YES;
        }
        
        if ( outputCallbacks || group->level_monitor_data.monitoringEnabled ) {
            // We need to register a callback to be notified when the mixer renders, to pass on the audio
            if ( !(channel->graphState & kGraphStateRenderNotificationSet) ) {
                // Add render notification callback
                result = AudioUnitAddRenderNotify(group->mixerAudioUnit, &groupRenderNotifyCallback, channel);
                if ( !checkResult(result, "AudioUnitRemoveRenderNotify") ) return result;
                channel->graphState |= kGraphStateRenderNotificationSet;
            }
        } else {
            if ( channel->graphState & kGraphStateRenderNotificationSet ) {
                // Remove render notification callback
                result = AudioUnitRemoveRenderNotify(group->mixerAudioUnit, &groupRenderNotifyCallback, channel);
                if ( !checkResult(result, "AudioUnitRemoveRenderNotify") ) return result;
                channel->graphState &= ~kGraphStateRenderNotificationSet;
            }
        }
    }
    
    if ( !outputCallbacks && !filters && !group->level_monitor_data.monitoringEnabled && group->audioConverter && !(channel->graphState & kGraphStateRenderCallbackSet) ) {
        // Cleanup audio converter
        AudioConverterDispose(group->audioConverter);
        group->audioConverter = NULL;
    }
    
    return noErr;
}

static void configureChannelsInRangeForGroup(AEAudioController *THIS, NSRange range, AEChannelGroupRef group, BOOL *updateRequired) {
    for ( int i = range.location; i < range.location+range.length; i++ ) {
        AEChannelRef channel = &group->channels[i];

        if ( channel->type == kChannelTypeChannel ) {
            
            // Set input stream format
            checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &channel->audioDescription, sizeof(channel->audioDescription)),
                        "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
            
            if ( channel->graphState & kGraphStateRenderCallbackSet || channel->graphState & kGraphStateNodeConnected ) {
                checkResult(AUGraphDisconnectNodeInput(THIS->_audioGraph, group->mixerNode, i), "AUGraphDisconnectNodeInput");
                channel->graphState = kGraphStateUninitialized;
                *updateRequired = YES;
            }
            
            // Setup render callback struct
            AURenderCallbackStruct rcbs;
            rcbs.inputProc = &renderCallback;
            rcbs.inputProcRefCon = channel;
            
            // Set a callback for the specified node's specified input
            if ( checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, i, &rcbs, sizeof(AURenderCallbackStruct)),
                             "AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback)") ) {
                channel->graphState = kGraphStateRenderCallbackSet;
            }
            
        } else if ( channel->type == kChannelTypeGroup ) {
            // Recursively initialise this channel group
            initialiseGroupChannel(THIS, channel, group, i, updateRequired);
        }
        
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
    }
}

static void updateGroupDelayed(AEAudioController *THIS, void *userInfo, int length) {
    AEChannelGroupRef group = *(AEChannelGroupRef*)userInfo;
    
    BOOL updateRequired = NO;
    configureChannelsInRangeForGroup(THIS, NSMakeRange(0, group->channelCount), group, &updateRequired);
    if ( updateRequired ) {
        checkResult(AUGraphUpdate(THIS->_audioGraph, NULL), "AUGraphUpdate");
    }
}

static void updateGraphDelayed(AEAudioController *THIS, void *userInfo, int length) {
    OSStatus result = [THIS updateGraph];
    if ( result != kAUGraphErr_NodeNotFound /* Ignore this error, it's mysterious and seems to have no consequences */ ) {
        checkResult(result, "AUGraphUpdate");
    }
}

static void removeChannelsFromGroup(AEAudioController *THIS, AEChannelGroupRef group, void **ptrs, void **userInfos, int count) {
    
    // Set new bus count of group
    UInt32 busCount = group->channelCount - count;
    assert(busCount >= 0);
    
    if ( !checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)),
                      "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    BOOL updateRequired = NO;
    
    for ( int i=0; i < count; i++ ) {
        
        // Find the channel in our fixed array
        int index = 0;
        for ( index=0; index < group->channelCount; index++ ) {
            if ( group->channels[index].ptr == ptrs[i] && group->channels[index].userInfo == userInfos[i] ) {
                group->channelCount--;
                
                // Shuffle the later elements backwards one space, disconnecting as we go
                for ( int j=index; j<group->channelCount; j++ ) {
                     int graphState = group->channels[j].graphState;
                     
                     if ( graphState & kGraphStateNodeConnected || graphState & kGraphStateRenderCallbackSet ) {
                         if ( j < busCount ) {
                             checkResult(AUGraphDisconnectNodeInput(THIS->_audioGraph, group->mixerNode, j), "AUGraphDisconnectNodeInput");
                             updateRequired = YES;
                         }
                         graphState &= ~(kGraphStateNodeConnected | kGraphStateRenderCallbackSet);
                     }
                     
                     memcpy(&group->channels[j], &group->channels[j+1], sizeof(channel_t));
                     group->channels[j].graphState = graphState;
                }
                
                // Zero out the now-unused space
                memset(&group->channels[group->channelCount], 0, sizeof(channel_t));
            }
        }
    }
    
    if ( updateRequired ) {
        OSStatus result = AUGraphUpdate(THIS->_audioGraph, NULL);
        if ( result == kAUGraphErr_CannotDoInCurrentContext ) {
            // Complete the refresh on the main thread
            AEAudioControllerSendAsynchronousMessageToMainThread(THIS, updateGroupDelayed, &group, sizeof(AEChannelGroupRef));
            return;
        } else if ( result != kAUGraphErr_NodeNotFound ) {
            checkResult(result, "AUGraphUpdate");
        }
    }
    
    updateRequired = NO;
    configureChannelsInRangeForGroup(THIS, NSMakeRange(0, group->channelCount), group, &updateRequired);
    if ( updateRequired ) {
        OSStatus result = AUGraphUpdate(THIS->_audioGraph, NULL);
        if ( result == kAUGraphErr_CannotDoInCurrentContext ) {
            AEAudioControllerSendAsynchronousMessageToMainThread(THIS, updateGraphDelayed, &group, sizeof(AEChannelGroupRef));
        }
    }
}

- (void)gatherChannelsFromGroup:(AEChannelGroupRef)group intoArray:(NSMutableArray*)array {
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self gatherChannelsFromGroup:(AEChannelGroupRef)channel->ptr intoArray:array];
        } else {
            [array addObject:(id)channel->userInfo];
        }
    }
}

- (AEChannelGroupRef)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo withinGroup:(AEChannelGroupRef)group index:(int*)index {
    // Find the matching channel in the table for the given group
    for ( int i=0; i < group->channelCount; i++ ) {
        AEChannelRef channel = &group->channels[i];
        if ( channel->ptr == ptr && channel->userInfo == userInfo ) {
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

- (void)releaseResourcesForGroup:(AEChannelGroupRef)group {
    if ( group->audioConverter ) {
        checkResult(AudioConverterDispose(group->audioConverter), "AudioConverterDispose");
        group->audioConverter = NULL;
    }
    
    if ( group->mixerNode ) {
        checkResult(AUGraphRemoveNode(_audioGraph, group->mixerNode), "AUGraphRemoveNode");
        group->mixerNode = 0;
        group->mixerAudioUnit = NULL;
    }
    
    NSArray *callbackObjects = [self associatedObjectsWithFlags:0 forChannelGroup:group];
    [callbackObjects makeObjectsPerformSelector:@selector(release)];
    
    // Release subgroup resources too
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self releaseResourcesForGroup:(AEChannelGroupRef)channel->ptr];
            channel->ptr = NULL;
        }
    }
    
    free(group);
}

- (void)markGroupTorndown:(AEChannelGroupRef)group {
    group->channel->graphState = kGraphStateUninitialized;
    group->mixerNode = 0;
    group->mixerAudioUnit = NULL;
    if ( group->level_monitor_data.scratchBuffer ) {
        free(group->level_monitor_data.scratchBuffer);
        memset(&group->level_monitor_data, 0, sizeof(audio_level_monitor_t));
    }
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = &group->channels[i];
        channel->graphState = kGraphStateUninitialized;
        if ( channel->type == kChannelTypeGroup ) {
            [self markGroupTorndown:(AEChannelGroupRef)channel->ptr];
        }
    }
}

- (BOOL)usingVPIO {
    return _voiceProcessingEnabled && _inputEnabled && (!_voiceProcessingOnlyForSpeakerAndMicrophone || _playingThroughDeviceSpeaker);
}

- (void)attemptRecoveryFromSystemError {
    int retries = 3;
    while ( retries > 0 ) {
        NSLog(@"TAAE: Trying to recover from system error (%d retries remain)", retries);
        retries--;
        
        [self stop];
        [self teardown];
        
        [NSThread sleepForTimeInterval:0.5];
        
        checkResult(AudioSessionSetActive(true), "AudioSessionSetActive");
        
        if ( [self setup] ) {
            NSLog(@"TAAE: Successfully recovered from system error");
            _hasSystemError = NO;
            [self start:NULL];
            return;
        }
    }
    
    NSLog(@"TAAE: Could not recover from system error.");
    _hasSystemError = YES;
}

#pragma mark - Callback management

static void addCallbackToTable(AEAudioController *THIS, callback_table_t *table, void *callback, void *userInfo, int flags) {
    table->callbacks[table->count].callback = callback;
    table->callbacks[table->count].userInfo = userInfo;
    table->callbacks[table->count].flags = flags;
    table->count++;
}

void removeCallbackFromTable(AEAudioController *THIS, callback_table_t *table, void *callback, void *userInfo, BOOL *found_p) {
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

- (void)addCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = &parentGroup->channels[index];
    
    [self performSynchronousMessageExchangeWithBlock:^{
        addCallbackToTable(self, &channel->callbacks, callback, userInfo, flags);
    }];
}

- (void)addCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group {
    [self performSynchronousMessageExchangeWithBlock:^{
        addCallbackToTable(self, &group->channel->callbacks, callback, userInfo, flags);
    }];

    AEChannelGroupRef parentGroup = NULL;
    int index=0;
    if ( group != _topGroup ) {
        parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
        NSAssert(parentGroup != NULL, @"Channel group not found");
    }
    
    BOOL updateRequired = NO;
    configureGraphStateOfGroupChannel(self, group->channel, parentGroup, index, &updateRequired);
    if ( updateRequired ) {
        checkResult([self updateGraph], "AUGraphUpdate");
    }
}

- (BOOL)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = &parentGroup->channels[index];
    
    __block BOOL found = NO;
    [self performSynchronousMessageExchangeWithBlock:^{
        removeCallbackFromTable(self, &channel->callbacks, callback, userInfo, &found);
    }];
    
    return found;
}

- (BOOL)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannelGroup:(AEChannelGroupRef)group {
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
    
    BOOL updateRequired = NO;
    configureGraphStateOfGroupChannel(self, group->channel, parentGroup, index, &updateRequired);
    if ( updateRequired ) {
        checkResult([self updateGraph], "AUGraphUpdate");
    }
    
    return YES;
}

- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags {
    NSArray *objects = [self associatedObjectsFromTable:&_topChannel.callbacks matchingFlag:flags];
    if ( (flags == 0 || flags & kAudiobusOutputPortFlag) && _topChannel.audiobusOutputPort ) {
        objects = [objects arrayByAddingObject:_topChannel.audiobusOutputPort];
    }
    return objects;
}

- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = &parentGroup->channels[index];
    
    NSArray *objects = [self associatedObjectsFromTable:&channel->callbacks matchingFlag:flags];
    if ( (flags == 0 || flags & kAudiobusOutputPortFlag) && channel->audiobusOutputPort ) {
        objects = [objects arrayByAddingObject:channel->audiobusOutputPort];
    }
    return objects;
}

- (NSArray*)associatedObjectsWithFlags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group {
    NSArray *objects = [self associatedObjectsFromTable:&group->channel->callbacks matchingFlag:flags];
    if ( (flags == 0 || flags & kAudiobusOutputPortFlag) && group->channel->audiobusOutputPort ) {
        objects = [objects arrayByAddingObject:group->channel->audiobusOutputPort];
    }
    return objects;
}

- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter forChannelStruct:(AEChannelRef)channel {
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        if ( (channel->callbacks.callbacks[i].flags & kVariableSpeedFilterFlag ) ) {
            // Remove the old callback
            __block BOOL found = NO;
            [self performSynchronousMessageExchangeWithBlock:^{
                removeCallbackFromTable(self, &channel->callbacks, channel->callbacks.callbacks[i].callback, channel->callbacks.callbacks[i].userInfo, &found);
            }];
            
            if ( found ) {
                [(id)(long)channel->callbacks.callbacks[i].userInfo autorelease];
            }
        }
    }
    
    if ( filter ) {
        [filter retain];
        void *callback = filter.filterCallback;
        [self performSynchronousMessageExchangeWithBlock:^{
            addCallbackToTable(self, &channel->callbacks, callback, filter, kVariableSpeedFilterFlag);
        }];
    }
}

static void handleCallbacksForChannel(AEChannelRef channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    // Pass audio to filters
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kFilterFlag ) {
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, channel->audioController, channel->ptr, inTimeStamp, inNumberFrames, ioData);
        }
    }
    
    // And finally pass to output callbacks
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kReceiverFlag ) {
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, channel->audioController, channel->ptr, inTimeStamp, inNumberFrames, ioData);
        }
    }
}

#pragma mark - Assorted helpers

static void performLevelMonitoring(audio_level_monitor_t* monitor, AudioBufferList *buffer, UInt32 numberFrames, AudioStreamBasicDescription *audioDescription) {
    if ( monitor->reset ) {
        monitor->reset  = NO;
        monitor->meanAccumulator = 0;
        monitor->meanBlockCount  = 0;
        monitor->average         = 0;
        monitor->peak            = 0;
    }
    
    UInt32 monitorFrames = min(numberFrames, kLevelMonitorScratchBufferSize/sizeof(float));
    for ( int i=0; i<buffer->mNumberBuffers; i++ ) {
        if ( audioDescription->mBitsPerChannel == 16 ) {
            vDSP_vflt16(buffer->mBuffers[i].mData, 1, monitor->scratchBuffer, 1, monitorFrames);
        } else if ( audioDescription->mBitsPerChannel == 32 ) {
            vDSP_vflt32(buffer->mBuffers[i].mData, 1, monitor->scratchBuffer, 1, monitorFrames);
        }
        float peak = 0.0;
        vDSP_maxmgv(monitor->scratchBuffer, 1, &peak, monitorFrames);
        if ( peak > monitor->peak ) monitor->peak = peak;
        float avg = 0.0;
        vDSP_meamgv(monitor->scratchBuffer, 1, &avg, monitorFrames);
        monitor->meanAccumulator += avg;
        monitor->meanBlockCount++;
        monitor->average = monitor->meanAccumulator / monitor->meanBlockCount;
    }
}

static void serveAudiobusInputQueue(AEAudioController *THIS) {
    UInt32 ioBufferLength = AEConvertSecondsToFrames(THIS, THIS->_preferredBufferDuration ? THIS->_preferredBufferDuration : 0.005);
    AudioTimeStamp timestamp;
    static Float64 __sampleTime = 0;
    AudioUnitRenderActionFlags flags = kAudiobusSourceFlag;
    while ( 1 ) {
        UInt32 frames = ABInputPortPeek(THIS->_audiobusInputPort, &timestamp);
        if ( frames == 0 ) break;
        
        frames = MIN(ioBufferLength, frames);
        timestamp.mSampleTime = __sampleTime;
        __sampleTime += frames;
        
        inputAvailableCallback(THIS, &flags, &timestamp, 0, frames, NULL);
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