//
//  TPAudioController.m
//
//  Created by Michael Tyson on 25/11/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "TPAudioController.h"
#import <libkern/OSAtomic.h>
#import "TPACCircularBuffer.h"
#include <sys/types.h>
#include <sys/sysctl.h>

#define kMaximumChannels 100
#define kMaximumDelegates 50
#define kMessageBufferLength 50

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

typedef struct {
    void *callback;
    void *userInfo;
} callback_t;

typedef struct _message_t {
    int action;
    int  kind;
    long parameter1;
    long parameter2;
    void *response_ptr;
    void (^response_block)(struct _message_t message, long response);
} message_t;

typedef struct {
    message_t message;
    long response;
} message_response_t;

enum {
    kMessageAdd,
    kMessageRemove,
    kMessageGet,
    kMessageFindIndexWithMatchingUserInfo
};

enum {
    kKindChannel,
    kKindRecordDelegate,
    kKindPlaybackDelegate,
    kKindTimingDelegate,
    kKindFilter
};

@interface TPAudioController () {
    AUGraph             _audioGraph;
    AUNode              _mixerNode;
    AudioUnit           _mixerAudioUnit;
    AUNode              _ioNode;
    AudioUnit           _ioAudioUnit;
    BOOL                _initialised;
    BOOL                _running;
    BOOL                _runningPriorToInterruption;
    int                 _channelCount;
    int                 _recordDelegateCount;
    int                 _playbackDelegateCount;
    int                 _timingDelegateCount;
    callback_t          _channels[kMaximumChannels];
    callback_t          _recordDelegates[kMaximumChannels];
    callback_t          _playbackDelegates[kMaximumChannels];
    callback_t          _timingDelegates[kMaximumChannels];
    TPACCircularBuffer  _messageBuffer;
    TPACCircularBuffer  _responseBuffer;
    NSTimer            *_responsePollTimer;
    int                 _pendingResponses;
}

- (void)setVolume:(float)volume forChannel:(id<TPAudioPlayable>)channel;
- (void)setPan:(float)pan forChannel:(id<TPAudioPlayable>)channel;
- (void)teardown;
- (void)refreshGraph;
- (void)setupAudioSession;
- (void)updateVoiceProcessingSettings;
- (NSArray *)getDelegatesOfKind:(int)kind;
- (void)performAsynchronousMessageExchange:(message_t)message responseBlock:(void (^)(struct _message_t message, long response))responseBlock;
- (long)performSynchronousMessageExchange:(message_t)message;
- (void)pollMessageResponses;
static void processPendingMessages(TPAudioController *THIS);
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
            recordDelegates,
            playbackDelegates,
            timingDelegates,
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
        THIS->_runningPriorToInterruption = THIS->_running;
        if ( THIS->_running ) {
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
        UInt32 *inputAvailable = (UInt32*)inData;
        UInt32 sessionCategory;
        if ( *inputAvailable ) {
            // Set the audio session category for simultaneous play and record
            sessionCategory = kAudioSessionCategory_PlayAndRecord;
        } else {
            // Just playback
            sessionCategory = kAudioSessionCategory_MediaPlayback;
        }
        
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof (sessionCategory), &sessionCategory), "AudioSessionSetProperty(kAudioSessionProperty_AudioCategory");
        UInt32 allowMixing = YES;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing), "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
        
        if ( *inputAvailable ) {
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
        } else {
            if ( THIS->_numberOfInputChannels != 0 ) {
                [THIS willChangeValueForKey:@"numberOfInputChannels"];
                THIS->_numberOfInputChannels = 0;
                [THIS didChangeValueForKey:@"numberOfInputChannels"];
            }
        }
        
        [THIS willChangeValueForKey:@"audioInputAvailable"];
        THIS->_audioInputAvailable = *inputAvailable;
        [THIS didChangeValueForKey:@"audioInputAvailable"];
    }
}

#pragma mark -
#pragma mark Input and render callbacks

static OSStatus playbackCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    TPAudioController *THIS = (TPAudioController *)inRefCon;
    
    if ( inBusNumber >= THIS->_channelCount ) return noErr;
    
    callback_t callback = THIS->_channels[inBusNumber];
    return ((TPAudioControllerAudioDelegateCallback)callback.callback)((id<TPAudioPlayable>)callback.userInfo, inTimeStamp, inNumberFrames, ioData);
}

static OSStatus inputAvailableCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
   
    TPAudioController *THIS = (TPAudioController *)inRefCon;

    processPendingMessages(THIS);
    
    for ( int i=0; i<THIS->_timingDelegateCount; i++ ) {
        callback_t *callback = &THIS->_timingDelegates[i];
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
    for ( int i=0; i<THIS->_recordDelegateCount; i++ ) {
        callback_t *callback = &THIS->_recordDelegates[i];
        ((TPAudioControllerAudioDelegateCallback)callback->callback)(callback->userInfo, inTimeStamp, inNumberFrames, &buffers.bufferList);
    }
    
    return noErr;
}

static OSStatus outputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    TPAudioController *THIS = (TPAudioController *)inRefCon;
        
    if ( *ioActionFlags & kAudioUnitRenderAction_PreRender ) {
        processPendingMessages(THIS);
        
        for ( int i=0; i<THIS->_timingDelegateCount; i++ ) {
            callback_t *callback = &THIS->_timingDelegates[i];
            ((TPAudioControllerTimingCallback)callback->callback)(callback->userInfo, inTimeStamp, TPAudioTimingContextOutput);
        }
    }
    
    if ( !(*ioActionFlags & kAudioUnitRenderAction_PostRender) ) {
        return noErr;
    }
    
    for ( int i=0; i<THIS->_playbackDelegateCount; i++ ) {
        callback_t *callback = &THIS->_playbackDelegates[i];
        ((TPAudioControllerAudioDelegateCallback)callback->callback)(callback->userInfo, inTimeStamp, inNumberFrames, ioData);
    }
    
    if ( THIS->_muteOutput ) {
        for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
    }
    
    return noErr;
}

#pragma mark -

+ (AudioStreamBasicDescription)defaultAudioDescription {
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

#pragma mark - Setup and start/stop

- (id)init {
    if ( !(self = [super init]) ) return nil;
    
    _preferredBufferDuration = 0.005;
    _receiveMonoInputAsBridgedStereo = YES;
    _voiceProcessingOnlyForSpeakerAndMicrophone = YES;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    
    if ( NSClassFromString(@"TPTrialModeController") ) {
        [[NSClassFromString(@"TPTrialModeController") alloc] init];
    }
    
    TPACCircularBufferInit(&_messageBuffer, kMessageBufferLength * sizeof(message_t));
    TPACCircularBufferInit(&_responseBuffer, kMessageBufferLength * sizeof(message_response_t));
    
    return self;
}

- (void)dealloc {
    if ( _responsePollTimer ) [_responsePollTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stop];
    [self teardown];
    
    for ( int i=0; i<_channelCount; i++ ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", nil] ) {
            [(NSObject*)_channels[i].userInfo removeObserver:self forKeyPath:property];
        }
        [(NSObject*)_channels[i].userInfo release];
    }
    
    TPACCircularBufferCleanup(&_messageBuffer);
    TPACCircularBufferCleanup(&_responseBuffer);
    
    [super dealloc];
}

- (void)setupWithAudioDescription:(AudioStreamBasicDescription)audioDescription {
    [self setupAudioSession];
    
    _audioDescription = audioDescription;
    
	OSStatus result = noErr;
    
    // create a new AUGraph
	result = NewAUGraph(&_audioGraph);
    if ( !checkResult(result, "NewAUGraph") ) return;
	
    // create AudioComponentDescriptions for the AUs we want in the graph
    // input/output unit
    AudioComponentDescription io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = (_voiceProcessingEnabled && _enableInput ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_RemoteIO),
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    // multichannel mixer unit
    AudioComponentDescription mixer_desc = {
        .componentType = kAudioUnitType_Mixer,
        .componentSubType = kAudioUnitSubType_MultiChannelMixer,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    // create a node in the graph that is an AudioUnit, using the supplied AudioComponentDescription to find and open that unit
	result = AUGraphAddNode(_audioGraph, &io_desc, &_ioNode);
	if ( !checkResult(result, "AUGraphAddNode io") ) return;
    
	result = AUGraphAddNode(_audioGraph, &mixer_desc, &_mixerNode );
	if ( !checkResult(result, "AUGraphAddNode mixer") ) return;
    
    // connect output of mixer to io output
	result = AUGraphConnectNodeInput(_audioGraph, _mixerNode, 0, _ioNode, 0);
	if ( !checkResult(result, "AUGraphConnectNodeInput") ) return;
	
    // open the graph AudioUnits are open but not initialized (no resource allocation occurs here)
	result = AUGraphOpen(_audioGraph);
	if ( !checkResult(result, "AUGraphOpen") ) return;
	
	result = AUGraphNodeInfo(_audioGraph, _mixerNode, NULL, &_mixerAudioUnit);
    if ( !checkResult(result, "AUGraphNodeInfo") ) return;
    
	// set output stream format to what we want
    result = AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(audioDescription));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) return;
    
    // set bus count
	UInt32 numbuses = _channelCount;
    result = AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numbuses, sizeof(numbuses));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // configure input audio unit
    result = AUGraphNodeInfo(_audioGraph, _ioNode, NULL, &_ioAudioUnit);
    if ( !checkResult(result, "AUGraphNodeInfo") ) return;
    
    AudioStreamBasicDescription inDesc;
    UInt32 inDescSize = sizeof(inDesc);
    result = AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kInputBus, &inDesc, &inDescSize);
    if ( checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") && inDesc.mChannelsPerFrame != 0 ) {
        _numberOfInputChannels = inDesc.mChannelsPerFrame;
    }
    
    result = AudioUnitSetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kInputBus, &audioDescription, sizeof(audioDescription));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) return;

    result = AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioDescription, sizeof(audioDescription));
    if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) return;

    
    if ( _enableInput ) {
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioDescription, sizeof(audioDescription));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) return;

        UInt32 enableInputFlag = 1;
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &enableInputFlag, sizeof(enableInputFlag));
        checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO)");
            
        // also register a callback to receive audio
        AURenderCallbackStruct inRenderProc;
        inRenderProc.inputProc = &inputAvailableCallback;
        inRenderProc.inputProcRefCon = self;
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, kInputBus, &inRenderProc, sizeof(inRenderProc));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_SetInputCallback)") ) return;
        
        if ( _voiceProcessingEnabled && _enableInput ) {
            UInt32 quality = 127;
            result = AudioUnitSetProperty(_ioAudioUnit, kAUVoiceIOProperty_VoiceProcessingQuality, kAudioUnitScope_Global, 1, &quality, sizeof(quality));
            checkResult(result, "AudioUnitSetProperty(kAUVoiceIOProperty_VoiceProcessingQuality)");
        }
    }
    
	for (int i = 0; i < _channelCount; i++) {
        id<TPAudioPlayable> channel = (id<TPAudioPlayable>)_channels[i].userInfo;
        
        // setup render callback struct
        AURenderCallbackStruct rcbs;
        rcbs.inputProc = &playbackCallback;
        rcbs.inputProcRefCon = self;
        
        // Set a callback for the specified node's specified input
        result = AUGraphSetNodeInputCallback(_audioGraph, _mixerNode, i, &rcbs);
        if ( !checkResult(result, "AUGraphSetNodeInputCallback") ) return;
        
        // set input stream format to what we want
        result = AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &audioDescription, sizeof(audioDescription));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) return;
        
        if ( [channel respondsToSelector:@selector(volume)] ) {
            // set volume
            AudioUnitParameterValue volumeValue = (AudioUnitParameterValue)channel.volume;
            result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, i, volumeValue, 0);
            checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
        }
        
        if ( [channel respondsToSelector:@selector(pan)] ) {
            // set pan
            AudioUnitParameterValue panValue = (AudioUnitParameterValue)channel.pan;
            OSStatus result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, i, panValue, 0);
            checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
        }
	}
	
    // set the mixer unit to handle 4096 samples per slice since we want to keep rendering during screen lock
    UInt32 maxFPS = 4096;
    AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    
    // set latency
    Float32 preferredBufferSize = _preferredBufferDuration;
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    
    checkResult(AudioUnitAddRenderNotify(_mixerAudioUnit, &outputCallback, self), "AudioUnitAddRenderNotify");
    
    // now that we've set everything up we can initialize the graph, this will also validate the connections
	result = AUGraphInitialize(_audioGraph);
    if ( !checkResult(result, "AUGraphInitialize") ) return;
    
    _initialised = YES;
}

- (void)start {
    checkResult(AudioSessionSetActive(true), "AudioSessionSetActive");
    checkResult(AUGraphStart(_audioGraph), "AUGraphStart");
    
    AudioStreamBasicDescription inDesc;
    UInt32 inDescSize = sizeof(inDesc);
    OSStatus result = AudioUnitGetProperty(_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kInputBus, &inDesc, &inDescSize);
    if ( checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") && inDesc.mChannelsPerFrame != 0 ) {
        _numberOfInputChannels = inDesc.mChannelsPerFrame;
    }
    
    _running = YES;
}

- (void)stop {
    if ( self.running ) {
        _running = NO;
        
        if ( !checkResult(AUGraphStop(_audioGraph), "AUGraphStop") ) return;
        AudioSessionSetActive(false);
    }
}

#pragma mark - Channel/delegate management

- (void)addChannels:(NSArray*)channels {
    id<TPAudioPlayable> lastChannel = [channels lastObject];
    for ( id<TPAudioPlayable> channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", nil] ) {
            [(NSObject*)channel addObserver:self forKeyPath:property options:0 context:NULL];
        }
        
        [channel retain];
        [self performAsynchronousMessageExchange:(message_t){ .action = kMessageAdd, .kind = kKindChannel, .parameter1 = (long)channel.playbackCallback, .parameter2 = (long)channel } 
                                   responseBlock:channel != lastChannel ? nil : ^(message_t message, long channelCount) {
                                       // After last channel has been added...
                                       if ( _initialised ) {
                                           // set bus count
                                           UInt32 numbuses = channelCount + [channels count];
                                           OSStatus result = AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numbuses, sizeof(numbuses));
                                           if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) {
                                               return;
                                           }
                                           
                                           NSInteger i = channelCount - [channels count];
                                           
                                           for ( id<TPAudioPlayable> channel in channels ) {
                                               // setup render callback struct
                                               AURenderCallbackStruct rcbs;
                                               rcbs.inputProc = &playbackCallback;
                                               rcbs.inputProcRefCon = self;
                                               
                                               // Set a callback for the specified node's specified input
                                               result = AUGraphSetNodeInputCallback(_audioGraph, _mixerNode, i, &rcbs);
                                               if ( !checkResult(result, "AUGraphSetNodeInputCallback") ) return;
                                               
                                               // set input stream format to what we want
                                               result = AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &_audioDescription, sizeof(_audioDescription));
                                               if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) return;
                                               
                                               // set volume
                                               AudioUnitParameterValue volumeValue = (AudioUnitParameterValue)([channel respondsToSelector:@selector(volume)] ? channel.volume : 1.0);
                                               result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, i, volumeValue, 0);
                                               if ( !checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)") ) return;
                                               
                                               // set pan
                                               AudioUnitParameterValue panValue = (AudioUnitParameterValue)([channel respondsToSelector:@selector(pan)] ? channel.pan : 0.0);
                                               result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, i, panValue, 0);
                                               if ( !checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)") ) return;
                                               
                                               i++;
                                           }
                                           
                                           [self refreshGraph];
                                       }
                                   }];
    }
}

- (void)removeChannels:(NSArray *)channels {
    id<TPAudioPlayable> lastChannel = [channels lastObject];
    callback_t final_channels_array[kMaximumChannels];
    
    for ( id<TPAudioPlayable> channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", nil] ) {
            [(NSObject*)channel removeObserver:self forKeyPath:property];
        }
        
        [self performAsynchronousMessageExchange:(message_t){ 
                            .action = kMessageRemove, 
                            .kind = kKindChannel, 
                            .parameter1 = (long)channel.playbackCallback, 
                            .parameter2 = (long)channel,
                            .response_ptr = &final_channels_array }
             responseBlock:channel != lastChannel ? nil : ^(message_t message, long newChannelCount){
                 // After channel removal is complete, update the graph, and release the channels
                 if ( _initialised ) {
                     // set bus count
                     UInt32 numbuses = newChannelCount;
                     OSStatus result = AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numbuses, sizeof(numbuses));
                     if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) {
                         return;
                     }
                     
                     // reassign channel parameters
                     callback_t *array = (callback_t*)message.response_ptr;
                     for ( NSInteger i=0; i<newChannelCount; i++ ) {
                         id<TPAudioPlayable> channel = (id<TPAudioPlayable>)(array[i].userInfo);
                         
                         // set volume
                         AudioUnitParameterValue volumeValue = (AudioUnitParameterValue)([channel respondsToSelector:@selector(volume)] ? channel.volume : 1.0);
                         result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, i, volumeValue, 0);
                         if ( !checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)") ) return;
                         
                         // set pan
                         AudioUnitParameterValue panValue = (AudioUnitParameterValue)([channel respondsToSelector:@selector(pan)] ? channel.pan : 0.0);
                         result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, i, panValue, 0);
                         if ( !checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)") ) return;
                     }
                     
                     [self refreshGraph];
                 }
                 
                 [channels makeObjectsPerformSelector:@selector(release)];
             }];
    }
}

-(NSArray *)channels {
    NSArray *callbacks = [self getDelegatesOfKind:kKindChannel];
    NSMutableArray *channels = [NSMutableArray array];
    for ( NSDictionary *callback in callbacks ) {
        [channels addObject:(id)[[callback objectForKey:kTPAudioControllerUserInfoKey] pointerValue]];
    }
    return channels;
}

- (void)addRecordDelegate:(TPAudioControllerAudioDelegateCallback)callback userInfo:(void*)userInfo {
    [self performAsynchronousMessageExchange:(message_t){ .action = kMessageAdd, .kind = kKindRecordDelegate, .parameter1 = (long)callback, .parameter2 = (long)userInfo } responseBlock:nil];
}

- (void)removeRecordDelegate:(TPAudioControllerAudioDelegateCallback)callback userInfo:(void*)userInfo {
    [self performAsynchronousMessageExchange:(message_t){ .action = kMessageRemove, .kind = kKindRecordDelegate, .parameter1 = (long)callback, .parameter2 = (long)userInfo } responseBlock:nil];
}

-(NSArray *)recordDelegates {
    return [self getDelegatesOfKind:kKindRecordDelegate];
}

- (void)addPlaybackDelegate:(TPAudioControllerAudioDelegateCallback)callback userInfo:(void*)userInfo {
    [self performAsynchronousMessageExchange:(message_t){ .action = kMessageAdd, .kind = kKindPlaybackDelegate, .parameter1 = (long)callback, .parameter2 = (long)userInfo } responseBlock:nil];
}

- (void)removePlaybackDelegate:(TPAudioControllerAudioDelegateCallback)callback userInfo:(void*)userInfo {
    [self performAsynchronousMessageExchange:(message_t){ .action = kMessageRemove, .kind = kKindPlaybackDelegate, .parameter1 = (long)callback, .parameter2 = (long)userInfo } responseBlock:nil];
}

-(NSArray *)playbackDelegates {
    return [self getDelegatesOfKind:kKindPlaybackDelegate];
}

- (void)addTimingDelegate:(TPAudioControllerTimingCallback)callback userInfo:(void *)userInfo {
    [self performAsynchronousMessageExchange:(message_t){ .action = kMessageAdd, .kind = kKindTimingDelegate, .parameter1 = (long)callback, .parameter2 = (long)userInfo } responseBlock:nil];
}

- (void)removeTimingDelegate:(TPAudioControllerTimingCallback)callback userInfo:(void *)userInfo {
    [self performAsynchronousMessageExchange:(message_t){ .action = kMessageRemove, .kind = kKindTimingDelegate, .parameter1 = (long)callback, .parameter2 = (long)userInfo } responseBlock:nil];
}

-(NSArray *)timingDelegates {
    return [self getDelegatesOfKind:kKindTimingDelegate];
}

#pragma mark - Setters, getters

- (BOOL)running {
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
    
    if ( _initialised ) {
        [self stop];
        [self teardown];
        
        UInt32 audioCategory;
        if ( _audioInputAvailable && _enableInput ) {
            // Set the audio session category for simultaneous play and record
            audioCategory = kAudioSessionCategory_PlayAndRecord;
        } else {
            // Just playback
            audioCategory = kAudioSessionCategory_MediaPlayback;
        }
        
        OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory);
        checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_AudioCategory)");
        
        UInt32 allowMixing = true;
        result = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing);
        checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");

        [self setupWithAudioDescription:_audioDescription];
        [self start];
    }
}

-(void)setPreferredBufferDuration:(float)preferredBufferDuration {
    _preferredBufferDuration = preferredBufferDuration;
    if ( _initialised ) {
        Float32 preferredBufferSize = _preferredBufferDuration;
        OSStatus result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
        checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    }
}

-(void)setVoiceProcessingEnabled:(BOOL)voiceProcessingEnabled {
    if ( _voiceProcessingEnabled == voiceProcessingEnabled ) return;
    
    _voiceProcessingEnabled = voiceProcessingEnabled;
    if ( _initialised ) [self updateVoiceProcessingSettings];
}

#pragma mark - Events

-(void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ( [keyPath isEqualToString:@"volume"] ) {
        [self setVolume:((id<TPAudioPlayable>)object).volume forChannel:object];
    } else if ( [keyPath isEqualToString:@"pan"] ) {
        [self setPan:((id<TPAudioPlayable>)object).pan forChannel:object];
    }
}

- (void)applicationDidBecomeActive:(NSNotification*)notification {
    OSStatus status = AudioSessionSetActive(true);
    checkResult(status, "AudioSessionSetActive");
}

#pragma mark - Helpers

- (void)setVolume:(float)volume forChannel:(id<TPAudioPlayable>)channel {
    AudioUnitParameterValue value = (AudioUnitParameterValue)volume;
    [self performAsynchronousMessageExchange:(message_t) { .action = kMessageFindIndexWithMatchingUserInfo, .kind = kKindChannel, .parameter1 = (long)channel }
         responseBlock:^(message_t message, long response) {
             UInt32 channelIndex = response;
             assert(channelIndex != NSNotFound);
             OSStatus result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, channelIndex, value, 0);
             checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
         }];
}

- (void)setPan:(float)pan forChannel:(id<TPAudioPlayable>)channel {
    AudioUnitParameterValue value = (AudioUnitParameterValue)pan;
    if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
    if ( value == 1.0 ) value = 0.999;
    
    [self performAsynchronousMessageExchange:(message_t) { .action = kMessageFindIndexWithMatchingUserInfo, .kind = kKindChannel, .parameter1 = (long)channel }
         responseBlock:^(message_t message, long response) {
             UInt32 channelIndex = response;
             assert(channelIndex != NSNotFound);
             OSStatus result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, channelIndex, value, 0);
             checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
         }];
}

- (void)teardown {
    checkResult(AUGraphClose(_audioGraph), "AUGraphClose");
}

- (void)refreshGraph {
    if ( _initialised ) {
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
}

- (void)setupAudioSession {
    // Initialize and configure the audio session
    OSStatus result;
    
    result = AudioSessionInitialize(NULL, NULL, interruptionListener, self);
    if ( !checkResult(result, "AudioSessionInitialize") ) return;
    
    UInt32 inputAvailable=0;
    UInt32 size = sizeof(inputAvailable);
    result = AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &size, &inputAvailable);
    checkResult(result, "AudioSessionGetProperty");
    
    if ( _audioInputAvailable != inputAvailable ) {
        [self willChangeValueForKey:@"audioInputAvailable"];
        _audioInputAvailable = inputAvailable;
        [self didChangeValueForKey:@"audioInputAvailable"];
    }
    
    UInt32 audioCategory;
    if ( inputAvailable && _enableInput ) {
        // Set the audio session category for simultaneous play and record
        audioCategory = kAudioSessionCategory_PlayAndRecord;
    } else {
        // Just playback
        audioCategory = kAudioSessionCategory_MediaPlayback;
    }
    
    result = AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_AudioCategory)");
    
    UInt32 allowMixing = true;
    result = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    
    
    
#if !TARGET_IPHONE_SIMULATOR
    CFStringRef route;
    size = sizeof(route);
    result = AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route);
    if ( checkResult(result, "AudioSessionGetProperty(kAudioSessionProperty_AudioRoute)") ) {
        if ( [(NSString*)route isEqualToString:@"ReceiverAndMicrophone"] ) {
            // Re-route audio to the speaker (not the receiver)
            UInt32 newRoute = kAudioSessionOverrideAudioRoute_Speaker;
            result = AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute,  sizeof(route), &newRoute);
            checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute)");
        }
    }
    CFRelease(route);
#endif
    
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioRouteChangePropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioInputAvailable, inputAvailablePropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    Float32 preferredBufferSize = _preferredBufferDuration;
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    
    Float64 hwSampleRate = 44100.0;
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate, sizeof(hwSampleRate), &hwSampleRate);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate)");
    
    if ( !checkResult(AudioSessionSetActive(true), "AudioSessionSetActive") ) return;
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
        [self setupWithAudioDescription:_audioDescription];
        [self start];
    }
}

-(NSArray *)getDelegatesOfKind:(int)kind {
    // Request copy of channels array from realtime thread
    callback_t array[kMaximumChannels];
    long count = [self performSynchronousMessageExchange:(message_t) { .action = kMessageGet, .kind = kind, .response_ptr = &array }];
    
    // Construct NSArray response
    NSMutableArray *result = [NSMutableArray array];
    for ( int i=0; i<count; i++ ) {
        [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                           [NSValue valueWithPointer:array[i].callback], kTPAudioControllerCallbackKey,
                           [NSValue valueWithPointer:array[i].userInfo], kTPAudioControllerUserInfoKey, nil]];
    }
    
    return result;
}

#pragma mark - Main thread-realtime thread message sending

static void processPendingMessages(TPAudioController *THIS) {
    // Only call this from the Core Audio thread, or the main thread if audio system is not yet running
    
    int32_t availableBytes;
    message_t *messages = TPACCircularBufferTail(&THIS->_messageBuffer, &availableBytes);
    int messageCount = availableBytes / sizeof(message_t);
    for ( int i=0; i<messageCount; i++ ) {
        message_t* message = &messages[i];
        long response = 0;
        
        int *counter;
        callback_t* array;
        if ( message->action == kMessageAdd || message->action == kMessageRemove || message->action == kMessageGet || message->action == kMessageFindIndexWithMatchingUserInfo ) {
            switch ( message->kind ) {
                case kKindChannel:
                    counter = &THIS->_channelCount;
                    array   = THIS->_channels;
                    break;
                case kKindRecordDelegate:
                    counter = &THIS->_recordDelegateCount;
                    array   = THIS->_recordDelegates;
                    break;
                case kKindPlaybackDelegate:
                    counter = &THIS->_playbackDelegateCount;
                    array   = THIS->_playbackDelegates;
                    break;
                case kKindTimingDelegate:
                    counter = &THIS->_timingDelegateCount;
                    array   = THIS->_timingDelegates;
                    break;
                case kKindFilter:
                    // TODO
                    break;
            };
        }
        
        switch ( message->action ) {
            case kMessageAdd: {
                array[*counter].callback = (void*)message->parameter1;
                array[*counter].userInfo = (void*)message->parameter2;
                (*counter)++;
                break;
            }
            case kMessageRemove: {
                // Find the item in our fixed array
                int index = 0;
                for ( index=0; index<*counter; index++ ) {
                    if ( array[*counter].callback == (void*)message->parameter1 && array[*counter].userInfo == (void*)message->parameter2 ) {
                        break;
                    }
                }
                if ( index < *counter ) {
                    // Now overwrite the channel's entry with the later elements
                    (*counter)--;
                    for ( int i=index; i<*counter; i++ ) {
                        array[i] = array[i+1];
                    }
                }
                break;
            }
            case kMessageGet: {
                // Nothing to do
                break;
            }
            case kMessageFindIndexWithMatchingUserInfo: {
                int index = 0;
                for ( index=0; index<*counter; index++ ) {
                    if ( array[*counter].userInfo == (void*)message->parameter1 ) {
                        break;
                    }
                }
                if ( index < *counter ) {
                    response = index;
                } else {
                    response = NSNotFound;
                }
            }
        }
        
        if ( (message->action == kMessageAdd || message->action == kMessageRemove || message->action == kMessageGet) && message->response_block ) {
            response = *counter;
            
            if ( message->response_ptr ) {
                // Parameter 4, if non-NULL, is a pointer to an array to copy the array to
                memcpy(message->response_ptr, array, *counter * sizeof(callback_t));
            }
        }
        
        if ( message->response_block ) {
            message_response_t message_response = { .message = *message, .response = response };
            TPACCircularBufferProduceBytes(&THIS->_responseBuffer, &message_response, sizeof(message_response_t));
        }
    }
    
    TPACCircularBufferConsume(&THIS->_messageBuffer, availableBytes);
}

-(void)pollMessageResponses {
    int32_t availableBytes;
    message_response_t *responses = TPACCircularBufferTail(&_responseBuffer, &availableBytes);
    int responseCount = availableBytes / sizeof(message_response_t);
    for ( int i=0; i<responseCount; i++ ) {
        message_response_t *response = &responses[i];
        response->message.response_block(response->message, response->response);
        [response->message.response_block release];
        _pendingResponses--;
    }
    
    if ( _pendingResponses == 0 && _responsePollTimer ) {
        [_responsePollTimer invalidate];
        _responsePollTimer = nil;
    }
}

- (void)performAsynchronousMessageExchange:(message_t)message responseBlock:(void (^)(struct _message_t message, long response))responseBlock {
    // Only perform on main thread
    if ( !_initialised && responseBlock ) {
        [responseBlock retain];
        _pendingResponses++;
        
        if ( !_responsePollTimer ) {
            _responsePollTimer = [NSTimer scheduledTimerWithTimeInterval:_preferredBufferDuration target:self selector:@selector(pollMessageResponses) userInfo:nil repeats:YES];
        }
    }
    
    message.response_block = responseBlock;
    TPACCircularBufferProduceBytes(&_messageBuffer, &message, sizeof(message_t));
    
    if ( !_initialised ) {
        processPendingMessages(self);
        [self pollMessageResponses];
    }
}

- (long)performSynchronousMessageExchange:(message_t)message {
    // Only perform on main thread
    __block long returned_response;
    __block BOOL finished = NO;
    
    [self performAsynchronousMessageExchange:message responseBlock:^(message_t message, long response) {
        returned_response = response;
        finished = YES;
    }];
    
    // Wait for response
    while ( !finished ) {
        [self pollMessageResponses];
        if ( finished ) break;
        [NSThread sleepForTimeInterval:_preferredBufferDuration];
    }
    
    return returned_response;
}


@end
