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
#define kMaximumCallbacks 50
#define kMaximumFiltersPerSource 5
#define kMessageBufferLength 50
#define kIdleMessagingPollDuration 0.2

#define kInputBus 1
#define kOutputBus 0

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

/*!
 * Callback
 */
typedef struct {
    void *callback;
    void *userInfo;
} callback_t;

/*!
 * Callback table
 */
typedef struct {
    callback_t callbacks[kMaximumCallbacks];
    int count;
} callback_table_t;

/*!
 * Source types
 */
typedef enum {
    ChannelTypeChannel,
    ChannelTypeChannelGroup
} ChannelType;

/*!
 * Channel
 */
typedef struct {
    ChannelType type;
    void *ptr;
    void *userInfo;
    BOOL playing;
    callback_t filters[kMaximumFiltersPerSource];
    int filterCount;
} channel_t;

/*!
 * Channel group
 */
typedef struct _channel_group_t {
    AUNode              mixerNode;
    AudioUnit           mixerAudioUnit;
    channel_t           channels[kMaximumChannelsPerGroup];
    int                 channelCount;
} channel_group_t;

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
    
    callback_table_t    _recordCallbacks;
    callback_table_t    _outputCallbacks;
    callback_table_t    _timingCallbacks;
    
    TPACCircularBuffer  _realtimeThreadMessageBuffer;
    TPACCircularBuffer  _mainThreadMessageBuffer;
    NSTimer            *_responsePollTimer;
    int                 _pendingResponses;
}

- (BOOL)setup;
- (void)teardown;
- (void)updateGraph;

- (BOOL)initialiseChannelGroup:(channel_group_t*)group;
- (void)configureChannelsInRange:(NSRange)range forGroup:(TPChannelGroup)group configureSubGroups:(BOOL)configureSubGroups;
- (TPChannelGroup)searchForGroupContainingChannelMatchingPtr:(void*)ptr userInfo:(void*)userInfo index:(int*)index;

- (void)updateVoiceProcessingSettings;
static void updateInputDeviceStatus(TPAudioController *THIS);

- (void)pollForMainThreadMessages;
static void processPendingMessagesOnRealtimeThread(TPAudioController *THIS);
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

@dynamic    channels,
            recordCallbacks,
            renderCallbacks,
            timingCallbacks,
            running;

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
        OSStatus result = AudioUnitGetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kInputBus, &inDesc, &inDescSize);
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
    
    TPAudioControllerAudioCallback callback = (TPAudioControllerAudioCallback) channel->ptr;
    id<TPAudioPlayable> channelObj = (id<TPAudioPlayable>) channel->userInfo;
    
    return callback(channelObj, inTimeStamp, inNumberFrames, ioData);
}

static OSStatus inputAvailableCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
   
    TPAudioController *THIS = (TPAudioController *)inRefCon;

    processPendingMessagesOnRealtimeThread(THIS);
    
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
    
    OSStatus err = AudioUnitRender(THIS->_ioAudioUnit, ioActionFlags, inTimeStamp, kInputBus, inNumberFrames, &buffers.bufferList);
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
        
    // Pass audio to record delegates
    for ( int i=0; i<THIS->_recordCallbacks.count; i++ ) {
        callback_t *callback = &THIS->_recordCallbacks.callbacks[i];
        ((TPAudioControllerAudioCallback)callback->callback)(callback->userInfo, inTimeStamp, inNumberFrames, &buffers.bufferList);
    }
    
    return noErr;
}

static OSStatus outputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    TPAudioController *THIS = (TPAudioController *)inRefCon;
        
    if ( *ioActionFlags & kAudioUnitRenderAction_PreRender ) {
        // Before render
        processPendingMessagesOnRealtimeThread(THIS);
        
        for ( int i=0; i<THIS->_timingCallbacks.count; i++ ) {
            callback_t *callback = &THIS->_timingCallbacks.callbacks[i];
            ((TPAudioControllerTimingCallback)callback->callback)(callback->userInfo, inTimeStamp, TPAudioTimingContextOutput);
        }
    } else if ( (*ioActionFlags & kAudioUnitRenderAction_PostRender) ) {
        // After render
        for ( int i=0; i<THIS->_outputCallbacks.count; i++ ) {
            callback_t *callback = &THIS->_outputCallbacks.callbacks[i];
            ((TPAudioControllerAudioCallback)callback->callback)(callback->userInfo, inTimeStamp, inNumberFrames, ioData);
        }
        
        if ( THIS->_muteOutput ) {
            for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
                memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
            }
        }
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
        if ( channel->type == ChannelTypeChannelGroup ) {
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
    channel_group_t *group = (channel_group_t*)calloc(1, sizeof(channel_group_t));
    
    // Add group as a channel to the parent group
    int groupIndex = parentGroup->channelCount;
    
    channel_t *channel = &parentGroup->channels[groupIndex];
    channel->type = ChannelTypeChannelGroup;
    channel->ptr = group;
    channel->filterCount = 0;
    channel->userInfo = NULL;
    
    parentGroup->channelCount++;    

    // Initialise group
    [self initialiseChannelGroup:group];
    
    // Connect group to parent group's mixer
    checkResult(AUGraphConnectNodeInput(_audioGraph, group->mixerNode, 0, parentGroup->mixerNode, groupIndex), "AUGraphConnectNodeInput");
    [self updateGraph];
    
    return group;
}

static long removeChannelsFromGroup(TPAudioController *THIS, long *matchingPtrArrayPtr, long *matchingUserInfoArrayPtr, long *channelsCount, void* groupPtr) {
    void **ptrArray = (void**)*matchingPtrArrayPtr;
    void **userInfoArray = (void**)*matchingUserInfoArrayPtr;
    channel_group_t *group = (channel_group_t*)groupPtr;
    
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
    if ( parentGroup == NULL ) return;
    
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
    [self configureChannelsInRange:NSMakeRange(0, parentGroup->channelCount) forGroup:parentGroup configureSubGroups:NO];
    
    // Release group resources
    checkResult(AUGraphRemoveNode(_audioGraph, group->mixerNode), "AUGraphRemoveNode");
    free(group);
    
    [self updateGraph];
}

- (NSArray*)topLevelChannelGroups {
    return [self channelGroupsInChannelGroup:&_channels];
}

- (NSArray*)channelGroupsInChannelGroup:(TPChannelGroup)group {
    NSMutableArray *groups = [NSMutableArray array];
    for ( int i=0; i<group->channelCount; i++ ) {
        channel_t *channel = &group->channels[i];
        if ( channel->type == ChannelTypeChannelGroup ) {
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
        if ( group->channelCount == kMaximumChannelsPerGroup ) break;
        
        [channel retain];
        
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", @"playing", @"muted", nil] ) {
            [(NSObject*)channel addObserver:self forKeyPath:property options:0 context:NULL];
        }
        
        channel_t *channelElement = &group->channels[group->channelCount++];
        
        channelElement->type = ChannelTypeChannel;
        channelElement->filterCount = 0;
        channelElement->ptr = channel.renderCallback;
        channelElement->userInfo = channel;
        channelElement->playing = channel.playing;
    }
    
    // Set bus count
    UInt32 busCount = group->channelCount;
    OSStatus result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // Configure each channel
    [self configureChannelsInRange:NSMakeRange(group->channelCount - [channels count], [channels count]) forGroup:group configureSubGroups:NO];
    
    [self updateGraph];
}

- (void)removeChannels:(NSArray*)channels fromChannelGroup:(TPChannelGroup)group {
    // Set new bus count
    UInt32 busCount = group->channelCount - [channels count];
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
    [self configureChannelsInRange:NSMakeRange(0, group->channelCount) forGroup:group configureSubGroups:NO];
    
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
        if ( group->channels[i].type == ChannelTypeChannel ) {
            [channels addObject:(id)group->channels[i].userInfo];
        }
    }
    return channels;
}

#pragma mark - Filter management

- (void)addFilter:(TPAudioControllerFilterCallback)filter userInfo:(void*)userInfo toChannel:(id<TPAudioPlayable>)channel {
    
}

- (void)removeFilter:(TPAudioControllerFilterCallback)filter userInfo:(void*)userInfo fromChannel:(id<TPAudioPlayable>)channel {
    
}

- (NSArray*)filtersForChannel:(id<TPAudioPlayable>)channel {
    return nil;
}

- (void)addFilter:(TPAudioControllerFilterCallback)filter userInfo:(void*)userInfo toChannelGroup:(TPChannelGroup)group {
    
}

- (void)removeFilter:(TPAudioControllerFilterCallback)filter userInfo:(void*)userInfo fromChannelGroup:(TPChannelGroup)group {
    
}

- (NSArray*)filtersForChannelGroup:(TPChannelGroup)group {
    return nil;
}

#pragma mark - Callback management

static long addCallbackToTable(TPAudioController *THIS, long *callbackTablePtr, long *callbackPtr, long *userInfoPtr, void* outPtr) {
    callback_table_t* table = (callback_table_t*)*callbackTablePtr;
    
    table->callbacks[table->count].callback = (void*)*callbackPtr;
    table->callbacks[table->count].userInfo = (void*)*userInfoPtr;
    table->count++;
    
    if ( outPtr ) {
        memcpy(outPtr, &table->callbacks, table->count * sizeof(callback_t));
    }
    
    return table->count;
}

static long removeCallbackFromTable(TPAudioController *THIS, long *callbackTablePtr, long *callbackPtr, long *userInfoPtr, void* outPtr) {
    callback_table_t* table = (callback_table_t*)*callbackTablePtr;
    
    // Find the item in our fixed array
    int index = 0;
    for ( index=0; index<table->count; index++ ) {
        if ( table->callbacks[table->count].callback == (void*)*callbackPtr && table->callbacks[table->count].userInfo == (void*)*userInfoPtr ) {
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
    
    if ( outPtr ) {
        memcpy(outPtr, &table->callbacks, table->count * sizeof(callback_t));
    }
    
    return table->count;
}

static long getCallbackTableContents(TPAudioController *THIS, long *callbackTablePtr, long *unused2, long *unused3, void* outPtr) {
    callback_table_t* table = (callback_table_t*)*callbackTablePtr;
    if ( outPtr ) {
        memcpy(outPtr, &table->callbacks, table->count * sizeof(callback_t));
    }
    return table->count;
}

- (NSArray *)getCallbacksFromTable:(callback_table_t*)table {
    // Request copy of channels array from realtime thread
    callback_t array[kMaximumCallbacks];
    long count = [self performSynchronousMessageExchangeWithHandler:&getCallbackTableContents parameter1:(long)table parameter2:0 parameter3:0 ioOpaquePtr:&array];
    
    // Construct NSArray response
    NSMutableArray *result = [NSMutableArray array];
    for ( int i=0; i<count; i++ ) {
        [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                           [NSValue valueWithPointer:array[i].callback], kTPAudioControllerCallbackKey,
                           [NSValue valueWithPointer:array[i].userInfo], kTPAudioControllerUserInfoKey, nil]];
    }
    
    return result;
}

- (void)addRecordCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo {
    [self performAsynchronousMessageExchangeWithHandler:&addCallbackToTable parameter1:(long)&_recordCallbacks parameter2:(long)callback parameter3:(long)userInfo ioOpaquePtr:NULL responseBlock:nil];
}

- (void)removeRecordCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo {
    [self performAsynchronousMessageExchangeWithHandler:&removeCallbackFromTable parameter1:(long)&_recordCallbacks parameter2:(long)callback parameter3:(long)userInfo ioOpaquePtr:NULL responseBlock:nil];
}

-(NSArray *)recordCallbacks {
    return [self getCallbacksFromTable:&_recordCallbacks];
}

- (void)addPlaybackCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo {
    [self performAsynchronousMessageExchangeWithHandler:&addCallbackToTable parameter1:(long)&_outputCallbacks parameter2:(long)callback parameter3:(long)userInfo ioOpaquePtr:NULL responseBlock:nil];
}

- (void)removePlaybackCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo {
    [self performAsynchronousMessageExchangeWithHandler:&removeCallbackFromTable parameter1:(long)&_outputCallbacks parameter2:(long)callback parameter3:(long)userInfo ioOpaquePtr:NULL responseBlock:nil];
}

-(NSArray *)renderCallbacks {
    return [self getCallbacksFromTable:&_outputCallbacks];
}

- (void)addTimingCallback:(TPAudioControllerTimingCallback)callback userInfo:(void *)userInfo {
    [self performAsynchronousMessageExchangeWithHandler:&addCallbackToTable parameter1:(long)&_timingCallbacks parameter2:(long)callback parameter3:(long)userInfo ioOpaquePtr:NULL responseBlock:nil];
}

- (void)removeTimingCallback:(TPAudioControllerTimingCallback)callback userInfo:(void *)userInfo {
    [self performAsynchronousMessageExchangeWithHandler:&removeCallbackFromTable parameter1:(long)&_timingCallbacks parameter2:(long)callback parameter3:(long)userInfo ioOpaquePtr:NULL responseBlock:nil];
}

-(NSArray *)timingCallbacks {
    return [self getCallbacksFromTable:&_timingCallbacks];
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
        AudioUnitParameterValue value = channel.playing && !channel.muted;
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
        result = AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kInputBus, &inDesc, &inDescSize);
        if ( checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") && inDesc.mChannelsPerFrame != 0 ) {
            if ( _numberOfInputChannels != inDesc.mChannelsPerFrame ) {
                [self willChangeValueForKey:@"numberOfInputChannels"];
                _numberOfInputChannels = inDesc.mChannelsPerFrame;
                [self didChangeValueForKey:@"numberOfInputChannels"];
            }
        }
        
        // Set input stream format
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kInputBus, &_audioDescription, sizeof(_audioDescription));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) return NO;
        
        // Enable input
        UInt32 enableInputFlag = 1;
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &enableInputFlag, sizeof(enableInputFlag));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)") ) return NO;
        
        // Register a callback to receive audio
        AURenderCallbackStruct inRenderProc;
        inRenderProc.inputProc = &inputAvailableCallback;
        inRenderProc.inputProcRefCon = self;
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, kInputBus, &inRenderProc, sizeof(inRenderProc));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_SetInputCallback)") ) return NO;
        
        // If doing voice processing, set its quality
        if ( _voiceProcessingEnabled ) {
            UInt32 quality = 127;
            result = AudioUnitSetProperty(_ioAudioUnit, kAUVoiceIOProperty_VoiceProcessingQuality, kAudioUnitScope_Global, 1, &quality, sizeof(quality));
            checkResult(result, "AudioUnitSetProperty(kAUVoiceIOProperty_VoiceProcessingQuality)");
        }
    }

    // Initialise and hook in the main mixer
    [self initialiseChannelGroup:&_channels];
    result = AUGraphConnectNodeInput(_audioGraph, _channels.mixerNode, 0, _ioNode, 0);
    if ( !checkResult(result, "AUGraphConnectNodeInput") ) return NO;

    // Register a callback to be notified when the main mixer unit renders
    checkResult(AudioUnitAddRenderNotify(_channels.mixerAudioUnit, &outputCallback, self), "AudioUnitAddRenderNotify");
    
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
}

- (void)updateGraph {
    Boolean graphIsRunning;
    AUGraphIsRunning(_audioGraph, &graphIsRunning);
    if ( graphIsRunning ) {
        OSStatus err;
        for ( int retry=0; retry<6; retry++ ) {
            err = AUGraphUpdate(_audioGraph, NULL);
            if ( err == noErr ) break;
            [NSThread sleepForTimeInterval:0.01];
        }
        if ( err != noErr ) {
            AUGraphStop(_audioGraph);
            checkResult(AUGraphStart(_audioGraph), "AUGraphUpdate/AUGraphStart");
        }
    }
}

- (BOOL)initialiseChannelGroup:(channel_group_t*)group {
    OSStatus result;
    
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
    
	// Set mixer's output stream format
    result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_audioDescription, sizeof(_audioDescription));
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The mixer only supports a subset of formats. If it doesn't support this one, then we'll convert manually
#if DEBUG
        NSLog(@"Note: The AudioStreamBasicDescription you have provided is not natively supported by the iOS mixer unit. Use of filters and playback callbacks will result in use of audio converters.");
#endif
    } else {
        checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
    }
    
    // Set mixer's input stream format
    result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_audioDescription, sizeof(_audioDescription));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) return NO;
    
    // Set the mixer unit to handle up to 4096 samples per slice to keep rendering during screen lock
    UInt32 maxFPS = 4096;
    AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));

    // Set bus count
	UInt32 busCount = group->channelCount;
    result = AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return NO;
    
    // Configure inputs
    [self configureChannelsInRange:NSMakeRange(0, busCount) forGroup:group configureSubGroups:YES];
    
    return YES;
}

- (void)configureChannelsInRange:(NSRange)range forGroup:(TPChannelGroup)group configureSubGroups:(BOOL)configureSubGroups {
    for ( int i = range.location; i < range.location+range.length; i++ ) {
        channel_t *channel = &group->channels[i];
        
        if ( channel->type == ChannelTypeChannel ) {
            id<TPAudioPlayable> channelObj = (id<TPAudioPlayable>)channel->userInfo;
            
            // Make sure the mixer input isn't connected to anything
            AUGraphDisconnectNodeInput(_audioGraph, group->mixerNode, i);
            
            // Setup render callback struct
            AURenderCallbackStruct rcbs;
            rcbs.inputProc = &renderCallback;
            rcbs.inputProcRefCon = channel;
            
            // Set a callback for the specified node's specified input
            checkResult(AUGraphSetNodeInputCallback(_audioGraph, group->mixerNode, i, &rcbs), 
                        "AUGraphSetNodeInputCallback");
            
            // Set input stream format
            checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &_audioDescription, sizeof(_audioDescription)),
                        "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
            
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
            
        } else if ( channel->type == ChannelTypeChannelGroup ) {
            channel_group_t *subgroup = (channel_group_t*)channel->ptr;
            
            // Recursively initialise this channel group
            if ( configureSubGroups ) {
                if ( ![self initialiseChannelGroup:subgroup] ) return;
            }
            
            // Remove any render callback
            AURenderCallbackStruct rcbs;
            rcbs.inputProc = NULL;
            rcbs.inputProcRefCon = NULL;
            
            // Remove any callback for the specified node's specified input
            checkResult(AUGraphSetNodeInputCallback(_audioGraph, group->mixerNode, i, &rcbs),
                        "AUGraphSetNodeInputCallback");
            
            // Set input stream format
            checkResult(AudioUnitSetProperty(group->mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &_audioDescription, sizeof(_audioDescription)),
                        "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
            
            // Set volume
            AudioUnitParameterValue volumeValue = 1.0;
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, i, volumeValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
            
            // Set pan
            AudioUnitParameterValue panValue = 0.0;
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, i, panValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
            
            // Set enabled
            AudioUnitParameterValue enabledValue = YES;
            checkResult(AudioUnitSetParameter(group->mixerAudioUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, i, enabledValue, 0),
                        "AudioUnitSetParameter(kMultiChannelMixerParam_Enable)");

            // Connect output of child group's mixer to our mixer
            checkResult(AUGraphConnectNodeInput(_audioGraph, subgroup->mixerNode, 0, group->mixerNode, i),
                        "AUGraphConnectNodeInput");
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
        if ( channel->type == ChannelTypeChannelGroup ) {
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
            OSStatus result = AudioUnitGetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kInputBus, &inDesc, &inDescSize);
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


@end
