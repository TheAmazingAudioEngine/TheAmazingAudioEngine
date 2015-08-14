//
//  AEAudioFilePlayer.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 13/02/2012.
//
//  Contributions by Ryan King and Jeremy Huff of Hello World Engineering, Inc on 7/15/15.
//      Copyright (c) 2015 Hello World Engineering, Inc. All rights reserved.
//  Contributions by Ryan Holmes
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

#import "AEAudioFilePlayer.h"
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

@interface AEAudioFilePlayer () {
    AudioFileID _audioFile;
    AudioStreamBasicDescription _fileDescription;
    AudioStreamBasicDescription _unitOutputDescription;
    UInt32 _lengthInFrames;
    volatile int32_t _playhead;
    volatile int32_t _playbackStoppedCallbackScheduled;
    BOOL _running;
}
@property (nonatomic, strong, readwrite) NSURL * url;
@property (nonatomic, weak) AEAudioController * audioController;
@end

@implementation AEAudioFilePlayer

+ (instancetype)audioFilePlayerWithURL:(NSURL *)url error:(NSError **)error {
    return [[self alloc] initWithURL:url error:error];
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    if ( !(self = [super initWithComponentDescription:AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Generator, kAudioUnitSubType_AudioFilePlayer)]) ) return nil;
    
    if ( ![self loadAudioFileWithURL:url error:error] ) {
        return nil;
    }
    
    return self;
}

- (void)dealloc {
    if ( _audioFile ) {
        AudioFileClose(_audioFile);
    }
}

- (void)setupWithAudioController:(AEAudioController *)audioController {
    [super setupWithAudioController:audioController];
    
    checkResult(AudioUnitAddRenderNotify(self.audioUnit, AEAudioFilePlayerRenderNotify, (__bridge void*)self), "AudioUnitAddRenderNotify");
    
    Float64 priorOutputSampleRate = _unitOutputDescription.mSampleRate;
    UInt32 size = sizeof(AudioStreamBasicDescription);
    checkResult(AudioUnitGetProperty(self.audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_unitOutputDescription, &size), "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
    
    double sampleRateScaleFactor = _unitOutputDescription.mSampleRate / (priorOutputSampleRate ? priorOutputSampleRate : _fileDescription.mSampleRate);
    _playhead = _playhead * sampleRateScaleFactor;
    self.audioController = audioController;
    
    // Set the file to play
    size = sizeof(_audioFile);
    OSStatus result = AudioUnitSetProperty(self.audioUnit, kAudioUnitProperty_ScheduledFileIDs, kAudioUnitScope_Global, 0, &_audioFile, size);
    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileIDs)");
    
    // Play the file region
    if ( self.channelIsPlaying ) {
        double outputToSourceSampleRateScale = _fileDescription.mSampleRate / _unitOutputDescription.mSampleRate;
        [self schedulePlayRegionFromPosition:_playhead * outputToSourceSampleRateScale];
        _running = YES;
    }
}

- (void)teardown {
    self.audioController = nil;
    [super teardown];
}

- (NSTimeInterval)duration {
    return (double)_lengthInFrames / (double)_fileDescription.mSampleRate;
}

- (NSTimeInterval)currentTime {
    return (double)_playhead / (_unitOutputDescription.mSampleRate ? _unitOutputDescription.mSampleRate : _fileDescription.mSampleRate);
}

- (void)setCurrentTime:(NSTimeInterval)currentTime {
    if ( _lengthInFrames == 0 ) return;
    [self schedulePlayRegionFromPosition:((UInt32)(currentTime * _fileDescription.mSampleRate) % _lengthInFrames)];
}

- (void)setChannelIsPlaying:(BOOL)playing {
    BOOL wasPlaying = self.channelIsPlaying;
    [super setChannelIsPlaying:playing];
    
    if ( wasPlaying == playing ) return;
    
    _running = playing;
    if ( self.audioUnit ) {
        if ( playing ) {
            double outputToSourceSampleRateScale = _fileDescription.mSampleRate / _unitOutputDescription.mSampleRate;
            [self schedulePlayRegionFromPosition:_playhead * outputToSourceSampleRateScale];
        } else {
            checkResult(AudioUnitReset(self.audioUnit, kAudioUnitScope_Global, 0), "AudioUnitReset");
        }
    }
}

- (BOOL)loadAudioFileWithURL:(NSURL*)url error:(NSError**)error {
    OSStatus result;
    
    // Open the file
    result = AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadPermission, 0, &_audioFile);
    if ( !checkResult(result, "AudioFileOpenURL") ) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't open the audio file", @"")}];
        return NO;
    }
    
    // Get the file data format
    UInt32 size = sizeof(_fileDescription);
    result = AudioFileGetProperty(_audioFile, kAudioFilePropertyDataFormat, &size, &_fileDescription);
    if ( !checkResult(result, "AudioFileGetProperty(kAudioFilePropertyDataFormat)") ) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
        return NO;
        
    }
    
    // Determine length in frames (in original file's sample rate)
    AudioFilePacketTableInfo packetInfo;
    size = sizeof(packetInfo);
    result = AudioFileGetProperty(_audioFile, kAudioFilePropertyPacketTableInfo, &size, &packetInfo);
    if ( result != noErr ) {
        size = 0;
    }
    
    UInt64 fileLengthInFrames;
    if ( size > 0 ) {
        fileLengthInFrames = packetInfo.mNumberValidFrames;
    } else {
        UInt64 packetCount;
        size = sizeof(packetCount);
        result = AudioFileGetProperty(_audioFile, kAudioFilePropertyAudioDataPacketCount, &size, &packetCount);
        if ( !checkResult(result, "AudioFileGetProperty(kAudioFilePropertyAudioDataPacketCount)") ) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
            return NO;
        }
        fileLengthInFrames = packetCount * _fileDescription.mFramesPerPacket;
    }
    _lengthInFrames = (UInt32)fileLengthInFrames;
    
    return YES;
}

- (void)schedulePlayRegionFromPosition:(UInt32)position {
    // Note: "position" is in frames, in the input file's sample rate
    
    AudioUnit audioUnit = self.audioUnit;
    if ( !audioUnit || !_audioFile ) {
        return;
    }
    
    double sourceToOutputSampleRateScale = _unitOutputDescription.mSampleRate / _fileDescription.mSampleRate;
    _playhead = position * sourceToOutputSampleRateScale;
    
    // Reset the unit, to clear prior schedules
    checkResult(AudioUnitReset(audioUnit, kAudioUnitScope_Global, 0), "AudioUnitReset");
    
    // Determine start time
    Float64 mainRegionStartTime = 0;
    
    if ( position > 0 ) {
        // Schedule the remaining part of the audio, from startFrame to the end (starting immediately, without the delay)
        ScheduledAudioFileRegion region = {
            .mTimeStamp = { .mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = 0 },
            .mAudioFile = _audioFile,
            .mStartFrame = position,
            .mFramesToPlay = _lengthInFrames - position
        };
        OSStatus result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region));
        checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)");
        
        mainRegionStartTime = (_lengthInFrames - position) * sourceToOutputSampleRateScale;
    }
    
    // Set the main file region to play
    ScheduledAudioFileRegion region = {
        .mTimeStamp = { .mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = mainRegionStartTime },
        .mAudioFile = _audioFile,
            // Always loop the unit, even if we're not actually looping, to avoid expensive rescheduling when switching loop mode.
            // We'll handle play completion in AEAudioFilePlayerRenderNotify
        .mLoopCount = (UInt32)-1,
        .mFramesToPlay = (UInt32)-1,
    };
    OSStatus result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region));
    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)");
    
    // Prime the player
    UInt32 primeFrames = 0;
    result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduledFilePrime, kAudioUnitScope_Global, 0, &primeFrames, sizeof(primeFrames));
    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFilePrime)");
    
    // Set the start time
    AudioTimeStamp startTime = { .mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = -1 /* ASAP */ };
    result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduleStartTimeStamp, kAudioUnitScope_Global, 0, &startTime, sizeof(startTime));
    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduleStartTimeStamp)");
}

static OSStatus AEAudioFilePlayerRenderNotify(void * inRefCon,
                                              AudioUnitRenderActionFlags *ioActionFlags,
                                              const AudioTimeStamp *inTimeStamp,
                                              UInt32 inBusNumber,
                                              UInt32 inNumberFrames,
                                              AudioBufferList *ioData) {
    if ( !(*ioActionFlags & kAudioUnitRenderAction_PostRender) ) return noErr;
    
    __unsafe_unretained AEAudioFilePlayer * THIS = (__bridge AEAudioFilePlayer*)inRefCon;
    
    if ( !THIS->_running ) return noErr;
    
    int32_t playhead = THIS->_playhead;
    int32_t originalPlayhead = playhead;
    
    double sourceToOutputSampleRateScale = THIS->_unitOutputDescription.mSampleRate / THIS->_fileDescription.mSampleRate;
    UInt32 lengthInFrames = ceil(THIS->_lengthInFrames * sourceToOutputSampleRateScale);
    playhead = (playhead + inNumberFrames) % lengthInFrames;
    
    if ( playhead < originalPlayhead && !THIS->_loop ) {
        // We just crossed the loop boundary; if not looping, end the track.
        UInt32 muteFrames = MIN(playhead, inNumberFrames);
        for ( int i=0; i<ioData->mNumberBuffers; i++) {
            // Silence the rest of the buffer past the end
            memset((char*)ioData->mBuffers[i].mData + (THIS->_unitOutputDescription.mBytesPerFrame * (inNumberFrames-muteFrames)), 0, (THIS->_unitOutputDescription.mBytesPerFrame * muteFrames));
        }
        
        // Reset the unit, to cease playback
        checkResult(AudioUnitReset(AEAudioUnitChannelGetAudioUnit(THIS), kAudioUnitScope_Global, 0), "AudioUnitReset");
        playhead = 0;
        
        // Schedule the playback ended callback (if it hasn't been scheduled already)
        if ( OSAtomicCompareAndSwap32(NO, YES, &THIS->_playbackStoppedCallbackScheduled) ) {
            AEAudioControllerSendAsynchronousMessageToMainThread(THIS->_audioController, AEAudioFilePlayerNotifyCompletion, &THIS, sizeof(AEAudioFilePlayer*));
        }
        
        THIS->_running = NO;
    }
    
    // update the playhead
    OSAtomicCompareAndSwap32(originalPlayhead, playhead, &THIS->_playhead);
    
    return noErr;
}

static void AEAudioFilePlayerNotifyCompletion(__unsafe_unretained AEAudioController *audioController, void *userInfo, int userInfoLength) {
    AEAudioFilePlayer *THIS = (__bridge AEAudioFilePlayer*)*(void**)userInfo;
    if ( !OSAtomicCompareAndSwap32(YES, NO, &THIS->_playbackStoppedCallbackScheduled) ) {
        // We've been pre-empted by another scheduled callback: bail for now
        return;
    }
    
    if ( THIS.removeUponFinish ) {
        [THIS.audioController removeChannels:@[THIS]];
    }
    THIS.channelIsPlaying = NO;
    if ( THIS.completionBlock ) {
        THIS.completionBlock();
    }
}

@end
