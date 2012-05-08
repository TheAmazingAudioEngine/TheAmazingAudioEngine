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

#ifdef TRIAL
#import "AETrialModeController.h"
#endif

const int kMaximumChannelsPerGroup              = 100;
const int kMaximumCallbacksPerSource            = 15;
const int kMessageBufferLength                  = 8192;
const NSTimeInterval kIdleMessagingPollDuration = 0.1;
const int kRenderConversionScratchBufferSize    = 16384;
const int kInputMonitorScratchBufferSize        = 8192;
const int kAudiobusSourceFlag                   = 1<<12;

NSString * AEAudioControllerSessionInterruptionBeganNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionBeganNotification";
NSString * AEAudioControllerSessionInterruptionEndedNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionEndedNotification";

const NSString *kAEAudioControllerCallbackKey = @"callback";
const NSString *kAEAudioControllerUserInfoKey = @"userinfo";

static inline int min(int a, int b) { return a>b ? b : a; }

static inline void AEAudioControllerError(OSStatus result, const char *operation, const char* file, int line) {
    NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
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
    kCallbackIsFilterFlag               = 1<<0,
    kCallbackIsOutputCallbackFlag       = 1<<1,
    kCallbackIsVariableSpeedFilterFlag  = 1<<2
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
    AEAudioController *audioController;
} channel_t, *AEChannelRef;

/*!
 * Group graph state
 */
enum {
    kGroupGraphStateUninitialized         = 0,
    kGroupGraphStateNodeConnected         = 1<<0,
    kGroupGraphStateRenderNotificationSet = 1<<1,
    kGroupGraphStateRenderCallbackSet     = 1<<2
};

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
    int                 graphState;
    BOOL                meteringEnabled;
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
    AudioStreamBasicDescription _audioDescription;
    AudioStreamBasicDescription _inputAudioDescription;
    
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
- (void)updateVoiceProcessingSettings;
- (void)updateInputDeviceStatus;

static BOOL initialiseGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index);
static void configureGraphStateOfGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index);
static void configureChannelsInRangeForGroup(AEAudioController *THIS, NSRange range, AEChannelGroupRef group);

struct removeChannelsFromGroup_t { void **ptrs; void **userInfos; int count; AEChannelGroupRef group; };
static void removeChannelsFromGroup(AEAudioController *THIS, void *userInfo, int userInfoLength);

- (void)gatherChannelsFromGroup:(AEChannelGroupRef)group intoArray:(NSMutableArray*)array;
- (AEChannelGroupRef)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo index:(int*)index;
- (void)releaseResourcesForGroup:(AEChannelGroupRef)group;
- (void)markGroupTorndown:(AEChannelGroupRef)group;

struct callbackTableInfo_t { void *callback; void *userInfo; int flags; callback_table_t *table; };
static void addCallbackToTable(AEAudioController *THIS, void *userInfo, int length);
static void removeCallbackFromTable(AEAudioController *THIS, void *userInfo, int length);
- (NSArray *)objectsAssociatedWithCallbacksFromTable:(callback_table_t*)table matchingFlag:(uint8_t)flag;
- (void)addCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj;
- (void)addCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group;
- (void)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannel:(id<AEAudioPlayable>)channelObj;
- (void)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannelGroup:(AEChannelGroupRef)group;
- (NSArray*)objectsAssociatedWithCallbacksWithFlags:(uint8_t)flags;
- (NSArray*)objectsAssociatedWithCallbacksWithFlags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj;
- (NSArray*)objectsAssociatedWithCallbacksWithFlags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group;
- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter forChannelStruct:(AEChannelRef)channel;
static void handleCallbacksForChannel(AEChannelRef channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData);

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
            audioUnit                   = _ioAudioUnit,
            audiobusInputPort           = _audiobusInputPort,
            audiobusOutputPort          = _audiobusOutputPort;

@dynamic    running, inputGainAvailable, inputGain, audioDescription, inputAudioDescription;

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
        int reason = [[(NSDictionary*)inData objectForKey:(id)kAudioSession_RouteChangeKey_Reason] intValue];
        
        CFStringRef route;
        UInt32 size = sizeof(route);
        if ( !checkResult(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route), "AudioSessionGetProperty(kAudioSessionProperty_AudioRoute)") ) return;
        
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
        
        if ( reason == kAudioSessionRouteChangeReason_NewDeviceAvailable || reason == kAudioSessionRouteChangeReason_OldDeviceUnavailable ) {
            [THIS updateInputDeviceStatus];
        }
        
        if ( THIS->_playingThroughDeviceSpeaker != playingThroughSpeaker ) {
            [THIS willChangeValueForKey:@"playingThroughDeviceSpeaker"];
            THIS->_playingThroughDeviceSpeaker = playingThroughSpeaker;
            [THIS didChangeValueForKey:@"playingThroughDeviceSpeaker"];
            
            if ( THIS->_voiceProcessingEnabled && THIS->_voiceProcessingOnlyForSpeakerAndMicrophone ) {
                [THIS updateVoiceProcessingSettings];
            }
        }
    } else if ( inID == kAudioSessionProperty_AudioInputAvailable ) {
        [THIS updateInputDeviceStatus];
    }
}

#pragma mark -
#pragma mark Input and render callbacks

static OSStatus channelAudioProducer(void *userInfo, AudioBufferList *audio, UInt32 frames) {
    channel_producer_arg_t *arg = (channel_producer_arg_t*)userInfo;
    AEChannelRef channel = arg->channel;
    
    OSStatus status = noErr;
    
    if ( channel->type == kChannelTypeChannel ) {
        AEAudioControllerRenderCallback callback = (AEAudioControllerRenderCallback) channel->ptr;
        id<AEAudioPlayable> channelObj = (id<AEAudioPlayable>) channel->userInfo;
        
        for ( int i=0; i<audio->mNumberBuffers; i++ ) {
            memset(audio->mBuffers[i].mData, 0, audio->mBuffers[i].mDataByteSize);
        }
        
        status = callback(channelObj, channel->audioController, &arg->inTimeStamp, frames, audio);
        
    } else if ( channel->type == kChannelTypeGroup ) {
        AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
        
        AudioBufferList *bufferList;
        
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
            
        } else {
            // We can render straight to the buffer, as audio format is the same
            bufferList = audio;
        }
        
        // Tell mixer to render into bufferList
        OSStatus status = AudioUnitRender(group->mixerAudioUnit, arg->ioActionFlags, &arg->inTimeStamp, 0, frames, bufferList);
        if ( !checkResult(status, "AudioUnitRender") ) return status;
        
        if ( group->converterRequired ) {
            // Perform conversion
            status = AudioConverterConvertComplexBuffer(group->audioConverter, frames, bufferList, audio);
            checkResult(status, "AudioConverterConvertComplexBuffer");
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
        if ( callback->flags & kCallbackIsVariableSpeedFilterFlag ) {
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
    
    for ( int i=0; i<THIS->_inputAudioBufferList->mNumberBuffers; i++ ) {
        THIS->_inputAudioBufferList->mBuffers[i].mData = NULL;
        THIS->_inputAudioBufferList->mBuffers[i].mDataByteSize = 0;
    }
    
    // Render audio into buffer
    if ( *ioActionFlags & kAudiobusSourceFlag && ABInputPortReceive != NULL ) {
        ABInputPortReceive(THIS->_audiobusInputPort, nil, THIS->_inputAudioBufferList, &inNumberFrames, NULL, NULL);
    } else {
        OSStatus err = AudioUnitRender(THIS->_ioAudioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, THIS->_inputAudioBufferList);
        if ( !checkResult(err, "AudioUnitRender") ) { 
            return err; 
        }
    }
    
    // Pass audio to input filters, then callbacks
    for ( int type=kCallbackIsFilterFlag; ; type = kCallbackIsOutputCallbackFlag ) {
        for ( int i=0; i<THIS->_inputCallbacks.count; i++ ) {
            callback_t *callback = &THIS->_inputCallbacks.callbacks[i];
            if ( !(callback->flags & type) ) continue;
            
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, THIS, AEAudioSourceInput, inTimeStamp, inNumberFrames, THIS->_inputAudioBufferList);
        }
        if ( type == kCallbackIsOutputCallbackFlag ) break;
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
            vDSP_maxmgv(THIS->_inputMonitorScratchBuffer, 1, &THIS->_inputPeak, monitorFrames);
            float avg;
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
            if ( !checkResult(AudioConverterConvertComplexBuffer(group->audioConverter, inNumberFrames, ioData, bufferList),
                              "AudioConverterConvertComplexBuffer") ) {
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
        if ( THIS->_audiobusOutputPort ) {
            ABOutputPortSendAudio(THIS->_audiobusOutputPort, ioData, inNumberFrames, inTimeStamp->mHostTime, NULL);
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
    
    if ( _inputAudioBufferList ) {
        for ( int i=0; i<_inputAudioBufferList->mNumberBuffers; i++ ) free(_inputAudioBufferList->mBuffers[i].mData);
        free(_inputAudioBufferList);
    }
    
    if ( _inputMonitorScratchBuffer ) {
        free(_inputMonitorScratchBuffer);
    }
    
    [super dealloc];
}

- (void)start {
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
        channelElement->audioDescription = [channel respondsToSelector:@selector(audioDescription)] ? *channel.audioDescription : _audioDescription;
        channelElement->audioController = self;
    }
    
    // Set bus count
    UInt32 busCount = group->channelCount;
    OSStatus result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // Configure each channel
    configureChannelsInRangeForGroup(self, NSMakeRange(group->channelCount - [channels count], [channels count]), group);
    
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
    // Get a list of all the callback objects for these channels
    NSMutableArray *callbackObjects = [NSMutableArray array];
    for ( id<AEAudioPlayable> channel in channels ) {
        NSArray *objects = [self objectsAssociatedWithCallbacksWithFlags:0 forChannel:channel];
        [callbackObjects addObjectsFromArray:objects];
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
    
    // And release the associated callback objects
    [callbackObjects makeObjectsPerformSelector:@selector(release)];
}


- (void)removeChannelGroup:(AEChannelGroupRef)group {
    
    // Find group's parent
    AEChannelGroupRef parentGroup = (group == _topGroup ? NULL : [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:NULL]);
    NSAssert(group == _topGroup || parentGroup != NULL, @"Channel group not found");
    
    // Get a list of contained channels
    NSMutableArray *channelsWithinGroup = [NSMutableArray array];
    [self gatherChannelsFromGroup:group intoArray:channelsWithinGroup];
    
    // Get a list of all the callback objects for these channels
    NSMutableArray *channelCallbackObjects = [NSMutableArray array];
    for ( id<AEAudioPlayable> channel in channelsWithinGroup ) {
        NSArray *objects = [self objectsAssociatedWithCallbacksWithFlags:0 forChannel:channel];
        [channelCallbackObjects addObjectsFromArray:objects];
    }
    
    // Get a list of callback objects for this group
    NSArray *groupCallbackObjects = [self objectsAssociatedWithCallbacksWithFlags:0 forChannelGroup:group];
    
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
    [channelCallbackObjects makeObjectsPerformSelector:@selector(release)];
    
    // Release group resources
    [groupCallbackObjects makeObjectsPerformSelector:@selector(release)];
    
    // Release subgroup resources
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self releaseResourcesForGroup:(AEChannelGroupRef)channel->ptr];
            channel->ptr = NULL;
        }
    }
    
    free(group);
    
    checkResult([self updateGraph], "Update graph");
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
    initialiseGroupChannel(self, channel, parentGroup, groupIndex);

    checkResult([self updateGraph], "Update graph");
    
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
    [self addCallback:filter.filterCallback userInfo:filter flags:kCallbackIsFilterFlag forChannelGroup:_topGroup];
}

- (void)addFilter:(id<AEAudioFilter>)filter toChannel:(id<AEAudioPlayable>)channel {
    [filter retain];
    [self addCallback:filter.filterCallback userInfo:filter flags:kCallbackIsFilterFlag forChannel:channel];
}

- (void)addFilter:(id<AEAudioFilter>)filter toChannelGroup:(AEChannelGroupRef)group {
    [filter retain];
    [self addCallback:filter.filterCallback userInfo:filter flags:kCallbackIsFilterFlag forChannelGroup:group];
}

- (void)addInputFilter:(id<AEAudioFilter>)filter {
    [filter retain];
    [self performSynchronousMessageExchangeWithHandler:addCallbackToTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = filter.filterCallback,
                                             .userInfo = filter,
                                             .flags = kCallbackIsFilterFlag,
                                             .table = &_inputCallbacks }
                                                length:sizeof(struct callbackTableInfo_t)];
}

- (void)removeFilter:(id<AEAudioFilter>)filter {
    [self removeCallback:filter.filterCallback userInfo:filter fromChannelGroup:_topGroup];
    [filter release];
}

- (void)removeFilter:(id<AEAudioFilter>)filter fromChannel:(id<AEAudioPlayable>)channel {
    [self removeCallback:filter.filterCallback userInfo:filter fromChannel:channel];
    [filter release];
}

- (void)removeFilter:(id<AEAudioFilter>)filter fromChannelGroup:(AEChannelGroupRef)group {
    [self removeCallback:filter.filterCallback userInfo:filter fromChannelGroup:group];
    [filter release];
}

- (void)removeInputFilter:(id<AEAudioFilter>)filter {
    [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = filter.filterCallback,
                                             .userInfo = filter,
                                             .table = &_inputCallbacks }
                                                length:sizeof(struct callbackTableInfo_t)];
    [filter release];
}

- (NSArray*)filters {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsFilterFlag];
}

- (NSArray*)filtersForChannel:(id<AEAudioPlayable>)channel {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsFilterFlag forChannel:channel];
}

- (NSArray*)filtersForChannelGroup:(AEChannelGroupRef)group {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsFilterFlag forChannelGroup:group];
}

-(NSArray *)inputFilters {
    return [self objectsAssociatedWithCallbacksFromTable:&_inputCallbacks matchingFlag:kCallbackIsFilterFlag];
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
    
    configureGraphStateOfGroupChannel(self, group->channel, parentGroup, index);
}

#pragma mark - Output receivers

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver {
    [receiver retain];
    [self addCallback:receiver.receiverCallback userInfo:receiver flags:kCallbackIsOutputCallbackFlag forChannelGroup:_topGroup];
}

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannel:(id<AEAudioPlayable>)channel {
    [receiver retain];
    [self addCallback:receiver.receiverCallback userInfo:receiver flags:kCallbackIsOutputCallbackFlag forChannel:channel];
}

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannelGroup:(AEChannelGroupRef)group {
    [receiver retain];
    [self addCallback:receiver.receiverCallback userInfo:receiver flags:kCallbackIsOutputCallbackFlag forChannelGroup:group];
}

- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver {
    [self removeCallback:receiver.receiverCallback userInfo:receiver fromChannelGroup:_topGroup];
    [receiver release];
}

- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver fromChannel:(id<AEAudioPlayable>)channel {
    [self removeCallback:receiver.receiverCallback userInfo:receiver fromChannel:channel];
    [receiver release];
}

- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver fromChannelGroup:(AEChannelGroupRef)group {
    [self removeCallback:receiver.receiverCallback userInfo:receiver fromChannelGroup:group];
    [receiver release];
}

- (NSArray*)outputReceivers {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsOutputCallbackFlag];
}

- (NSArray*)outputReceiversForChannel:(id<AEAudioPlayable>)channel {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsOutputCallbackFlag forChannel:channel];
}

- (NSArray*)outputReceiversForChannelGroup:(AEChannelGroupRef)group {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsOutputCallbackFlag forChannelGroup:group];
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
                                             .flags = kCallbackIsOutputCallbackFlag,
                                             .table = &_inputCallbacks }
                                                length:sizeof(struct callbackTableInfo_t)];
}

- (void)removeInputReceiver:(id<AEAudioReceiver>)receiver {
    [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = receiver.receiverCallback,
                                             .userInfo = receiver,
                                             .table = &_inputCallbacks }
                                                length:sizeof(struct callbackTableInfo_t)];
    [receiver release];
}

-(NSArray *)inputReceivers {
    return [self objectsAssociatedWithCallbacksFromTable:&_inputCallbacks matchingFlag:kCallbackIsOutputCallbackFlag];
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
    [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = receiver.timingReceiverCallback,
                                             .userInfo = receiver,
                                             .table = &_timingCallbacks }
                                                length:sizeof(struct callbackTableInfo_t)];

    [receiver release];
}

-(NSArray *)timingReceivers {
    return [self objectsAssociatedWithCallbacksFromTable:&_timingCallbacks matchingFlag:0];
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

- (void)averagePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel forGroup:(AEChannelGroupRef)group {
    if ( !group->meteringEnabled ) {
        UInt32 enable = YES;
        checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_MeteringMode, kAudioUnitScope_Output, 0, &enable, sizeof(enable)), 
                    "AudioUnitSetProperty(kAudioUnitProperty_MeteringMode)");
    }
    
    if ( averagePower ) {
        checkResult(AudioUnitGetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_PostAveragePower, kAudioUnitScope_Output, 0, averagePower), 
                    "AudioUnitGetParameter(kMultiChannelMixerParam_PostAveragePower)");
    }
    if ( peakLevel ) {
        checkResult(AudioUnitGetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_PostPeakHoldLevel, kAudioUnitScope_Output, 0, peakLevel), 
                    "AudioUnitGetParameter(kMultiChannelMixerParam_PostAveragePower)");
    }
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
    if ( _enableInput == enableInput ) return;
    _enableInput = enableInput;
    
    BOOL running = self.running;
    if ( running ) [self stop];
    [self teardown];
    
    [self setAudioSessionCategory];
    
    [NSThread sleepForTimeInterval:0.1]; // Sleep for a moment http://prod.lists.apple.com/archives/coreaudio-api/2012/Jan/msg00028.html
    
    [self setup];
    if ( running ) [self start];
}

-(void)setEnableBluetoothInput:(BOOL)enableBluetoothInput {
    _enableBluetoothInput = enableBluetoothInput;

    // Enable/disable bluetooth input
    UInt32 allowBluetoothInput = _enableBluetoothInput;
    OSStatus result = AudioSessionSetProperty (kAudioSessionProperty_OverrideCategoryEnableBluetoothInput, sizeof (allowBluetoothInput), &allowBluetoothInput);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput)");
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

-(void)setPreferredBufferDuration:(float)preferredBufferDuration {
    _preferredBufferDuration = preferredBufferDuration;

    Float32 preferredBufferSize = _preferredBufferDuration;
    OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
}

-(void)setVoiceProcessingEnabled:(BOOL)voiceProcessingEnabled {
    if ( _voiceProcessingEnabled == voiceProcessingEnabled ) return;
    
    _voiceProcessingEnabled = voiceProcessingEnabled;
    [self updateVoiceProcessingSettings];
}

-(void)setVoiceProcessingOnlyForSpeakerAndMicrophone:(BOOL)voiceProcessingOnlyForSpeakerAndMicrophone {
    _voiceProcessingOnlyForSpeakerAndMicrophone = voiceProcessingOnlyForSpeakerAndMicrophone;
    [self updateVoiceProcessingSettings];
}

-(AudioStreamBasicDescription *)audioDescription {
    return &_audioDescription;
}

-(AudioStreamBasicDescription *)inputAudioDescription {
    return &_inputAudioDescription;
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
        _audiobusInputPort.clientFormat = _audioDescription;
        [_audiobusInputPort addObserver:self forKeyPath:@"sources" options:0 context:NULL];
        if ( ABInputPortIsConnected(_audiobusInputPort) ) [self updateInputDeviceStatus];
    }
}

-(void)setAudiobusOutputPort:(ABOutputPort *)audiobusOutputPort {
    if ( _audiobusOutputPort ) [_audiobusOutputPort removeObserver:self forKeyPath:@"connectedPortAttributes"];
    
    [audiobusOutputPort retain];
    [_audiobusOutputPort release];
    _audiobusOutputPort = audiobusOutputPort;
    
    if ( _audiobusOutputPort ) {
        AudioStreamBasicDescription outputAudioDescription;
        UInt32 size = sizeof(outputAudioDescription);
        if ( checkResult(AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputAudioDescription, &size), 
                         "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") ) {
            _audiobusOutputPort.clientFormat = outputAudioDescription;
        }
        _muteOutput = _muteOutput || _audiobusOutputPort.connectedPortAttributes & ABInputPortAttributePlaysLiveAudio;
        [_audiobusOutputPort addObserver:self forKeyPath:@"connectedPortAttributes" options:0 context:NULL];
    }
}

#pragma mark - Events

-(void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ( object == _audiobusOutputPort ) {
        _muteOutput = _audiobusOutputPort.connectedPortAttributes & ABInputPortAttributePlaysLiveAudio;
        return;
    }
    if ( object == _audiobusInputPort ) {
        [self updateInputDeviceStatus];
        return;
    }
    
    id<AEAudioPlayable> channel = (id<AEAudioPlayable>)object;
    
    int index;
    AEChannelGroupRef group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:channel index:&index];
    if ( !group ) return;
    AEChannelRef channelElement = &group->channels[index];
    
    if ( [keyPath isEqualToString:@"volume"] ) {
        AudioUnitParameterValue value = channelElement->volume = channel.volume;
        OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0);
        checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
        
    } else if ( [keyPath isEqualToString:@"pan"] ) {
        AudioUnitParameterValue value = channelElement->pan = channel.pan;
        if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
        if ( value == 1.0 ) value = 0.999;
        OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0);
        checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");

    } else if ( [keyPath isEqualToString:@"playing"] ) {
        channelElement->playing = channel.playing;
        AudioUnitParameterValue value = channel.playing && (![channel respondsToSelector:@selector(muted)] || !channel.muted);
        OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
        checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
        group->channels[index].playing = value;
        
    }  else if ( [keyPath isEqualToString:@"muted"] ) {
        channelElement->muted = channel.muted;
        AudioUnitParameterValue value = ([channel respondsToSelector:@selector(playing)] ? channel.playing : YES) && !channel.muted;
        OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
        checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
        
    } else if ( [keyPath isEqualToString:@"audioDescription"] ) {
        channelElement->audioDescription = *channel.audioDescription;
        OSStatus result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, index, &channelElement->audioDescription, sizeof(AudioStreamBasicDescription));
        checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        
    }
}

- (void)applicationDidBecomeActive:(NSNotification*)notification {
    OSStatus status = AudioSessionSetActive(true);
    checkResult(status, "AudioSessionSetActive");
}

#pragma mark - Graph and audio session configuration

- (void)initAudioSession {
    
    // Initialise the audio session
    OSStatus result = AudioSessionInitialize(NULL, NULL, interruptionListener, self);
    if ( !checkResult(result, "AudioSessionInitialize") ) return;
    
    // Register property listeners
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioSessionPropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioInputAvailable, audioSessionPropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    // Set preferred buffer size
    Float32 preferredBufferSize = _preferredBufferDuration;
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    
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
    }
    
    UInt32 inputAvailable = NO;
    if ( _enableInput ) {
        // See if input's available
        UInt32 size = sizeof(inputAvailable);
        OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &size, &inputAvailable);
        checkResult(result, "AudioSessionGetProperty");
    }
    _audioInputAvailable = inputAvailable;
    
    [self setAudioSessionCategory];

    // Start session
    checkResult(AudioSessionSetActive(true), "AudioSessionSetActive");
    
    // Determine audio route
    CFStringRef route;
    size = sizeof(route);
    checkResult(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route),
                "AudioSessionGetProperty(kAudioSessionProperty_AudioRoute)");
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

- (BOOL)setup {
    
    // Create a new AUGraph
	OSStatus result = NewAUGraph(&_audioGraph);
    if ( !checkResult(result, "NewAUGraph") ) return NO;
	
    BOOL useVoiceProcessing = (_voiceProcessingEnabled && _enableInput && (!_voiceProcessingOnlyForSpeakerAndMicrophone || _playingThroughDeviceSpeaker));
    
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
    
    // Get reference to input audio unit
    result = AUGraphNodeInfo(_audioGraph, _ioNode, NULL, &_ioAudioUnit);
    if ( !checkResult(result, "AUGraphNodeInfo") ) return NO;

    if ( _enableInput ) {
        
        // Enable input
        UInt32 enableInputFlag = 1;
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInputFlag, sizeof(enableInputFlag));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)") ) return NO;
        
        // Register a callback to receive audio
        AURenderCallbackStruct inRenderProc;
        inRenderProc.inputProc = &inputAvailableCallback;
        inRenderProc.inputProcRefCon = self;
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inRenderProc, sizeof(inRenderProc));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_SetInputCallback)") ) return NO;
        
        // If doing voice processing, set its quality
        if ( useVoiceProcessing ) {
            UInt32 quality = 127;
            result = AudioUnitSetProperty(_ioAudioUnit, kAUVoiceIOProperty_VoiceProcessingQuality, kAudioUnitScope_Global, 1, &quality, sizeof(quality));
            checkResult(result, "AudioUnitSetProperty(kAUVoiceIOProperty_VoiceProcessingQuality)");
        }
        
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
        _topChannel.audioDescription = _audioDescription;
        _topChannel.audioController = self;
        _topGroup->channel   = &_topChannel;
    }
    
    // Initialise group
    initialiseGroupChannel(self, &_topChannel, NULL, 0);
    
    // Register a callback to be notified when the main mixer unit renders
    checkResult(AudioUnitAddRenderNotify(_topGroup->mixerAudioUnit, &topRenderNotifyCallback, self), "AudioUnitAddRenderNotify");
    
    if ( useVoiceProcessing ) {
        // If we're using voice processing, clamp the buffer duration
        Float32 preferredBufferSize = MAX(0.01, _preferredBufferDuration);
        OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
        checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    }
    
    // Initialize the graph
	result = AUGraphInitialize(_audioGraph);
    if ( !checkResult(result, "AUGraphInitialize") ) return NO;
    
    return YES;
}

- (void)teardown {
    checkResult(AUGraphClose(_audioGraph), "AUGraphClose");
    checkResult(DisposeAUGraph(_audioGraph), "AUGraphClose");
    _audioGraph = NULL;
    _ioAudioUnit = NULL;
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
            if ( err == noErr ) break;
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
    if ( currentCategory == audioCategory ) {
        return;
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

- (void)updateVoiceProcessingSettings {
    
    BOOL useVoiceProcessing = (_voiceProcessingEnabled && _enableInput && (!_voiceProcessingOnlyForSpeakerAndMicrophone || _playingThroughDeviceSpeaker));
    
    AudioComponentDescription target_io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = useVoiceProcessing ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    AudioComponentDescription io_desc;
    if ( !checkResult(AUGraphNodeInfo(_audioGraph, _ioNode, &io_desc, NULL), "AUGraphNodeInfo(ioNode)") )
        return;
    
    if ( io_desc.componentSubType != target_io_desc.componentSubType ) {
        // Replace audio unit
        [self stop];
        [self teardown];
        [NSThread sleepForTimeInterval:0.1]; // Sleep for a moment http://prod.lists.apple.com/archives/coreaudio-api/2012/Jan/msg00028.html
        AudioSessionSetActive(true);
        [self setup];
        [self start];
    }
}

struct updateInputDeviceStatusHandler_t { UInt32 numberOfInputChannels; BOOL inputAvailable; AudioStreamBasicDescription *audioDescription; AudioBufferList *audioBufferList; };
static void updateInputDeviceStatusHandler(AEAudioController *THIS, void* userInfo, int length) {
    struct updateInputDeviceStatusHandler_t *arg = userInfo;
    
    if ( !THIS->_audiobusInputPort || !ABInputPortIsConnected(THIS->_audiobusInputPort) ) {
        OSStatus result = AudioUnitSetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, arg->audioDescription, sizeof(AudioStreamBasicDescription));
        checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
    }
    
    THIS->_numberOfInputChannels = arg->numberOfInputChannels;
    THIS->_inputAudioDescription = *arg->audioDescription;
    THIS->_audioInputAvailable = arg->inputAvailable;
    THIS->_inputAudioBufferList = arg->audioBufferList;
}

- (void)updateInputDeviceStatus {
    UInt32 inputAvailable=0;
    
    if ( _enableInput ) {
        // Determine if audio input is available, and the number of input channels available
        AudioStreamBasicDescription inputAudioDescription = _audioDescription;
        UInt32 numberOfInputChannels = 0;
        
        if ( _audiobusInputPort && ABInputPortIsConnected(_audiobusInputPort) ) {
            inputAvailable = YES;
            inputAudioDescription = _audioDescription;
            numberOfInputChannels = inputAudioDescription.mChannelsPerFrame;
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
        
        if ( _inputMode == AEInputModeVariableAudioFormat) {
            // Set the input audio description channels to the number of actual available channels
            if ( !(inputAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ) {
                inputAudioDescription.mBytesPerFrame *= (float)numberOfInputChannels / inputAudioDescription.mChannelsPerFrame;
                inputAudioDescription.mBytesPerPacket *= (float)numberOfInputChannels / inputAudioDescription.mChannelsPerFrame;
            }
            inputAudioDescription.mChannelsPerFrame = numberOfInputChannels;
        }
        
        AudioBufferList *inputBufferList = _inputAudioBufferList;
        
        BOOL inputChannelsChanged = _numberOfInputChannels != numberOfInputChannels;
        BOOL inputAvailableChanged = _audioInputAvailable != inputAvailable;
        
        if ( !_inputAudioBufferList || memcmp(&inputAudioDescription, &_inputAudioDescription, sizeof(inputAudioDescription)) != 0 ) {
            inputBufferList = AEAllocateAndInitAudioBufferList(&inputAudioDescription, 0);
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
                                                 .audioBufferList = inputBufferList }
                                                    length:sizeof(struct callbackTableInfo_t)];
        
        if ( oldInputBuffer && oldInputBuffer != _inputAudioBufferList ) {
            free(oldInputBuffer);
        }
        
        if ( inputChannelsChanged ) {
            [self didChangeValueForKey:@"inputAudioDescription"];
            [self didChangeValueForKey:@"numberOfInputChannels"];
            
            if ( _audiobusInputPort && ABInputPortIsConnected(_audiobusInputPort) && _audiobusInputPort.clientFormat.mChannelsPerFrame != _audioDescription.mChannelsPerFrame ) {
                _audiobusInputPort.clientFormat = inputAudioDescription;
            }
        }
        
        if ( inputAvailableChanged ) {
            [self didChangeValueForKey:@"audioInputAvailable"];
        }
    }
    
    [self setAudioSessionCategory];
}

static BOOL initialiseGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index) {
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
    }
    
    // Set bus count
	UInt32 busCount = group->channelCount;
    result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return NO;
    
    // Configure graph state
    configureGraphStateOfGroupChannel(THIS, channel, parentGroup, index);
    
    // Configure inputs
    configureChannelsInRangeForGroup(THIS, NSMakeRange(0, busCount), group);
    
    return YES;
}

static void configureGraphStateOfGroupChannel(AEAudioController *THIS, AEChannelRef channel, AEChannelGroupRef parentGroup, int index) {
    AEChannelGroupRef group = (AEChannelGroupRef)channel->ptr;
    
    BOOL outputCallbacks=NO, filters=NO;
    for ( int i=0; i<channel->callbacks.count && (!outputCallbacks || !filters); i++ ) {
        if ( channel->callbacks.callbacks[i].flags & (kCallbackIsFilterFlag | kCallbackIsVariableSpeedFilterFlag) ) {
            filters = YES;
        } else if ( channel->callbacks.callbacks[i].flags & kCallbackIsOutputCallbackFlag ) {
            outputCallbacks = YES;
        }
    }
    
    
    Boolean wasRunning = false;
    OSStatus result = AUGraphIsRunning(THIS->_audioGraph, &wasRunning);
    checkResult(result, "AUGraphIsRunning");

    BOOL updateGraph = NO;
    BOOL graphStopped = !wasRunning;
    
    if ( (outputCallbacks || filters) && group->converterRequired && !group->audioConverter ) {
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
    
    if ( filters ) {
        // We need to use our own render callback, because the audio will be being converted and modified
        if ( group->graphState & kGroupGraphStateNodeConnected ) {
            if ( !parentGroup && !graphStopped ) {
                // Stop the graph first, because we're going to modify the root
                if ( checkResult(AUGraphStop(THIS->_audioGraph), "AUGraphStop") ) {
                    graphStopped = YES;
                }
            }
            // Remove the node connection
            if ( checkResult(AUGraphDisconnectNodeInput(THIS->_audioGraph, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0), "AUGraphDisconnectNodeInput") ) {
                group->graphState &= ~kGroupGraphStateNodeConnected;
                checkResult(AUGraphUpdate(THIS->_audioGraph, NULL), "AUGraphUpdate");
            }
        }
        
        if ( group->graphState & kGroupGraphStateRenderNotificationSet ) {
            // Remove render notification callback
            if ( checkResult(AudioUnitRemoveRenderNotify(group->mixerAudioUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify") ) {
                group->graphState &= ~kGroupGraphStateRenderNotificationSet;
            }
        }

        // Set stream format for callback
        checkResult(AudioUnitSetProperty(parentGroup ? parentGroup->mixerAudioUnit : THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, parentGroup ? index : 0, &THIS->_audioDescription, sizeof(THIS->_audioDescription)),
                    "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        
        if ( !(group->graphState & kGroupGraphStateRenderCallbackSet) ) {
            // Add the render callback
            AURenderCallbackStruct rcbs;
            rcbs.inputProc = &renderCallback;
            rcbs.inputProcRefCon = channel;
            if ( checkResult(AUGraphSetNodeInputCallback(THIS->_audioGraph, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0, &rcbs), "AUGraphSetNodeInputCallback") ) {
                group->graphState |= kGroupGraphStateRenderCallbackSet;
                updateGraph = YES;
            }
        }
        
    } else if ( group->graphState & kGroupGraphStateRenderCallbackSet ) {
        // Expermentation reveals that once the render callback has been set, no further connections or render callbacks can be established.
        // So, we leave the node in this state, regardless of whether we have callbacks or not
    } else {
        if ( !(group->graphState & kGroupGraphStateNodeConnected) ) {
            // Connect output of mixer directly to the parent mixer
            if ( checkResult(AUGraphConnectNodeInput(THIS->_audioGraph, group->mixerNode, 0, parentGroup ? parentGroup->mixerNode : THIS->_ioNode, parentGroup ? index : 0), "AUGraphConnectNodeInput") ) {
                group->graphState |= kGroupGraphStateNodeConnected;
                updateGraph = YES;
            }
        }
        
        if ( outputCallbacks ) {
            // We need to register a callback to be notified when the mixer renders, to pass on the audio
            if ( !(group->graphState & kGroupGraphStateRenderNotificationSet) ) {
                // Add render notification callback
                if ( checkResult(AudioUnitAddRenderNotify(group->mixerAudioUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify") ) {
                    group->graphState |= kGroupGraphStateRenderNotificationSet;
                }
            }
        } else {
            if ( group->graphState & kGroupGraphStateRenderNotificationSet ) {
                // Remove render notification callback
                if ( checkResult(AudioUnitRemoveRenderNotify(group->mixerAudioUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify") ) {
                    group->graphState &= ~kGroupGraphStateRenderNotificationSet;
                }
            }
        }
    }
    
    if ( updateGraph ) {
        Boolean updated;
        AUGraphUpdate(THIS->_audioGraph, &updated);
    }
    
    if ( graphStopped && wasRunning ) {
        checkResult(AUGraphStart(THIS->_audioGraph), "AUGraphStart");
    }
    
    if ( !outputCallbacks && !filters && group->audioConverter && !(group->graphState & kGroupGraphStateRenderCallbackSet) ) {
        // Cleanup audio converter
        AudioConverterDispose(group->audioConverter);
        group->audioConverter = NULL;
    }
}

static void configureChannelsInRangeForGroup(AEAudioController *THIS, NSRange range, AEChannelGroupRef group) {
    for ( int i = range.location; i < range.location+range.length; i++ ) {
        AEChannelRef channel = &group->channels[i];
        
        // Set volume
        AudioUnitParameterValue volumeValue = channel->volume;
        checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, i, volumeValue, 0),
                    "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
        
        // Set pan
        AudioUnitParameterValue panValue = channel->pan;
        checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, i, panValue, 0),
                    "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
        
        // Set enabled
        AudioUnitParameterValue enabledValue = channel->playing && !channel->muted;
        checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, i, enabledValue, 0),
                    "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
        
        if ( channel->type == kChannelTypeChannel ) {
            
            // Set input stream format
            checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &channel->audioDescription, sizeof(channel->audioDescription)),
                        "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
            
            // Setup render callback struct
            AURenderCallbackStruct rcbs;
            rcbs.inputProc = &renderCallback;
            rcbs.inputProcRefCon = channel;
            
            // Set a callback for the specified node's specified input
            checkResult(AUGraphSetNodeInputCallback(THIS->_audioGraph, group->mixerNode, i, &rcbs), 
                        "AUGraphSetNodeInputCallback");


            
        } else if ( channel->type == kChannelTypeGroup ) {
            // Recursively initialise this channel group
            initialiseGroupChannel(THIS, channel, group, i);
        }
    }
}

static void updateGroupDelayed(AEAudioController *THIS, void *userInfo, int length) {
    AEChannelGroupRef group = *(AEChannelGroupRef*)userInfo;
    OSStatus result = AUGraphUpdate(THIS->_audioGraph, NULL);
    if ( result == kAUGraphErr_InvalidConnection && group->channelCount == 0 ) {
        // Ignore this error
    } else {
        checkResult(result, "AUGraphUpdate");
    }
    configureChannelsInRangeForGroup(THIS, NSMakeRange(0, group->channelCount), group);
}

static void removeChannelsFromGroup(AEAudioController *THIS, void *userInfo, int userInfoLength) {
    struct removeChannelsFromGroup_t *args = userInfo;
    
    // Set new bus count of group
    UInt32 busCount = args->group->channelCount - args->count;
    assert(busCount >= 0);
    
    if ( busCount == 0 ) busCount = 1; // Note: Mixer must have at least 1 channel. It'll just be silent.
    if ( !checkResult(AudioUnitSetProperty(args->group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)),
                      "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    if ( args->group->channelCount - args->count == 0 ) {
        // Remove render callback and disconnect channel 0, as the mixer must have at least 1 channel, and we want to leave it disconnected
        
        // Remove any render callback
        AURenderCallbackStruct rcbs;
        rcbs.inputProc = NULL;
        rcbs.inputProcRefCon = NULL;
        checkResult(AUGraphSetNodeInputCallback(THIS->_audioGraph, args->group->mixerNode, 0, &rcbs),
                    "AUGraphSetNodeInputCallback");
        
        // Make sure the mixer input isn't connected to anything
        checkResult(AUGraphDisconnectNodeInput(THIS->_audioGraph, args->group->mixerNode, 0), 
                    "AUGraphDisconnectNodeInput");
    }
    
    for ( int i=0; i < args->count; i++ ) {
        
        // Find the channel in our fixed array
        int index = 0;
        for ( index=0; index < args->group->channelCount; index++ ) {
            if ( args->group->channels[index].ptr == args->ptrs[i] && args->group->channels[index].userInfo == args->userInfos[i] ) {
                break;
            }
        }
        
        if ( index < args->group->channelCount ) {
            args->group->channelCount--;
            
            if ( index < args->group->channelCount ) {
                // Shuffle the later elements backwards one space
                memmove(&args->group->channels[index], &args->group->channels[index+1], (args->group->channelCount-index) * sizeof(channel_t));
            }
            
            // Zero out the now-unused space
            memset(&args->group->channels[args->group->channelCount], 0, sizeof(channel_t));
        }
    }
    
    OSStatus result = AUGraphUpdate(THIS->_audioGraph, NULL);
    if ( result == kAUGraphErr_CannotDoInCurrentContext ) {
        // Complete the refresh on the main thread
        AEAudioControllerSendAsynchronousMessageToMainThread(THIS, updateGroupDelayed, &args->group, sizeof(AEChannelGroupRef));
    } else if ( checkResult(result, "AUGraphUpdate") ) {
        configureChannelsInRangeForGroup(THIS, NSMakeRange(0, args->group->channelCount), args->group);
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
    
    NSArray *callbackObjects = [self objectsAssociatedWithCallbacksWithFlags:0 forChannelGroup:group];
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
    group->graphState = kGroupGraphStateUninitialized;
    group->mixerNode = 0;
    group->mixerAudioUnit = NULL;
    group->meteringEnabled = NO;
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannelRef channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self markGroupTorndown:(AEChannelGroupRef)channel->ptr];
        }
    }
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
    
    // Find the item in our fixed array
    int index = 0;
    for ( index=0; index<table->count; index++ ) {
        if ( table->callbacks[index].callback == arg->callback && table->callbacks[index].userInfo == arg->userInfo ) {
            break;
        }
    }
    if ( index < table->count ) {
        // Now shuffle the later elements backwards one space
        table->count--;
        for ( int i=index; i<table->count; i++ ) {
            table->callbacks[i] = table->callbacks[i+1];
        }
    }
}

- (NSArray *)objectsAssociatedWithCallbacksFromTable:(callback_table_t*)table matchingFlag:(uint8_t)flag {
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

    configureGraphStateOfGroupChannel(self, group->channel, parentGroup, index);
}

- (void)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = &parentGroup->channels[index];
    
    [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = callback,
                                             .userInfo = userInfo,
                                             .table = &channel->callbacks }
                                                length:sizeof(struct callbackTableInfo_t)];
}

- (void)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannelGroup:(AEChannelGroupRef)group {
    [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                         userInfoBytes:&(struct callbackTableInfo_t){
                                             .callback = callback,
                                             .userInfo = userInfo,
                                             .table = &group->channel->callbacks }
                                                length:sizeof(struct callbackTableInfo_t)];
    
    AEChannelGroupRef parentGroup = NULL;
    int index=0;
    if ( group != _topGroup ) {
        parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
        NSAssert(parentGroup != NULL, @"Channel group not found");
    }
    
    configureGraphStateOfGroupChannel(self, group->channel, parentGroup, index);
}

- (NSArray*)objectsAssociatedWithCallbacksWithFlags:(uint8_t)flags {
    return [self objectsAssociatedWithCallbacksFromTable:&_topChannel.callbacks matchingFlag:flags];
}

- (NSArray*)objectsAssociatedWithCallbacksWithFlags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroupRef parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannelRef channel = &parentGroup->channels[index];
    
    return [self objectsAssociatedWithCallbacksFromTable:&channel->callbacks matchingFlag:flags];
}

- (NSArray*)objectsAssociatedWithCallbacksWithFlags:(uint8_t)flags forChannelGroup:(AEChannelGroupRef)group {
    return [self objectsAssociatedWithCallbacksFromTable:&group->channel->callbacks matchingFlag:flags];
}

- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter forChannelStruct:(AEChannelRef)channel {
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        if ( (channel->callbacks.callbacks[i].flags & kCallbackIsVariableSpeedFilterFlag ) ) {
            // Remove the old callback
            [self performSynchronousMessageExchangeWithHandler:removeCallbackFromTable
                                                 userInfoBytes:&(struct callbackTableInfo_t){
                                                     .callback = channel->callbacks.callbacks[i].callback,
                                                     .userInfo = channel->callbacks.callbacks[i].userInfo,
                                                     .table = &channel->callbacks }
                                                        length:sizeof(struct callbackTableInfo_t)];
            break;
            [(id)(long)channel->callbacks.callbacks[i].userInfo release];
        }
    }
    
    if ( filter ) {
        [filter retain];
        [self performSynchronousMessageExchangeWithHandler:addCallbackToTable
                                             userInfoBytes:&(struct callbackTableInfo_t){
                                                 .callback = filter.filterCallback,
                                                 .userInfo = filter,
                                                 .flags = kCallbackIsVariableSpeedFilterFlag,
                                                 .table = &channel->callbacks }
                                                    length:sizeof(struct callbackTableInfo_t)];
        
    }
}

static void handleCallbacksForChannel(AEChannelRef channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    // Pass audio to filters
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kCallbackIsFilterFlag ) {
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, channel->audioController, channel->userInfo, inTimeStamp, inNumberFrames, ioData);
        }
    }
    
    // And finally pass to output callbacks
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kCallbackIsOutputCallbackFlag ) {
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, channel->audioController, channel->userInfo, inTimeStamp, inNumberFrames, ioData);
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