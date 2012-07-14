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

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

#ifdef TRIAL
#import "AETrialModeController.h"
#endif

const int kMaximumChannelsPerGroup              = 100;
const int kMaximumCallbacksPerSource            = 15;
const int kMessageBufferLength                  = 8192;
const NSTimeInterval kIdleMessagingPollDuration = 0.1;
const int kRenderConversionScratchBufferSize    = 16384;
const int kInputAudioBufferBytes                = 8192;
const int kInputMonitorScratchBufferSize        = 8192;
const int kAudiobusSourceFlag                   = 1<<12;
const NSTimeInterval kMaxBufferDurationWithVPIO = 0.01;

NSString * AEAudioControllerSessionInterruptionBeganNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionBeganNotification";
NSString * AEAudioControllerSessionInterruptionEndedNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionEndedNotification";

const NSString *kAEAudioControllerCallbackKey = @"callback";
const NSString *kAEAudioControllerUserInfoKey = @"userinfo";

static inline int min(int a, int b) { return a>b ? b : a; }

static inline void AEAudioControllerError(OSStatus result, const char *operation, const char* file, int line) {
    int fourCC = CFSwapInt32HostToBig(result);
    NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&fourCC); 
}

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        AEAudioControllerError(result, operation, file, line);
        return NO;
    }
    return YES;
}

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
    BOOL                meteringEnabled;
    Float32             averagePower;
    Float32             peakLevel;
    BOOL                resetMeterStats;
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
typedef struct _message_t {
    AEAudioControllerMessageHandler handler;
    void                            (^responseBlock)();
    void                           *userInfoByReference;
    int                             userInfoLength;
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
    BOOL                _runningPriorToInterruption;
    
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
    BOOL                _inputLevelMonitoring;
    float               _inputMeanAccumulator;
    int                 _inputMeanBlockCount;
    Float32             _inputPeak;
    Float32             _inputAverage;
    float              *_inputMonitorScratchBuffer;
    BOOL                _resetNextInputStats;
}

- (void)pollForMainThreadMessages;
static void processPendingMessagesOnRealtimeThread(AEAudioController *THIS);

- (void)initAudioSession;
- (BOOL)setup;
- (void)teardown;
- (OSStatus)updateGraph;
- (void)setAudioSessionCategory;
- (BOOL)mustUpdateVoiceProcessingSettings;
- (void)replaceIONode;
- (void)updateInputDeviceStatus;

static BOOL initialiseGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index, BOOL *updateRequired);
static void configureGraphStateOfGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index, BOOL *updateRequired);
static void configureChannelsInRangeForGroup(AEAudioController *THIS, NSRange range, AEChannelGroupRef group, BOOL *updateRequired);

struct removeChannelsFromGroup_t { void **ptrs; void **userInfos; int count; AEChannelGroupRef group; };
static void removeChannelsFromGroup(AEAudioController *THIS, void *userInfo, int userInfoLength);

- (void)gatherChannelsFromGroup:(AEChannelGroupRef)group intoArray:(NSMutableArray*)array;
- (AEChannelGroupRef)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo index:(int*)index;
- (void)releaseResourcesForGroup:(AEChannelGroupRef)group;
- (void)markGroupTorndown:(AEChannelGroupRef)group;

struct callbackTableInfo_t { void *callback; void *userInfo; int flags; callback_table_t *table; BOOL found; };
static void addCallbackToTable(AEAudioController *THIS, void *userInfo, int length);
static void removeCallbackFromTable(AEAudioController *THIS, void *userInfo, int length);
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

@property (nonatomic, retain, readwrite) NSString *audioRoute;
@property (nonatomic, retain) ABInputPort *audiobusInputPort;
@property (nonatomic, retain) ABOutputPort *audiobusOutputPort;
@end

@implementation AEAudioController
@synthesize audioInputAvailable         = _audioInputAvailable, 
            numberOfInputChannels       = _numberOfInputChannels, 
            enableInput                 = _enableInput, 
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
        if ( [[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground || THIS->_runningPriorToInterruption ) {
            // make sure we are again the active session
            checkResult(AudioSessionSetActive(true), "AudioSessionSetActive");
        }
        
        if ( THIS->_runningPriorToInterruption ) {
            [THIS start];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerSessionInterruptionEndedNotification object:THIS];
	} else if (inInterruption == kAudioSessionBeginInterruption) {
        THIS->_runningPriorToInterruption = THIS.running;
        if ( THIS->_runningPriorToInterruption ) {
            [THIS stop];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:AEAudioControllerSessionInterruptionBeganNotification object:THIS];
    }
}

static void audioSessionPropertyListener(void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void *inData) {
    AEAudioController *THIS = (AEAudioController *)inClientData;
    
    if (inID == kAudioSessionProperty_AudioRouteChange) {
        int reason = [[(NSDictionary*)inData objectForKey:[NSString stringWithCString:kAudioSession_AudioRouteChangeKey_Reason encoding:NSUTF8StringEncoding]] intValue];
        
        CFStringRef route;
        UInt32 size = sizeof(route);
        if ( !checkResult(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route), "AudioSessionGetProperty(kAudioSessionProperty_AudioRoute)") ) return;
        
        THIS.audioRoute = [[(NSString*)route copy] autorelease];
        
        BOOL playingThroughSpeaker;
        if ( [(NSString*)route isEqualToString:@"ReceiverAndMicrophone"] ) {
            checkResult(AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, THIS), "AudioSessionRemovePropertyListenerWithUserData");
            
            // Re-route audio to the speaker (not the receiver)
            UInt32 newRoute = kAudioSessionOverrideAudioRoute_Speaker;
            checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute,  sizeof(route), &newRoute), "AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute)");
            
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
        
        if ( !updatedVP && (reason == kAudioSessionRouteChangeReason_NewDeviceAvailable || reason == kAudioSessionRouteChangeReason_OldDeviceUnavailable) ) {
            [THIS updateInputDeviceStatus];
        }
        
    } else if ( inID == kAudioSessionProperty_AudioInputAvailable ) {
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
        
        char audioBufferListSpace[sizeof(AudioBufferList)+sizeof(AudioBuffer)];

        if ( group->converterRequired ) {
            // Initialise output buffer
            bufferList = (AudioBufferList*)audioBufferListSpace;
            bufferList->mNumberBuffers = (group->audioConverterSourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? group->audioConverterSourceFormat.mChannelsPerFrame : 1;
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
        
        if ( group->meteringEnabled && group->resetMeterStats ) {
            checkResult(AudioUnitGetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_PostAveragePower, kAudioUnitScope_Output, 0, &group->averagePower), 
                        "AudioUnitGetParameter(kMultiChannelMixerParam_PostAveragePower)");

            checkResult(AudioUnitGetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_PostPeakHoldLevel, kAudioUnitScope_Output, 0, &group->peakLevel), 
                        "AudioUnitGetParameter(kMultiChannelMixerParam_PostAveragePower)");
        }
    }
    
    if ( channel->audiobusOutputPort ) {
        // Send via Audiobus
        ABOutputPortSendAudio(channel->audiobusOutputPort, audio, frames, arg->inTimeStamp.mHostTime, NULL);
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
    
    if ( THIS->_audiobusInputPort && !(*ioActionFlags & kAudiobusSourceFlag) && ABInputPortIsConnected(THIS->_audiobusInputPort) ) {
        
        // If Audiobus is connected, then serve Audiobus queue rather than serving system input queue
        UInt32 ioBufferLength = AEConvertSecondsToFrames(THIS, THIS->_preferredBufferDuration);
        AudioTimeStamp timestamp;
        static Float64 __sampleTime = 0;
        AudioUnitRenderActionFlags flags = kAudiobusSourceFlag;
        while ( 1 ) {
            UInt32 frames = ABInputPortPeek(THIS->_audiobusInputPort, &timestamp.mHostTime);
            if ( frames < ioBufferLength ) break;
            frames = MIN(ioBufferLength, frames);
            timestamp.mSampleTime = __sampleTime;
            __sampleTime += frames;
            
            inputAvailableCallback(THIS, &flags, &timestamp, 0, frames, NULL);
        }
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
            THIS->_inputAudioBufferList->mBuffers[i].mDataByteSize = kInputAudioBufferBytes;
        }
    } else {
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
    if ( THIS->_inputLevelMonitoring && THIS->_inputAudioDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger ) {
        if ( THIS->_resetNextInputStats ) {
            THIS->_resetNextInputStats  = NO;
            THIS->_inputMeanAccumulator = 0;
            THIS->_inputMeanBlockCount  = 0;
            THIS->_inputAverage         = 0;
            THIS->_inputPeak            = 0;
        }
        
        UInt32 monitorFrames = min(inNumberFrames, kInputMonitorScratchBufferSize/sizeof(float));
        for ( int i=0; i<THIS->_inputAudioBufferList->mNumberBuffers; i++ ) {
            if ( THIS->_inputAudioDescription.mBitsPerChannel == 16 ) {
                vDSP_vflt16(THIS->_inputAudioBufferList->mBuffers[i].mData, 1, THIS->_inputMonitorScratchBuffer, 1, monitorFrames);
            } else if ( THIS->_inputAudioDescription.mBitsPerChannel == 32 ) {
                vDSP_vflt32(THIS->_inputAudioBufferList->mBuffers[i].mData, 1, THIS->_inputMonitorScratchBuffer, 1, monitorFrames);
            }
            float peak = 0.0;
            vDSP_maxmgv(THIS->_inputMonitorScratchBuffer, 1, &peak, monitorFrames);
            if ( peak > THIS->_inputPeak ) THIS->_inputPeak = peak;
            float avg = 0.0;
            vDSP_meamgv(THIS->_inputMonitorScratchBuffer, 1, &avg, monitorFrames);
            THIS->_inputMeanAccumulator += avg;
            THIS->_inputMeanBlockCount++;
            THIS->_inputAverage = THIS->_inputMeanAccumulator / THIS->_inputMeanBlockCount;
        }
    }
    
    return noErr;
}

static OSStatus groupRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEChannelRef channel = (AEChannelRef)inRefCon;
    AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
    
    if ( !(*ioActionFlags & kAudioUnitRenderAction_PreRender) ) {
        // After render
        AudioBufferList *bufferList;
        
        if ( group->converterRequired ) {
            // Initialise output buffer
            char audioBufferListSpace[sizeof(AudioBufferList)+sizeof(AudioBuffer)];
            bufferList = (AudioBufferList*)audioBufferListSpace;
            bufferList->mNumberBuffers = (group->audioConverterTargetFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? group->audioConverterTargetFormat.mChannelsPerFrame : 1;
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
    }
    
    return noErr;
}

static OSStatus topRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    AEAudioController *THIS = (AEAudioController *)inRefCon;
        
    if ( *ioActionFlags & kAudioUnitRenderAction_PreRender ) {
        // Before render: Perform timing callbacks
        for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
            callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
            ((AEAudioControllerTimingCallback)callback->callback)(callback->userInfo, THIS, inTimeStamp, AEAudioTimingContextOutput);
        }
    } else {
        // After render
        if ( THIS->_topGroup->meteringEnabled && THIS->_topGroup->resetMeterStats ) {
            checkResult(AudioUnitGetParameter(THIS->_topGroup->mixerAudioUnit, kMultiChannelMixerParam_PostAveragePower, kAudioUnitScope_Output, 0, &THIS->_topGroup->averagePower), 
                        "AudioUnitGetParameter(kMultiChannelMixerParam_PostAveragePower)");
            
            checkResult(AudioUnitGetParameter(THIS->_topGroup->mixerAudioUnit, kMultiChannelMixerParam_PostPeakHoldLevel, kAudioUnitScope_Output, 0, &THIS->_topGroup->peakLevel), 
                        "AudioUnitGetParameter(kMultiChannelMixerParam_PostAveragePower)");
        }
        
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
    
    // These devices aren't fast enough to do low latency audio
    NSArray *badDevices = [NSArray arrayWithObjects:@"iPhone1,2", @"iPod1,1", @"iPod2,1", @"iPod3,1", nil];
    return ![badDevices containsObject:platform];
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription {
    return [self initWithAudioDescription:audioDescription inputEnabled:NO useVoiceProcessing:NO];
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput useVoiceProcessing:(BOOL)useVoiceProcessing {
    if ( !(self = [super init]) ) return nil;
    
    NSAssert(audioDescription.mChannelsPerFrame <= 2, @"Only mono or stereo audio supported");
    NSAssert(audioDescription.mFormatID == kAudioFormatLinearPCM, @"Only linear PCM supported");

    _audioDescription = audioDescription;
    _inputAudioDescription = audioDescription;
    _enableInput = enableInput;
    _enableBluetoothInput = YES;
    _voiceProcessingEnabled = useVoiceProcessing;
    _preferredBufferDuration = 0.005;
    _inputMode = AEInputModeFixedAudioFormat;
    _voiceProcessingOnlyForSpeakerAndMicrophone = YES;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    
    TPCircularBufferInit(&_realtimeThreadMessageBuffer, kMessageBufferLength);
    TPCircularBufferInit(&_mainThreadMessageBuffer, kMessageBufferLength);
    
    [self initAudioSession];
    
    if ( ![self setup] ) {
        [self release];
        return nil;
    }
    
#ifdef TRIAL
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AETrialModeController alloc] init];
    });
#endif
    
    return self;
}

- (void)dealloc {
    if ( _pollThread ) {
        [_pollThread cancel];
        [_pollThread release];
    }
    
    self.audiobusInputPort = nil;
    self.audiobusOutputPort = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stop];
    [self teardown];
    
    self.audioRoute = nil;
    
    self.inputChannelSelection = nil;
    
    NSArray *channels = [self channels];
    for ( NSObject *channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"playing", @"muted", @"audioDescription", nil] ) {
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
    
    if ( _inputMonitorScratchBuffer ) {
        free(_inputMonitorScratchBuffer);
    }
    
    [super dealloc];
}

- (void)start {
    NSLog(@"TAAE: Starting Engine");
    AudioSessionSetActive(true);
    
    // Determine if audio input is available, and the number of input channels available
    [self updateInputDeviceStatus];
    
    // Start messaging poll thread
    _pollThread = [[AEAudioControllerMessagePollThread alloc] initWithAudioController:self];
    _pollThread.pollInterval = kIdleMessagingPollDuration;
    OSMemoryBarrier();
    [_pollThread start];
    
    // Start things up
    checkResult(AUGraphStart(_audioGraph), "AUGraphStart");
}

- (void)stop {
    NSLog(@"TAAE: Stopping Engine");
    
    if ( self.running ) {
        if ( !checkResult(AUGraphStop(_audioGraph), "AUGraphStop") ) return;
        AudioSessionSetActive(false);
    }
    [_pollThread cancel];
    [_pollThread release];
    _pollThread = nil;
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
        
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"playing", @"muted", @"audioDescription", nil] ) {
            [(NSObject*)channel addObserver:self forKeyPath:property options:0 context:NULL];
        }
        
        AEChannelRef channelElement = &group->channels[group->channelCount++];
        
        channelElement->type        = kChannelTypeChannel;
        channelElement->ptr         = channel.renderCallback;
        channelElement->userInfo    = channel;
        channelElement->playing     = [channel respondsToSelector:@selector(playing)] ? channel.playing : YES;
        channelElement->volume      = [channel respondsToSelector:@selector(volume)] ? channel.volume : 1.0;
        channelElement->pan         = [channel respondsToSelector:@selector(pan)] ? channel.pan : 0.0;
        channelElement->muted       = [channel respondsToSelector:@selector(muted)] ? channel.muted : NO;
        channelElement->audioDescription = [channel respondsToSelector:@selector(audioDescription)] ? channel.audioDescription : _audioDescription;
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
    void* ptrMatchArray[[channels count]];
    void* userInfoMatchArray[[channels count]];
    for ( int i=0; i<[channels count]; i++ ) {
        ptrMatchArray[i] = ((id<AEAudioPlayable>)[channels objectAtIndex:i]).renderCallback;
        userInfoMatchArray[i] = [channels objectAtIndex:i];
    }
    [self performSynchronousMessageExchangeWithHandler:removeChannelsFromGroup 
                                         userInfoBytes:&(struct removeChannelsFromGroup_t){
                                             .ptrs = ptrMatchArray,
                                             .userInfos = userInfoMatchArray,
                                             .count = [channels count],
                                             .group = group } 
                                                length:sizeof(struct removeChannelsFromGroup_t)];
    
    // Finally, stop observing and release channels
    for ( NSObject *channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"playing", @"muted", @"audioDescription", nil] ) {
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
        void* ptrMatchArray[1] = { group };
        void* userInfoMatchArray[1] = { NULL };
        [self performSynchronousMessageExchangeWithHandler:removeChannelsFromGroup 
                                             userInfoBytes:&(struct removeChannelsFromGroup_t){
                                                 .ptrs = ptrMatchArray,
                                                 .userInfos = userInfoMatchArray,
                                                 .count = 1,
                                                 .group = parentGroup } 
                                                    length:sizeof(struct removeChannelsFromGroup_t)];
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
    [self performSynchronousMessageExchangeWithHandler:addCallbackToTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = filter.filterCallback,
                                             .userInfo = filter,
                                             .flags = kFilterFlag,
                                             .table = &_inputCallbacks }
                                                length:sizeof(struct callbackTableInfo_t)];
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
    struct callbackTableInfo_t arg = {
        .callback = filter.filterCallback,
        .userInfo = filter,
        .table = &_inputCallbacks };
    [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                         userInfoBytes:&arg
                                                length:sizeof(struct callbackTableInfo_t)];
    if ( arg.found ) {
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
    
    [self performSynchronousMessageExchangeWithHandler:addCallbackToTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = receiver.receiverCallback,
                                             .userInfo = receiver,
                                             .flags = kReceiverFlag,
                                             .table = &_inputCallbacks }
                                                length:sizeof(struct callbackTableInfo_t)];
}

- (void)removeInputReceiver:(id<AEAudioReceiver>)receiver {
    struct callbackTableInfo_t arg = {
        .callback = receiver.receiverCallback,
        .userInfo = receiver,
        .table = &_inputCallbacks };
    [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                         userInfoBytes:&arg
                                                length:sizeof(struct callbackTableInfo_t)];
    if ( arg.found ) {
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

    [self performSynchronousMessageExchangeWithHandler:addCallbackToTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = receiver.timingReceiverCallback,
                                             .userInfo = receiver,
                                             .table = &_timingCallbacks }
                                                length:sizeof(struct callbackTableInfo_t)];
}

- (void)removeTimingReceiver:(id<AEAudioTimingReceiver>)receiver {
    struct callbackTableInfo_t arg = {
        .callback = receiver.timingReceiverCallback,
        .userInfo = receiver,
        .table = &_timingCallbacks };
    [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                         userInfoBytes:&arg
                                                length:sizeof(struct callbackTableInfo_t)];
    if ( arg.found ) {
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
    message_t *message = TPCircularBufferTail(&THIS->_realtimeThreadMessageBuffer, &availableBytes);
    void *end = (char*)message + availableBytes;
    while ( (void*)message < (void*)end ) {
        if ( message->handler ) {
            message->handler(THIS, 
                             message->userInfoLength > 0
                                ? (message->userInfoByReference ? message->userInfoByReference : message+1) 
                                : NULL, 
                             message->userInfoLength);
        }        

        int messageLength = sizeof(message_t) + (message->userInfoLength && !message->userInfoByReference ? message->userInfoLength : 0);
        if ( message->responseBlock ) {
            TPCircularBufferProduceBytes(&THIS->_mainThreadMessageBuffer, message, messageLength);
        }
        
        message = (message_t*)((char*)message + messageLength);
    }
    
    TPCircularBufferConsume(&THIS->_realtimeThreadMessageBuffer, availableBytes);
}

-(void)pollForMainThreadMessages {
    NSAssert([NSThread isMainThread], @"Must be called on main thread");
    while ( 1 ) {
        int32_t availableBytes;
        message_t *buffer = TPCircularBufferTail(&_mainThreadMessageBuffer, &availableBytes);
        if ( !buffer ) break;
        
        int messageLength = sizeof(message_t) + (buffer->userInfoLength && !buffer->userInfoByReference ? buffer->userInfoLength : 0);
        message_t *message = malloc(messageLength);
        memcpy(message, buffer, messageLength);
        
        TPCircularBufferConsume(&_mainThreadMessageBuffer, messageLength);
    
        if ( message->responseBlock ) {
            message->responseBlock(message->userInfoLength > 0
                                   ? (message->userInfoByReference ? message->userInfoByReference : message+1) 
                                   : NULL, 
                                   message->userInfoLength);
            [message->responseBlock release];
        } else if ( message->handler ) {
            message->handler(self, 
                             message->userInfoLength > 0
                             ? (message->userInfoByReference ? message->userInfoByReference : message+1) 
                             : NULL, 
                             message->userInfoLength);
        }
        
        free(message);
        
        _pendingResponses--;
        
        if ( _pollThread && _pendingResponses == 0 ) {
            _pollThread.pollInterval = kIdleMessagingPollDuration;
        }
    }
}

- (void)performAsynchronousMessageExchangeWithHandler:(AEAudioControllerMessageHandler)handler 
                                        userInfoBytes:(void *)userInfo 
                                               length:(int)userInfoLength
                                        responseBlock:(void (^)(void *, int))responseBlock
                                  userInfoByReference:(BOOL)userInfoByReference {
    // Only perform on main thread
    if ( ![NSThread isMainThread] ) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performAsynchronousMessageExchangeWithHandler:handler userInfoBytes:userInfo length:userInfoLength responseBlock:responseBlock userInfoByReference:userInfoByReference];
        });
        return;
    }
    
    if ( responseBlock ) {
        responseBlock = [responseBlock copy];
        _pendingResponses++;
        
        if ( self.running && _pollThread.pollInterval == kIdleMessagingPollDuration ) {
            // Perform more rapid active polling while we expect a response
            _pollThread.pollInterval = _preferredBufferDuration;
        }
    }
    
    int32_t availableBytes;
    message_t *message = TPCircularBufferHead(&_realtimeThreadMessageBuffer, &availableBytes);
    assert(availableBytes >= sizeof(message_t) + (userInfoByReference ? 0 : userInfoLength));
    
    message->handler                = handler;
    message->responseBlock          = responseBlock;
    message->userInfoByReference    = userInfoByReference ? userInfo : NULL;
    message->userInfoLength         = userInfoLength;
    
    if ( !userInfoByReference && userInfoLength > 0 ) {
        memcpy((message+1), userInfo, userInfoLength);
    }
    
    TPCircularBufferProduce(&_realtimeThreadMessageBuffer, sizeof(message_t) + (userInfoByReference ? 0 : userInfoLength));
    
    if ( !self.running ) {
        processPendingMessagesOnRealtimeThread(self);
        [self pollForMainThreadMessages];
    }
}

- (void)performAsynchronousMessageExchangeWithHandler:(AEAudioControllerMessageHandler)handler 
                                        userInfoBytes:(void *)userInfo 
                                               length:(int)userInfoLength
                                        responseBlock:(void (^)(void *, int))responseBlock {
    
    [self performAsynchronousMessageExchangeWithHandler:handler 
                                          userInfoBytes:userInfo 
                                                 length:userInfoLength 
                                          responseBlock:responseBlock
                                    userInfoByReference:NO];
}

- (void)performSynchronousMessageExchangeWithHandler:(AEAudioControllerMessageHandler)handler 
                                       userInfoBytes:(void *)userInfo 
                                              length:(int)userInfoLength {
    __block BOOL finished = NO;
    
    [self performAsynchronousMessageExchangeWithHandler:handler 
                                          userInfoBytes:userInfo 
                                                 length:userInfoLength 
                                          responseBlock:^(void * userInfo, int length){ finished = YES; }
                                    userInfoByReference:YES];
    
    // Wait for response
    while ( !finished ) {
        [self pollForMainThreadMessages];
        if ( finished ) break;
        [NSThread sleepForTimeInterval:_preferredBufferDuration];
    }
}

void AEAudioControllerSendAsynchronousMessageToMainThread(AEAudioController                 *THIS, 
                                                          AEAudioControllerMessageHandler    handler, 
                                                          void                              *userInfo,
                                                          int                                userInfoLength) {
    int32_t availableBytes;
    message_t *message = TPCircularBufferHead(&THIS->_mainThreadMessageBuffer, &availableBytes);
    assert(availableBytes >= sizeof(message_t) + userInfoLength);
    
    message->handler                = handler;
    message->responseBlock          = NULL;
    message->userInfoByReference    = NULL;
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

static void enableMetering(AEAudioController *THIS, void *userInfo, int length) {
    AEChannelGroupRef group = *(AEChannelGroupRef*)userInfo;
    UInt32 enable = YES;
    checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_MeteringMode, kAudioUnitScope_Output, 0, &enable, sizeof(enable)), 
                "AudioUnitSetProperty(kAudioUnitProperty_MeteringMode)");
    group->meteringEnabled = YES;
    
}

- (void)averagePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel forGroup:(AEChannelGroupRef)group {
    if ( !group->meteringEnabled ) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSynchronousMessageExchangeWithHandler:enableMetering userInfoBytes:(void*)&group length:sizeof(AEChannelGroupRef*)];
        });
    }
    
    if ( averagePower ) *averagePower = group->averagePower;
    if ( peakLevel )    *peakLevel    = group->peakLevel;
    group->resetMeterStats = YES;
}

- (void)inputAveragePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel {
    if ( !_inputLevelMonitoring ) {
        _inputMonitorScratchBuffer = malloc(kInputMonitorScratchBufferSize);
        OSMemoryBarrier();
        _inputLevelMonitoring = YES;
    }
    
    if ( averagePower ) *averagePower = 10.0 * log10((double)_inputAverage / (_inputAudioDescription.mBitsPerChannel == 16 ? INT16_MAX : INT32_MAX));
    if ( peakLevel ) *peakLevel = 10.0 * log10((double)_inputPeak / (_inputAudioDescription.mBitsPerChannel == 16 ? INT16_MAX : INT32_MAX));;
    
    _resetNextInputStats = YES;
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

- (BOOL)running {
    if ( !_audioGraph ) return NO;
    
    Boolean isRunning = false;
    
    OSStatus result = AUGraphIsRunning(_audioGraph, &isRunning);
    if ( !checkResult(result, "AUGraphIsRunning") ) {
        return NO;
    }
    
    return isRunning;
}

-(void)setEnableInput:(BOOL)enableInput {
    _enableInput = enableInput;
    
    if ( !_ioAudioUnit ) return;
    
    if ( [self mustUpdateVoiceProcessingSettings] ) {
        [self replaceIONode];
        return;
    }
    
    [self setAudioSessionCategory];
        
    if ( _enableInput ) {
        // Enable input
        UInt32 enableInputFlag = 1;
        OSStatus result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInputFlag, sizeof(enableInputFlag));
        checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)");
        
        // Register a callback to receive audio
        AURenderCallbackStruct inRenderProc;
        inRenderProc.inputProc = &inputAvailableCallback;
        inRenderProc.inputProcRefCon = self;
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inRenderProc, sizeof(inRenderProc));
        checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_SetInputCallback)");
        
        [self updateInputDeviceStatus];
    } else {
        // Disable input
        UInt32 enableInputFlag = 0;
        OSStatus result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInputFlag, sizeof(enableInputFlag));
        checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)");
    }
    
    if ( [self usingVPIO] ) {
        // Set quality
        UInt32 quality = 127;
        OSStatus result = AudioUnitSetProperty(_ioAudioUnit, kAUVoiceIOProperty_VoiceProcessingQuality, kAudioUnitScope_Global, 1, &quality, sizeof(quality));
        checkResult(result, "AudioUnitSetProperty(kAUVoiceIOProperty_VoiceProcessingQuality)");
        
        // If we're using voice processing, clamp the buffer duration
        Float32 preferredBufferSize = MAX(kMaxBufferDurationWithVPIO, _preferredBufferDuration);
        result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
        checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    } else {
        // Set the buffer duration
        Float32 preferredBufferSize = _preferredBufferDuration;
        OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
        checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    }
}

-(void)setEnableBluetoothInput:(BOOL)enableBluetoothInput {
    _enableBluetoothInput = enableBluetoothInput;

    // Enable/disable bluetooth input
    UInt32 allowBluetoothInput = _enableBluetoothInput;
    OSStatus result = AudioSessionSetProperty (kAudioSessionProperty_OverrideCategoryEnableBluetoothInput, sizeof (allowBluetoothInput), &allowBluetoothInput);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput)");
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

-(void)setInputGain:(float)inputGain {
    Float32 inputGainScaler = inputGain;
    OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_InputGainScalar, sizeof(inputGainScaler), &inputGainScaler);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_InputGainScalar)");
}

-(void)setInputMode:(AEInputMode)inputMode {
    _inputMode = inputMode;
    
    [self updateInputDeviceStatus];
}

-(void)setInputChannelSelection:(NSArray *)inputChannelSelection {
    [inputChannelSelection retain];
    [_inputChannelSelection release];
    _inputChannelSelection = inputChannelSelection;
    
    [self updateInputDeviceStatus];
}

-(void)setPreferredBufferDuration:(float)preferredBufferDuration {
    _preferredBufferDuration = preferredBufferDuration;

    Float32 preferredBufferSize = [self usingVPIO] ? MAX(kMaxBufferDurationWithVPIO, _preferredBufferDuration) : _preferredBufferDuration;
    OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
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
        _audiobusInputPort.audioInputBlock = nil;
        [_audiobusInputPort removeObserver:self forKeyPath:@"sources"];
    }
    
    [audiobusInputPort retain];
    [_audiobusInputPort release];
    _audiobusInputPort = audiobusInputPort;

    if ( _audiobusInputPort ) {
        [_audiobusInputPort addObserver:self forKeyPath:@"sources" options:0 context:NULL];
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
        [self performSynchronousMessageExchangeWithHandler:removeAudiobusOutputPortFromChannelElement userInfoBytes:&channelElement length:sizeof(AEChannelRef)];
    } else {
        audiobusOutputPort.clientFormat = channelElement->audioDescription;
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

    if ( object == _audiobusInputPort ) {
        [self updateInputDeviceStatus];
        return;
    }
    
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

    } else if ( [keyPath isEqualToString:@"playing"] ) {
        channelElement->playing = channel.playing;
        AudioUnitParameterValue value = channel.playing && (![channel respondsToSelector:@selector(muted)] || !channel.muted);
        
        if ( group->mixerAudioUnit ) {
            OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
            checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
        }
        
        group->channels[index].playing = value;
        
    }  else if ( [keyPath isEqualToString:@"muted"] ) {
        channelElement->muted = channel.muted;
        
        if ( group->mixerAudioUnit ) {
            AudioUnitParameterValue value = ([channel respondsToSelector:@selector(playing)] ? channel.playing : YES) && !channel.muted;
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
            channelElement->audiobusOutputPort.clientFormat = channel.audioDescription;
        }
    }
}

- (void)applicationDidBecomeActive:(NSNotification*)notification {
    OSStatus status = AudioSessionSetActive(true);
    checkResult(status, "AudioSessionSetActive");
}

#pragma mark - Graph and audio session configuration

- (void)initAudioSession {
    NSMutableString *extraInfo = [NSMutableString string];
    
    // Initialise the audio session
    OSStatus result = AudioSessionInitialize(NULL, NULL, interruptionListener, self);
    if ( !checkResult(result, "AudioSessionInitialize") ) return;
    
    // Register property listeners
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioInputAvailable, audioSessionPropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    // Set preferred buffer size
    Float32 preferredBufferSize = [self usingVPIO] ? MAX(kMaxBufferDurationWithVPIO, _preferredBufferDuration) : _preferredBufferDuration;
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    [extraInfo appendFormat:@"Buffer duration %g", preferredBufferSize];
    
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
    if ( _enableInput ) {
        // See if input's available
        UInt32 size = sizeof(inputAvailable);
        OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &size, &inputAvailable);
        checkResult(result, "AudioSessionGetProperty");
        if ( inputAvailable ) [extraInfo appendFormat:@", input available"];
    }
    _audioInputAvailable = inputAvailable;
    
    [self setAudioSessionCategory];

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
            
            checkResult(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, self),
                        "AudioSessionAddPropertyListener");
            
            _playingThroughDeviceSpeaker = YES;
        } else if ( [(NSString*)route isEqualToString:@"SpeakerAndMicrophone"] || [(NSString*)route isEqualToString:@"Speaker"] ) {
            _playingThroughDeviceSpeaker = YES;
        } else {
            _playingThroughDeviceSpeaker = NO;
        }
    }
    
    NSLog(@"TAAE: Audio session initialized (%@)", extraInfo);
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

    [self setEnableInput:_enableInput];

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
        _topChannel.audioDescription = _audioDescription;
        _topChannel.audioController = self;
        _topGroup->channel   = &_topChannel;
    }
    
    // Initialise group
    BOOL unused;
    initialiseGroupChannel(self, &_topChannel, NULL, 0, &unused);
    
    // Register a callback to be notified when the main mixer unit renders
    checkResult(AudioUnitAddRenderNotify(_topGroup->mixerAudioUnit, &topRenderNotifyCallback, self), "AudioUnitAddRenderNotify");
    
    // Initialize the graph
	result = AUGraphInitialize(_audioGraph);
    if ( !checkResult(result, "AUGraphInitialize") ) return NO;
    
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
    
    // Stop graph
    checkResult(AUGraphStop(_audioGraph), "AUGraphStop");
    
    // Remove the old IO node
    checkResult(AUGraphRemoveNode(_audioGraph, _ioNode), "AUGraphRemoveNode");
    
    // Create new IO node
    if ( !checkResult(AUGraphAddNode(_audioGraph, &io_desc, &_ioNode), "AUGraphAddNode io") ) return;
    
    // Get reference to input audio unit
    if ( !checkResult(AUGraphNodeInfo(_audioGraph, _ioNode, NULL, &_ioAudioUnit), "AUGraphNodeInfo") ) return;
    
    [self setEnableInput:_enableInput];
    
    OSStatus result = AUGraphUpdate(_audioGraph, NULL);
    if ( result != kAUGraphErr_NodeNotFound /* Ignore this error */ ) checkResult(result, "AUGraphUpdate");

    [self updateInputDeviceStatus];
    
    _topChannel.graphState &= ~(kGraphStateNodeConnected | kGraphStateRenderCallbackSet);
    BOOL unused;
    configureGraphStateOfGroupChannel(self, &_topChannel, NULL, 0, &unused);
    
    checkResult(AUGraphStart(_audioGraph), "AUGraphStart");
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
    Boolean graphIsRunning;
    AUGraphIsRunning(_audioGraph, &graphIsRunning);
    if ( graphIsRunning ) {
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

- (void)setAudioSessionCategory {
    UInt32 audioCategory;
    if ( _audioInputAvailable && _enableInput ) {
        // Set the audio session category for simultaneous play and record
        audioCategory = kAudioSessionCategory_PlayAndRecord;
    } else {
        // Just playback
        audioCategory = kAudioSessionCategory_MediaPlayback;
    }
    
    UInt32 size = sizeof(audioCategory);
    UInt32 currentCategory;
    AudioSessionGetProperty(kAudioSessionProperty_AudioCategory, &size, &currentCategory);
    if ( currentCategory != audioCategory ) {
        NSLog(@"TAAE: Set audio session category to %@", audioCategory == kAudioSessionCategory_PlayAndRecord ? @"Play and record" : @"Media playback");
    }
    
    UInt32 allowMixing = YES;
    checkResult(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof (audioCategory), &audioCategory), "AudioSessionSetProperty(kAudioSessionProperty_AudioCategory");
    checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing), "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    if ( audioCategory == kAudioSessionCategory_PlayAndRecord ) {
        UInt32 toSpeaker = YES;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker, sizeof (toSpeaker), &toSpeaker), "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker)");
        [self setEnableBluetoothInput:_enableBluetoothInput];
    }
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

struct updateInputDeviceStatusHandler_t { 
    UInt32 numberOfInputChannels; 
    BOOL inputAvailable; 
    AudioStreamBasicDescription *audioDescription;
    AudioBufferList *audioBufferList;
    BOOL bufferIsAllocated;
    AudioStreamBasicDescription *rawAudioDescription;
    AudioConverterRef audioConverter;
    AudioBufferList *scratchBuffer;
};
static void updateInputDeviceStatusHandler(AEAudioController *THIS, void* userInfo, int length) {
    struct updateInputDeviceStatusHandler_t *arg = userInfo;
    
    if ( !THIS->_audiobusInputPort || !ABInputPortIsConnected(THIS->_audiobusInputPort) ) {
        AudioStreamBasicDescription currentAudioDescription;
        UInt32 size = sizeof(currentAudioDescription);
        OSStatus result = AudioUnitGetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &currentAudioDescription, &size);
        checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
        
        if ( memcmp(&currentAudioDescription, arg->rawAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
            result = AudioUnitSetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, arg->rawAudioDescription, sizeof(AudioStreamBasicDescription));
            checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        }
    }
    
    THIS->_numberOfInputChannels    = arg->numberOfInputChannels;
    THIS->_inputAudioDescription    = *arg->audioDescription;
    THIS->_audioInputAvailable      = arg->inputAvailable;
    THIS->_inputAudioBufferList     = arg->audioBufferList;
    THIS->_inputAudioBufferListBuffersAreAllocated = arg->bufferIsAllocated;
    THIS->_inputAudioConverter      = arg->audioConverter;
    THIS->_inputAudioScratchBufferList = arg->scratchBuffer;
}

- (void)updateInputDeviceStatus {
    UInt32 inputAvailable=0;
    
    if ( _enableInput ) {
        // Determine if audio input is available, and the number of input channels available
        AudioStreamBasicDescription rawAudioDescription = _audioDescription;
        UInt32 numberOfInputChannels = rawAudioDescription.mChannelsPerFrame;
        
        if ( _audiobusInputPort && ABInputPortIsConnected(_audiobusInputPort) ) {
            inputAvailable = YES;
            rawAudioDescription = _audioDescription;
            numberOfInputChannels = _audioDescription.mChannelsPerFrame;
        } else {
            UInt32 size = sizeof(inputAvailable);
            OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &size, &inputAvailable);
            checkResult(result, "AudioSessionGetProperty");
            
            numberOfInputChannels = 0;
            size = sizeof(numberOfInputChannels);
            if ( inputAvailable ) {
                // Check channels on input
                OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels, &size, &numberOfInputChannels);
                if ( !checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels)") ) {
                    return;
                }
            }
        }
        
        if ( _inputMode == AEInputModeVariableAudioFormat ) {
            // Set the input audio description channels to the number of actual available channels
            if ( !(rawAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ) {
                rawAudioDescription.mBytesPerFrame *= (float)numberOfInputChannels / rawAudioDescription.mChannelsPerFrame;
                rawAudioDescription.mBytesPerPacket *= (float)numberOfInputChannels / rawAudioDescription.mChannelsPerFrame;
            }
            rawAudioDescription.mChannelsPerFrame = numberOfInputChannels;
        }
        
        AudioStreamBasicDescription inputAudioDescription = rawAudioDescription;

        if ( [_inputChannelSelection count] > 0 && _inputMode == AEInputModeVariableAudioFormat ) {
            // Set the target input audio description channels to the number of selected channels
            int channels = MIN(2, [_inputChannelSelection count]);
            if ( !(inputAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ) {
                inputAudioDescription.mBytesPerFrame *= (float)channels / inputAudioDescription.mChannelsPerFrame;
                inputAudioDescription.mBytesPerPacket *= (float)channels / inputAudioDescription.mChannelsPerFrame;
            }
            inputAudioDescription.mChannelsPerFrame = channels;
        }
        
        AudioBufferList *inputBufferList = _inputAudioBufferList;
        BOOL bufferIsAllocated = _inputAudioBufferListBuffersAreAllocated;
        
        BOOL inputBufferListBuffersWereAllocated = _inputAudioBufferListBuffersAreAllocated;
        
        AudioConverterRef converter = _inputAudioConverter;
        AudioBufferList *scratchBuffer = _inputAudioScratchBufferList;
        AudioConverterRef oldConverter = converter;
        AudioBufferList *oldScratchBuffer = scratchBuffer;
        
        // Determine if conversion is required
        BOOL channelMapRequired = inputAudioDescription.mChannelsPerFrame != numberOfInputChannels || (_inputChannelSelection && [_inputChannelSelection count] != inputAudioDescription.mChannelsPerFrame);
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
            
            AudioStreamBasicDescription converterFormat;
            UInt32 formatSize = sizeof(converterFormat);
            
            UInt32 mappingSize = 0;
            if ( converter ) {
                checkResult(AudioConverterGetPropertyInfo(converter, kAudioConverterChannelMap, &mappingSize, NULL),
                            "AudioConverterGetPropertyInfo(kAudioConverterChannelMap)");
            }
            SInt32 *mapping = (SInt32*)(mappingSize != 0 ? malloc(mappingSize) : NULL);
            
            if ( converter ) {
                checkResult(AudioConverterGetProperty(converter, kAudioConverterChannelMap, &formatSize, &converterFormat),
                            "AudioConverterGetProperty(kAudioConverterCurrentInputStreamDescription)");
                checkResult(AudioConverterGetProperty(converter, kAudioConverterChannelMap, &mappingSize, mapping),
                            "AudioConverterGetProperty(kAudioConverterCurrentInputStreamDescription)");
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
                    || memcmp(&converterFormat, &rawAudioDescription, sizeof(AudioStreamBasicDescription)) != 0
                    || (mappingSize != targetMappingSize || memcmp(mapping, targetMapping, targetMappingSize)) ) {
                checkResult(AudioConverterNew(&rawAudioDescription, &inputAudioDescription, &converter), "AudioConverterNew");
                scratchBuffer = AEAllocateAndInitAudioBufferList(rawAudioDescription, 0);
                inputBufferList = AEAllocateAndInitAudioBufferList(inputAudioDescription, kInputAudioBufferBytes / inputAudioDescription.mBytesPerFrame);
                bufferIsAllocated = YES;
                
                checkResult(AudioConverterSetProperty(converter, kAudioConverterChannelMap, targetMappingSize, targetMapping), "AudioConverterSetProperty(kAudioConverterChannelMap");
            }
            
            if ( targetMapping) free(targetMapping);
            if ( mapping ) free(mapping);
        } else {
            converter = NULL;
            scratchBuffer = NULL;
        }
        
        BOOL inputChannelsChanged = _numberOfInputChannels != numberOfInputChannels;
        BOOL inputAvailableChanged = _audioInputAvailable != inputAvailable;
        
        if ( !_inputAudioBufferList || memcmp(&inputAudioDescription, &_inputAudioDescription, sizeof(inputAudioDescription)) != 0 ) {
            if ( !converter ) {
                inputBufferList = AEAllocateAndInitAudioBufferList(inputAudioDescription, 0);
                bufferIsAllocated = NO;
            }
            inputChannelsChanged = YES;
            [self willChangeValueForKey:@"numberOfInputChannels"];
            [self willChangeValueForKey:@"inputAudioDescription"];
        }
        
        if ( inputAvailableChanged ) {
            [self willChangeValueForKey:@"audioInputAvailable"];
        }
        
        AudioBufferList *oldInputBuffer = _inputAudioBufferList;
        
        // Set input stream format and update the properties
        [self performSynchronousMessageExchangeWithHandler:updateInputDeviceStatusHandler
                                             userInfoBytes:&(struct updateInputDeviceStatusHandler_t){
                                                 .numberOfInputChannels = numberOfInputChannels,
                                                 .inputAvailable = inputAvailable,
                                                 .audioDescription = &inputAudioDescription,
                                                 .audioBufferList = inputBufferList,
                                                 .bufferIsAllocated = bufferIsAllocated ,
                                                 .rawAudioDescription = &rawAudioDescription,
                                                 .audioConverter = converter,
                                                 .scratchBuffer = scratchBuffer }
                                                    length:sizeof(struct callbackTableInfo_t)];
        
        if ( oldInputBuffer && oldInputBuffer != _inputAudioBufferList ) {
            if ( inputBufferListBuffersWereAllocated ) {
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
        
        if ( _audiobusInputPort ) {
            AudioStreamBasicDescription clientFormat = _audiobusInputPort.clientFormat;
            if ( memcmp(&clientFormat, &inputAudioDescription, sizeof(AudioStreamBasicDescription)) != 0 ) {
                _audiobusInputPort.clientFormat = inputAudioDescription;
            }
        }
        
        if ( inputAvailableChanged ) {
            [self didChangeValueForKey:@"audioInputAvailable"];
        }
        
        if ( inputChannelsChanged || inputAvailableChanged || oldConverter != converter || (oldInputBuffer && oldInputBuffer != _inputAudioBufferList) || (oldScratchBuffer && oldScratchBuffer != scratchBuffer) ) {
            NSLog(@"TAAE: Input status updated (%lu channel, %@%@%@)",
                  numberOfInputChannels,
                  inputAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? @"non-interleaved" : @"interleaved",
                  useVoiceProcessing ? @", using voice processing" : @"",
                  converter ? @", with converter" : @"");
        }
    }
    
    [self setAudioSessionCategory];
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

static void configureGraphStateOfGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index, BOOL *updateRequired) {
    AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
    
    BOOL outputCallbacks=NO, filters=NO;
    for ( int i=0; i<channel->callbacks.count && (!outputCallbacks || !filters); i++ ) {
        if ( channel->callbacks.callbacks[i].flags & (kFilterFlag | kVariableSpeedFilterFlag) ) {
            filters = YES;
        } else if ( channel->callbacks.callbacks[i].flags & kReceiverFlag ) {
            outputCallbacks = YES;
        }
    }
    
    Boolean wasRunning = false;
    OSStatus result = AUGraphIsRunning(THIS->_audioGraph, &wasRunning);
    checkResult(result, "AUGraphIsRunning");

    if ( (outputCallbacks || filters || channel->audiobusOutputPort) && group->converterRequired && !group->audioConverter ) {
        // Initialise audio converter if necessary
        
        // Get mixer's output stream format
        AudioStreamBasicDescription mixerFormat;
        UInt32 size = sizeof(mixerFormat);
        if ( !checkResult(AudioUnitGetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mixerFormat, &size), 
                          "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") ) return;
        
        group->audioConverterTargetFormat = THIS->_audioDescription;
        group->audioConverterSourceFormat = mixerFormat;
        
        // Create audio converter
        if ( !checkResult(AudioConverterNew(&mixerFormat, &THIS->_audioDescription, &group->audioConverter), 
                          "AudioConverterNew") ) return;
        
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
            if ( checkResult(AUGraphDisconnectNodeInput(THIS->_audioGraph, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0), "AUGraphDisconnectNodeInput") ) {
                channel->graphState &= ~kGraphStateNodeConnected;
                checkResult(AUGraphUpdate(THIS->_audioGraph, NULL), "AUGraphUpdate");
            }
        }
        
        if ( channel->graphState & kGraphStateRenderNotificationSet ) {
            // Remove render notification callback
            if ( checkResult(AudioUnitRemoveRenderNotify(group->mixerAudioUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify") ) {
                channel->graphState &= ~kGraphStateRenderNotificationSet;
            }
        }

        // Set stream format for callback
        checkResult(AudioUnitSetProperty(parentGroup ? parentGroup->mixerAudioUnit : THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, parentGroup ? index : 0, &THIS->_audioDescription, sizeof(THIS->_audioDescription)),
                    "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        
        if ( !(channel->graphState & kGraphStateRenderCallbackSet) ) {
            // Add the render callback
            AURenderCallbackStruct rcbs;
            rcbs.inputProc = &renderCallback;
            rcbs.inputProcRefCon = channel;
            if ( checkResult(AUGraphSetNodeInputCallback(THIS->_audioGraph, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0, &rcbs), "AUGraphSetNodeInputCallback") ) {
                channel->graphState |= kGraphStateRenderCallbackSet;
            }
            *updateRequired = YES;
        }
        
    } else {
        if ( channel->graphState & kGraphStateRenderCallbackSet ) {
            // Remove the render callback
            if ( checkResult(AUGraphDisconnectNodeInput(THIS->_audioGraph, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0), "AUGraphDisconnectNodeInput") ) {
                channel->graphState &= ~kGraphStateRenderCallbackSet;
                checkResult(AUGraphUpdate(THIS->_audioGraph, NULL), "AUGraphUpdate");
            }
        }
        
        if ( !(channel->graphState & kGraphStateNodeConnected) ) {
            // Connect output of mixer directly to the parent mixer
            if ( checkResult(AUGraphConnectNodeInput(THIS->_audioGraph, group->mixerNode, 0, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0), "AUGraphConnectNodeInput") ) {
                channel->graphState |= kGraphStateNodeConnected;
            }
            *updateRequired = YES;
        }
        
        if ( outputCallbacks ) {
            // We need to register a callback to be notified when the mixer renders, to pass on the audio
            if ( !(channel->graphState & kGraphStateRenderNotificationSet) ) {
                // Add render notification callback
                if ( checkResult(AudioUnitAddRenderNotify(group->mixerAudioUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify") ) {
                    channel->graphState |= kGraphStateRenderNotificationSet;
                }
            }
        } else {
            if ( channel->graphState & kGraphStateRenderNotificationSet ) {
                // Remove render notification callback
                if ( checkResult(AudioUnitRemoveRenderNotify(group->mixerAudioUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify") ) {
                    channel->graphState &= ~kGraphStateRenderNotificationSet;
                }
            }
        }
    }
    
    if ( !outputCallbacks && !filters && group->audioConverter && !(channel->graphState & kGraphStateRenderCallbackSet) ) {
        // Cleanup audio converter
        AudioConverterDispose(group->audioConverter);
        group->audioConverter = NULL;
    }
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

static void removeChannelsFromGroup(AEAudioController *THIS, void *userInfo, int userInfoLength) {
    struct removeChannelsFromGroup_t *args = userInfo;
    
    // Set new bus count of group
    UInt32 busCount = args->group->channelCount - args->count;
    assert(busCount >= 0);
    
    if ( !checkResult(AudioUnitSetProperty(args->group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)),
                      "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    BOOL updateRequired = NO;
    
    for ( int i=0; i < args->count; i++ ) {
        
        // Find the channel in our fixed array
        int index = 0;
        for ( index=0; index < args->group->channelCount; index++ ) {
            if ( args->group->channels[index].ptr == args->ptrs[i] && args->group->channels[index].userInfo == args->userInfos[i] ) {
                args->group->channelCount--;
                
                // Shuffle the later elements backwards one space, disconnecting as we go
                for ( int j=index; j<args->group->channelCount; j++ ) {
                     int graphState = args->group->channels[j].graphState;
                     
                     if ( graphState & kGraphStateNodeConnected || graphState & kGraphStateRenderCallbackSet ) {
                         if ( j < busCount ) {
                             checkResult(AUGraphDisconnectNodeInput(THIS->_audioGraph, args->group->mixerNode, j), "AUGraphDisconnectNodeInput");
                             updateRequired = YES;
                         }
                         graphState &= ~(kGraphStateNodeConnected | kGraphStateRenderCallbackSet);
                     }
                     
                     memcpy(&args->group->channels[j], &args->group->channels[j+1], sizeof(channel_t));
                     args->group->channels[j].graphState = graphState;
                }
                
                // Zero out the now-unused space
                memset(&args->group->channels[args->group->channelCount], 0, sizeof(channel_t));
            }
        }
    }
    
    if ( updateRequired ) {
        OSStatus result = AUGraphUpdate(THIS->_audioGraph, NULL);
        if ( result == kAUGraphErr_CannotDoInCurrentContext ) {
            // Complete the refresh on the main thread
            AEAudioControllerSendAsynchronousMessageToMainThread(THIS, updateGroupDelayed, &args->group, sizeof(AEChannelGroupRef));
            return;
        } else if ( result != kAUGraphErr_NodeNotFound ) {
            checkResult(result, "AUGraphUpdate");
        }
    }
    
    updateRequired = NO;
    configureChannelsInRangeForGroup(THIS, NSMakeRange(0, args->group->channelCount), args->group, &updateRequired);
    if ( updateRequired ) {
        OSStatus result = AUGraphUpdate(THIS->_audioGraph, NULL);
        if ( result == kAUGraphErr_CannotDoInCurrentContext ) {
            AEAudioControllerSendAsynchronousMessageToMainThread(THIS, updateGraphDelayed, &args->group, sizeof(AEChannelGroupRef));
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
    group->meteringEnabled = NO;
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = &group->channels[i];
        channel->graphState = kGraphStateUninitialized;
        if ( channel->type == kChannelTypeGroup ) {
            [self markGroupTorndown:(AEChannelGroupRef)channel->ptr];
        }
    }
}

- (BOOL)usingVPIO {
    return _voiceProcessingEnabled && _enableInput && (!_voiceProcessingOnlyForSpeakerAndMicrophone || _playingThroughDeviceSpeaker);
}

#pragma mark - Callback management

static void addCallbackToTable(AEAudioController *THIS, void *userInfo, int length) {
    struct callbackTableInfo_t *arg = userInfo;
    
    callback_table_t* table = arg->table;
    
    table->callbacks[table->count].callback = arg->callback;
    table->callbacks[table->count].userInfo = arg->userInfo;
    table->callbacks[table->count].flags = arg->flags;
    table->count++;
}

void removeCallbackFromTable(AEAudioController *THIS, void *userInfo, int length) {
    struct callbackTableInfo_t *arg = userInfo;
    
    callback_table_t* table = arg->table;
    arg->found = NO;
    
    // Find the item in our fixed array
    int index = 0;
    for ( index=0; index<table->count; index++ ) {
        if ( table->callbacks[index].callback == arg->callback && table->callbacks[index].userInfo == arg->userInfo ) {
            arg->found = YES;
            break;
        }
    }
    if ( arg->found ) {
        // Now shuffle the later elements backwards one space
        table->count--;
        for ( int i=index; i<table->count; i++ ) {
            table->callbacks[i] = table->callbacks[i+1];
        }
    }
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
    
    [self performSynchronousMessageExchangeWithHandler:addCallbackToTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = callback,
                                             .userInfo = userInfo,
                                             .flags = flags,
                                             .table = &channel->callbacks }
                                                length:sizeof(struct callbackTableInfo_t)];
}

- (void)addCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group {
    [self performSynchronousMessageExchangeWithHandler:addCallbackToTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = callback,
                                             .userInfo = userInfo,
                                             .flags = flags,
                                             .table = &group->channel->callbacks }
                                                length:sizeof(struct callbackTableInfo_t)];

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
    
    struct callbackTableInfo_t arg = {
        .callback = callback,
        .userInfo = userInfo,
        .table = &channel->callbacks };
    [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                         userInfoBytes:&arg
                                                length:sizeof(struct callbackTableInfo_t)];
    return arg.found;
}

- (BOOL)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannelGroup:(AEChannelGroupRef)group {
    struct callbackTableInfo_t arg = {
        .callback = callback,
        .userInfo = userInfo,
        .table = &group->channel->callbacks };
    [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                         userInfoBytes:&arg
                                                length:sizeof(struct callbackTableInfo_t)];
    
    if ( !arg.found ) return NO;
    
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
            struct callbackTableInfo_t arg = {
                .callback = channel->callbacks.callbacks[i].callback,
                .userInfo = channel->callbacks.callbacks[i].userInfo,
                .table = &channel->callbacks };
            [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                                 userInfoBytes:&arg
                                                        length:sizeof(struct callbackTableInfo_t)];
            if ( arg.found ) {
                [(id)(long)channel->callbacks.callbacks[i].userInfo autorelease];
            }
        }
    }
    
    if ( filter ) {
        [filter retain];
        [self performSynchronousMessageExchangeWithHandler:addCallbackToTable
                                             userInfoBytes:&(struct callbackTableInfo_t){
                                                 .callback = filter.filterCallback,
                                                 .userInfo = filter,
                                                 .flags = kVariableSpeedFilterFlag,
                                                 .table = &channel->callbacks }
                                                    length:sizeof(struct callbackTableInfo_t)];
        
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
    self.name = @"com.theamazingaudioengine.AEAudioControllerMessagePollThread";
    return self;
}
-(void)main {
    while ( ![self isCancelled] ) {
        if ( AEAudioControllerHasPendingMainThreadMessages(_audioController) ) {
            [_audioController performSelectorOnMainThread:@selector(pollForMainThreadMessages) withObject:nil waitUntilDone:YES];
        }
        usleep(_pollInterval*1.0e6);
    }
}
@end