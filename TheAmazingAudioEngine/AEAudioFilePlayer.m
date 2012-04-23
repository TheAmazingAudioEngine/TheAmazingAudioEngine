//
//  AEAudioFilePlayer.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEAudioFilePlayer.h"
#import "AEAudioFileLoaderOperation.h"

#define checkStatus(status) \
    if ( (status) != noErr ) {\
        NSLog(@"Error: %ld -> %s:%d", (status), __FILE__, __LINE__);\
    }

@interface AEAudioFilePlayer () {
    AudioBufferList              *_audio;
    UInt32                        _lengthInFrames;
    AudioStreamBasicDescription   _audioDescription;
    int                           _playhead;
}
@end

@implementation AEAudioFilePlayer
@synthesize loop=_loop, volume=_volume, pan=_pan, playing=_playing, muted=_muted, removeUponFinish=_removeUponFinish;

+ (id)audioFilePlayerWithURL:(NSURL*)url audioController:(AEAudioController *)audioController error:(NSError **)error {
    
    AEAudioFilePlayer *player = [[[AEAudioFilePlayer alloc] init] autorelease];
    player->_volume = 1.0;
    player->_playing = YES;
    player->_audioDescription = *audioController.audioDescription;
    
    AEAudioFileLoaderOperation *operation = [[AEAudioFileLoaderOperation alloc] initWithFileURL:url targetAudioDescription:player->_audioDescription];
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    [queue addOperation:operation];
    [queue waitUntilAllOperationsAreFinished];
    
    if ( operation.error ) {
        if ( error ) *error = operation.error;
        [player release];
        [operation release];
        [queue release];
        return nil;
    }
    
    player->_audio = operation.bufferList;
    player->_lengthInFrames = operation.lengthInFrames;
    
    [operation release];
    [queue release];
    
    return player;
}

- (void)dealloc {
    if ( _audio ) {
        for ( int i=0; i<_audio->mNumberBuffers; i++ ) {
            free(_audio->mBuffers[i].mData);
        }
        free(_audio);
    }
    [super dealloc];
}

static void notifyPlaybackStopped(AEAudioController *audioController, void *userInfo, int length) {
    AEAudioFilePlayer *THIS = *(AEAudioFilePlayer**)userInfo;
    THIS.playing = NO;
    
    if ( THIS->_removeUponFinish ) {
        [audioController removeChannels:[NSArray arrayWithObject:THIS]];
    }
}

static OSStatus renderCallback(AEAudioFilePlayer *THIS, AEAudioController *audioController, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
    if ( !THIS->_loop && THIS->_playhead == THIS->_lengthInFrames ) {
        // At the end of playback - silence whole buffer and return
        for ( int i=0; i<audio->mNumberBuffers; i++ ) memset(audio->mBuffers[i].mData, 0, audio->mBuffers[i].mDataByteSize);
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
        int framesToCopy = MIN(remainingFrames, THIS->_lengthInFrames - THIS->_playhead);

        // Fill each buffer with the audio
        for ( int i=0; i<audio->mNumberBuffers; i++ ) {
            memcpy(audioPtrs[i], ((char*)THIS->_audio->mBuffers[i].mData) + THIS->_playhead * bytesPerFrame, framesToCopy * bytesPerFrame);
            
            // Advance the output buffers
            audioPtrs[i] += framesToCopy * bytesPerFrame;
        }
        
        // Advance playhead
        remainingFrames -= framesToCopy;
        THIS->_playhead += framesToCopy;
        
        if ( THIS->_playhead >= THIS->_lengthInFrames ) {
            // Reached the end of the audio - either loop, or stop
            if ( THIS->_loop ) {
                THIS->_playhead = 0;
            } else {
                // Silence remainder of buffer
                for ( int i=0; i<audio->mNumberBuffers; i++ ) memset(audioPtrs[i], 0, remainingFrames * bytesPerFrame);
                
                // Notify main thread that playback has finished
                AEAudioControllerSendAsynchronousMessageToMainThread(audioController, notifyPlaybackStopped, &THIS, sizeof(AEAudioFilePlayer*));
                break;
            }
        }
    }
    
    return noErr;
}

-(AEAudioControllerRenderCallback)renderCallback {
    return &renderCallback;
}

@end
