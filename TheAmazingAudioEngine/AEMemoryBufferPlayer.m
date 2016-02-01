//
//  AEMemoryBufferPlayer.m
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

#import "AEMemoryBufferPlayer.h"
#import "AEAudioFileLoaderOperation.h"
#import "AEUtilities.h"
#import <libkern/OSAtomic.h>

@interface AEMemoryBufferPlayer () {
    AudioBufferList              *_audio;
    BOOL                          _freeWhenDone;
    UInt32                        _lengthInFrames;
    volatile int32_t              _playhead;
    uint64_t                      _startTime;
}
@property (nonatomic, strong) NSURL *url;
@end

@implementation AEMemoryBufferPlayer
@dynamic duration, currentTime;

+ (void)beginLoadingAudioFileAtURL:(NSURL *)url
                  audioDescription:(AudioStreamBasicDescription)audioDescription
                   completionBlock:(void (^)(AEMemoryBufferPlayer *, NSError *))completionBlock {
    
    completionBlock = [completionBlock copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        AEAudioFileLoaderOperation *operation = [[AEAudioFileLoaderOperation alloc] initWithFileURL:url targetAudioDescription:audioDescription];
        [operation start];
        
        if ( operation.error ) {
            completionBlock(nil, operation.error);
        } else {
            AEMemoryBufferPlayer * player = [[AEMemoryBufferPlayer alloc] initWithBuffer:operation.bufferList audioDescription:audioDescription freeWhenDone:YES];
            completionBlock(player, nil);
        }
    });
}

- (instancetype)initWithBuffer:(AudioBufferList *)buffer audioDescription:(AudioStreamBasicDescription)audioDescription freeWhenDone:(BOOL)freeWhenDone {
    if ( !(self = [super init]) ) return nil;
    _audio = buffer;
    _freeWhenDone = freeWhenDone;
    _audioDescription = audioDescription;
    _lengthInFrames = buffer->mBuffers[0].mDataByteSize / audioDescription.mBytesPerFrame;
    _volume = 1.0;
    _channelIsPlaying = YES;
    return self;
}

- (void)dealloc {
    if ( _audio && _freeWhenDone ) {
        for ( int i=0; i<_audio->mNumberBuffers; i++ ) {
            free(_audio->mBuffers[i].mData);
        }
        free(_audio);
    }
}

- (void)playAtTime:(uint64_t)time {
    _startTime = time;
    if ( !self.channelIsPlaying ) {
        self.channelIsPlaying = YES;
    }
}

-(NSTimeInterval)duration {
    return (double)_lengthInFrames / (double)_audioDescription.mSampleRate;
}

-(NSTimeInterval)currentTime {
    if ( _lengthInFrames == 0 ) {
        return 0.0;
    } else {
        return ((double)_playhead / (double)_lengthInFrames) * self.duration;
    }
}

-(void)setCurrentTime:(NSTimeInterval)currentTime {
    if (_lengthInFrames == 0) return;
    _playhead = (int32_t)((currentTime / self.duration) * _lengthInFrames) % _lengthInFrames;
}

static void notifyLoopRestart(void *userInfo, int length) {
    AEMemoryBufferPlayer *THIS = (__bridge AEMemoryBufferPlayer*)*(void**)userInfo;
    
    if ( THIS.startLoopBlock ) THIS.startLoopBlock();
}

struct notifyPlaybackStopped_arg { __unsafe_unretained AEMemoryBufferPlayer * THIS; __unsafe_unretained AEAudioController * audioController; };
static void notifyPlaybackStopped(void *userInfo, int length) {
    struct notifyPlaybackStopped_arg * arg = (struct notifyPlaybackStopped_arg*)userInfo;
    AEMemoryBufferPlayer *THIS = arg->THIS;
    THIS.channelIsPlaying = NO;

    if ( THIS->_removeUponFinish ) {
        [arg->audioController removeChannels:@[THIS]];
    }
    
    if ( THIS.completionBlock ) THIS.completionBlock();
    
    THIS->_playhead = 0;
}

static OSStatus renderCallback(__unsafe_unretained AEMemoryBufferPlayer *THIS, __unsafe_unretained AEAudioController *audioController, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
    int32_t playhead = THIS->_playhead;
    int32_t originalPlayhead = playhead;
    
    if ( !THIS->_channelIsPlaying ) return noErr;
    
    uint64_t hostTimeAtBufferEnd = time->mHostTime + AEHostTicksFromSeconds((double)frames / THIS->_audioDescription.mSampleRate);
    if ( THIS->_startTime && THIS->_startTime > hostTimeAtBufferEnd ) {
        // Start time not yet reached: emit silence
        return noErr;
    }
    
    uint32_t silentFrames = THIS->_startTime && THIS->_startTime > time->mHostTime
    ? AESecondsFromHostTicks(THIS->_startTime - time->mHostTime) * THIS->_audioDescription.mSampleRate : 0;
    AEAudioBufferListCopyOnStack(scratchAudioBufferList, audio, silentFrames * THIS->_audioDescription.mBytesPerFrame);
    
    if ( silentFrames > 0 ) {
        // Start time is offset into this buffer - silence beginning of buffer
        for ( int i=0; i<audio->mNumberBuffers; i++) {
            memset(audio->mBuffers[i].mData, 0, silentFrames * THIS->_audioDescription.mBytesPerFrame);
        }
        
        // Point buffer list to remaining frames
        audio = scratchAudioBufferList;
        frames -= silentFrames;
    }
    
    THIS->_startTime = 0;
    
    if ( !THIS->_loop && playhead == THIS->_lengthInFrames ) {
        // Notify main thread that playback has finished
        AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyPlaybackStopped, &THIS, sizeof(AEMemoryBufferPlayer*));
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
                    AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyLoopRestart, &THIS, sizeof(AEMemoryBufferPlayer*));
                }
            } else {
                // Notify main thread that playback has finished
                AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyPlaybackStopped, &(struct notifyPlaybackStopped_arg) { .THIS = THIS, .audioController = audioController }, sizeof(struct notifyPlaybackStopped_arg));
                THIS->_channelIsPlaying = NO;
                break;
            }
        }
    }
    
    OSAtomicCompareAndSwap32(originalPlayhead, playhead, &THIS->_playhead);
    
    return noErr;
}

-(AEAudioRenderCallback)renderCallback {
    return renderCallback;
}

@end
