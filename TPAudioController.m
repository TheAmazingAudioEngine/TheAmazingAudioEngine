//
//  TPAudioController.m
//
//  Created by Michael Tyson on 25/11/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "TPAudioController.h"
#import <UIKit/UIKit.h>
#import <libkern/OSAtomic.h>
#import "TPACCircularBuffer.h"
#include <sys/types.h>
#include <sys/sysctl.h>

#ifdef TRIAL
#import "TPTrialModeController.h"
#endif

#define kMaximumChannelsPerGroup 100
#define kMaximumCallbacksPerSource 15
#define kMessageBufferLength 50
#define kIdleMessagingPollDuration 0.2
#define kRenderConversionScratchBufferSizeInFrames 4096

const NSString *kTPAudioControllerCallbackKey = @"callback";
const NSString *kTPAudioControllerUserInfoKey = @"userinfo";

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
    callback_table_t callbacks;
} channel_t;

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
    float               volume;
    float               pan;
    BOOL                muted;
} channel_group_t;

/*!
 * Channel producer argument
 */
typedef struct {
    channel_t *channel;
    const AudioTimeStamp *inTimeStamp;
    AudioUnitRenderActionFlags *ioActionFlags;
} channel_producer_arg_t;

#pragma mark Messaging

/*!
 * Message 
 */
typedef struct _message_t {
    TPAudioControllerMessageHandler handler;
    long parameter1;
    long parameter2;
    long parameter3;
    void *ioOpaquePtr;
    long result;
    void (^responseBlock)(long result, long parameter1, long parameter2, long parameter3, void *ioOpaquePtr);
} message_t;

#pragma mark -

@interface TPAudioController () {
    AUGraph             _audioGraph;
    AUNode              _ioNode;
    AudioUnit           _ioAudioUnit;
    BOOL                _audioSessionSetup;
    BOOL                _runningPriorToInterruption;
    
    channel_group_t     _channels;
    channel_t           _topLevelChannel;
    
    callback_table_t    _inputCallbacks;
    callback_table_t    _timingCallbacks;
    
    TPACCircularBuffer  _realtimeThreadMessageBuffer;
    TPACCircularBuffer  _mainThreadMessageBuffer;
    NSTimer            *_responsePollTimer;
    int                 _pendingResponses;
    
    char               *_renderConversionScratchBuffer;
}

- (BOOL)setup;
- (void)teardown;
- (void)updateGraph;

- (void)pollForMainThreadMessages;
static void processPendingMessagesOnRealtimeThread(TPAudioController *THIS);

- (BOOL)initialiseGroupChannel:(channel_t*)channel parentGroup:(TPChannelGroup)parentGroup indexInParent:(int)index;
- (void)configureGraphStateOfGroupChannel:(channel_t*)channel parentGroup:(TPChannelGroup)parentGroup indexInParent:(int)index;
- (void)configureChannelsInRange:(NSRange)range forGroup:(TPChannelGroup)group;
- (TPChannelGroup)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo index:(int*)index;

- (void)updateVoiceProcessingSettings;
static void updateInputDeviceStatus(TPAudioController *THIS);

static long addCallbackToTable(TPAudioController *THIS, long *callbackTablePtr, long *callbackPtr, long *userInfoPtr, void* outPtr);
static long removeCallbackFromTable(TPAudioController *THIS, long *callbackTablePtr, long *callbackPtr, long *userInfoPtr, void* outPtr);
- (NSArray *)callbacksFromTable:(callback_table_t*)table matchingFlag:(uint8_t)flag;
- (void)addCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannel:(id<TPAudioPlayable>)channelObj;
- (void)addCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannelGroup:(TPChannelGroup)group;
- (void)removeCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannel:(id<TPAudioPlayable>)channelObj;
- (void)removeCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannelGroup:(TPChannelGroup)group;
- (NSArray*)callbacksWithFlags:(uint8_t)flags;
- (NSArray*)callbacksWithFlags:(uint8_t)flags forChannel:(id<TPAudioPlayable>)channelObj;
- (NSArray*)callbacksWithFlags:(uint8_t)flags forChannelGroup:(TPChannelGroup)group;
- (void)setVariableSpeedFilter:(TPAudioControllerVariableSpeedFilterCallback)filter userInfo:(void *)userInfo forChannelStruct:(channel_t*)channel;
- (void)releaseGroupResources:(TPChannelGroup)group freeGroupMemory:(BOOL)freeGroup;
- (void)teardownGroup:(TPChannelGroup)group;

static void handleCallbacksForChannel(channel_t *channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData);
static OSStatus channelAudioProducer(void *userInfo, AudioBufferList *audio, UInt32 frames);
@end

@implementation TPAudioController
@synthesize audioInputAvailable         = _audioInputAvailable, 
            numberOfInputChannels       = _numberOfInputChannels, 
            enableInput                 = _enableInput, 
            muteOutput                  = _muteOutput, 
            voiceProcessingEnabled      = _voiceProcessingEnabled,
            voiceProcessingOnlyForSpeakerAndMicrophone = _voiceProcessingOnlyForSpeakerAndMicrophone,
            playingThroughDeviceSpeaker = _playingThroughDeviceSpeaker,
            preferredBufferDuration     = _preferredBufferDuration, 
            receiveMonoInputAsBridgedStereo = _receiveMonoInputAsBridgedStereo, 
            audioDescription            = _audioDescription, 
            audioUnit                   = _ioAudioUnit;

@dynamic    running;

#pragma mark - Audio session callbacks

static void interruptionListener(void *inClientData, UInt32 inInterruption) {
	TPAudioController *THIS = (TPAudioController *)inClientData;
    
	if (inInterruption == kAudioSessionEndInterruption) {
        if ( [[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground || THIS->_runningPriorToInterruption ) {
            // make sure we are again the active session
            checkResult(AudioSessionSetActive(true), "AudioSessionSetActive");
        }
        
        if ( THIS->_runningPriorToInterruption ) {
            [THIS start];
        }
	} else if (inInterruption == kAudioSessionBeginInterruption) {
        THIS->_runningPriorToInterruption = THIS.running;
        if ( THIS->_runningPriorToInterruption ) {
            [THIS stop];
        }
    }
}

static void audioRouteChangePropertyListener(void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void *inData) {
    if (inID == kAudioSessionProperty_AudioRouteChange) {
        TPAudioController *THIS = (TPAudioController *)inClientData;
        
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

        if ( THIS->_playingThroughDeviceSpeaker != playingThroughSpeaker ) {
            [THIS willChangeValueForKey:@"playingThroughDeviceSpeaker"];
            THIS->_playingThroughDeviceSpeaker = playingThroughSpeaker;
            [THIS didChangeValueForKey:@"playingThroughDeviceSpeaker"];
            
            if ( THIS->_voiceProcessingEnabled && THIS->_voiceProcessingOnlyForSpeakerAndMicrophone ) {
                [THIS updateVoiceProcessingSettings];
            }
        }
        
        // Check channels on input
        AudioStreamBasicDescription inDesc;
        UInt32 inDescSize = sizeof(inDesc);
        OSStatus result = AudioUnitGetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &inDesc, &inDescSize);
        if ( checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") && inDesc.mChannelsPerFrame != 0 ) {
            if ( THIS->_numberOfInputChannels != inDesc.mChannelsPerFrame ) {
                [THIS willChangeValueForKey:@"numberOfInputChannels"];
                THIS->_numberOfInputChannels = inDesc.mChannelsPerFrame;
                [THIS didChangeValueForKey:@"numberOfInputChannels"];
            }
        }
    }
}

static void inputAvailablePropertyListener (void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void *inData) {
    TPAudioController *THIS = (TPAudioController *)inClientData;
    if ( inID == kAudioSessionProperty_AudioInputAvailable ) {
        updateInputDeviceStatus(THIS);
    }
}

#pragma mark -
#pragma mark Input and render callbacks

static OSStatus renderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    channel_t *channel = (channel_t*)inRefCon;
    
    if ( channel->ptr == NULL || !channel->playing ) {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    
    channel_producer_arg_t arg = { .channel = channel, .inTimeStamp = inTimeStamp, .ioActionFlags = ioActionFlags };
    
    // Use variable speed filter, if there is one
    TPAudioControllerVariableSpeedFilterCallback varispeedFilter = NULL;
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
   
    TPAudioController *THIS = (TPAudioController *)inRefCon;

    for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
        callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
        ((TPAudioControllerTimingCallback)callback->callback)(callback->userInfo, inTimeStamp, TPAudioTimingContextInput);
    }
    
    int sampleCount = inNumberFrames * THIS->_audioDescription.mChannelsPerFrame;
    
    // Render audio into buffer
    struct bufferlist_t { AudioBufferList bufferList; AudioBuffer nextBuffer; } buffers;
    
    AudioStreamBasicDescription asbd = THIS->_audioDescription;
    
    buffers.bufferList.mNumberBuffers = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? asbd.mChannelsPerFrame : 1;
    
    buffers.bufferList.mBuffers[0].mNumberChannels = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : asbd.mChannelsPerFrame;
    buffers.bufferList.mBuffers[0].mData = NULL;
    buffers.bufferList.mBuffers[0].mDataByteSize = inNumberFrames * asbd.mBytesPerFrame;
    
    if ( asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved && asbd.mChannelsPerFrame == 2 ) {
        buffers.bufferList.mBuffers[1].mNumberChannels = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : asbd.mChannelsPerFrame;
        buffers.bufferList.mBuffers[1].mData = NULL;
        buffers.bufferList.mBuffers[1].mDataByteSize = inNumberFrames * asbd.mBytesPerFrame;
    }
    
    OSStatus err = AudioUnitRender(THIS->_ioAudioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &buffers.bufferList);
    if ( !checkResult(err, "AudioUnitRender") ) { 
        return err; 
    }
    
    if ( THIS->_numberOfInputChannels == 1 && asbd.mChannelsPerFrame == 2 && !THIS->_receiveMonoInputAsBridgedStereo ) {
        // Convert audio from stereo with only one channel provided, to proper mono
        if ( asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved ) {
            buffers.bufferList.mNumberBuffers = 1;
        } else {
            // Need to replaced interleaved stereo audio with just mono audio
            sampleCount /= 2;
            buffers.bufferList.mBuffers[0].mDataByteSize /= 2;
            
            // We support doing this for a couple of different audio formats
            if ( asbd.mBitsPerChannel == sizeof(SInt16)*8 ) {
                SInt16 *buffer = buffers.bufferList.mBuffers[0].mData;
                for ( UInt32 i = 0, j = 0; i < sampleCount; i++, j+=2 ) {
                    buffer[i] = buffer[j];
                }
            } else if ( asbd.mBitsPerChannel == sizeof(SInt32)*8 ) {
                SInt32 *buffer = buffers.bufferList.mBuffers[0].mData;
                for ( UInt32 i = 0, j = 0; i < sampleCount; i++, j+=2 ) {
                    buffer[i] = buffer[j];
                }
            } else {
                printf("Unsupported audio format (%lu bits per channel) for conversion of bridged stereo to mono input\n", asbd.mBitsPerChannel);
                assert(0);
            }
        }
    }
        
    // Pass audio to input callbacks
    for ( int i=0; i<THIS->_inputCallbacks.count; i++ ) {
        callback_t *callback = &THIS->_inputCallbacks.callbacks[i];
        ((TPAudioControllerAudioCallback)callback->callback)(callback->userInfo, inTimeStamp, inNumberFrames, &buffers.bufferList);
    }
    
    return noErr;
}

static OSStatus groupRenderNotifyCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    channel_t *channel = (channel_t*)inRefCon;
    TPChannelGroup group = (TPChannelGroup)channel->ptr;
    
    if ( (*ioActionFlags & kAudioUnitRenderAction_PostRender) ) {
        // After render
        AudioBufferList *bufferList;
        
        if ( group->converterRequired ) {
            // Initialise output buffer
            struct { AudioBufferList bufferList; AudioBuffer nextBuffer; } buffers;
            bufferList = &buffers.bufferList;
            bufferList->mNumberBuffers = (group->audioConverterTargetFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? group->audioConverterTargetFormat.mChannelsPerFrame : 1;
            char *dataPtr = group->audioConverterScratchBuffer;
            for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
                bufferList->mBuffers[i].mNumberChannels = (group->audioConverterTargetFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : group->audioConverterTargetFormat.mChannelsPerFrame;
                bufferList->mBuffers[i].mData           = dataPtr;
                bufferList->mBuffers[i].mDataByteSize   = group->audioConverterTargetFormat.mBytesPerFrame * inNumberFrames;
                dataPtr += bufferList->mBuffers[i].mDataByteSize;
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
    
    TPAudioController *THIS = (TPAudioController *)inRefCon;
        
    if ( *ioActionFlags & kAudioUnitRenderAction_PreRender ) {
        // Before render: Perform timing callbacks
        for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
            callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
            ((TPAudioControllerTimingCallback)callback->callback)(callback->userInfo, inTimeStamp, TPAudioTimingContextOutput);
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
    _voiceProcessingEnabled = useVoiceProcessing;
    _preferredBufferDuration = 0.005;
    _receiveMonoInputAsBridgedStereo = YES;
    _voiceProcessingOnlyForSpeakerAndMicrophone = YES;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    
    TPACCircularBufferInit(&_realtimeThreadMessageBuffer, kMessageBufferLength * sizeof(message_t));
    TPACCircularBufferInit(&_mainThreadMessageBuffer, kMessageBufferLength * sizeof(message_t));
    
    if ( ![self setup] ) {
        [self release];
        return nil;
    }
    
#ifdef TRIAL
    [[TPTrialModeController alloc] init];
#endif
    
    return self;
}

- (void)dealloc {
    if ( _responsePollTimer ) [_responsePollTimer invalidate];
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
    
    [self releaseGroupResources:&_channels freeGroupMemory:NO];
    
    TPACCircularBufferCleanup(&_realtimeThreadMessageBuffer);
    TPACCircularBufferCleanup(&_mainThreadMessageBuffer);
    
    [super dealloc];
}

- (void)start {
    OSStatus result;
    
    if ( !_audioSessionSetup ) {
        // Initialise the audio session
        result = AudioSessionInitialize(NULL, NULL, interruptionListener, self);
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
        
        _audioSessionSetup = YES;
    }
    
    // Determine if audio input is available, and the number of input channels available
    updateInputDeviceStatus(self);
    
#if !TARGET_IPHONE_SIMULATOR
    // Force audio to speaker, not receiver
    CFStringRef route;
    UInt32 size = sizeof(route);
    result = AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route);
    if ( checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_AudioRoute)") ) {
        if ( [(NSString*)route isEqualToString:@"ReceiverAndMicrophone"] ) {
            UInt32 newRoute = kAudioSessionOverrideAudioRoute_Speaker;
            result = AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute,  sizeof(route), &newRoute);
            checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute)");
        }
    }
    CFRelease(route);
#endif
    
    // Start messaging poll timer
    _responsePollTimer = [NSTimer scheduledTimerWithTimeInterval:kIdleMessagingPollDuration target:self selector:@selector(pollForMainThreadMessages) userInfo:nil repeats:YES];
    
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
    [self addChannels:channels toChannelGroup:&_channels];
}

- (void)removeChannels:(NSArray *)channels {
    // Find parent groups of each channel, and remove channels (in batches, if possible)
    NSMutableArray *siblings = [NSMutableArray array];
    TPChannelGroup lastGroup = NULL;
    for ( id<TPAudioPlayable> channel in channels ) {
        TPChannelGroup group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:channel index:NULL];
        
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

- (void)gatherChannelsFromGroup:(TPChannelGroup)group intoArray:(NSMutableArray*)array {
    for ( int i=0; i<group->channelCount; i++ ) {
        channel_t *channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self gatherChannelsFromGroup:(TPChannelGroup)channel->ptr intoArray:array];
        } else {
            [array addObject:(id)channel->userInfo];
        }
    }
}

-(NSArray *)channels {
    NSMutableArray *channels = [NSMutableArray array];
    [self gatherChannelsFromGroup:&_channels intoArray:channels];
    return channels;
}

- (TPChannelGroup)createChannelGroup {
    return [self createChannelGroupWithinChannelGroup:&_channels];
}

- (TPChannelGroup)createChannelGroupWithinChannelGroup:(TPChannelGroup)parentGroup {
    if ( parentGroup->channelCount == kMaximumChannelsPerGroup ) {
        NSLog(@"Maximum channels reached in group %p\n", parentGroup);
        return NULL;
    }
    
    // Allocate group
    TPChannelGroup group = (TPChannelGroup)calloc(1, sizeof(channel_group_t));
    group->volume = 1.0;
    group->pan = 0.0;
    
    // Add group as a channel to the parent group
    int groupIndex = parentGroup->channelCount;
    
    channel_t *channel = &parentGroup->channels[groupIndex];
    memset(channel, 0, sizeof(channel_t));
    channel->type = kChannelTypeGroup;
    channel->ptr = group;
    channel->playing = YES;
    
    parentGroup->channelCount++;    

    // Initialise group
    [self initialiseGroupChannel:channel parentGroup:parentGroup indexInParent:groupIndex];

    [self updateGraph];
    
    return group;
}

static long removeChannelsFromGroup(TPAudioController *THIS, long *matchingPtrArrayPtr, long *matchingUserInfoArrayPtr, long *channelsCount, void* groupPtr) {
    void **ptrArray = (void**)*matchingPtrArrayPtr;
    void **userInfoArray = (void**)*matchingUserInfoArrayPtr;
    TPChannelGroup group = (TPChannelGroup)groupPtr;
    
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
    
    return group->channelCount;
}

- (void)removeChannelGroup:(TPChannelGroup)group {
    
    // Find group's parent
    TPChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:NULL];
    NSAssert(parentGroup != NULL, @"Channel group not found");
    
    // Move all channels beneath this group to the root group
    NSMutableArray *channels = [NSMutableArray array];
    [self gatherChannelsFromGroup:group intoArray:channels];
    if ( [channels count] > 0 ) {
        [self addChannels:channels toChannelGroup:&_channels];
    }

    // Set new bus count of parent group
    UInt32 busCount = parentGroup->channelCount - 1;
    OSStatus result = AudioUnitSetProperty(parentGroup->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // Remove the group from the parent group's table, on the core audio thread
    void* ptrMatchArray[1] = { group };
    void* userInfoMatchArray[1] = { NULL };
    [self performSynchronousMessageExchangeWithHandler:&removeChannelsFromGroup parameter1:(long)&ptrMatchArray parameter2:(long)&userInfoMatchArray parameter3:1 ioOpaquePtr:parentGroup];

    // Reconfigure all channels for container group
    [self configureChannelsInRange:NSMakeRange(0, parentGroup->channelCount) forGroup:parentGroup];
    
    // Release group resources
    [self releaseGroupResources:group freeGroupMemory:YES];
    
    [self updateGraph];
}

- (NSArray*)topLevelChannelGroups {
    return [self channelGroupsInChannelGroup:&_channels];
}

- (NSArray*)channelGroupsInChannelGroup:(TPChannelGroup)group {
    NSMutableArray *groups = [NSMutableArray array];
    for ( int i=0; i<group->channelCount; i++ ) {
        channel_t *channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [groups addObject:[NSValue valueWithPointer:channel->ptr]];
        }
    }
    return groups;
}

- (void)addChannels:(NSArray*)channels toChannelGroup:(TPChannelGroup)group {
    // Remove the channels from the system, if they're already added
    [self removeChannels:channels];
    
    // Add to group's channel array
    for ( id<TPAudioPlayable> channel in channels ) {
        if ( group->channelCount == kMaximumChannelsPerGroup ) {
            NSLog(@"Warning: Channel limit reached");
            break;
        }
        
        [channel retain];
        
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"playing", @"muted", nil] ) {
            [(NSObject*)channel addObserver:self forKeyPath:property options:0 context:NULL];
        }
        
        channel_t *channelElement = &group->channels[group->channelCount++];
        
        channelElement->type = kChannelTypeChannel;
        channelElement->ptr = channel.renderCallback;
        channelElement->userInfo = channel;
        channelElement->playing = [channel respondsToSelector:@selector(playing)] ? channel.playing : YES;
    }
    
    // Set bus count
    UInt32 busCount = group->channelCount;
    OSStatus result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // Configure each channel
    [self configureChannelsInRange:NSMakeRange(group->channelCount - [channels count], [channels count]) forGroup:group];
    
    [self updateGraph];
}

- (void)removeChannels:(NSArray*)channels fromChannelGroup:(TPChannelGroup)group {
    // Set new bus count
    UInt32 busCount = group->channelCount - [channels count];
    
    NSAssert(busCount >= 0, @"Tried to remove channels that weren't added");
    
    if ( busCount == 0 ) busCount = 1; // Note: Mixer must have at least 1 channel. It'll just be silent.
    OSStatus result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    if ( group->channelCount - [channels count] == 0 ) {
        // Remove render callback and disconnect channel 0, as the mixer must have at least 1 channel, and we want to leave it disconnected

        // Remove any render callback
        AURenderCallbackStruct rcbs;
        rcbs.inputProc = NULL;
        rcbs.inputProcRefCon = NULL;
        checkResult(AUGraphSetNodeInputCallback(_audioGraph, group->mixerNode, 0, &rcbs),
                    "AUGraphSetNodeInputCallback");
        
        // Make sure the mixer input isn't connected to anything
        checkResult(AUGraphDisconnectNodeInput(_audioGraph, group->mixerNode, 0), 
                    "AUGraphDisconnectNodeInput");
    }
    
    [self updateGraph];
    
    // Remove the channels from the tables, on the core audio thread
    void* ptrMatchArray[[channels count]];
    void* userInfoMatchArray[[channels count]];
    for ( int i=0; i<[channels count]; i++ ) {
        ptrMatchArray[i] = ((id<TPAudioPlayable>)[channels objectAtIndex:i]).renderCallback;
        userInfoMatchArray[i] = [channels objectAtIndex:i];
    }
    [self performSynchronousMessageExchangeWithHandler:&removeChannelsFromGroup parameter1:(long)&ptrMatchArray parameter2:(long)&userInfoMatchArray parameter3:[channels count] ioOpaquePtr:group];
    
    // Now reconfigure all channels
    [self configureChannelsInRange:NSMakeRange(0, group->channelCount) forGroup:group];
    
    // Finally, stop observing and release channels
    for ( NSObject *channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"playing", @"muted", nil] ) {
            [(NSObject*)channel removeObserver:self forKeyPath:property];
        }
    }
    [channels makeObjectsPerformSelector:@selector(release)];
}

- (NSArray*)channelsInChannelGroup:(TPChannelGroup)group {
    NSMutableArray *channels = [NSMutableArray array];
    for ( int i=0; i<group->channelCount; i++ ) {
        if ( group->channels[i].type == kChannelTypeChannel ) {
            [channels addObject:(id)group->channels[i].userInfo];
        }
    }
    return channels;
}

- (void)setVolume:(float)volume forChannelGroup:(TPChannelGroup)group {
    int index;
    TPChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AudioUnitParameterValue value = group->volume = volume;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
}

- (void)setPan:(float)pan forChannelGroup:(TPChannelGroup)group {
    int index;
    TPChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AudioUnitParameterValue value = group->pan = pan;
    if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
    if ( value == 1.0 ) value = 0.999;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
}

- (void)setMuted:(BOOL)muted forChannelGroup:(TPChannelGroup)group {
    int index;
    TPChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    AudioUnitParameterValue value = group->muted = muted;
    OSStatus result = AudioUnitSetParameter(parentGroup->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
}

#pragma mark - Filters

- (void)addFilter:(TPAudioControllerAudioCallback)filter userInfo:(void*)userInfo {
    [self addCallback:filter userInfo:userInfo flags:kCallbackIsFilterFlag forChannelGroup:&_channels];
}

- (void)addFilter:(TPAudioControllerAudioCallback)filter userInfo:(void*)userInfo toChannel:(id<TPAudioPlayable>)channel {
    [self addCallback:filter userInfo:userInfo flags:kCallbackIsFilterFlag forChannel:channel];
}

- (void)addFilter:(TPAudioControllerAudioCallback)filter userInfo:(void*)userInfo toChannelGroup:(TPChannelGroup)group {
    [self addCallback:filter userInfo:userInfo flags:kCallbackIsFilterFlag forChannelGroup:group];
}

- (void)removeFilter:(TPAudioControllerAudioCallback)filter userInfo:(void*)userInfo {
    [self removeFilter:filter userInfo:userInfo fromChannelGroup:&_channels];
}

- (void)removeFilter:(TPAudioControllerAudioCallback)filter userInfo:(void*)userInfo fromChannel:(id<TPAudioPlayable>)channel {
    [self removeCallback:filter userInfo:userInfo fromChannel:channel];
}

- (void)removeFilter:(TPAudioControllerAudioCallback)filter userInfo:(void*)userInfo fromChannelGroup:(TPChannelGroup)group {
    [self removeCallback:filter userInfo:userInfo fromChannelGroup:group];
}

- (NSArray*)filters {
    return [self callbacksWithFlags:kCallbackIsFilterFlag];
}

- (NSArray*)filtersForChannel:(id<TPAudioPlayable>)channel {
    return [self callbacksWithFlags:kCallbackIsFilterFlag forChannel:channel];
}

- (NSArray*)filtersForChannelGroup:(TPChannelGroup)group {
    return [self callbacksWithFlags:kCallbackIsFilterFlag forChannelGroup:group];
}

#pragma mark - Variable speed filters

- (void)setVariableSpeedFilter:(TPAudioControllerVariableSpeedFilterCallback)filter userInfo:(void*)userInfo {
    [self setVariableSpeedFilter:filter userInfo:userInfo forChannelGroup:&_channels];
}

- (void)setVariableSpeedFilter:(TPAudioControllerVariableSpeedFilterCallback)filter userInfo:(void*)userInfo forChannel:(id<TPAudioPlayable>)channelObj {
    int index=0;
    TPChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    channel_t *channel = &parentGroup->channels[index];
    
    [self setVariableSpeedFilter:filter userInfo:userInfo forChannelStruct:channel];
}

- (void)setVariableSpeedFilter:(TPAudioControllerVariableSpeedFilterCallback)filter userInfo:(void*)userInfo forChannelGroup:(TPChannelGroup)group {
    channel_t *channel = NULL;
    TPChannelGroup parentGroup = NULL;
    int index=0;
    
    if ( group == &_channels ) {
        channel = &_topLevelChannel;
    } else {
        parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
        NSAssert(parentGroup != NULL, @"Channel group not found");
        channel = &parentGroup->channels[index];
    }
    
    [self setVariableSpeedFilter:filter userInfo:userInfo forChannelStruct:channel];
    
    [self configureGraphStateOfGroupChannel:channel parentGroup:parentGroup indexInParent:index];
}

#pragma mark - Output callbacks

- (void)addOutputCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo {
    [self addCallback:callback userInfo:userInfo flags:kCallbackIsOutputCallbackFlag forChannelGroup:&_channels];
}

- (void)addOutputCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo forChannel:(id<TPAudioPlayable>)channel {
    [self addCallback:callback userInfo:userInfo flags:kCallbackIsOutputCallbackFlag forChannel:channel];
}

- (void)addOutputCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo forChannelGroup:(TPChannelGroup)group {
    [self addCallback:callback userInfo:userInfo flags:kCallbackIsOutputCallbackFlag forChannelGroup:group];
}

- (void)removeOutputCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo {
    [self removeCallback:callback userInfo:userInfo fromChannelGroup:&_channels];
}

- (void)removeOutputCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannel:(id<TPAudioPlayable>)channel {
    [self removeCallback:callback userInfo:userInfo fromChannel:channel];
}

- (void)removeOutputCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannelGroup:(TPChannelGroup)group {
    [self removeCallback:callback userInfo:userInfo fromChannelGroup:group];
}

- (NSArray*)outputCallbacks {
    return [self callbacksWithFlags:kCallbackIsOutputCallbackFlag];
}

- (NSArray*)outputCallbacksForChannel:(id<TPAudioPlayable>)channel {
    return [self callbacksWithFlags:kCallbackIsOutputCallbackFlag forChannel:channel];
}

- (NSArray*)outputCallbacksForChannelGroup:(TPChannelGroup)group {
    return [self callbacksWithFlags:kCallbackIsOutputCallbackFlag forChannelGroup:group];
}

#pragma mark - Other callbacks

- (void)addInputCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo {
    if ( _inputCallbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"Warning: Maximum number of callbacks reached");
        return;
    }
    
    [self performAsynchronousMessageExchangeWithHandler:&addCallbackToTable parameter1:(long)callback parameter2:(long)userInfo parameter3:0 ioOpaquePtr:&_inputCallbacks responseBlock:nil];
}

- (void)removeInputCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo {
    [self performAsynchronousMessageExchangeWithHandler:&removeCallbackFromTable parameter1:(long)callback parameter2:(long)userInfo parameter3:0 ioOpaquePtr:&_inputCallbacks responseBlock:nil];
}

-(NSArray *)inputCallbacks {
    return [self callbacksFromTable:&_inputCallbacks matchingFlag:0];
}

- (void)addTimingCallback:(TPAudioControllerTimingCallback)callback userInfo:(void *)userInfo {
    if ( _timingCallbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"Warning: Maximum number of callbacks reached");
        return;
    }
    
    [self performAsynchronousMessageExchangeWithHandler:&addCallbackToTable parameter1:(long)callback parameter2:(long)userInfo parameter3:0 ioOpaquePtr:&_timingCallbacks responseBlock:nil];
}

- (void)removeTimingCallback:(TPAudioControllerTimingCallback)callback userInfo:(void *)userInfo {
    [self performAsynchronousMessageExchangeWithHandler:&removeCallbackFromTable parameter1:(long)callback parameter2:(long)userInfo parameter3:0 ioOpaquePtr:&_timingCallbacks responseBlock:nil];
}

-(NSArray *)timingCallbacks {
    return [self callbacksFromTable:&_timingCallbacks matchingFlag:0];
}

#pragma mark - Main thread-realtime thread message sending

static void processPendingMessagesOnRealtimeThread(TPAudioController *THIS) {
    // Only call this from the Core Audio thread, or the main thread if audio system is not yet running
    
    int32_t availableBytes;
    message_t *messages = TPACCircularBufferTail(&THIS->_realtimeThreadMessageBuffer, &availableBytes);
    int messageCount = availableBytes / sizeof(message_t);
    for ( int i=0; i<messageCount; i++ ) {
        message_t message = messages[i];
        TPACCircularBufferConsume(&THIS->_realtimeThreadMessageBuffer, sizeof(message_t));
        
        message.result = 0;
        
        if ( message.handler ) {
            message.result = message.handler(THIS, &message.parameter1, &message.parameter2, &message.parameter3, message.ioOpaquePtr);
        }
        
        if ( message.responseBlock ) {
            TPACCircularBufferProduceBytes(&THIS->_mainThreadMessageBuffer, &message, sizeof(message_t));
        }
    }
    
}

-(void)pollForMainThreadMessages {
    int32_t availableBytes;
    message_t *messages = TPACCircularBufferTail(&_mainThreadMessageBuffer, &availableBytes);
    int messageCount = availableBytes / sizeof(message_t);
    for ( int i=0; i<messageCount; i++ ) {
        message_t message = messages[i];
        TPACCircularBufferConsume(&_mainThreadMessageBuffer, sizeof(message_t));
        
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
        _responsePollTimer = [NSTimer scheduledTimerWithTimeInterval:kIdleMessagingPollDuration target:self selector:@selector(pollForMainThreadMessages) userInfo:nil repeats:YES];
    }
}

- (void)performAsynchronousMessageExchangeWithHandler:(TPAudioControllerMessageHandler)handler 
                                           parameter1:(long)parameter1 
                                           parameter2:(long)parameter2
                                           parameter3:(long)parameter3
                                          ioOpaquePtr:(void*)ioOpaquePtr 
                                        responseBlock:(void (^)(long result, long parameter1, long parameter2, long parameter3, void *ioOpaquePtr))responseBlock {
    // Only perform on main thread
    if ( responseBlock ) {
        [responseBlock retain];
        _pendingResponses++;
        
        if ( self.running && (!_responsePollTimer || _responsePollTimer.timeInterval == kIdleMessagingPollDuration) ) {
            // Replace idle poll timer with more rapid active polling
            _responsePollTimer = [NSTimer scheduledTimerWithTimeInterval:_preferredBufferDuration target:self selector:@selector(pollForMainThreadMessages) userInfo:nil repeats:YES];
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
    
    TPACCircularBufferProduceBytes(&_realtimeThreadMessageBuffer, &message, sizeof(message_t));
    
    if ( !self.running ) {
        processPendingMessagesOnRealtimeThread(self);
        [self pollForMainThreadMessages];
    }
}

- (long)performSynchronousMessageExchangeWithHandler:(TPAudioControllerMessageHandler)handler 
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

void TPAudioControllerSendAsynchronousMessageToMainThread(TPAudioController* audioController, 
                                                          TPAudioControllerMessageHandler handler, 
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
    
    TPACCircularBufferProduceBytes(&audioController->_mainThreadMessageBuffer, &message, sizeof(message_t));
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

    [self setup];
    if ( running ) [self start];
}

-(void)setPreferredBufferDuration:(float)preferredBufferDuration {
    _preferredBufferDuration = preferredBufferDuration;

    if ( _audioSessionSetup ) {
        Float32 preferredBufferSize = _preferredBufferDuration;
        OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
        checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    }
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
    id<TPAudioPlayable> channel = (id<TPAudioPlayable>)object;
    
    int index;
    TPChannelGroup group = [self searchForGroupContainingChannelMatchingPtr:channel.renderCallback userInfo:channel index:&index];
    if ( !group ) return;
    
    if ( [keyPath isEqualToString:@"volume"] ) {
        AudioUnitParameterValue value = channel.volume;
        OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0);
        checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
        
    } else if ( [keyPath isEqualToString:@"pan"] ) {
        AudioUnitParameterValue value = channel.pan;
        if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
        if ( value == 1.0 ) value = 0.999;
        OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0);
        checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");

    } else if ( [keyPath isEqualToString:@"playing"] ) {
        AudioUnitParameterValue value = channel.playing && !channel.muted;
        OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
        checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
        group->channels[index].playing = value;
        
    }  else if ( [keyPath isEqualToString:@"muted"] ) {
        AudioUnitParameterValue value = ([channel respondsToSelector:@selector(playing)] ? channel.playing : YES) && !channel.muted;
        OSStatus result = AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, index, value, 0);
        checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
        
    }
}

- (void)applicationDidBecomeActive:(NSNotification*)notification {
    OSStatus status = AudioSessionSetActive(true);
    checkResult(status, "AudioSessionSetActive");
}

#pragma mark - Helpers

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
        AudioStreamBasicDescription inDesc;
        UInt32 inDescSize = sizeof(inDesc);
        result = AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &inDesc, &inDescSize);
        if ( checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") && inDesc.mChannelsPerFrame != 0 ) {
            if ( _numberOfInputChannels != inDesc.mChannelsPerFrame ) {
                [self willChangeValueForKey:@"numberOfInputChannels"];
                _numberOfInputChannels = inDesc.mChannelsPerFrame;
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

    // Initialise and hook in the main mixer
    _topLevelChannel.type = kChannelTypeGroup;
    _topLevelChannel.ptr  = &_channels;
    _topLevelChannel.playing = YES;
    [self initialiseGroupChannel:&_topLevelChannel parentGroup:NULL indexInParent:0];
    
    // Register a callback to be notified when the main mixer unit renders
    checkResult(AudioUnitAddRenderNotify(_channels.mixerAudioUnit, &topRenderNotifyCallback, self), "AudioUnitAddRenderNotify");
    
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
    [self teardownGroup:&_channels];
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

- (BOOL)initialiseGroupChannel:(channel_t*)channel parentGroup:(TPChannelGroup)parentGroup indexInParent:(int)index {
    TPChannelGroup group = (TPChannelGroup)channel->ptr;
    
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
        result = AUGraphAddNode(_audioGraph, &mixer_desc, &group->mixerNode );
        if ( !checkResult(result, "AUGraphAddNode mixer") ) return NO;
        
        // Get reference to the audio unit
        result = AUGraphNodeInfo(_audioGraph, group->mixerNode, NULL, &group->mixerAudioUnit);
        if ( !checkResult(result, "AUGraphNodeInfo") ) return NO;
        
        // Try to set mixer's output stream format
        group->converterRequired = NO;
        result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_audioDescription, sizeof(_audioDescription));
        
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
            mixerFormat.mSampleRate = _audioDescription.mSampleRate;
            
            checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mixerFormat, sizeof(mixerFormat)), 
                        "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat");
            
        } else {
            checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        }
        
        // Set mixer's input stream format
        result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_audioDescription, sizeof(_audioDescription));
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
    [self configureGraphStateOfGroupChannel:channel parentGroup:parentGroup indexInParent:index];
    
    // Configure inputs
    [self configureChannelsInRange:NSMakeRange(0, busCount) forGroup:group];
    
    return YES;
}

- (void)configureGraphStateOfGroupChannel:(channel_t*)channel parentGroup:(TPChannelGroup)parentGroup indexInParent:(int)index {
    TPChannelGroup group = (TPChannelGroup)channel->ptr;
    
    BOOL outputCallbacks=NO, filters=NO;
    for ( int i=0; i<channel->callbacks.count && (!outputCallbacks || !filters); i++ ) {
        if ( channel->callbacks.callbacks[i].flags & (kCallbackIsFilterFlag | kCallbackIsVariableSpeedFilterFlag) ) {
            filters = YES;
        } else if ( channel->callbacks.callbacks[i].flags & kCallbackIsOutputCallbackFlag ) {
            outputCallbacks = YES;
        }
    }
    
    
    Boolean wasRunning = false;
    OSStatus result = AUGraphIsRunning(_audioGraph, &wasRunning);
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
        
        group->audioConverterTargetFormat = _audioDescription;
        group->audioConverterSourceFormat = mixerFormat;
        
        // Create audio converter
        if ( !checkResult(AudioConverterNew(&mixerFormat, &_audioDescription, &group->audioConverter), 
                          "AudioConverterNew") ) return;
        
        
        if ( !_renderConversionScratchBuffer ) {
            // Allocate temporary conversion buffer
            _renderConversionScratchBuffer = (char*)malloc(kRenderConversionScratchBufferSizeInFrames
                                                                * MAX(_audioDescription.mBytesPerFrame, mixerFormat.mBytesPerFrame)
                                                                * MAX((_audioDescription.mFormatFlags&kAudioFormatFlagIsNonInterleaved ? _audioDescription.mChannelsPerFrame : 1),
                                                                      (mixerFormat.mFormatFlags&kAudioFormatFlagIsNonInterleaved ? mixerFormat.mChannelsPerFrame : 1)));
        }
        group->audioConverterScratchBuffer = _renderConversionScratchBuffer;
    }
    
    if ( filters ) {
        // We need to use our own render callback, because the audio will be being converted and modified
        if ( group->graphState & kGroupGraphStateNodeConnected ) {
            if ( !parentGroup && !graphStopped ) {
                // Stop the graph first, because we're going to modify the root
                if ( checkResult(AUGraphStop(_audioGraph), "AUGraphStop") ) {
                    graphStopped = YES;
                }
            }
            // Remove the node connection
            if ( checkResult(AUGraphDisconnectNodeInput(_audioGraph, parentGroup ? parentGroup->mixerNode : _ioNode, parentGroup ? index : 0), "AUGraphDisconnectNodeInput") ) {
                group->graphState &= ~kGroupGraphStateNodeConnected;
                [self updateGraph];
            }
        }
        
        if ( group->graphState & kGroupGraphStateRenderNotificationSet ) {
            // Remove render notification callback
            if ( checkResult(AudioUnitRemoveRenderNotify(group->mixerAudioUnit, &groupRenderNotifyCallback, channel), "AudioUnitRemoveRenderNotify") ) {
                group->graphState &= ~kGroupGraphStateRenderNotificationSet;
            }
        }

        // Set stream format for callback
        checkResult(AudioUnitSetProperty(parentGroup ? parentGroup->mixerAudioUnit : _ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, parentGroup ? index : 0, &_audioDescription, sizeof(_audioDescription)),
                    "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        
        // Add the render callback
        AURenderCallbackStruct rcbs;
        rcbs.inputProc = &renderCallback;
        rcbs.inputProcRefCon = channel;
        if ( checkResult(AUGraphSetNodeInputCallback(_audioGraph, parentGroup ? parentGroup->mixerNode : _ioNode, parentGroup ? index : 0, &rcbs), "AUGraphSetNodeInputCallback") ) {
            group->graphState |= kGroupGraphStateRenderCallbackSet;
            updateGraph = YES;
        }
        
    } else if ( group->graphState & kGroupGraphStateRenderCallbackSet ) {
        // Expermentation reveals that once the render callback has been set, no further connections or render callbacks can be established.
        // So, we leave the node in this state, regardless of whether we have callbacks or not
    } else {
        if ( !(group->graphState & kGroupGraphStateNodeConnected) ) {
            // Connect output of mixer directly to the parent mixer
            if ( checkResult(AUGraphConnectNodeInput(_audioGraph, group->mixerNode, 0, parentGroup ? parentGroup->mixerNode : _ioNode, parentGroup ? index : 0), "AUGraphConnectNodeInput") ) {
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
        [self updateGraph];
    }
    
    if ( graphStopped && wasRunning ) {
        checkResult(AUGraphStart(_audioGraph), "AUGraphStart");
    }
    
    if ( !outputCallbacks && !filters && group->audioConverter && !(group->graphState & kGroupGraphStateRenderCallbackSet) ) {
        // Cleanup audio converter
        
        // Sync first, to wait until end of the current render, whereupon any changes we just made will be applied
        [self performSynchronousMessageExchangeWithHandler:NULL parameter1:0 parameter2:0 parameter3:0 ioOpaquePtr:NULL];
        
        // Now dispose converter
        AudioConverterDispose(group->audioConverter);
        group->audioConverter = NULL;
    }
}

- (void)configureChannelsInRange:(NSRange)range forGroup:(TPChannelGroup)group {
    for ( int i = range.location; i < range.location+range.length; i++ ) {
        channel_t *channel = &group->channels[i];
        
        if ( channel->type == kChannelTypeChannel ) {
            id<TPAudioPlayable> channelObj = (id<TPAudioPlayable>)channel->userInfo;
            
            // Make sure the mixer input isn't connected to anything
            AUGraphDisconnectNodeInput(_audioGraph, group->mixerNode, i);
            
            // Set input stream format
            checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &_audioDescription, sizeof(_audioDescription)),
                        "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
            
            // Setup render callback struct
            AURenderCallbackStruct rcbs;
            rcbs.inputProc = &renderCallback;
            rcbs.inputProcRefCon = channel;
            
            // Set a callback for the specified node's specified input
            checkResult(AUGraphSetNodeInputCallback(_audioGraph, group->mixerNode, i, &rcbs), 
                        "AUGraphSetNodeInputCallback");

            // Set volume
            AudioUnitParameterValue volumeValue = (AudioUnitParameterValue)([channelObj respondsToSelector:@selector(volume)] ? channelObj.volume : 1.0);
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, i, volumeValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
            
            // Set pan
            AudioUnitParameterValue panValue = (AudioUnitParameterValue)([channelObj respondsToSelector:@selector(pan)] ? channelObj.pan : 0.0);
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, i, panValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
            
            // Set enabled
            BOOL playing = [channelObj respondsToSelector:@selector(playing)] ? channelObj.playing : YES;
            BOOL muted = [channelObj respondsToSelector:@selector(muted)] ? channelObj.muted : NO;
            AudioUnitParameterValue enabledValue = (AudioUnitParameterValue)(playing && !muted);
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, i, enabledValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
            
        } else if ( channel->type == kChannelTypeGroup ) {
            TPChannelGroup subgroup = (TPChannelGroup)channel->ptr;
            
            // Set volume
            AudioUnitParameterValue volumeValue = subgroup->volume;
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, i, volumeValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
            
            // Set pan
            AudioUnitParameterValue panValue = subgroup->pan;
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, i, panValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
            
            // Set enabled
            AudioUnitParameterValue enabledValue = !subgroup->muted;
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, i, enabledValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");
            
            // Recursively initialise this channel group
            if ( ![self initialiseGroupChannel:channel parentGroup:group indexInParent:i] ) return;
        }
    }
}

- (TPChannelGroup)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo withinGroup:(TPChannelGroup)group index:(int*)index {
    // Find the matching channel in the table for the given group
    for ( int i=0; i < group->channelCount; i++ ) {
        channel_t *channel = &group->channels[i];
        if ( channel->ptr == ptr && channel->userInfo == userInfo ) {
            if ( index ) *index = i;
            return group;
        }
        if ( channel->type == kChannelTypeGroup ) {
            TPChannelGroup match = [self searchForGroupContainingChannelMatchingPtr:ptr userInfo:userInfo withinGroup:channel->ptr index:index];
            if ( match ) return match;
        }
    }
    
    return NULL;
}

- (TPChannelGroup)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo index:(int*)index {
    return [self searchForGroupContainingChannelMatchingPtr:ptr userInfo:userInfo withinGroup:&_channels index:(int*)index];
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
        [self setup];
        [self start];
    }
}

static void updateInputDeviceStatus(TPAudioController *THIS) {
    UInt32 inputAvailable=0;
    
    if ( THIS->_enableInput ) {
        // Determine if audio input is available, and the number of input channels available
        UInt32 size = sizeof(inputAvailable);
        OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &size, &inputAvailable);
        checkResult(result, "AudioSessionGetProperty");
        
        int numberOfInputChannels = 0;
        if ( THIS->_audioInputAvailable ) {
            AudioStreamBasicDescription inDesc;
            UInt32 inDescSize = sizeof(inDesc);
            OSStatus result = AudioUnitGetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &inDesc, &inDescSize);
            if ( checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") && inDesc.mChannelsPerFrame != 0 ) {
                numberOfInputChannels = inDesc.mChannelsPerFrame;
            }
        }
        
        if ( THIS->_numberOfInputChannels != numberOfInputChannels ) {
            [THIS willChangeValueForKey:@"numberOfInputChannels"];
            THIS->_numberOfInputChannels = numberOfInputChannels;
            [THIS didChangeValueForKey:@"numberOfInputChannels"];
        }
        
        if ( THIS->_audioInputAvailable != inputAvailable ) {
            [THIS willChangeValueForKey:@"audioInputAvailable"];
            THIS->_audioInputAvailable = inputAvailable;
            [THIS didChangeValueForKey:@"audioInputAvailable"];
        }
    }
    
    // Assign audio category depending on whether we're recording or not
    UInt32 audioCategory;
    if ( inputAvailable && THIS->_enableInput ) {
        // Set the audio session category for simultaneous play and record
        audioCategory = kAudioSessionCategory_PlayAndRecord;
    } else {
        // Just playback
        audioCategory = kAudioSessionCategory_MediaPlayback;
    }
    
    UInt32 allowMixing = YES;
    checkResult(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory), "AudioSessionSetProperty(kAudioSessionProperty_AudioCategory");
    checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing), "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
}

static long addCallbackToTable(TPAudioController *THIS, long *callbackPtr, long *userInfoPtr, long *flags, void* callbackTablePtr) {
    callback_table_t* table = (callback_table_t*)callbackTablePtr;
    
    table->callbacks[table->count].callback = (void*)*callbackPtr;
    table->callbacks[table->count].userInfo = (void*)*userInfoPtr;
    table->callbacks[table->count].flags = (uint8_t)*flags;
    table->count++;
    
    return table->count;
}

static long removeCallbackFromTable(TPAudioController *THIS, long *callbackPtr, long *userInfoPtr, long *unused, void* callbackTablePtr) {
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

- (NSArray *)callbacksFromTable:(callback_table_t*)table matchingFlag:(uint8_t)flag {
    // Construct NSArray response
    NSMutableArray *result = [NSMutableArray array];
    for ( int i=0; i<table->count; i++ ) {
        if ( flag && !(table->callbacks[i].flags & flag) ) continue;
        
        [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                           [NSValue valueWithPointer:table->callbacks[i].callback], kTPAudioControllerCallbackKey,
                           [NSValue valueWithPointer:table->callbacks[i].userInfo], kTPAudioControllerUserInfoKey, nil]];
    }
    
    return result;
}

- (void)addCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannel:(id<TPAudioPlayable>)channelObj {
    int index=0;
    TPChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    channel_t *channel = &parentGroup->channels[index];
    
    [self performSynchronousMessageExchangeWithHandler:&addCallbackToTable parameter1:(long)callback parameter2:(long)userInfo parameter3:flags ioOpaquePtr:&channel->callbacks];
}

- (void)addCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo flags:(uint8_t)flags forChannelGroup:(TPChannelGroup)group {
    channel_t *channel = NULL;
    TPChannelGroup parentGroup = NULL;
    int index=0;
    
    if ( group == &_channels ) {
        channel = &_topLevelChannel;
    } else {
        parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
        NSAssert(parentGroup != NULL, @"Channel group not found");
        channel = &parentGroup->channels[index];
    }
    
    if ( channel->callbacks.count == kMaximumCallbacksPerSource ) {
        NSLog(@"Warning: Maximum number of callbacks reached");
        return;
    }
    
    [self performSynchronousMessageExchangeWithHandler:&addCallbackToTable parameter1:(long)callback parameter2:(long)userInfo parameter3:flags ioOpaquePtr:&channel->callbacks];
    
    [self configureGraphStateOfGroupChannel:channel parentGroup:parentGroup indexInParent:index];
}

- (void)removeCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannel:(id<TPAudioPlayable>)channelObj {
    int index=0;
    TPChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    channel_t *channel = &parentGroup->channels[index];
    
    [self performSynchronousMessageExchangeWithHandler:&removeCallbackFromTable parameter1:(long)callback parameter2:(long)userInfo parameter3:0 ioOpaquePtr:&channel->callbacks];
}

- (void)removeCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo fromChannelGroup:(TPChannelGroup)group {
    channel_t *channel = NULL;
    TPChannelGroup parentGroup = NULL;
    int index = 0;
    
    if ( group == &_channels ) {
        channel = &_topLevelChannel;
    } else {
        parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
        NSAssert(parentGroup != NULL, @"Channel group not found");
        channel = &parentGroup->channels[index];
    }
    
    [self performSynchronousMessageExchangeWithHandler:&removeCallbackFromTable parameter1:(long)callback parameter2:(long)userInfo parameter3:0 ioOpaquePtr:&channel->callbacks];
    
    [self configureGraphStateOfGroupChannel:channel parentGroup:parentGroup indexInParent:index];
}

- (NSArray*)callbacksWithFlags:(uint8_t)flags {
    return [self callbacksFromTable:&_topLevelChannel.callbacks matchingFlag:flags];
}

- (NSArray*)callbacksWithFlags:(uint8_t)flags forChannel:(id<TPAudioPlayable>)channelObj {
    int index=0;
    TPChannelGroup parentGroup = [self searchForGroupContainingChannelMatchingPtr:channelObj.renderCallback userInfo:channelObj index:&index];
    NSAssert(parentGroup != NULL, @"Channel not found");
    
    channel_t *channel = &parentGroup->channels[index];
    
    return [self callbacksFromTable:&channel->callbacks matchingFlag:flags];
}

- (NSArray*)callbacksWithFlags:(uint8_t)flags forChannelGroup:(TPChannelGroup)group {
    channel_t *channel = NULL;
    TPChannelGroup parentGroup = NULL;
    int index = 0;
    
    if ( group == &_channels ) {
        channel = &_topLevelChannel;
    } else {
        parentGroup = [self searchForGroupContainingChannelMatchingPtr:group userInfo:NULL index:&index];
        NSAssert(parentGroup != NULL, @"Channel group not found");
        channel = &parentGroup->channels[index];
    }
    
    return [self callbacksFromTable:&channel->callbacks matchingFlag:flags];
}

- (void)releaseGroupResources:(TPChannelGroup)group freeGroupMemory:(BOOL)freeGroup {
    if ( group->audioConverter ) {
        checkResult(AudioConverterDispose(group->audioConverter), "AudioConverterDispose");
        group->audioConverter = NULL;
    }
    
    for ( int i=0; i<group->channelCount; i++ ) {
        channel_t* channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self releaseGroupResources:(TPChannelGroup)channel->ptr freeGroupMemory:YES];
        }
    }

    checkResult(AUGraphRemoveNode(_audioGraph, group->mixerNode), "AUGraphRemoveNode");

    if ( freeGroup ) free(group);
}

- (void)setVariableSpeedFilter:(TPAudioControllerVariableSpeedFilterCallback)filter userInfo:(void *)userInfo forChannelStruct:(channel_t*)channel {
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        if ( (channel->callbacks.callbacks[i].flags & kCallbackIsVariableSpeedFilterFlag ) ) {
            // Remove the old callback
            [self performSynchronousMessageExchangeWithHandler:&removeCallbackFromTable
                                                    parameter1:(long)channel->callbacks.callbacks[i].callback
                                                    parameter2:(long)channel->callbacks.callbacks[i].userInfo
                                                    parameter3:0
                                                   ioOpaquePtr:&channel->callbacks];
        }
    }
    
    if ( filter ) {
        [self performSynchronousMessageExchangeWithHandler:&addCallbackToTable 
                                                parameter1:(long)filter
                                                parameter2:(long)userInfo 
                                                parameter3:kCallbackIsVariableSpeedFilterFlag 
                                               ioOpaquePtr:&channel->callbacks];
    }
}

- (void)teardownGroup:(TPChannelGroup)group {
    group->graphState = kGroupGraphStateUninitialized;
    for ( int i=0; i<group->channelCount; i++ ) {
        channel_t* channel = &group->channels[i];
        if ( channel->type == kChannelTypeGroup ) {
            [self teardownGroup:(TPChannelGroup)channel->ptr];
        }
    }
}

static void handleCallbacksForChannel(channel_t *channel, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    // Pass audio to filters
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kCallbackIsFilterFlag ) {
            ((TPAudioControllerAudioCallback)callback->callback)(callback->userInfo, inTimeStamp, inNumberFrames, ioData);
        }
    }
    
    // And finally pass to output callbacks
    for ( int i=0; i<channel->callbacks.count; i++ ) {
        callback_t *callback = &channel->callbacks.callbacks[i];
        if ( callback->flags & kCallbackIsOutputCallbackFlag ) {
            ((TPAudioControllerAudioCallback)callback->callback)(callback->userInfo, inTimeStamp, inNumberFrames, ioData);
        }
    }
}

static OSStatus channelAudioProducer(void *userInfo, AudioBufferList *audio, UInt32 frames) {
    channel_producer_arg_t *arg = (channel_producer_arg_t*)userInfo;
    channel_t *channel = arg->channel;
    
    OSStatus status = noErr;
    
    if ( channel->type == kChannelTypeChannel ) {
        TPAudioControllerRenderCallback callback = (TPAudioControllerRenderCallback) channel->ptr;
        id<TPAudioPlayable> channelObj = (id<TPAudioPlayable>) channel->userInfo;
        
        status = callback(channelObj, arg->inTimeStamp, frames, audio);
        
    } else if ( channel->type == kChannelTypeGroup ) {
        TPChannelGroup group = (TPChannelGroup)channel->ptr;
        
        AudioBufferList *bufferList;
        
        if ( group->converterRequired ) {
            // Initialise output buffer
            struct { AudioBufferList bufferList; AudioBuffer nextBuffer; } buffers;
            bufferList = &buffers.bufferList;
            bufferList->mNumberBuffers = (group->audioConverterSourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? group->audioConverterSourceFormat.mChannelsPerFrame : 1;
            char *dataPtr = group->audioConverterScratchBuffer;
            for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
                bufferList->mBuffers[i].mNumberChannels = (group->audioConverterSourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : group->audioConverterSourceFormat.mChannelsPerFrame;
                bufferList->mBuffers[i].mData           = dataPtr;
                bufferList->mBuffers[i].mDataByteSize   = group->audioConverterSourceFormat.mBytesPerFrame * frames;
                dataPtr += bufferList->mBuffers[i].mDataByteSize;
            }
            
        } else {
            // We can render straight to the buffer, as audio format is the same
            bufferList = audio;
        }
        
        // Tell mixer to render into bufferList
        OSStatus status = AudioUnitRender(group->mixerAudioUnit, arg->ioActionFlags, arg->inTimeStamp, 0, frames, bufferList);
        if ( !checkResult(status, "AudioUnitRender") ) return status;
        
        if ( group->converterRequired ) {
            // Perform conversion
            status = AudioConverterConvertComplexBuffer(group->audioConverter, frames, bufferList, audio);
            checkResult(status, "AudioConverterConvertComplexBuffer");
        }
    }
    
    return status;
}

@end
