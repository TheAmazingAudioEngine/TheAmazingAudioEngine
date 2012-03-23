//
//  AEAudioController.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 25/11/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "AEAudioController.h"
#import <UIKit/UIKit.h>
#import <libkern/OSAtomic.h>
#import "TPCircularBuffer.h"
#include <sys/types.h>
#include <sys/sysctl.h>

#ifdef TRIAL
#import "AETrialModeController.h"
#endif

#define kMaximumChannelsPerGroup 100
#define kMaximumCallbacksPerSource 15
#define kMessageBufferLength 50
#define kIdleMessagingPollDuration 0.2
#define kRenderConversionScratchBufferSize 16384

NSString * AEAudioControllerSessionInterruptionBeganNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionBeganNotification";
NSString * AEAudioControllerSessionInterruptionEndedNotification = @"com.theamazingaudioengine.AEAudioControllerSessionInterruptionEndedNotification";

const NSString *kAEAudioControllerCallbackKey = @"callback";
const NSString *kAEAudioControllerUserInfoKey = @"userinfo";

static inline int min(int a, int b) { return a>b ? b : a; }

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/'),__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
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
    callback_table_t callbacks;
} channel_t, *AEChannel;

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
    AEChannel           channel;
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
} channel_group_t;

/*!
 * Channel producer argument
 */
typedef struct {
    AEChannel channel;
    AudioTimeStamp inTimeStamp;
    AudioUnitRenderActionFlags *ioActionFlags;
} channel_producer_arg_t;

#pragma mark Messaging

/*!
 * Message 
 */
typedef struct _message_t {
    AEAudioControllerMessageHandler handler;
    long parameter1;
    long parameter2;
    long parameter3;
    void *ioOpaquePtr;
    long result;
    void (^responseBlock)(long result, long parameter1, long parameter2, long parameter3, void *ioOpaquePtr);
} message_t;

#pragma mark -

@interface AEAudioController () {
    AUGraph             _audioGraph;
    AUNode              _ioNode;
    AudioUnit           _ioAudioUnit;
    BOOL                _runningPriorToInterruption;
    
    AEChannelGroup      _topGroup;
    channel_t           _topChannel;
    
    callback_table_t    _inputCallbacks;
    callback_table_t    _timingCallbacks;
    
    TPCircularBuffer    _realtimeThreadMessageBuffer;
    TPCircularBuffer    _mainThreadMessageBuffer;
    NSTimer            *_responsePollTimer;
    int                 _pendingResponses;
    
    char               *_renderConversionScratchBuffer;
}

- (void)pollForMainThreadMessages;
static void processPendingMessagesOnRealtimeThread(AEAudioController *THIS);

- (void)initAudioSession;
- (BOOL)setup;
- (void)teardown;
- (void)updateGraph;
- (void)setAudioSessionCategory;
- (void)updateVoiceProcessingSettings;
- (void)updateInputDeviceStatus;
static BOOL initialiseGroupChannel(AEAudioController *THIS, AEChannel channel, AEChannelGroup parentGroup, int index);
static void configureGraphStateOfGroupChannel(AEAudioController *THIS, AEChannel channel, AEChannelGroup parentGroup, int index);
static void configureChannelsInRangeForGroup(AEAudioController *THIS, NSRange range, AEChannelGroup group);
static long removeChannelsFromGroup(AEAudioController *THIS, long *matchingPtrArrayPtr, long *matchingUserInfoArrayPtr, long *channelsCount, void* groupPtr);
- (void)gatherChannelsFromGroup:(AEChannelGroup)group intoArray:(NSMutableArray*)array;
- (AEChannelGroup)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo index:(int*)index;
- (void)releaseResourcesForGroup:(AEChannelGroup)group;
- (void)markGroupTorndown:(AEChannelGroup)group;

static long addCallbackToTable(AEAudioController *THIS, long *callbackTablePtr, long *callbackPtr, long *userInfoPtr, void* outPtr);
static long removeCallbackFromTable(AEAudioController *THIS, long *callbackTablePtr, long *callbackPtr, long *userInfoPtr, void* outPtr);
- (NSArray *)objectsAssociatedWithCallbacksFromTable:(callback_table_t*)table matchingFlag:(uint8_t)flag;
- (void)addCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj;
- (void)addCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannelGroup:(AEChannelGroup)group;
- (void)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannel:(id<AEAudioPlayable>)channelObj;
- (void)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannelGroup:(AEChannelGroup)group;
- (NSArray*)objectsAssociatedWithCallbacksWithFlags:(uint8_t)flags;
- (NSArray*)objectsAssociatedWithCallbacksWithFlags:(uint8_t)flags forChannel:(id<AEAudioPlayable>)channelObj;
- (NSArray*)objectsAssociatedWithCallbacksWithFlags:(uint8_t)flags forChannelGroup:(AEChannelGroup)group;
- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter forChannelStruct:(AEChannel)channel;
static void handleCallbacksForChannel(AEChannel channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData);
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
            audioDescription            = _audioDescription, 
            audioUnit                   = _ioAudioUnit;

@dynamic    running, inputGainAvailable, inputGain;

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

static void audioRouteChangePropertyListener(void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void *inData) {
    if (inID == kAudioSessionProperty_AudioRouteChange) {
        int reason = [[(NSDictionary*)inData objectForKey:(id)kAudioSession_RouteChangeKey_Reason] intValue];
        AEAudioController *THIS = (AEAudioController *)inClientData;
        
        CFStringRef route;
        UInt32 size = sizeof(route);
        if ( !checkResult(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route), "AudioSessionGetProperty(kAudioSessionProperty_AudioRoute)") ) return;
        
        BOOL playingThroughSpeaker;
        if ( [(NSString*)route isEqualToString:@"ReceiverAndMicrophone"] ) {
            checkResult(AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange, audioRouteChangePropertyListener, THIS), "AudioSessionRemovePropertyListenerWithUserData");
            
            // Re-route audio to the speaker (not the receiver)
            UInt32 newRoute = kAudioSessionOverrideAudioRoute_Speaker;
            checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute,  sizeof(route), &newRoute), "AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute)");
            
            checkResult(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioRouteChangePropertyListener, THIS), "AudioSessionAddPropertyListener");
            
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
    }
}

static void inputAvailablePropertyListener (void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void *inData) {
    AEAudioController *THIS = (AEAudioController *)inClientData;
    if ( inID == kAudioSessionProperty_AudioInputAvailable ) {
        [THIS updateInputDeviceStatus];
    }
}

#pragma mark -
#pragma mark Input and render callbacks

static OSStatus channelAudioProducer(void *userInfo, AudioBufferList *audio, UInt32 frames) {
    channel_producer_arg_t *arg = (channel_producer_arg_t*)userInfo;
    AEChannel channel = arg->channel;
    
    OSStatus status = noErr;
    
    if ( channel->type == kChannelTypeChannel ) {
        AEAudioControllerRenderCallback callback = (AEAudioControllerRenderCallback) channel->ptr;
        id<AEAudioPlayable> channelObj = (id<AEAudioPlayable>) channel->userInfo;
        
        status = callback(channelObj, &arg->inTimeStamp, frames, audio);
        
    } else if ( channel->type == kChannelTypeGroup ) {
        AEChannelGroup group = (AEChannelGroup)channel->ptr;
        
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
    AEChannel channel = (AEChannel)inRefCon;
    
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
        varispeedFilter(varispeedFilterUserinfo, &channelAudioProducer, (void*)&arg, inTimeStamp, inNumberFrames, ioData);
    } else {
        // Take audio directly from channel
        result = channelAudioProducer((void*)&arg, ioData, inNumberFrames);
    }
    
    handleCallbacksForChannel(channel, inTimeStamp, inNumberFrames, ioData);
    
    return result;
}

static OSStatus inputAvailableCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
   
    AEAudioController *THIS = (AEAudioController *)inRefCon;

    for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
        callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
        ((AEAudioControllerTimingCallback)callback->callback)(callback->userInfo, inTimeStamp, AEAudioTimingContextInput);
    }
    
    // Render audio into buffer
    AudioStreamBasicDescription asbd = THIS->_audioDescription;
    
    char audioBufferListSpace[sizeof(AudioBufferList)+sizeof(AudioBuffer)];
    AudioBufferList *bufferList = (AudioBufferList*)audioBufferListSpace;
    
    int channels = THIS->_inputMode == ABInputModeStereoOrBridgedMono ? THIS->_audioDescription.mChannelsPerFrame :
                    THIS->_inputMode == ABInputModeDualMonoOrMono ? THIS->_numberOfInputChannels :
                      MIN(THIS->_audioDescription.mChannelsPerFrame, THIS->_numberOfInputChannels);
    BOOL nonInterleaved = THIS->_inputMode == ABInputModeDualMonoOrMono ? YES : THIS->_audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved;
    
    assert(channels <= 2);
    
    bufferList->mNumberBuffers = nonInterleaved ? channels : 1;
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        bufferList->mBuffers[i].mNumberChannels = nonInterleaved ? 1 : channels;
        bufferList->mBuffers[i].mData = NULL;
        bufferList->mBuffers[i].mDataByteSize = inNumberFrames * asbd.mBytesPerFrame;
    }
    
    OSStatus err = AudioUnitRender(THIS->_ioAudioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, bufferList);
    if ( !checkResult(err, "AudioUnitRender") ) { 
        return err; 
    }
    
    // Pass audio to input callbacks
    for ( int i=0; i<THIS->_inputCallbacks.count; i++ ) {
        callback_t *callback = &THIS->_inputCallbacks.callbacks[i];
        if ( THIS->_inputMode == ABInputModeDualMonoOrMono && channels == 2 ) {
            // Dual mono mode: Pass each channel to the callback separately
            AudioBufferList dualMonoBufferList;
            dualMonoBufferList.mNumberBuffers = 1;
            dualMonoBufferList.mBuffers[0].mNumberChannels = 1;
            
            dualMonoBufferList.mBuffers[0].mDataByteSize = bufferList->mBuffers[0].mDataByteSize;
            dualMonoBufferList.mBuffers[0].mData = bufferList->mBuffers[0].mData;
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, AEAudioSourceInput, inTimeStamp, inNumberFrames, &dualMonoBufferList);
            
            dualMonoBufferList.mBuffers[0].mDataByteSize = bufferList->mBuffers[1].mDataByteSize;
            dualMonoBufferList.mBuffers[0].mData = bufferList->mBuffers[1].mData;
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, AEAudioSourceInputAlternate, inTimeStamp, inNumberFrames, &dualMonoBufferList);
            
        } else {
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, AEAudioSourceInput, inTimeStamp, inNumberFrames, bufferList);
        }
    }
    
    return noErr;
}

static OSStatus groupRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEChannel channel = (AEChannel)inRefCon;
    AEChannelGroup group = (AEChannelGroup)channel->ptr;
    
    if ( (*ioActionFlags & kAudioUnitRenderAction_PostRender) ) {
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
            ((AEAudioControllerTimingCallback)callback->callback)(callback->userInfo, inTimeStamp, AEAudioTimingContextOutput);
        }
    } else if ( (*ioActionFlags & kAudioUnitRenderAction_PostRender) ) {
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
    _enableInput = enableInput;
    _enableBluetoothInput = YES;
    _voiceProcessingEnabled = useVoiceProcessing;
    _preferredBufferDuration = 0.005;
    _inputMode = ABInputModeStereoOrBridgedMono;
    _voiceProcessingOnlyForSpeakerAndMicrophone = YES;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    
    TPCircularBufferInit(&_realtimeThreadMessageBuffer, kMessageBufferLength * sizeof(message_t));
    TPCircularBufferInit(&_mainThreadMessageBuffer, kMessageBufferLength * sizeof(message_t));
    
    [self initAudioSession];
    
    if ( ![self setup] ) {
        [self release];
        return nil;
    }
    
#ifdef TRIAL
    [[AETrialModeController alloc] init];
#endif
    
    return self;
}

- (void)dealloc {
    if ( _responsePollTimer ) {
        [_responsePollTimer invalidate];
        [_responsePollTimer release];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stop];
    [self teardown];
    
    NSArray *channels = [self channels];
    for ( NSObject *channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", "playing", @"muted", nil] ) {
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
    
    [super dealloc];
}

- (void)start {

    // Determine if audio input is available, and the number of input channels available
    [self updateInputDeviceStatus];
    
    // Start messaging poll timer
    _responsePollTimer = [[NSTimer scheduledTimerWithTimeInterval:kIdleMessagingPollDuration target:self selector:@selector(pollForMainThreadMessages) userInfo:nil repeats:YES] retain];
    
    // Start things up
    checkResult(AudioSessionSetActive(true), "AudioSessionSetActive");
    checkResult(AUGraphStart(_audioGraph), "AUGraphStart");
}

- (void)stop {
    if ( self.running ) {
        if ( !checkResult(AUGraphStop(_audioGraph), "AUGraphStop") ) return;
        AudioSessionSetActive(false);
    }
}

#pragma mark - Channel and channel group management

- (void)addChannels:(NSArray*)channels {
    [self addChannels:channels toChannelGroup:_topGroup];
}

- (void)addChannels:(NSArray*)channels toChannelGroup:(AEChannelGroup)group {
    // Remove the channels from the system, if they're already added
    [self removeChannels:channels];
    
    // Add to group's channel array
    for ( id<AEAudioPlayable> channel in channels ) {
        if ( group->channelCount == kMaximumChannelsPerGroup ) {
            NSLog(@"Warning: Channel limit reached");
            break;
        }
        
        [channel retain];
        
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"playing", @"muted", nil] ) {
            [(NSObject*)channel addObserver:self forKeyPath:property options:0 context:NULL];
        }
        
        AEChannel channelElement = &group->channels[group->channelCount++];
        
        channelElement->type        = kChannelTypeChannel;
        channelElement->ptr         = channel.renderCallback;
        channelElement->userInfo    = channel;
        channelElement->playing     = [channel respondsToSelector:@selector(playing)] ? channel.playing : YES;
        channelElement->volume      = [channel respondsToSelector:@selector(volume)] ? channel.volume : 1.0;
        channelElement->pan         = [channel respondsToSelector:@selector(pan)] ? channel.pan : 0.0;
        channelElement->muted       = [channel respondsToSelector:@selector(muted)] ? channel.muted : NO;
    }
    
    // Set bus count
    UInt32 busCount = group->channelCount;
    OSStatus result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // Configure each channel
    configureChannelsInRangeForGroup(self, NSMakeRange(group->channelCount - [channels count], [channels count]), group);
    
    [self updateGraph];
}

- (void)removeChannels:(NSArray *)channels {
    // Find parent groups of each channel, and remove channels (in batches, if possible)
    NSMutableArray *siblings = [NSMutableArray array];
    AEChannelGroup lastGroup = NULL;
    for ( id<AEAudioPlayable> channel in channels ) {
        AEChannelGroup group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:channel index:NULL];
        
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

- (void)removeChannels:(NSArray*)channels fromChannelGroup:(AEChannelGroup)group {
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
    [self performSynchronousMessageExchangeWithHandler:&removeChannelsFromGroup parameter1:(long)&ptrMatchArray parameter2:(long)&userInfoMatchArray parameter3:[channels count] ioOpaquePtr:group];
    
    // Finally, stop observing and release channels
    for ( NSObject *channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"playing", @"muted", nil] ) {
            [(NSObject*)channel removeObserver:self forKeyPath:property];
        }
    }
    [channels makeObjectsPerformSelector:@selector(release)];
    
    // And release the associated callback objects
    [callbackObjects makeObjectsPerformSelector:@selector(release)];
}


- (void)removeChannelGroup:(AEChannelGroup)group {
    
    // Find group's parent
    AEChannelGroup parentGroup = (group == _topGroup ? NULL : [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:NULL]);
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
        [self performSynchronousMessageExchangeWithHandler:&removeChannelsFromGroup 
                                                parameter1:(long)&ptrMatchArray
                                                parameter2:(long)&userInfoMatchArray
                                                parameter3:1 
                                               ioOpaquePtr:parentGroup];
    }
    
    // Release channel resources
    [channelsWithinGroup makeObjectsPerformSelector:@selector(release)];
    [channelCallbackObjects makeObjectsPerformSelector:@selector(release)];
    
    // Release group resources
    [groupCallbackObjects makeObjectsPerformSelector:@selector(release)];
    
    // Release subgroup resources
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannel channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self releaseResourcesForGroup:(AEChannelGroup)channel->ptr];
            channel->ptr = NULL;
        }
    }
    
    free(group);
    
    [self updateGraph];
}

-(NSArray *)channels {
    NSMutableArray *channels = [NSMutableArray array];
    [self gatherChannelsFromGroup:_topGroup intoArray:channels];
    return channels;
}

- (NSArray*)channelsInChannelGroup:(AEChannelGroup)group {
    NSMutableArray *channels = [NSMutableArray array];
    for ( int i=0; i<group->channelCount; i++ ) {
        if ( group->channels[i].type == kChannelTypeChannel ) {
            [channels addObject:(id)group->channels[i].userInfo];
        }
    }
    return channels;
}


- (AEChannelGroup)createChannelGroup {
    return [self createChannelGroupWithinChannelGroup:_topGroup];
}

- (AEChannelGroup)createChannelGroupWithinChannelGroup:(AEChannelGroup)parentGroup {
    if ( parentGroup->channelCount == kMaximumChannelsPerGroup ) {
        NSLog(@"Maximum channels reached in group %p\n", parentGroup);
        return NULL;
    }
    
    // Allocate group
    AEChannelGroup group = (AEChannelGroup)calloc(1, sizeof(channel_group_t));
    
    // Add group as a channel to the parent group
    int groupIndex = parentGroup->channelCount;
    
    AEChannel channel = &parentGroup->channels[groupIndex];
    memset(channel, 0, sizeof(channel_t));
    channel->type    = kChannelTypeGroup;
    channel->ptr     = group;
    channel->playing = YES;
    channel->volume  = 1.0;
    channel->pan     = 0.0;
    channel->muted   = NO;
    
    group->channel   = channel;
    
    parentGroup->channelCount++;    

    // Initialise group
    initialiseGroupChannel(self, channel, parentGroup, groupIndex);

    [self updateGraph];
    
    return group;
}

- (NSArray*)topLevelChannelGroups {
    return [self channelGroupsInChannelGroup:_topGroup];
}

- (NSArray*)channelGroupsInChannelGroup:(AEChannelGroup)group {
    NSMutableArray *groups = [NSMutableArray array];
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannel channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [groups addObject:[NSValue valueWithPointer:channel->ptr]];
        }
    }
    return groups;
}

- (void)setVolume:(float)volume forChannelGroup:(AEChannelGroup)group {
    int index;
    AEChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AudioUnitParameterValue value = group->channel->volume = volume;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
}

- (void)setPan:(float)pan forChannelGroup:(AEChannelGroup)group {
    int index;
    AEChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AudioUnitParameterValue value = group->channel->pan = pan;
    if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
    if ( value == 1.0 ) value = 0.999;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
}

- (void)setMuted:(BOOL)muted forChannelGroup:(AEChannelGroup)group {
    int index;
    AEChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
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

- (void)addFilter:(id<AEAudioFilter>)filter toChannelGroup:(AEChannelGroup)group {
    [filter retain];
    [self addCallback:filter.filterCallback userInfo:filter flags:kCallbackIsFilterFlag forChannelGroup:group];
}

- (void)removeFilter:(id<AEAudioFilter>)filter {
    [self removeCallback:filter.filterCallback userInfo:filter fromChannelGroup:_topGroup];
    [filter release];
}

- (void)removeFilter:(id<AEAudioFilter>)filter fromChannel:(id<AEAudioPlayable>)channel {
    [self removeCallback:filter.filterCallback userInfo:filter fromChannel:channel];
    [filter release];
}

- (void)removeFilter:(id<AEAudioFilter>)filter fromChannelGroup:(AEChannelGroup)group {
    [self removeCallback:filter.filterCallback userInfo:filter fromChannelGroup:group];
    [filter release];
}

- (NSArray*)filters {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsFilterFlag];
}

- (NSArray*)filtersForChannel:(id<AEAudioPlayable>)channel {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsFilterFlag forChannel:channel];
}

- (NSArray*)filtersForChannelGroup:(AEChannelGroup)group {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsFilterFlag forChannelGroup:group];
}

- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter {
    [self setVariableSpeedFilter:filter forChannelGroup:_topGroup];
}

- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter forChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannel channel = &parentGroup->channels[index];
    
    [self setVariableSpeedFilter:filter forChannelStruct:channel];
}

- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter forChannelGroup:(AEChannelGroup)group {
    [self setVariableSpeedFilter:filter forChannelStruct:group->channel];
    
    AEChannelGroup parentGroup = NULL;
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

- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannelGroup:(AEChannelGroup)group {
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

- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver fromChannelGroup:(AEChannelGroup)group {
    [self removeCallback:receiver.receiverCallback userInfo:receiver fromChannelGroup:group];
    [receiver release];
}

- (NSArray*)outputReceivers {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsOutputCallbackFlag];
}

- (NSArray*)outputReceiversForChannel:(id<AEAudioPlayable>)channel {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsOutputCallbackFlag forChannel:channel];
}

- (NSArray*)outputReceiversForChannelGroup:(AEChannelGroup)group {
    return [self objectsAssociatedWithCallbacksWithFlags:kCallbackIsOutputCallbackFlag forChannelGroup:group];
}

#pragma mark - Input receivers

- (void)addInputReceiver:(id<AEAudioReceiver>)receiver {
    if ( _inputCallbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"Warning: Maximum number of callbacks reached");
        return;
    }
    
    [receiver retain];
    [self performSynchronousMessageExchangeWithHandler:&addCallbackToTable parameter1:(long)receiver.receiverCallback parameter2:(long)receiver parameter3:0 ioOpaquePtr:&_inputCallbacks];
}

- (void)removeInputReceiver:(id<AEAudioReceiver>)receiver {
    [self performSynchronousMessageExchangeWithHandler:&removeCallbackFromTable parameter1:(long)receiver.receiverCallback parameter2:(long)receiver parameter3:0 ioOpaquePtr:&_inputCallbacks];
    [receiver release];
}

-(NSArray *)inputReceivers {
    return [self objectsAssociatedWithCallbacksFromTable:&_inputCallbacks matchingFlag:0];
}

#pragma mark - Timing receivers

- (void)addTimingReceiver:(id<AEAudioTimingReceiver>)receiver {
    if ( _timingCallbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"Warning: Maximum number of callbacks reached");
        return;
    }
    
    [receiver retain];
    [self performSynchronousMessageExchangeWithHandler:&addCallbackToTable parameter1:(long)receiver.timingReceiverCallback parameter2:(long)receiver parameter3:0 ioOpaquePtr:&_timingCallbacks];
}

- (void)removeTimingReceiver:(id<AEAudioTimingReceiver>)receiver {
    [self performSynchronousMessageExchangeWithHandler:&removeCallbackFromTable parameter1:(long)receiver.timingReceiverCallback parameter2:(long)receiver parameter3:0 ioOpaquePtr:&_timingCallbacks];
    [receiver release];
}

-(NSArray *)timingReceivers {
    return [self objectsAssociatedWithCallbacksFromTable:&_timingCallbacks matchingFlag:0];
}

#pragma mark - Main thread-realtime thread message sending

static void processPendingMessagesOnRealtimeThread(AEAudioController *THIS) {
    // Only call this from the Core Audio thread, or the main thread if audio system is not yet running
    
    int32_t availableBytes;
    message_t *messages = TPCircularBufferTail(&THIS->_realtimeThreadMessageBuffer, &availableBytes);
    int messageCount = availableBytes / sizeof(message_t);
    for ( int i=0; i<messageCount; i++ ) {
        message_t message = messages[i];
        TPCircularBufferConsume(&THIS->_realtimeThreadMessageBuffer, sizeof(message_t));
        
        message.result = 0;
        
        if ( message.handler ) {
            message.result = message.handler(THIS, &message.parameter1, &message.parameter2, &message.parameter3, message.ioOpaquePtr);
        }
        
        if ( message.responseBlock ) {
            TPCircularBufferProduceBytes(&THIS->_mainThreadMessageBuffer, &message, sizeof(message_t));
        }
    }
    
}

-(void)pollForMainThreadMessages {
    int32_t availableBytes;
    message_t *messages = TPCircularBufferTail(&_mainThreadMessageBuffer, &availableBytes);
    int messageCount = availableBytes / sizeof(message_t);
    for ( int i=0; i<messageCount; i++ ) {
        message_t message = messages[i];
        TPCircularBufferConsume(&_mainThreadMessageBuffer, sizeof(message_t));
        
        if ( message.responseBlock ) {
            message.responseBlock(message.result, message.parameter1, message.parameter2, message.parameter3, message.ioOpaquePtr);
            [message.responseBlock release];
        } else if ( message.handler ) {
            message.handler(self, &message.parameter1, &message.parameter2, &message.parameter3, message.ioOpaquePtr);
        }
        
        _pendingResponses--;
    }
    
    if ( _pendingResponses == 0 ) {
        // Replace active poll timer with less demanding idle one
        [_responsePollTimer invalidate];
        [_responsePollTimer release];
        _responsePollTimer = [[NSTimer scheduledTimerWithTimeInterval:kIdleMessagingPollDuration target:self selector:@selector(pollForMainThreadMessages) userInfo:nil repeats:YES] retain];
    }
}

- (void)performAsynchronousMessageExchangeWithHandler:(AEAudioControllerMessageHandler)handler 
                                           parameter1:(long)parameter1 
                                           parameter2:(long)parameter2
                                           parameter3:(long)parameter3
                                          ioOpaquePtr:(void*)ioOpaquePtr 
                                        responseBlock:(void (^)(long result, long parameter1, long parameter2, long parameter3, void *ioOpaquePtr))responseBlock {
    // Only perform on main thread
    if ( responseBlock ) {
        [responseBlock retain];
        _pendingResponses++;
        
        if ( self.running && _responsePollTimer.timeInterval == kIdleMessagingPollDuration ) {
            // Replace idle poll timer with more rapid active polling
            [_responsePollTimer invalidate];
            [_responsePollTimer release];
            _responsePollTimer = [[NSTimer scheduledTimerWithTimeInterval:_preferredBufferDuration target:self selector:@selector(pollForMainThreadMessages) userInfo:nil repeats:YES] retain];
        }
    }
    
    message_t message = (message_t) {
        .handler = handler,
        .parameter1 = parameter1,
        .parameter2 = parameter2,
        .parameter3 = parameter3,
        .ioOpaquePtr = ioOpaquePtr,
        .responseBlock = responseBlock
    };
    
    TPCircularBufferProduceBytes(&_realtimeThreadMessageBuffer, &message, sizeof(message_t));
    
    if ( !self.running ) {
        processPendingMessagesOnRealtimeThread(self);
        [self pollForMainThreadMessages];
    }
}

- (long)performSynchronousMessageExchangeWithHandler:(AEAudioControllerMessageHandler)handler 
                                          parameter1:(long)parameter1 
                                          parameter2:(long)parameter2 
                                          parameter3:(long)parameter3
                                         ioOpaquePtr:(void*)ioOpaquePtr {
    // Only perform on main thread
    __block long returned_response;
    __block BOOL finished = NO;
    
    [self performAsynchronousMessageExchangeWithHandler:handler 
                                             parameter1:parameter1
                                             parameter2:parameter2 
                                             parameter3:parameter3 
                                            ioOpaquePtr:ioOpaquePtr 
                                          responseBlock:^(long result, long parameter1, long parameter2, long parameter3, void *ioOpaquePtr) {
                                              returned_response = result;
                                              finished = YES;
                                          }];
    
    // Wait for response
    while ( !finished ) {
        [self pollForMainThreadMessages];
        if ( finished ) break;
        [NSThread sleepForTimeInterval:_preferredBufferDuration];
    }
    
    return returned_response;
}

void AEAudioControllerSendAsynchronousMessageToMainThread(AEAudioController* audioController, 
                                                          AEAudioControllerMessageHandler handler, 
                                                          long parameter1, 
                                                          long parameter2,
                                                          long parameter3,
                                                          void *ioOpaquePtr){
    message_t message = (message_t) {
        .handler = handler,
        .parameter1 = parameter1,
        .parameter2 = parameter2,
        .parameter3 = parameter3,
        .ioOpaquePtr = ioOpaquePtr,
        .result = 0,
        .responseBlock = nil
    };
    
    TPCircularBufferProduceBytes(&audioController->_mainThreadMessageBuffer, &message, sizeof(message_t));
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

-(void)setInputMode:(ABInputMode)inputMode {
    _inputMode = inputMode;
    
    if ( _inputMode != ABInputModeStereoOrMono ) {
        // Set input stream format to the main audio description
        OSStatus result = AudioUnitSetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &_audioDescription, sizeof(_audioDescription));
        checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
    }
    
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

#pragma mark - Events

-(void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    id<AEAudioPlayable> channel = (id<AEAudioPlayable>)object;
    
    int index;
    AEChannelGroup group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:channel index:&index];
    if ( !group ) return;
    AEChannel channelElement = &group->channels[index];
    
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
        AudioUnitParameterValue value = channel.playing && !channel.muted;
        OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
        checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
        group->channels[index].playing = value;
        
    }  else if ( [keyPath isEqualToString:@"muted"] ) {
        channelElement->muted = channel.muted;
        AudioUnitParameterValue value = ([channel respondsToSelector:@selector(playing)] ? channel.playing : YES) && !channel.muted;
        OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
        checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
        
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
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioRouteChangePropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioInputAvailable, inputAvailablePropertyListener, self);
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
}

- (BOOL)setup {

    // Create a new AUGraph
	OSStatus result = NewAUGraph(&_audioGraph);
    if ( !checkResult(result, "NewAUGraph") ) return NO;
	
    // Input/output unit description
    AudioComponentDescription io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = (_voiceProcessingEnabled && _enableInput ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_RemoteIO),
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
        // Determine number of input channels
        UInt32 numberOfChannels;
        UInt32 size = sizeof(numberOfChannels);
        OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels, &size, &numberOfChannels);
        if ( checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels)") ) {
            if ( _numberOfInputChannels != numberOfChannels ) {
                [self willChangeValueForKey:@"numberOfInputChannels"];
                _numberOfInputChannels = numberOfChannels;
                [self didChangeValueForKey:@"numberOfInputChannels"];
            }
        }
        
        // Set input stream format
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &_audioDescription, sizeof(_audioDescription));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) return NO;
        
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
        if ( _voiceProcessingEnabled ) {
            UInt32 quality = 127;
            result = AudioUnitSetProperty(_ioAudioUnit, kAUVoiceIOProperty_VoiceProcessingQuality, kAudioUnitScope_Global, 1, &quality, sizeof(quality));
            checkResult(result, "AudioUnitSetProperty(kAUVoiceIOProperty_VoiceProcessingQuality)");
        }
    }

    if ( !_topGroup ) {
        // Allocate top-level group
        _topGroup = (AEChannelGroup)calloc(1, sizeof(channel_group_t));
        memset(&_topChannel, 0, sizeof(channel_t));
        _topChannel.type     = kChannelTypeGroup;
        _topChannel.ptr      = _topGroup;
        _topChannel.userInfo = AEAudioSourceMainOutput;
        _topChannel.playing  = YES;
        _topChannel.volume   = 1.0;
        _topChannel.pan      = 0.0;
        _topChannel.muted    = NO;
        _topGroup->channel   = &_topChannel;
    }
    
    // Initialise group
    initialiseGroupChannel(self, &_topChannel, NULL, 0);
    
    // Register a callback to be notified when the main mixer unit renders
    checkResult(AudioUnitAddRenderNotify(_topGroup->mixerAudioUnit, &topRenderNotifyCallback, self), "AudioUnitAddRenderNotify");
    
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

- (void)updateGraph {
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
        
        if ( err != noErr ) {
            checkResult(err, "AUGraphUpdate");
        }
    }
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
        [self setup];
        [self start];
    }
}

static long updateInputDeviceStatusHandler(AEAudioController *THIS, long *ioParameter1, long *ioParameter2, long *ioParameter3, void *ioOpaquePtr) {
    UInt32 numberOfInputChannels = *ioParameter1;
    UInt32 inputAvailable = *ioParameter2;
    AudioStreamBasicDescription *audioDescription = (AudioStreamBasicDescription*)*ioParameter3;
    OSStatus result = AudioUnitSetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, audioDescription, sizeof(AudioStreamBasicDescription));
    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
    
    THIS->_numberOfInputChannels = numberOfInputChannels;
    THIS->_audioInputAvailable = inputAvailable;
    return 0;
}

- (void)updateInputDeviceStatus {
    UInt32 inputAvailable=0;
    
    if ( _enableInput ) {
        // Determine if audio input is available, and the number of input channels available
        UInt32 size = sizeof(inputAvailable);
        OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &size, &inputAvailable);
        checkResult(result, "AudioSessionGetProperty");
        
        UInt32 numberOfInputChannels = 0;
        size = sizeof(numberOfInputChannels);
        if ( inputAvailable ) {
            // Check channels on input
            OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels, &size, &numberOfInputChannels);
            checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels)");
        }
        
        AudioStreamBasicDescription audioDescription = _audioDescription;
        
        if ( _inputMode == ABInputModeStereoOrMono && audioDescription.mChannelsPerFrame == 2 && numberOfInputChannels == 1 ) {
            // Set the input audio description channels to the number of actual available channels
            if ( !(audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ) {
                audioDescription.mBytesPerFrame *= (float)numberOfInputChannels / audioDescription.mChannelsPerFrame;
                audioDescription.mBytesPerPacket *= (float)numberOfInputChannels / audioDescription.mChannelsPerFrame;
            }
            audioDescription.mChannelsPerFrame = numberOfInputChannels;
        } else if ( _inputMode == ABInputModeDualMonoOrMono && numberOfInputChannels == 2 ) {
            // Use a noninterleaved stereo audio description
            audioDescription.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
            audioDescription.mChannelsPerFrame = 2;
            audioDescription.mBytesPerFrame = 
            audioDescription.mBytesPerPacket = audioDescription.mBitsPerChannel / 8;
        }
        
        // Set input stream format and update the properties
        [self performSynchronousMessageExchangeWithHandler:updateInputDeviceStatusHandler parameter1:numberOfInputChannels parameter2:inputAvailable parameter3:(long)&audioDescription ioOpaquePtr:NULL];
        
        if ( _numberOfInputChannels != numberOfInputChannels ) {
            [self willChangeValueForKey:@"numberOfInputChannels"];
            [self didChangeValueForKey:@"numberOfInputChannels"];
        }
        
        if ( _audioInputAvailable != inputAvailable ) {
            [self willChangeValueForKey:@"audioInputAvailable"];
            [self didChangeValueForKey:@"audioInputAvailable"];
        }
    }
    
    [self setAudioSessionCategory];
}

static BOOL initialiseGroupChannel(AEAudioController *THIS, AEChannel channel, AEChannelGroup parentGroup, int index) {
    AEChannelGroup group = (AEChannelGroup)channel->ptr;
    
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
            #if DEBUG
            if ( parentGroup == NULL ) {
                NSLog(@"Note: The AudioStreamBasicDescription you have provided is not natively supported by the iOS mixer unit. Use of filters and output callbacks will result in use of audio converters.");
            }
            #endif
            
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

static void configureGraphStateOfGroupChannel(AEAudioController *THIS, AEChannel channel, AEChannelGroup parentGroup, int index) {
    AEChannelGroup group = (AEChannelGroup)channel->ptr;
    
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

static void configureChannelsInRangeForGroup(AEAudioController *THIS, NSRange range, AEChannelGroup group) {
    for ( int i = range.location; i < range.location+range.length; i++ ) {
        AEChannel channel = &group->channels[i];
        
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
            
            // Make sure the mixer input isn't connected to anything
            AUGraphDisconnectNodeInput(THIS->_audioGraph, group->mixerNode, i);
            
            // Set input stream format
            checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &THIS->_audioDescription, sizeof(THIS->_audioDescription)),
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

static long removeChannelsFromGroup(AEAudioController *THIS, long *matchingPtrArrayPtr, long *matchingUserInfoArrayPtr, long *channelsCount, void* groupPtr) {
    void **ptrArray = (void**)*matchingPtrArrayPtr;
    void **userInfoArray = (void**)*matchingUserInfoArrayPtr;
    AEChannelGroup group = (AEChannelGroup)groupPtr;
    
    // Set new bus count of group
    UInt32 busCount = group->channelCount - *channelsCount;
    assert(busCount >= 0);
    
    if ( busCount == 0 ) busCount = 1; // Note: Mixer must have at least 1 channel. It'll just be silent.
    if ( !checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)),
                      "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return group->channelCount;
    
    if ( group->channelCount - *channelsCount == 0 ) {
        // Remove render callback and disconnect channel 0, as the mixer must have at least 1 channel, and we want to leave it disconnected
        
        // Remove any render callback
        AURenderCallbackStruct rcbs;
        rcbs.inputProc = NULL;
        rcbs.inputProcRefCon = NULL;
        checkResult(AUGraphSetNodeInputCallback(THIS->_audioGraph, group->mixerNode, 0, &rcbs),
                    "AUGraphSetNodeInputCallback");
        
        // Make sure the mixer input isn't connected to anything
        checkResult(AUGraphDisconnectNodeInput(THIS->_audioGraph, group->mixerNode, 0), 
                    "AUGraphDisconnectNodeInput");
    }
    
    for ( int i=0; i < *channelsCount; i++ ) {
        
        // Find the channel in our fixed array
        int index = 0;
        for ( index=0; index < group->channelCount; index++ ) {
            if ( group->channels[index].ptr == ptrArray[i] && group->channels[index].userInfo == userInfoArray[i] ) {
                break;
            }
        }
        
        if ( index < group->channelCount ) {
            group->channelCount--;
            
            if ( index < group->channelCount ) {
                // Shuffle the later elements backwards one space
                memmove(&group->channels[index], &group->channels[index+1], (group->channelCount-index) * sizeof(channel_t));
            }
            
            // Zero out the now-unused space
            memset(&group->channels[group->channelCount], 0, sizeof(channel_t));
        }
    }
    
    checkResult(AUGraphUpdate(THIS->_audioGraph, NULL), "AUGraphUpdate");
    
    configureChannelsInRangeForGroup(THIS, NSMakeRange(0, group->channelCount), group);
    
    return group->channelCount;
}

- (void)gatherChannelsFromGroup:(AEChannelGroup)group intoArray:(NSMutableArray*)array {
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannel channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self gatherChannelsFromGroup:(AEChannelGroup)channel->ptr intoArray:array];
        } else {
            [array addObject:(id)channel->userInfo];
        }
    }
}

- (AEChannelGroup)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo withinGroup:(AEChannelGroup)group index:(int*)index {
    // Find the matching channel in the table for the given group
    for ( int i=0; i < group->channelCount; i++ ) {
        AEChannel channel = &group->channels[i];
        if ( channel->ptr == ptr && channel->userInfo == userInfo ) {
            if ( index ) *index = i;
            return group;
        }
        if ( channel->type == kChannelTypeGroup ) {
            AEChannelGroup match = [self searchForGroupContainingChannelMatchingPtr:ptr userInfo:userInfo withinGroup:channel->ptr index:index];
            if ( match ) return match;
        }
    }
    
    return NULL;
}

- (AEChannelGroup)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo index:(int*)index {
    return [self searchForGroupContainingChannelMatchingPtr:ptr userInfo:userInfo withinGroup:_topGroup index:(int*)index];
}

- (void)releaseResourcesForGroup:(AEChannelGroup)group {
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
        AEChannel channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self releaseResourcesForGroup:(AEChannelGroup)channel->ptr];
            channel->ptr = NULL;
        }
    }
    
    free(group);
}

- (void)markGroupTorndown:(AEChannelGroup)group {
    group->graphState = kGroupGraphStateUninitialized;
    group->mixerNode = 0;
    group->mixerAudioUnit = NULL;
    for ( int i=0; i<group->channelCount; i++ ) {
        AEChannel channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self markGroupTorndown:(AEChannelGroup)channel->ptr];
        }
    }
}

#pragma mark - Callback management

static long addCallbackToTable(AEAudioController *THIS, long *callbackPtr, long *userInfoPtr, long *flags, void* callbackTablePtr) {
    callback_table_t* table = (callback_table_t*)callbackTablePtr;
    
    table->callbacks[table->count].callback = (void*)*callbackPtr;
    table->callbacks[table->count].userInfo = (void*)*userInfoPtr;
    table->callbacks[table->count].flags = (uint8_t)*flags;
    table->count++;
    
    return table->count;
}

static long removeCallbackFromTable(AEAudioController *THIS, long *callbackPtr, long *userInfoPtr, long *unused, void* callbackTablePtr) {
    callback_table_t* table = (callback_table_t*)callbackTablePtr;
    
    // Find the item in our fixed array
    int index = 0;
    for ( index=0; index<table->count; index++ ) {
        if ( table->callbacks[index].callback == (void*)*callbackPtr && table->callbacks[index].userInfo == (void*)*userInfoPtr ) {
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
    
    return table->count;
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
    AEChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannel channel = &parentGroup->channels[index];
    
    [self performSynchronousMessageExchangeWithHandler:&addCallbackToTable 
                                            parameter1:(long)callback 
                                            parameter2:(long)userInfo 
                                            parameter3:flags 
                                           ioOpaquePtr:&channel->callbacks];
}

- (void)addCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannelGroup:(AEChannelGroup)group {
    [self performSynchronousMessageExchangeWithHandler:&addCallbackToTable 
                                            parameter1:(long)callback 
                                            parameter2:(long)userInfo 
                                            parameter3:flags 
                                           ioOpaquePtr:&group->channel->callbacks];

    AEChannelGroup parentGroup = NULL;
    int index=0;
    if ( group != _topGroup ) {
        parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
        NSAssert(parentGroup != NULL, @"Channel group not found");
    }

    configureGraphStateOfGroupChannel(self, group->channel, parentGroup, index);
}

- (void)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannel:(id<AEAudioPlayable>)channelObj {
    int index=0;
    AEChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannel channel = &parentGroup->channels[index];
    
    [self performSynchronousMessageExchangeWithHandler:&removeCallbackFromTable 
                                            parameter1:(long)callback 
                                            parameter2:(long)userInfo
                                            parameter3:0
                                           ioOpaquePtr:&channel->callbacks];
}

- (void)removeCallback:(AEAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannelGroup:(AEChannelGroup)group {
    [self performSynchronousMessageExchangeWithHandler:&removeCallbackFromTable 
                                            parameter1:(long)callback 
                                            parameter2:(long)userInfo
                                            parameter3:0 
                                           ioOpaquePtr:&group->channel->callbacks];
    
    AEChannelGroup parentGroup = NULL;
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
    AEChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AEChannel channel = &parentGroup->channels[index];
    
    return [self objectsAssociatedWithCallbacksFromTable:&channel->callbacks matchingFlag:flags];
}

- (NSArray*)objectsAssociatedWithCallbacksWithFlags:(uint8_t)flags forChannelGroup:(AEChannelGroup)group {
    return [self objectsAssociatedWithCallbacksFromTable:&group->channel->callbacks matchingFlag:flags];
}

- (void)setVariableSpeedFilter:(id<AEAudioVariableSpeedFilter>)filter forChannelStruct:(AEChannel)channel {
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        if ( (channel->callbacks.callbacks[i].flags & kCallbackIsVariableSpeedFilterFlag ) ) {
            // Remove the old callback
            [self performSynchronousMessageExchangeWithHandler:&removeCallbackFromTable
                                                    parameter1:(long)channel->callbacks.callbacks[i].callback
                                                    parameter2:(long)channel->callbacks.callbacks[i].userInfo
                                                    parameter3:0
                                                   ioOpaquePtr:&channel->callbacks];
            break;
            [(id)(long)channel->callbacks.callbacks[i].userInfo release];
        }
    }
    
    if ( filter ) {
        [filter retain];
        [self performSynchronousMessageExchangeWithHandler:&addCallbackToTable 
                                                parameter1:(long)filter.filterCallback
                                                parameter2:(long)filter 
                                                parameter3:kCallbackIsVariableSpeedFilterFlag 
                                               ioOpaquePtr:&channel->callbacks];
    }
}

static void handleCallbacksForChannel(AEChannel channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    // Pass audio to filters
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kCallbackIsFilterFlag ) {
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, channel->userInfo, inTimeStamp, inNumberFrames, ioData);
        }
    }
    
    // And finally pass to output callbacks
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kCallbackIsOutputCallbackFlag ) {
            ((AEAudioControllerAudioCallback)callback->callback)(callback->userInfo, channel->userInfo, inTimeStamp, inNumberFrames, ioData);
        }
    }
}

@end
