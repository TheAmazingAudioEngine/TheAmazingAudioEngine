//
//  AEAudioBufferListPlayer.m
//  The Amazing Audio Engine
//
//  Created by Mark Wise on 01/01/2015.
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

#import "AEAudioBufferListPlayer.h"
#import "AEUtilities.h"
#import <libkern/OSAtomic.h>

#define checkStatus(status) \
    if ( (status) != noErr ) {\
        NSLog(@"Error: %ld -> %s:%d", (status), __FILE__, __LINE__);\
    }

@interface AEAudioBufferListPlayer () {
    int _lengthInFrames;
    NSTimeInterval _duration;
    AudioStreamBasicDescription   _audioDescription;
    volatile int32_t              _playhead;
}
@end

@implementation AEAudioBufferListPlayer
@synthesize audio=_audio, duration=_duration, loop=_loop, volume=_volume, pan=_pan, channelIsPlaying=_channelIsPlaying, channelIsMuted=_channelIsMuted, removeUponFinish=_removeUponFinish, completionBlock = _completionBlock, startLoopBlock = _startLoopBlock;
@dynamic currentTime;

+ (id)audioBufferListPlayerWithAudioController:(AEAudioController *)audioController error:(NSError **)error {
    AEAudioBufferListPlayer *player = [[self alloc] init];
    player->_volume = 1.0;
    player->_channelIsPlaying = YES;
    player->_audioDescription = audioController.audioDescription;

    return player;
}

+ (id)audioBufferListPlayerWithAudioBufferList:(AudioBufferList*)audio audioController:(AEAudioController *)audioController error:(NSError **)error {
    AEAudioBufferListPlayer *player = [[self alloc] init];
    player->_volume = 1.0;
    player->_channelIsPlaying = YES;
    player->_audioDescription = audioController.audioDescription;
    player->_audio = audio;

    int *channels = malloc(sizeof(int));;
    player->_lengthInFrames = AEGetNumberOfFramesInAudioBufferList(audio, player->_audioDescription, channels);
    player->_lengthInFrames *= *channels;
    player->_duration = (double) player->_lengthInFrames / (double)player->_audioDescription.mSampleRate;
    free(channels);

    return player;
}

-(void)setAudio:(AudioBufferList *)audio {
    _channelIsPlaying = NO;
    _audio = audio;
    int *channels = malloc(sizeof(int));;
    _lengthInFrames = AEGetNumberOfFramesInAudioBufferList(audio, _audioDescription, channels);
    _lengthInFrames *= *channels;
    _duration = (double) _lengthInFrames / (double)_audioDescription.mSampleRate;
    free(channels);
}

- (void)dealloc {
    if ( _audio ) {
        for ( int i=0; i<_audio->mNumberBuffers; i++ ) {
            free(_audio->mBuffers[i].mData);
        }
        free(_audio);
    }
}

-(NSTimeInterval)currentTime {
    return ((double)_playhead / (double)_lengthInFrames) * _duration;
}

-(void)setCurrentTime:(NSTimeInterval)currentTime {
    _playhead = (int32_t)((currentTime / [self duration]) * _lengthInFrames) % _lengthInFrames;
}

static void notifyLoopRestart(AEAudioController *audioController, void *userInfo, int length) {
    AEAudioBufferListPlayer *THIS = (__bridge AEAudioBufferListPlayer*)*(void**)userInfo;

    if ( THIS.startLoopBlock ) THIS.startLoopBlock();
}

static void notifyPlaybackStopped(AEAudioController *audioController, void *userInfo, int length) {
    AEAudioBufferListPlayer *THIS = (__bridge AEAudioBufferListPlayer*)*(void**)userInfo;
    THIS.channelIsPlaying = NO;

    if ( THIS->_removeUponFinish ) {
        [audioController removeChannels:@[THIS]];
    }

    if ( THIS.completionBlock ) THIS.completionBlock();

    THIS->_playhead = 0;
}

static OSStatus renderCallback(__unsafe_unretained AEAudioBufferListPlayer *THIS, __unsafe_unretained AEAudioController *audioController, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
    int32_t playhead = THIS->_playhead;
    int32_t originalPlayhead = playhead;

    if ( !THIS->_channelIsPlaying ) return noErr;

    if ( !THIS->_loop && playhead == THIS->_lengthInFrames ) {
        // Notify main thread that playback has finished
        AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyPlaybackStopped, &THIS, sizeof(AEAudioBufferListPlayer*));
        THIS->_channelIsPlaying = NO;
        return noErr;
    }

    // Get pointers to each buffer that we can advance
    char *audioPtrs[audio->mNumberBuffers];
    for ( int i=0; i<audio->mNumberBuffers; i++ ) {
        audioPtrs[i] = audio->mBuffers[i].mData;
    }

    int bytesPerFrame = THIS->_audioDescription.mBytesPerFrame;
    int remainingFrames = frames;

    // Copy audio in contiguous chunks, wrapping around if we're looping
    while ( remainingFrames > 0 ) {
        // The number of frames left before the end of the audio
        int framesToCopy = MIN(remainingFrames, THIS->_lengthInFrames - playhead);

        // Fill each buffer with the audio
        for ( int i=0; i<audio->mNumberBuffers; i++ ) {
            memcpy(audioPtrs[i], ((char*)THIS->_audio->mBuffers[i].mData) + playhead * bytesPerFrame, framesToCopy * bytesPerFrame);

            // Advance the output buffers
            audioPtrs[i] += framesToCopy * bytesPerFrame;
        }

        // Advance playhead
        remainingFrames -= framesToCopy;
        playhead += framesToCopy;

        if ( playhead >= THIS->_lengthInFrames ) {
            // Reached the end of the audio - either loop, or stop
            if ( THIS->_loop ) {
                playhead = 0;
                if ( THIS->_startLoopBlock ) {
                    // Notify main thread that the loop playback has restarted
                    AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyLoopRestart, &THIS, sizeof(AEAudioBufferListPlayer*));
                }
            } else {
                // Notify main thread that playback has finished
                AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyPlaybackStopped, &THIS, sizeof(AEAudioBufferListPlayer*));
                THIS->_channelIsPlaying = NO;
                break;
            }
        }
    }

    OSAtomicCompareAndSwap32(originalPlayhead, playhead, &THIS->_playhead);

    return noErr;
}

-(AEAudioControllerRenderCallback)renderCallback {
    return &renderCallback;
}

@end
