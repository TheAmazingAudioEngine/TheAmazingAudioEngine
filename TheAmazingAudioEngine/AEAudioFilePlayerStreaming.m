//
//  AEAudioFilePlayerStreaming.m
//  The Amazing Audio Engine
//
//  AmazingAudioEngine created by Michael Tyson.
//  AEAudioFilePlayerStreaming created by Joel Shapiro (RepublicOfApps) on 10/24/13.
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

#import "AEAudioFilePlayerStreaming.h"
#import "AEUtilities.h"

/*
 * It's safe to increase this if need be, but generally only
 * 2048 bytes are needed at once, so this seems sufficient.
 *
 * There's no advantage to increasing this unless you get
 * a kAudio_ParamError from MyAudioCallback.
 *
 * Even then, increase it carefully to avoid excess memory usage.
 */
#define kMaxNumberOfFramesToReadAtOnce 16 * 1024

#pragma mark - Class Extension

@interface AEAudioFilePlayerStreaming ()
@property (nonatomic, readwrite, retain) NSURL* url;
@property (nonatomic, readwrite) AudioStreamBasicDescription audioDescription;
@property (nonatomic, assign) ExtAudioFileRef audioFileRef;
@property (nonatomic, assign) AudioBufferList *audioBufferList;
@property (nonatomic) SInt64 playbackStartFrame;
@property (nonatomic) SInt64 playbackEndFrame;
@property (nonatomic) SInt64 lastPlayedbackFrame;
@end


@implementation AEAudioFilePlayerStreaming

@dynamic renderCallback;

#pragma mark - Initialization and Dealloc

+ (instancetype)playerWithURL:(NSURL*)url audioController:(AEAudioController*)audioController playbackStartTime:(NSNumber*)playbackStartTime playbackEndTime:(NSNumber*)playbackEndTime
{
    /*
     * Create the player, open its backing file and prep for buffering.
     */

    AEAudioFilePlayerStreaming* player = [[[AEAudioFilePlayerStreaming alloc] init] autorelease];
    player.url = url;
    player.volume = 1.0;
    player.channelIsPlaying = YES;
    player.audioDescription = audioController.audioDescription;

    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)player.url, &player->_audioFileRef);
    if (status != noErr) return nil;

    status = ExtAudioFileSetProperty(player.audioFileRef, kExtAudioFileProperty_ClientDataFormat, sizeof(player->_audioDescription), &player->_audioDescription);
    if (status != noErr) return nil;

    AudioBufferList* bufferList = AEAllocateAndInitAudioBufferList(player.audioDescription, kMaxNumberOfFramesToReadAtOnce);
    if (!bufferList) return nil;
    player.audioBufferList = bufferList;

    /*
     * Translate playbackStartTime and playbackEndTime to frames so we can
     * seek the backing file to start there and not read past the end.
     */

    if (playbackStartTime && playbackEndTime && [playbackEndTime doubleValue] < [playbackStartTime doubleValue]) {
        // Invalid combination
        return nil;
    }

    AudioStreamBasicDescription fileFormat;
    size_t fileFormatSize = sizeof(fileFormat);
    status = ExtAudioFileGetProperty(player.audioFileRef, kExtAudioFileProperty_FileDataFormat, &fileFormatSize, &fileFormat);
    if (status != noErr) return nil;

    SInt64 fileLengthFrames;
    size_t fileLengthFramesSize = sizeof(fileLengthFrames);
    status = ExtAudioFileGetProperty(player.audioFileRef, kExtAudioFileProperty_FileLengthFrames, &fileLengthFramesSize, &fileLengthFrames);
    if (status != noErr) return nil;

    if (playbackStartTime) {
        player.playbackStartFrame = MAX(floor([playbackStartTime doubleValue] * fileFormat.mSampleRate), 0);
        player.playbackStartFrame = MIN(player.playbackStartFrame, fileLengthFrames);
    } else {
        player.playbackStartFrame = 0;
    }

    if (playbackEndTime) {
        player.playbackEndFrame = MAX(ceil([playbackEndTime doubleValue] * fileFormat.mSampleRate), 0);
        player.playbackEndFrame = MIN(player.playbackEndFrame, fileLengthFrames);
    } else {
        player.playbackEndFrame = fileLengthFrames;
    }

    if (player.playbackEndFrame < player.playbackStartFrame) {
        player.playbackStartFrame = player.playbackEndFrame;
    }

    status = ExtAudioFileSeek(player.audioFileRef, player.playbackStartFrame);
    if (status != noErr) return nil;

    player.lastPlayedbackFrame = -1;

    return player;
}

+ (instancetype)playerWithURL:(NSURL*)url audioController:(AEAudioController*)audioController
{
    return [self playerWithURL:url audioController:audioController playbackStartTime:nil playbackEndTime:nil];
}

- (id)initWithURL:(NSURL *)url audioController:(AEAudioController *)audioController
{
    if ((self = [super init])) {
        _url = [url retain];
        _audioDescription = audioController.audioDescription;
    }
    return self;
}

- (void)dealloc
{
    if (_audioFileRef) {
        ExtAudioFileDispose(_audioFileRef);
    }

    if (_audioBufferList) {
        for (int i = 0; i < _audioBufferList->mNumberBuffers; ++i) {
            if (_audioBufferList->mBuffers[i].mData) free(_audioBufferList->mBuffers[i].mData);
        }
        free(_audioBufferList);
    }

    [_url release];

    [super dealloc];
}


#pragma mark - Properties

- (AEAudioControllerRenderCallback)renderCallback
{
    return MyAudioCallback;
}


#pragma mark - Audio Callback

static OSStatus MyAudioCallback(id channel, AEAudioController *audioController, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio)
{
    NSCAssert2(frames <= kMaxNumberOfFramesToReadAtOnce, @"Expected frames %u to be <= %d (max frames expected; buffers will be too small)", (unsigned int)frames, kMaxNumberOfFramesToReadAtOnce);
    if (frames > kMaxNumberOfFramesToReadAtOnce) return kAudio_ParamError;

    AEAudioFilePlayerStreaming *THIS = channel;
    if (!THIS->_channelIsPlaying) return noErr;

    if (THIS->_lastPlayedbackFrame >= THIS->_playbackEndFrame) {
        // We're done playback
        THIS->_channelIsPlaying = NO;
        return noErr;
    }

    // Determine how many frames we could/should read
    UInt32 framesRead = frames;
    UInt32 playbackFramesRemaining = (UInt32)(THIS->_lastPlayedbackFrame < 0 ?
                                                THIS->_playbackEndFrame - THIS->_playbackStartFrame  + 1:
                                                THIS->_playbackEndFrame - THIS->_lastPlayedbackFrame);
    playbackFramesRemaining = MAX(playbackFramesRemaining, 0);
    framesRead = MIN(framesRead, playbackFramesRemaining);

    // Read the needed audio data from the backing file.
    // Even though we should generally avoid doing file I/O in a Core Audio callback, this read is very fast (< 1 ms) and given that this callback
    // gets called about once every 23 ms, I have seen no droputs after testing multiple songs under load.
    //
    // If we start to see dropouts, we might want to use a TPCircularBuffer and do file reads on a separate thread and only read from the
    // circular buffer here, but that requires a lot of scheduling, queues, etc., so no need for now as this works just fine.
    OSStatus status = ExtAudioFileRead(THIS->_audioFileRef, &framesRead, THIS->_audioBufferList);
    if (status != noErr) return status;

    for (int i = 0; i < audio->mNumberBuffers; ++i) {
        size_t bytesToCopy = framesRead * THIS->_audioDescription.mBytesPerFrame;
        memcpy(audio->mBuffers[i].mData, THIS->_audioBufferList->mBuffers[i].mData, bytesToCopy);
    }

    if (framesRead > 0) {
        THIS->_lastPlayedbackFrame = THIS->_lastPlayedbackFrame >= 0 ? THIS->_lastPlayedbackFrame + framesRead : THIS->_playbackStartFrame + framesRead - 1;
    }

    if (framesRead == 0 || framesRead < frames || THIS->_lastPlayedbackFrame >= THIS->_playbackEndFrame) {
        // We've exhausted the contents of the audio file and there's nothing more to read
        // or we've read the entire playback section we defined in playback[Start,End]Time.
        THIS->_channelIsPlaying = NO;
    }

    return noErr;
}

@end
