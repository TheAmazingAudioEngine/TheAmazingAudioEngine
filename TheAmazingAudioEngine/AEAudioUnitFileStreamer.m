//
//  AEAudioUnitFileStreamer.m
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

#import "AEAudioUnitFileStreamer.h"
#import <libkern/OSAtomic.h>

@implementation AEAudioUnitFileStreamer

@dynamic duration,currentTime, playbackDelayInSeconds, channelIsPlaying;

// MARK:  Debug Properties
@synthesize currentFrame = _playhead, totalFrames = _lengthInFrames;

// Notifications
static void notifyPlaybackStopped(AEAudioController *audioController, void *userInfo, int length) {
    AEAudioUnitFileStreamer *THIS = (__bridge AEAudioUnitFileStreamer*)*(void**)userInfo;
    
    if(OSAtomicCompareAndSwap32(YES,NO,&THIS->_playbackStoppedCallbackScheduled)) {
        THIS.channelIsPlaying = NO;
        THIS->_playhead = 0;

        if ( THIS.completionBlock )
            THIS.completionBlock();
        
        NSError* error;
        [THIS setupPlayRegion:&error];
        if(error)
            NSLog(@"Error on playback stopped callback: %@",error.description);
    }
}

// MARK: Setup and Teardown functions
- (BOOL)setupPlayRegion: (NSError**) error
{
    OSStatus result = -1;
    
    if(_audioUnitFile)
    {
        // Set playhead to starting point if it is beyond the end of the song.
        if(_playhead >= _lengthInFrames)
            _playhead = 0;
        
        // Reset the audio unit before modifying properties
        AudioUnit au = AEAudioUnitChannelGetAudioUnit(self);
        checkResultForError(AudioUnitReset(au, kAudioUnitScope_Global, 0),"AudioUnitReset()","Error resetting audio unit",NO,result,error)
        
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
        region.mFramesToPlay = _lengthInFrames;// - _playhead;
        
        checkResultForError(AudioUnitSetProperty(au, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region)), "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)", "Error Scheduling File Region for audio unit", NO, result, error)
        
        // Set up the looping region whether or not we're going to loop. We must have it scheduled to avoid missing frames
        [self setupLoopingAudioRegion:error audioUnit:au];
        
        // Prime the player by reading some frames from disk. This is the referenced way of performing a prime
        UInt32 defaultNumberOfFrames = 0;
        checkResultForError(AudioUnitSetProperty(au, kAudioUnitProperty_ScheduledFilePrime, kAudioUnitScope_Global, 0, &defaultNumberOfFrames, sizeof(defaultNumberOfFrames)), "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFilePrime)", "Error priming scheduled audio unit.", NO, result, error)
        
        // Set the start time. We have to do this after priming
        AudioTimeStamp startTime;
        memset (&startTime, 0, sizeof(startTime));
        startTime.mFlags = kAudioTimeStampSampleTimeValid;
        startTime.mSampleTime = -1;
        checkResultForError(AudioUnitSetProperty(au, kAudioUnitProperty_ScheduleStartTimeStamp, kAudioUnitScope_Global, 0, &startTime, sizeof(startTime)), "AudioUnitSetProperty(kAudioUnitProperty_ScheduleStartTimeStamp)", "Error setting timestamp for audio unit.", NO, result, error)
    }
    
    return YES;
}

- (BOOL) setupLoopingAudioRegion:(NSError**)error audioUnit:(AudioUnit) au {
    // Need to manually validate the time stamp and set it's start time to just after playthrough completes
    ScheduledAudioFileRegion region;
    memset (&region.mTimeStamp, 0, sizeof(region.mTimeStamp));
    
    region.mTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
    region.mTimeStamp.mSampleTime = _playbackDelay + _lengthInFrames - _playhead;
    
    // No process will be called on completion
    region.mCompletionProc = NULL;
    region.mCompletionProcUserData = NULL;
    
    // Point to the audio unit file
    region.mAudioFile = _audioUnitFile;
    region.mLoopCount = -1;
    region.mStartFrame = 0;
    region.mFramesToPlay = _lengthInFrames;// - _playhead;
    
    OSStatus result;
    checkResultForError(AudioUnitSetProperty(au, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region)), "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)", "Error Scheduling File Region for audio unit", NO, result, error)
    
    return(YES);
}

- (void) setupWithAudioController:(AEAudioController *)audioController
{
    [super setupWithAudioController:audioController];
    
    _controllerDescription = audioController.audioDescription;
    
    // Setup URL
    NSError* error = nil;
    [self setupURL:_url error:&error];
    if(error) {
        NSLog(@"Error: %@",[error description]);
    }
    
    // Setup play region
    error = nil;
    [self setupPlayRegion:&error];
    if(error) {
        NSLog(@"Error: %@",[error description]);
    }
    
    // set our own audio controller property so we can use it during the postrender callback
    _audioController = audioController;
    
    // Setup the postrender callback
    AudioUnitAddRenderNotify(AEAudioUnitChannelGetAudioUnit(self), postRenderCallback, (__bridge void *)(self));
}

- (id) initWithURL:(NSURL *)url audioController:(AEAudioController *)audioController error:(NSError **)error
{
    // Verify that the URL is valid and set the url
    if(![[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
        *error = [NSError errorWithDomain: NSURLErrorDomain code:-50 userInfo:[NSDictionary dictionaryWithObject:@"URL is invalid" forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    AudioComponentDescription aedesc = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Generator, kAudioUnitSubType_AudioFilePlayer);
    if(self = [super initWithComponentDescription:aedesc]) {
        
        // we don't want to start playing immediately.
        self.channelIsPlaying = NO;
        
        _url = url;
    }
    
    return(self);
}

- (BOOL) setupURL: (NSURL*) url error:(NSError**) error{
    // Load the URL
    OSStatus result;
    ExtAudioFileRef audioFileRef;
    checkResult(result = ExtAudioFileOpenURL((CFURLRef)CFBridgingRetain(url), &audioFileRef), "AudioFileOpenURL");
    if(result == noErr)
    {
        // Get the audio file itself
        UInt32 size = sizeof(_audioUnitFile);
        checkResultForError(ExtAudioFileGetProperty(audioFileRef, kExtAudioFileProperty_AudioFile, &size, &_audioUnitFile), "ExtAudioFileGetProperty(kExtAudioFileProperty_AudioFile)", "Failed getting audio file from extAudioFileRef", NO, result, error)
        
        // Set the file to play
        AudioUnit au = AEAudioUnitChannelGetAudioUnit(self);
        checkResultForError(AudioUnitSetProperty(au, kAudioUnitProperty_ScheduledFileIDs, kAudioUnitScope_Global, 0, &_audioUnitFile, sizeof(_audioUnitFile)), "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileIDs)", "Failed setting audio unit file IDs", NO, result, error)
        
        // Get audio description
        size = sizeof(_audioDescription);
        checkResultForError(AudioFileGetProperty(_audioUnitFile, kAudioFilePropertyDataFormat, &size, &_audioDescription), "AudioFileGetProperty(kAudioFilePropertyDataFormat)", "Failed getting audio file data format", NO, result, error)
        
        // Get file length
        UInt64 fileLengthInFrames = 0;
        size = sizeof(fileLengthInFrames);
        checkResultForError(ExtAudioFileGetProperty(audioFileRef, kExtAudioFileProperty_FileLengthFrames, &size, &fileLengthInFrames), "ExtAudioFileGetProperty(kExtAudioFileProperty_AudioFile)", "Failed getting file length", NO, result, error)
        
        _lengthInFrames = (UInt32)fileLengthInFrames;
        _url = url;
        
        return(YES);
    }
    else {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"URL failed to open" forKey:NSLocalizedDescriptionKey]];
        return(NO);
    }
}

- (void)dealloc {
    
    if ( _audioUnitFile ) {
        AudioFileClose(_audioUnitFile);
    }
    
    _completionBlock = nil;
    _audioController = nil;
}

// MARK: Audio functions

- (void) play
{
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
    NSError* error;
    [self setupPlayRegion:&error];
    if(error)
        NSLog(@"Error on playback stopped callback: %@",error.description);
}

- (void) mute
{
    self.channelIsMuted = true;
}

- (void) unmute
{
    self.channelIsMuted = false;
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
    
    // Reload the audio region
    NSError* error;
    [self setupPlayRegion:&error];
    if(error) {
        NSLog(@"Error trying to change the playhead time. %@",error.description);
    }
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
    if(channelIsPlaying && !super.channelIsPlaying) {
        if(_playbackDelay != 0) {
            
            NSError* error;
            [self setupPlayRegion:&error];
            if(error) {
                NSLog(@"Error setting up audio file region for playback. %@",error.description);
            }
        }
    }
    
    // Set the variable
    super.channelIsPlaying = channelIsPlaying;
}

// MARK: Render Callbacks
static OSStatus postRenderCallback(void *							inRefCon,
                                  AudioUnitRenderActionFlags *	ioActionFlags,
                                  const AudioTimeStamp *			inTimeStamp,
                                  UInt32							inBusNumber,
                                  UInt32							inNumberFrames,
                                  AudioBufferList *				ioData) {
    
    if(*ioActionFlags & kAudioUnitRenderAction_PostRender) {
        __unsafe_unretained AEAudioUnitFileStreamer* THIS = (__bridge __unsafe_unretained AEAudioUnitFileStreamer*)inRefCon;
    
        int32_t playhead = THIS->_playhead;
        int32_t originalPlayhead = playhead;
    
        playhead += inNumberFrames;
        
        if(playhead >= THIS->_lengthInFrames + THIS->_playbackDelay) {
            // If not looping, end the track
            if( !THIS->_looping ) {
                
                // If the playhead is too far, we have to null out the relevant buffer data
                char *audioPtrs[ioData->mNumberBuffers];
                for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
                    audioPtrs[i] = ioData->mBuffers[i].mData;
                }
                
                // Calculate the offset
                if(THIS->_controllerDescription.mChannelsPerFrame == 1) {
                    int totalBytes = ioData->mBuffers[0].mDataByteSize;
                    int frameOffset = inNumberFrames - (playhead - (THIS->_lengthInFrames + THIS->_playbackDelay));
                    int byteOffset = (frameOffset / inNumberFrames * totalBytes);
                    int bytesToOverwrite = totalBytes - byteOffset;

                    for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
                        memset(audioPtrs[i] + byteOffset,0,bytesToOverwrite);
                    }
                }
                else {
                    int totalBytes = ioData->mBuffers[0].mDataByteSize;
                    int channelsPerFrame = THIS->_controllerDescription.mChannelsPerFrame;
                    for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
                        // TODO: Vectorize this
                        for(int byteIndex = channelsPerFrame - 1 ; byteIndex < totalBytes ; byteIndex += channelsPerFrame) {
                            memset(audioPtrs[i] + byteIndex,0,1);
                        }
                    }
                }
                    
                THIS.channelIsPlaying = NO;
                THIS->_playhead = THIS->_lengthInFrames + THIS->_playbackDelay;
            
                // Only schedule the playback ended callback if it hasn't been scheduled
                if(OSAtomicCompareAndSwap32(NO, YES, &THIS->_playbackStoppedCallbackScheduled)) {
                    AEAudioControllerSendAsynchronousMessageToMainThread(THIS->_audioController, notifyPlaybackStopped, &THIS, sizeof(AEAudioUnitFileStreamer*));
                }
                return noErr;
            }
            // If we are looping, reset the playhead position.
            else {
                playhead = playhead - THIS->_lengthInFrames;
            }
        }
    
        // update the playhead
        OSAtomicCompareAndSwap32(originalPlayhead, playhead, &THIS->_playhead);
    }
    
    return noErr;
}

@end
