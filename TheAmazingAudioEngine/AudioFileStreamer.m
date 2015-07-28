//
//  AudioFileStreamer.m
//
//  Created by Ryan King and Jeremy Huff of Hello World Engineering, Inc on 7/15/15.
//  Copyright (c) 2015 Hello World Engineering, Inc. All rights reserved.
//
//  AudioFileStreamer is based on code written by Michael Tyson from The Amazing Audio Engine.
//  It also uses code written by Rob Rampley for The Amazing Audio Engine.
//  This source file is released under The Amazing Audio Engine license, pasted below.
//  This notice, beginning with "Created by Ryan..." may not be removed or altered from any source distribution.
//
//
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

#import "AudioFileStreamer.h"
#import <libkern/OSAtomic.h>
@import AudioUnit;

@implementation AudioFileStreamer
@synthesize audioUnit = _audioUnit, node = _node;
@dynamic duration,currentTime, playbackDelayInSeconds;

// MARK:  Debug Properties
@synthesize currentFrame = _playhead, totalFrames = _lengthInFrames;

// MARK: Init and Dealloc
- (id) init
{
    self = [super init];
    if(self) {
        _url = nil;
        _channelIsMuted = NO;
        _channelIsPlaying = NO;
        _completionBlock = nil;
        
        _lengthInFrames = 0;
        _playhead = 0;
        _playbackDelay = 0;
        _reloadAudioRegionOnPlay = NO;
        _looping = NO;
        
        // Audio Playable protocol properties
        self.volume = 1.0;
        self.pan = 0;
    }
    return(self);
}

static void notifyPlaybackStopped(AEAudioController *audioController, void *userInfo, int length) {
    AudioFileStreamer *THIS = (__bridge AudioFileStreamer*)*(void**)userInfo;
    THIS.channelIsPlaying = NO;
    
    if ( THIS.completionBlock ) THIS.completionBlock();
    
    THIS->_playhead = 0;
    THIS->_reloadAudioRegionOnPlay = YES;
}

- (BOOL)setupPlayRegion: (NSError**) error
{
    OSStatus result = -1;
    
    if(_audioUnitFile)
    {
        // Set playhead to starting point if it is beyond the end of the song.
        if(_playhead >= _lengthInFrames)
            _playhead = 0;
        
        // Reset the audio unit before modifying properties
        checkResultForError(AudioUnitReset(_audioUnit, kAudioUnitScope_Global, 0),"AudioUnitReset()","Error resetting audio unit",NO,result,error)
        
        // Create the Scheduled Audio File Region struct
        ScheduledAudioFileRegion region;
        memset (&region.mTimeStamp, 0, sizeof(region.mTimeStamp));
        
        // Need to manually validate the time stamp and set it's start time to 0
        region.mTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
        region.mTimeStamp.mSampleTime = _playbackDelay;
        
        // No process will be called on completion
        region.mCompletionProc = NULL;
        region.mCompletionProcUserData = NULL;
        
        // Point to the audio unit file
        region.mAudioFile = _audioUnitFile;
        region.mLoopCount = 0;
        region.mStartFrame = _playhead;
        region.mFramesToPlay = _lengthInFrames - _playhead;
        
        checkResultForError(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region)), "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)", "Error Scheduling File Region for audio unit", NO, result, error)
        
        // Prime the player by reading some frames from disk. This is the referenced way of performing a prime
        UInt32 defaultNumberOfFrames = 0;
        checkResultForError(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_ScheduledFilePrime, kAudioUnitScope_Global, 0, &defaultNumberOfFrames, sizeof(defaultNumberOfFrames)), "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFilePrime)", "Error priming scheduled audio unit.", NO, result, error)
        
        // Set the start time. We have to do this after priming
        AudioTimeStamp startTime;
        memset (&startTime, 0, sizeof(startTime));
        startTime.mFlags = kAudioTimeStampSampleTimeValid;
        startTime.mSampleTime = -1;
        checkResultForError(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_ScheduleStartTimeStamp, kAudioUnitScope_Global, 0, &startTime, sizeof(startTime)), "AudioUnitSetProperty(kAudioUnitProperty_ScheduleStartTimeStamp)", "Error setting timestamp for audio unit.", NO, result, error)
    }
    
    return YES;
}

- (id) initWithURL:(NSURL *)url audioController:(AEAudioController *)audioController error:(NSError **)error
{
    self = [self init];
    if(self) {
        // Verify that the URL is valid and set the url
        if(![[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
            // TODO : Create error domain and code for this purpose
            //*error = [NSError errorWithDomain: NSOSStatusErrorDomain code:0 userInfo:[NSDictionary dictionaryWithObject:@"URL is invalid" forKey:NSLocalizedDescriptionKey]];
            return nil;
        }
        else {
            _url = url;
        }
        
        // the following is lifted from the AEAudioUnitChannel/AEAudioUnitFilePlayer class
        AudioComponentDescription aedesc = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Generator, kAudioUnitSubType_AudioFilePlayer);
        
        // Create the node, and the audio unit
        _audioGraph = audioController.audioGraph;
        OSStatus result;
        if ( !checkResult(result=AUGraphAddNode(_audioGraph, &aedesc, &_node), "AUGraphAddNode") ||
             !checkResult(result=AUGraphNodeInfo(_audioGraph, _node, NULL, &_audioUnit), "AUGraphNodeInfo") ) {
            
            if ( error )
                *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Couldn't initialise audio unit" forKey:NSLocalizedDescriptionKey]];
            return nil;
        }
        
        // Now that the auio unit has been put into the graph, load the URL
        // Taken from AEAudioUnitFilePlayer
        checkResult(result = AudioFileOpenURL((CFURLRef)CFBridgingRetain(url), kAudioFileReadPermission, 0, &_audioUnitFile), "AudioFileOpenURL");
        if(result == noErr)
        {
            // Set the file to play
            checkResultForError(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_ScheduledFileIDs, kAudioUnitScope_Global, 0, &_audioUnitFile, sizeof(_audioUnitFile)), "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileIDs)", "Failed setting audio unit file IDs", nil, result, error)
                
            // Determine file properties
            UInt64 packetCount;
            UInt32 size = sizeof(packetCount);
            checkResultForError(AudioFileGetProperty(_audioUnitFile, kAudioFilePropertyAudioDataPacketCount, &size, &packetCount), "AudioFileGetProperty(kAudioFilePropertyAudioDataPacketCount)", "Failed getting audio file number of packets", nil, result, error)
                
            size = sizeof(_audioDescription);
            checkResultForError(AudioFileGetProperty(_audioUnitFile, kAudioFilePropertyDataFormat, &size, &_audioDescription), "AudioFileGetProperty(kAudioFilePropertyDataFormat)", "Failed getting audio file data format", nil, result, error)
                
            _lengthInFrames = (UInt32)(packetCount * _audioDescription.mFramesPerPacket);
            _url = url;
        }
        else {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"URL failed to open" forKey:NSLocalizedDescriptionKey]];
            return nil;
        }
        
        // Try to set the output audio description
        AudioStreamBasicDescription audioDescription = audioController.audioDescription;
        result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription));
        if ( result == kAudioUnitErr_FormatNotSupported ) {
            // The audio description isn't supported. Assign modified default audio description, and create an audio converter.
            AudioStreamBasicDescription defaultAudioDescription;
            UInt32 size = sizeof(defaultAudioDescription);
            result = AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, &size);
            defaultAudioDescription.mSampleRate = audioDescription.mSampleRate;
            AEAudioStreamBasicDescriptionSetChannelsPerFrame(&defaultAudioDescription, audioDescription.mChannelsPerFrame);
            checkResultForError(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, size), "AudioUnitSetProperty", "Incompatible audio format", nil, result, error)
            
            AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
            
            if ( !checkResult(result=AUGraphAddNode(_audioGraph, &audioConverterDescription, &_converterNode), "AUGraphAddNode") ||
                !checkResult(result=AUGraphNodeInfo(_audioGraph, _converterNode, NULL, &_converterUnit), "AUGraphNodeInfo") ||
                !checkResult(result=AUGraphConnectNodeInput(_audioGraph, _node, 0, _converterNode, 0), "AUGraphConnectNodeInput") ||
                !checkResult(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
                !checkResult(result=AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) {
                
                if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Couldn't setup converter audio unit" forKey:NSLocalizedDescriptionKey]];
                return nil;
            }
        }
        
        // Attempt to set the max frames per slice
        UInt32 maxFPS = 4096;
        AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
        
        checkResultForError(AUGraphUpdate(_audioGraph, NULL), "AUGraphUpdate", "Couldn't update audio graph", nil, result, error)

        checkResultForError( AudioUnitInitialize(_audioUnit), "AudioUnitInitialize", "Couldn't initialize audio unit", nil, result, error)
        
        // Initialize the converter unit, if necessary
        if ( _converterUnit ) {
            checkResultForError( AudioUnitInitialize(_converterUnit), "AudioUnitInitialize", "Couldn't initialize converter audio unit", nil, result, error)
            
            AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
        }
        
        // set the audio controller at the end
        _audioController = audioController;
        
        // Setup play region
        error = nil;
        if(![self setupPlayRegion:error]) {
            if(error) {
                return nil;
            }
        }
    }
    return(self);
}

- (void)dealloc {
    
    if ( _node ) {
        checkResult(AUGraphRemoveNode(_audioGraph, _node), "AUGraphRemoveNode");
    }
    if ( _converterNode ) {
        checkResult(AUGraphRemoveNode(_audioGraph, _converterNode), "AUGraphRemoveNode");
    }
    
    checkResult(AUGraphUpdate(_audioGraph, NULL), "AUGraphUpdate");
    
    if ( _audioUnitFile ) {
        AudioFileClose(_audioUnitFile);
    }
    
    _completionBlock = nil;
    _audioController = nil;
}

// MARK: Audio functions

- (void) play
{
    if(_playbackDelay != 0) {
        [self setupPlayRegion:nil];
    }
    self.channelIsPlaying = true;
}
- (void) pause
{
    self.channelIsPlaying = false;
}
- (void) stop
{
    self.channelIsPlaying = NO;
    _playhead = 0;
    _reloadAudioRegionOnPlay = YES;
}

// TODO : Mute and Unmute - channelIsPlaying
- (void) mute
{
    _channelIsMuted = true;
}

- (void) unmute
{
    _channelIsMuted = false;
}

// MARK: Getters and Setters
-(NSTimeInterval)duration {
    return (double)_lengthInFrames / (double)_audioDescription.mSampleRate;
}

-(NSTimeInterval)currentTime {
    if (_lengthInFrames == 0) return 0.0;
    else return ((double)_playhead / (double)_lengthInFrames) * [self duration];
}

-(void)setCurrentTime:(NSTimeInterval)currentTime {
    if (_lengthInFrames == 0) return;
    _playhead = (int32_t)((currentTime / [self duration]) * _lengthInFrames) % _lengthInFrames;
    
    // If we're paused, make sure to set the reload flag. If we're not paused, we have to reload the audio immediately.
    if(_channelIsPlaying) {
        NSError* error;
        [self setupPlayRegion:&error];
        if(error) {
            NSLog(@"Error trying to change the playhead time. %@",error.description);
        }
    }
    else
        _reloadAudioRegionOnPlay = YES;
}

-(void)setPlaybackDelay:(int)playbackDelay {
    _playbackDelay = playbackDelay;
    
    // Reschedule audio region
    NSError* error;
    [self setupPlayRegion:&error];
    if(error) {
        NSLog(@"Error changing the playback: %@",error.description);
    }
}

-(void)setPlaybackDelayInSeconds:(Float64)playbackDelayInSeconds {
    // Calculate the number of frames to delay
    int playbackDelayFrames = playbackDelayInSeconds * _audioDescription.mSampleRate;
    
    self.playbackDelay = playbackDelayFrames;
}

-(Float64)playbackDelayInSeconds {
    return(_playbackDelay / _audioDescription.mSampleRate);
}

// MARK: Override Getters and Setters
-(void)setChannelIsPlaying:(BOOL)channelIsPlaying {
    // If we've turned on the channel, reload audio data if needed
    if(channelIsPlaying && !_channelIsPlaying) {
        if(_reloadAudioRegionOnPlay) {
            _reloadAudioRegionOnPlay = NO;
            
            NSError* error;
            [self setupPlayRegion:&error];
            if(error) {
                NSLog(@"Error setting up audio file region for playback. %@",error.description);
            }
        }
    }
    
    // Set the variable
    _channelIsPlaying = channelIsPlaying;
}

// MARK: Render Callbacks
+(OSStatus) renderCallback:(AudioFileStreamer *__unsafe_unretained)THIS audioController:(AEAudioController *__unsafe_unretained)audioController time:(const AudioTimeStamp *)time numberOfFrames:(UInt32)frames audioBufferList:(AudioBufferList *)audio {
    
    int32_t playhead = THIS->_playhead;
    int32_t originalPlayhead = playhead;
    
    playhead += frames;
    
    if(playhead >= THIS->_lengthInFrames) {
        THIS->_channelIsPlaying = NO;
        THIS->_playhead = THIS->_lengthInFrames;
        // TODO : Race condition : while this message is waiting to be executed, _channelisplaying may be set to YES externally, causing another render call while the playback should be stopped. This if statement will catch and prevent a render, but it will call the notifyPlaybackStopped function twice. Need to prevent this : use a flag to signify that the method is scheduled.
        AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyPlaybackStopped, &THIS, sizeof(AudioFileStreamer*));
        return noErr;
    }
    
    // Render the audio unit
    AudioUnitRenderActionFlags flags = 0;
    checkResult(AudioUnitRender(THIS->_converterUnit ? THIS->_converterUnit : THIS->_audioUnit, &flags, time, 0, frames, audio), "AudioUnitRender");
    
    // update the playhead
    OSAtomicCompareAndSwap32(originalPlayhead, playhead, &THIS->_playhead);
    
    // DEBUG
  //  NSLog(@"Delay %d playhead %d",THIS->_playbackDelay, THIS->_playhead);
    
    return noErr;
}

static OSStatus renderCallback(__unsafe_unretained AudioFileStreamer *THIS, __unsafe_unretained AEAudioController *audioController, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
    
    // Call the class method, so that it can be overriden by subclasses
    return([AudioFileStreamer renderCallback:THIS audioController:audioController time:time numberOfFrames:frames audioBufferList:audio]);
}

-(AEAudioControllerRenderCallback)renderCallback {
    return &renderCallback;
}

@end
