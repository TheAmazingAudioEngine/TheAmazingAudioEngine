//
//  AEAudioFilePlayer.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 13/02/2012.
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
    UInt32 _lengthInFrames;
    UInt32 _currentRegionOffset;
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
    
    self.audioController = audioController;
    
    // Set the file to play
    UInt32 size = sizeof(_audioFile);
    OSStatus result = AudioUnitSetProperty(self.audioUnit, kAudioUnitProperty_ScheduledFileIDs, kAudioUnitScope_Global, 0, &_audioFile, size);
    checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileIDs)");
    
    // Play the file region
    if ( self.channelIsPlaying ) {
        [self schedulePlayRegionFromPosition:_currentRegionOffset];
    }
}

- (void)teardown {
    self.audioController = nil;
    
    // Remember our playback position, so we can resume if needed
    _currentRegionOffset = [self playbackPositionInFrames];
    
    [super teardown];
}

- (NSTimeInterval)duration {
    return (double)_lengthInFrames / (double)_fileDescription.mSampleRate;
}

- (NSTimeInterval)currentTime {
    AudioUnit audioUnit = self.audioUnit;
    if ( !audioUnit || _lengthInFrames == 0 ) {
        return (double)_currentRegionOffset / (double)_fileDescription.mSampleRate;
    }
    
    UInt32 position = [self playbackPositionInFrames];
    return (double)position / (double)_fileDescription.mSampleRate;
}

- (void)setCurrentTime:(NSTimeInterval)currentTime {
    if ( _lengthInFrames == 0 ) return;
    [self schedulePlayRegionFromPosition:(UInt32)(currentTime * _fileDescription.mSampleRate) % _lengthInFrames];
}

- (void)setChannelIsPlaying:(BOOL)playing {
    if ( self.channelIsPlaying == playing ) return;
    
    if ( self.audioUnit ) {
        if ( playing ) {
            [self schedulePlayRegionFromPosition:_currentRegionOffset];
        } else {
            // Remember prior playback position
            _currentRegionOffset = [self playbackPositionInFrames];
            AudioUnitReset(self.audioUnit, kAudioUnitScope_Global, 0);
        }
    }
    
    [super setChannelIsPlaying:playing];
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
    if ( !checkResult(result, "AudioFileGetProperty(kAudioFilePropertyPacketTableInfo)") ) {
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
    // Calculate the start frame (in original file's sample rate)
    _currentRegionOffset = position;
    
    AudioUnit audioUnit = self.audioUnit;
    if ( !audioUnit || !_audioFile ) {
        return;
    }
    
    Float64 mainRegionStartTime = 0;
    if ( position != 0 ) {
        // Schedule the remaining part of the audio, from startFrame to the end
        ScheduledAudioFileRegion region = {
            .mTimeStamp = { .mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = 0 },
            .mAudioFile = _audioFile,
            .mStartFrame = position,
            .mFramesToPlay = (UInt32)(_lengthInFrames - position)
        };
        OSStatus result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region));
        checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)");
        
        mainRegionStartTime = _lengthInFrames - position;
    }
    
    // Set the main file region to play
    ScheduledAudioFileRegion region = {
        .mTimeStamp = { .mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = mainRegionStartTime },
        .mCompletionProc = !_loop ? AEAudioFilePlayerCompletionProc : NULL,
        .mCompletionProcUserData = !_loop ? (__bridge void*)self : NULL,
        .mAudioFile = _audioFile,
        .mLoopCount = _loop ? (UInt32)-1 : 0,
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

- (UInt32)playbackPositionInFrames {
    AudioTimeStamp timestamp;
    UInt32 size = sizeof(timestamp);
    OSStatus result = AudioUnitGetProperty(self.audioUnit, kAudioUnitProperty_CurrentPlayTime, kAudioUnitScope_Global, 0, &timestamp, &size);
    if ( !checkResult(result, "AudioUnitGetProperty(kAudioUnitProperty_CurrentPlayTime)") ) {
        return 0;
    }
    return timestamp.mSampleTime == -1 ? 0 : (_currentRegionOffset + (UInt32)timestamp.mSampleTime) % (UInt32)_lengthInFrames;
}

static void AEAudioFilePlayerNotifyCompletion(__unsafe_unretained AEAudioController *audioController, void *userInfo, int userInfoLength) {
    AEAudioFilePlayer *THIS = (__bridge AEAudioFilePlayer*)*(void**)userInfo;
    if ( THIS.removeUponFinish ) {
        [THIS.audioController removeChannels:@[THIS]];
    }
    THIS.channelIsPlaying = NO;
    THIS->_currentRegionOffset = 0;
    if ( THIS.completionBlock ) {
        THIS.completionBlock();
    }
}

static void AEAudioFilePlayerCompletionProc(void *userData, ScheduledAudioFileRegion *fileRegion, OSStatus result) {
    AEAudioFilePlayer *THIS = (__bridge AEAudioFilePlayer*)userData;
    THIS->_currentRegionOffset = ((UInt32)fileRegion->mTimeStamp.mSampleTime % THIS->_lengthInFrames);
    if ( THIS->_audioController && (UInt32)fileRegion->mTimeStamp.mSampleTime == THIS->_lengthInFrames ) {
        AEAudioControllerSendAsynchronousMessageToMainThread(THIS->_audioController, AEAudioFilePlayerNotifyCompletion, &THIS, sizeof(AEAudioFilePlayer*));
    }
}

@end
