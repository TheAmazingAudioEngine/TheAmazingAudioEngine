//
//  TPAudioController.m
//
//  Created by Michael Tyson on 25/11/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "TPAudioController.h"
#import <libkern/OSAtomic.h>

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/'),__LINE__))

#define kInputBus 1
#define kOutputBus 0

static inline int min(int a, int b) { return a>b ? b : a; }

static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
        return NO;
    }
    return YES;
}

@interface TPAudioController () {
    AUGraph     _audioGraph;
    AUNode      _mixerNode;
    AudioUnit   _mixerAudioUnit;
    AUNode      _ioNode;
    AudioUnit   _ioAudioUnit;
    BOOL        _initialised;
    BOOL        _audioSessionSetup;
    BOOL        _running;
    BOOL        _runningPriorToInterruption;
    BOOL        _setRenderNotify;
}

- (void)teardown;
- (void)refreshGraph;
@property (retain, readwrite) NSArray *channels;
@property (retain, readwrite) NSArray *recordDelegates;
@property (retain, readwrite) NSArray *playbackDelegates;
@end

@implementation TPAudioController
@synthesize channels=_channels, recordDelegates=_recordDelegates, playbackDelegates=_playbackDelegates, audioInputAvailable=_audioInputAvailable, 
            numberOfInputChannels=_numberOfInputChannels, enableInput=_enableInput, muteOutput=_muteOutput;
@dynamic running;

#pragma mark Audio session callbacks

static void interruptionListener(void *inClientData, UInt32 inInterruption)
{
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
        
        if ( [(NSString*)route isEqualToString:@"ReceiverAndMicrophone"] ) {
            checkResult(AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange, audioRouteChangePropertyListener, THIS), "AudioSessionRemovePropertyListenerWithUserData");
            
            // Re-route audio to the speaker (not the receiver)
            UInt32 newRoute = kAudioSessionOverrideAudioRoute_Speaker;
            checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute,  sizeof(route), &newRoute), "AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute)");
            
            checkResult(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioRouteChangePropertyListener, THIS), "AudioSessionAddPropertyListener");
        }
                
        // Check channels on input
        AudioStreamBasicDescription inDesc;
        UInt32 inDescSize = sizeof(inDesc);
        OSStatus result = AudioUnitGetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kInputBus, &inDesc, &inDescSize);
        if ( checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") && inDesc.mChannelsPerFrame != 0 ) {
            if ( THIS->_numberOfInputChannels != inDesc.mChannelsPerFrame ) {
                THIS->_numberOfInputChannels = inDesc.mChannelsPerFrame;
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
        
        if ( *inputAvailable ) {
            AudioStreamBasicDescription inDesc;
            UInt32 inDescSize = sizeof(inDesc);
            OSStatus result = AudioUnitGetProperty(THIS->_ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kInputBus, &inDesc, &inDescSize);
            if ( checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)") && inDesc.mChannelsPerFrame != 0 ) {
                if ( THIS->_numberOfInputChannels != inDesc.mChannelsPerFrame ) {
                    THIS->_numberOfInputChannels = inDesc.mChannelsPerFrame;
                }
            }
        }
        
        [THIS willChangeValueForKey:@"audioInputAvailable"];
        THIS->_audioInputAvailable = *inputAvailable;
        [THIS didChangeValueForKey:@"audioInputAvailable"];
    }
}

#pragma mark -
#pragma mark Input and render callbacks

static OSStatus playbackCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    TPAudioController *THIS = (TPAudioController *)inRefCon;
    NSArray *channels = THIS.channels;
    
    memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
    id<TPAudioPlayable> channel = ([channels count] > inBusNumber ? [channels objectAtIndex:inBusNumber] : nil);
    [channel audioController:THIS needsBuffer:(SInt16*)ioData->mBuffers[0].mData ofLength:inNumberFrames time:inTimeStamp];

    [pool release];
	return noErr;
}

static OSStatus recordingCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    TPAudioController *THIS = (TPAudioController *)inRefCon;
    
    int sampleCount = inNumberFrames * 2;
    
    // Render audio into buffer
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mNumberChannels = 2;
    bufferList.mBuffers[0].mData = NULL;
    bufferList.mBuffers[0].mDataByteSize = inNumberFrames * sizeof(SInt16) * 2; // Always provides 2 channels, even if mono (right channel is silent)
    OSStatus err = AudioUnitRender(THIS->_ioAudioUnit, ioActionFlags, inTimeStamp, kInputBus, inNumberFrames, &bufferList);
    if ( !checkResult(err, "AudioUnitRender") ) { [pool release]; return err; }
        
    SInt16 *buffer = (SInt16*)bufferList.mBuffers[0].mData;
    
    if ( THIS->_numberOfInputChannels == 1 ) {
        // Convert audio from stereo with only channel 0 provided, to proper mono
        sampleCount /= 2;
        for ( UInt32 i = 0, j = 0; i < sampleCount; i++, j+=2 ) {
            buffer[i] = buffer[j];
        }
    }
        
    int frameCount = sampleCount / THIS->_numberOfInputChannels;
        
    // Pass audio to record delegates
    for ( id<TPAudioRecordDelegate> recordDelegate in THIS.recordDelegates ) {
        [recordDelegate audioController:THIS 
                          incomingAudio:buffer
                               ofLength:frameCount
                       numberOfChannels:THIS->_numberOfInputChannels
                                   time:inTimeStamp];
    }
     
    [pool release];
    
    return noErr;
}


static OSStatus outputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    TPAudioController *THIS = (TPAudioController *)inRefCon;
        
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        
    if ( !(*ioActionFlags & kAudioUnitRenderAction_PostRender) ) {
        [pool release];
        return noErr;
    }
    
    SInt16 *buffer = ioData->mBuffers[0].mData;
    int sampleCount = ioData->mBuffers[0].mDataByteSize / sizeof(SInt16);
    
    // Pass audio to playback delegates
    for ( id<TPAudioPlaybackDelegate> playbackDelegate in THIS.playbackDelegates ) {
        [playbackDelegate audioController:THIS 
                            outgoingAudio:buffer
                                 ofLength:sampleCount / 2
                                     time:inTimeStamp];
    }
    
    if ( THIS->_muteOutput ) {
        memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
    }
    
    return noErr;
}

#pragma mark -

+ (AudioStreamBasicDescription)audioDescription {
    // Linear PCM, stereo, noninterleaved stream at the hardware sample rate.
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

- (id)init {
    if ( !(self = [super init]) ) return nil;
    
    self.channels = [NSArray array];
    self.recordDelegates = [NSArray array];
    self.playbackDelegates = [NSArray array];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    
    if ( NSClassFromString(@"TPTrialModeController") ) {
        [[NSClassFromString(@"TPTrialModeController") alloc] init];
    }
    
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stop];
    [self teardown];
    
    for ( id<TPAudioPlayable> channel in _channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", nil] ) {
            [(NSObject*)channel removeObserver:self forKeyPath:property];
        }
    }
    
    self.channels = nil;
    self.recordDelegates = nil;
    self.playbackDelegates = nil;
    
    [super dealloc];
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
#endif
    
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioRouteChangePropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioInputAvailable, inputAvailablePropertyListener, self);
    checkResult(result, "AudioSessionAddPropertyListener");
    
    Float32 preferredBufferSize = 0.005;
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    
    Float64 hwSampleRate = 44100.0;
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate, sizeof(hwSampleRate), &hwSampleRate);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate)");
    
    if ( !checkResult(AudioSessionSetActive(true), "AudioSessionSetActive") ) return;
    
    _audioSessionSetup = YES;
}

- (void)setup {
    if ( !_audioSessionSetup ) [self setupAudioSession];
    
	OSStatus result = noErr;
    
    AudioStreamBasicDescription audioDescription = [TPAudioController audioDescription];
    
    // create a new AUGraph
	result = NewAUGraph(&_audioGraph);
    if ( !checkResult(result, "NewAUGraph") ) return;
	
    // create AudioComponentDescriptions for the AUs we want in the graph
    // input/output unit
    AudioComponentDescription io_desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_RemoteIO,
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
	UInt32 numbuses = [_channels count];
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
        inRenderProc.inputProc = &recordingCallback;
        inRenderProc.inputProcRefCon = self;
        result = AudioUnitSetProperty(_ioAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, kInputBus, &inRenderProc, sizeof(inRenderProc));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioOutputUnitProperty_SetInputCallback)") ) return;
    }
    
	for (int i = 0; i < [_channels count]; i++) {
        id<TPAudioPlayable> channel = [_channels objectAtIndex:i];
        
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
    Float32 preferredBufferSize = 0.005;
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    checkResult(result, "AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration)");
    
    if ( [_playbackDelegates count] > 0 ) {
        // Register a callback to receive outgoing audio
        _setRenderNotify = YES;
        checkResult(AudioUnitAddRenderNotify(_mixerAudioUnit, &outputCallback, self), "AudioUnitAddRenderNotify");
    } else {
        _setRenderNotify = NO;
    }
    
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

- (void)addChannels:(NSArray*)channels {
    if ( _initialised ) {
        // set bus count
        UInt32 numbuses = [_channels count] + [channels count];
        OSStatus result = AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numbuses, sizeof(numbuses));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) {
            return;
        }
    
        NSInteger i = [_channels count];
        
        for ( id<TPAudioPlayable> channel in channels ) {
            // setup render callback struct
            AURenderCallbackStruct rcbs;
            rcbs.inputProc = &playbackCallback;
            rcbs.inputProcRefCon = self;
            
            // Set a callback for the specified node's specified input
            result = AUGraphSetNodeInputCallback(_audioGraph, _mixerNode, i, &rcbs);
            if ( !checkResult(result, "AUGraphSetNodeInputCallback") ) return;
            
            // set input stream format to what we want
            AudioStreamBasicDescription audioDescription = [TPAudioController audioDescription];
            result = AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, i, &audioDescription, sizeof(audioDescription));
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
    }
    
    for ( id<TPAudioPlayable> channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", nil] ) {
            [(NSObject*)channel addObserver:self forKeyPath:property options:0 context:NULL];
        }
    }
    
    self.channels = [_channels arrayByAddingObjectsFromArray:channels];
    
    if ( _initialised ) {
        [self performSelector:@selector(refreshGraph) withObject:nil afterDelay:0];
    }
}

- (void)removeChannels:(NSArray *)channels {
    NSMutableArray *newChannels = [[_channels mutableCopy] autorelease];

    for ( id<TPAudioPlayable> channel in channels ) {
        for ( NSString *property in [NSArray arrayWithObjects:@"volume", @"pan", nil] ) {
            [(NSObject*)channel removeObserver:self forKeyPath:property];
        }
    }

    if ( _initialised ) {
        // set bus count
        UInt32 numbuses = [newChannels count];
        OSStatus result = AudioUnitSetProperty(_mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numbuses, sizeof(numbuses));
        if ( !checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) {
            return;
        }
        
        // reassign channel parameters
        for ( NSInteger i=0; i<[newChannels count]; i++ ) {
            id<TPAudioPlayable> channel = [newChannels objectAtIndex:i];
            
            // set volume
            AudioUnitParameterValue volumeValue = (AudioUnitParameterValue)([channel respondsToSelector:@selector(volume)] ? channel.volume : 1.0);
            result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, i, volumeValue, 0);
            if ( !checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)") ) return;
            
            // set pan
            AudioUnitParameterValue panValue = (AudioUnitParameterValue)([channel respondsToSelector:@selector(pan)] ? channel.pan : 0.0);
            result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, i, panValue, 0);
            if ( !checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)") ) return;
        }
    }
    
    self.channels = newChannels;
    
    [self performSelector:@selector(refreshGraph) withObject:nil afterDelay:0];
}

- (void)addRecordDelegate:(id<TPAudioRecordDelegate>)delegate {
    self.recordDelegates = [_recordDelegates arrayByAddingObject:delegate];
}

- (void)removeRecordDelegate:(id<TPAudioRecordDelegate>)delegate {
    NSMutableArray *mutableDelegates = [[_recordDelegates mutableCopy] autorelease];
    [mutableDelegates removeObject:delegate];
    self.recordDelegates = mutableDelegates;
}

- (void)addPlaybackDelegate:(id<TPAudioPlaybackDelegate>)delegate {
    self.playbackDelegates = [_playbackDelegates arrayByAddingObject:delegate];
    
    if ( _initialised && !_setRenderNotify ) {
        // Register a callback to receive outgoing audio
        _setRenderNotify = YES;
        checkResult(AudioUnitAddRenderNotify(_mixerAudioUnit, &outputCallback, self), "AudioUnitAddRenderNotify");
    }
}

- (void)removePlaybackDelegate:(id<TPAudioPlaybackDelegate>)delegate {
    NSMutableArray *mutableDelegates = [[_playbackDelegates mutableCopy] autorelease];
    [mutableDelegates removeObject:delegate];
    self.playbackDelegates = mutableDelegates;
    
    if ( _initialised && [_playbackDelegates count] == 0 && _setRenderNotify ) {
        // Unregister callback
        _setRenderNotify = NO;
        checkResult(AudioUnitRemoveRenderNotify(_mixerAudioUnit, &outputCallback, self), "AudioUnitRemoveRenderNotify");
    }
}

- (BOOL)running {
    Boolean isRunning = false;
    
    OSStatus result = AUGraphIsRunning(_audioGraph, &isRunning);
    if ( !checkResult(result, "AUGraphIsRunning") ) {
        return NO;
    }
    
    return isRunning;
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

- (void)setVolume:(float)volume forChannel:(id<TPAudioPlayable>)channel {
    AudioUnitParameterValue value = (AudioUnitParameterValue)volume;
    UInt32 channelIndex = [_channels indexOfObject:channel];
    assert(channelIndex != NSNotFound);
    OSStatus result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, channelIndex, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
}

- (float)volumeForChannel:(id<TPAudioPlayable>)channel {
    AudioUnitParameterValue value;
    UInt32 channelIndex = [_channels indexOfObject:channel];
    assert(channelIndex != NSNotFound);
    OSStatus result = AudioUnitGetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, channelIndex, &value);
    checkResult(result, "AudioUnitGetParameter(kMultiChannelMixerParam_Volume)");
    return (float)value;
}

- (void)setPan:(float)pan forChannel:(id<TPAudioPlayable>)channel {
    AudioUnitParameterValue value = (AudioUnitParameterValue)pan;
    if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
    if ( value == 1.0 ) value = 0.999;
    UInt32 channelIndex = [_channels indexOfObject:channel];
    assert(channelIndex != NSNotFound);
    OSStatus result = AudioUnitSetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, channelIndex, value, 0);
    checkResult(result, "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
}

- (float)panForChannel:(id<TPAudioPlayable>)channel {
    AudioUnitParameterValue value;
    UInt32 channelIndex = [_channels indexOfObject:channel];
    assert(channelIndex != NSNotFound);
    OSStatus result = AudioUnitGetParameter(_mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, channelIndex, &value);
    checkResult(result, "AudioUnitGetParameter(kMultiChannelMixerParam_Pan)");
    return (float)value;
}

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

@end
