//
//  AEAudioUnitFilePlayer.m
//  TheAmazingAudioEngine
//
//  Created by Ryan Holmes on 8/9/15.
//  Copyright (c) 2015 A Tasty Pixel. All rights reserved.
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

#import "AEAudioUnitFilePlayer.h"
#import "AEUtilities.h"
#import <libkern/OSAtomic.h>

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        int fourCC = CFSwapInt32HostToBig(result);
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&fourCC);
        return NO;
    }
    return YES;
}

@interface AEAudioUnitFilePlayer () {
    AudioUnit _audioUnit;
    AudioUnit _converterUnit;
    AudioFileID _audioFileID;
    UInt32 _lengthInFrames;
    AudioStreamBasicDescription _audioDescription;
    AudioStreamBasicDescription _fileAudioDescription;
    BOOL _channelIsPlaying;
    volatile int32_t _playhead;
}
@property (nonatomic, strong, readwrite) NSURL *url;

@end

@implementation AEAudioUnitFilePlayer

+ (instancetype)audioUnitFilePlayerWithURL:(NSURL *)url error:(NSError **)error {
    return [[self alloc] initWithURL:url error:error];
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    
    AudioComponentDescription audioFilePlayerDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Generator, kAudioUnitSubType_AudioFilePlayer);
    
    self = [super initWithComponentDescription:audioFilePlayerDescription];
    if (self != nil) {
        _url = url;
    }
    
    if ( ![self loadFileFromURL:url error:error] ) {
        return  nil;
    }
    
    return self;
}

- (void)dealloc {
    if ( _audioFileID ) {
        AudioFileClose(_audioFileID);
    }
}

- (NSTimeInterval)duration {
    return (double)_lengthInFrames / (double)_audioDescription.mSampleRate;
}

- (NSTimeInterval)currentTime {
    if (_lengthInFrames == 0) return 0.0;
    return ((double)_playhead / (double)_lengthInFrames) * [self duration];
}

- (void)setCurrentTime:(NSTimeInterval)currentTime {
    if (_lengthInFrames == 0) return;
    _playhead = (int32_t)((currentTime / [self duration]) * _lengthInFrames) % _lengthInFrames;
    
    [self resetAudioUnit];
    [self playFileRegion];
}

- (BOOL)channelIsPlaying {
    return _channelIsPlaying;
}

- (void)setChannelIsPlaying:(BOOL)channelIsPlaying {
    if (_channelIsPlaying != channelIsPlaying) {
        if (channelIsPlaying) {
            [self playFileRegion];
        } else {
            [self resetAudioUnit];
        }
        _channelIsPlaying = channelIsPlaying;
    }
    [super setChannelIsPlaying:channelIsPlaying];
}

- (BOOL)loadFileFromURL:(NSURL*)url error:(NSError**)error {
    OSStatus result;
    
    // Open the file
    result = AudioFileOpenURL((CFURLRef)CFBridgingRetain(url), kAudioFileReadPermission, 0, &_audioFileID);
    if ( !checkResult(result, "AudioFileOpenURL") ) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't open the audio file", @"")}];
        return NO;
    }
    
    // Get the file data format
    UInt32 size = sizeof(_fileAudioDescription);
    result = AudioFileGetProperty(_audioFileID, kAudioFilePropertyDataFormat, &size, &_fileAudioDescription);
    if ( !checkResult(result, "AudioFileGetProperty(kAudioFilePropertyDataFormat)") ) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
        return NO;
        
    }
    
    // Determine length in frames (in original file's sample rate)
    AudioFilePacketTableInfo packetInfo;
    size = sizeof(packetInfo);
    result = AudioFileGetProperty(_audioFileID, kAudioFilePropertyPacketTableInfo, &size, &packetInfo);
    if ( !checkResult(result, "AudioFileGetProperty(kAudioFilePropertyPacketTableInfo)") ) {
        size = 0;
    }
    
    UInt64 fileLengthInFrames;
    if(size > 0) {
        fileLengthInFrames = packetInfo.mNumberValidFrames;
    } else {
        UInt64 packetCount;
        size = sizeof(packetCount);
        result = AudioFileGetProperty(_audioFileID, kAudioFilePropertyAudioDataPacketCount, &size, &packetCount);
        if ( !checkResult(result, "AudioFileGetProperty(kAudioFilePropertyAudioDataPacketCount)") ) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
            return NO;
        }
        fileLengthInFrames = packetCount * _fileAudioDescription.mFramesPerPacket;
    }
    _lengthInFrames = (UInt32)fileLengthInFrames;
    
    // Initialize the audio description with the file's data format. We'll update it later
    // when we're added to an audio controller.
    _audioDescription = _fileAudioDescription;
    
    return YES;
}

- (void)playFileRegion {
    
    if (!_audioUnit || !_audioFileID) {
        return;
    }
    
    // Calculate the start frame (in original file's sample rate)
    double sampleRateRatio = _fileAudioDescription.mSampleRate / _audioDescription.mSampleRate;
    SInt64 startFrame = (SInt64)ceil(_playhead * sampleRateRatio);
    
    // Set the file region to play
    ScheduledAudioFileRegion region;
    memset (&region.mTimeStamp, 0, sizeof(region.mTimeStamp));
    region.mTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
    region.mTimeStamp.mSampleTime = 0;
    region.mCompletionProc = NULL;
    region.mCompletionProcUserData = NULL;
    region.mAudioFile = _audioFileID;
    region.mLoopCount = _loop ? (UInt32)-1 : 0;
    region.mStartFrame = startFrame;
    region.mFramesToPlay = (UInt32)-1;
    
    OSStatus result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region));
    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)");
    
    // Prime the player by reading some frames from disk
    UInt32 primeFrames = 0;
    result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_ScheduledFilePrime, kAudioUnitScope_Global, 0, &primeFrames, sizeof(primeFrames));
    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFilePrime)");
    
    // Set the start time (now = -1)
    AudioTimeStamp startTime;
    memset (&startTime, 0, sizeof(startTime));
    startTime.mFlags = kAudioTimeStampSampleTimeValid;
    startTime.mSampleTime = -1;
    result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_ScheduleStartTimeStamp, kAudioUnitScope_Global, 0, &startTime, sizeof(startTime));
    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduleStartTimeStamp)");
}

- (void)resetAudioUnit {
    checkResult(AudioUnitReset(_audioUnit, kAudioUnitScope_Global, 0), "AudioUnitReset");
}

#pragma mark - Playable Protocol

- (void)setupWithAudioController:(AEAudioController *)audioController {
    [super setupWithAudioController:audioController];
    
    _audioUnit = self.audioUnit;
    _converterUnit = self.converterUnit;
    
    // Update the audio description
    double originalSampleRate = _audioDescription.mSampleRate;
    _audioDescription = audioController.audioDescription;
    
    // Convert the frame length and playhead to the new sample rate
    double sampleRateRatio = _audioDescription.mSampleRate / originalSampleRate;
    _lengthInFrames = (UInt32)ceil(_lengthInFrames * sampleRateRatio);
    _playhead = (int32_t)ceil(_playhead * sampleRateRatio);

    // Set the file to play
    UInt32 size = sizeof(_audioFileID);
    OSStatus result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_ScheduledFileIDs, kAudioUnitScope_Global, 0, &_audioFileID, size);
    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileIDs)");
    
    // Play the file region
    if (self.channelIsPlaying) {
        [self playFileRegion];
    }
}

- (void)teardown {
    [self resetAudioUnit];
    [super teardown];
}

#pragma mark - Render Callback and Notifications

static void notifyLoopRestart(AEAudioController *audioController, void *userInfo, int length) {
    AEAudioUnitFilePlayer *THIS = (__bridge AEAudioUnitFilePlayer*)*(void**)userInfo;
    
    if ( THIS.startLoopBlock ) THIS.startLoopBlock();
}

static void notifyPlaybackStopped(AEAudioController *audioController, void *userInfo, int length) {
    AEAudioUnitFilePlayer *THIS = (__bridge AEAudioUnitFilePlayer*)*(void**)userInfo;
    THIS.channelIsPlaying = NO;
    
    if ( THIS->_removeUponFinish ) {
        [audioController removeChannels:@[THIS]];
    }
    
    if ( THIS.completionBlock ) THIS.completionBlock();
    
    THIS->_playhead = 0;
}

static OSStatus renderCallback(__unsafe_unretained AEAudioUnitFilePlayer *THIS,
                               __unsafe_unretained AEAudioController *audioController,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    AudioUnitRenderActionFlags flags = 0;
    checkResult(AudioUnitRender(THIS->_converterUnit ? THIS->_converterUnit : THIS->_audioUnit, &flags, time, 0, frames, audio), "AudioUnitRender");
    
    int32_t playhead = THIS->_playhead;
    int32_t originalPlayhead = playhead;
    
    if ( !THIS->_loop && playhead == THIS->_lengthInFrames ) {
        // Notify main thread that playback has finished
        AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyPlaybackStopped, &THIS, sizeof(AEAudioUnitFilePlayer*));
        return noErr;
    }
    
    // The number of frames left before the end of the audio
    UInt32 remainingFrames = MIN(frames, THIS->_lengthInFrames - playhead);
    
    // Advance playhead
    playhead += remainingFrames;
    
    if ( playhead >= THIS->_lengthInFrames ) {
        // Reached the end of the audio - either loop, or stop
        if ( THIS->_loop ) {
            playhead = 0;
            if ( THIS->_startLoopBlock ) {
                // Notify main thread that the loop playback has restarted
                AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyLoopRestart, &THIS, sizeof(AEAudioUnitFilePlayer*));
            }
        } else {
            // Notify main thread that playback has finished
            AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyPlaybackStopped, &THIS, sizeof(AEAudioUnitFilePlayer*));
        }
    }
    
    OSAtomicCompareAndSwap32(originalPlayhead, playhead, &THIS->_playhead);
    
    return noErr;
}

-(AEAudioControllerRenderCallback)renderCallback {
    return renderCallback;
}

@end
