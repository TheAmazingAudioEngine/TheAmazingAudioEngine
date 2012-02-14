//
//  TPAudioFilePlayer.m
//  TPAudioController
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "TPAudioFilePlayer.h"

#define checkStatus(status) \
    if ( (status) != noErr ) {\
        NSLog(@"Error: %ld -> %s:%d", (status), __FILE__, __LINE__);\
    }

@interface TPAudioFilePlayer () {
    char                         *_audio;
    int                           _lengthInFrames;
    AudioStreamBasicDescription   _audioDescription;
    int                           _playhead;
    TPAudioController            *_audioController;
}
@end

@implementation TPAudioFilePlayer
@synthesize loop=_loop, volume=_volume, pan=_pan, playing=_playing, muted=_muted;

+ (id)audioFilePlayerWithURL:(NSURL*)url audioController:(TPAudioController *)audioController error:(NSError **)error {
    
    ExtAudioFileRef audioFile;
    OSStatus status;
    
    // Open file
    status = ExtAudioFileOpenURL((CFURLRef)url, &audioFile);
    checkStatus(status);
    if ( status != noErr ) {
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't open the audio file", @"") 
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    // Get file data format
    AudioStreamBasicDescription fileAudioDescription;
    UInt32 size = sizeof(fileAudioDescription);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &size, &fileAudioDescription);
    if ( status != noErr ) {
        ExtAudioFileDispose(audioFile);
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the audio file", @"") 
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    // Apply client format
    AudioStreamBasicDescription audioDescription = audioController.audioDescription;
    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(audioDescription), &audioDescription);
    if ( status != noErr ) {
        ExtAudioFileDispose(audioFile);
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:
                                                                                           NSLocalizedString(@"Couldn't convert the audio file (error %d)", @""),
                                                                                           status]
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    // Determine length in frames (in original file's sample rate)
    UInt64 fileLengthInFrames;
    size = sizeof(fileLengthInFrames);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &size, &fileLengthInFrames);
    if ( status != noErr ) {
        ExtAudioFileDispose(audioFile);
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the audio file", @"") 
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    // Calculate the true length in frames, given the original and target sample rates
    fileLengthInFrames = ceil(fileLengthInFrames * (audioDescription.mSampleRate / fileAudioDescription.mSampleRate));
    
    // Allocate space for audio
    char *audioSamples = malloc(fileLengthInFrames * (audioDescription.mBitsPerChannel/8) * audioDescription.mChannelsPerFrame);
    
    if ( !audioSamples ) {
        ExtAudioFileDispose(audioFile);
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:
                                                                                           NSLocalizedString(@"Not enough memory to open file", @""),
                                                                                           status]
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    // Prepare buffers
    int bufferCount = (audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? audioDescription.mChannelsPerFrame : 1;
    UInt64 remainingFrames = fileLengthInFrames;
    char* audioDataPtr[bufferCount];
    audioDataPtr[0] = audioSamples;
    for ( int i=1; i<bufferCount; i++ ) {
        audioDataPtr[i] = audioDataPtr[i-1] + (fileLengthInFrames * audioDescription.mBytesPerFrame);
    }
    
    struct { AudioBufferList bufferList; AudioBuffer nextBuffer; } buffers;
    buffers.bufferList.mNumberBuffers = bufferCount;

    // Perform read in multiple small chunks (otherwise ExtAudioFileRead crashes when performing sample rate conversion)
    while ( remainingFrames > 0 ) {
        for ( int i=0; i<buffers.bufferList.mNumberBuffers; i++ ) {
            buffers.bufferList.mBuffers[i].mNumberChannels = (audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : audioDescription.mChannelsPerFrame;
            buffers.bufferList.mBuffers[i].mData = audioDataPtr[i];
            buffers.bufferList.mBuffers[i].mDataByteSize = MIN(16384, remainingFrames * audioDescription.mBytesPerFrame);
        }
        
        // Perform read
        UInt32 numberOfPackets = (UInt32)(buffers.bufferList.mBuffers[0].mDataByteSize / audioDescription.mBytesPerFrame);
        status = ExtAudioFileRead(audioFile, &numberOfPackets, &buffers.bufferList);
        
        if ( numberOfPackets == 0 ) {
            // Termination condition
            break;
        }
        
        if ( status != noErr ) {
            ExtAudioFileDispose(audioFile);
            free(audioSamples);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                                  userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:
                                                                                               NSLocalizedString(@"Couldn't read the audio file (error %d)", @""),
                                                                                               status]
                                                                                       forKey:NSLocalizedDescriptionKey]];
            return nil;
        }
        
        for ( int i=0; i<buffers.bufferList.mNumberBuffers; i++ ) {
            audioDataPtr[i] += numberOfPackets * audioDescription.mBytesPerFrame;
        }
        remainingFrames -= numberOfPackets;
    }
    
    // Clean up        
    ExtAudioFileDispose(audioFile);
    
    TPAudioFilePlayer *player = [[[TPAudioFilePlayer alloc] init] autorelease];
    player->_volume = 1.0;
    player->_playing = YES;
    player->_audioController = audioController;
    player->_audioDescription = audioDescription;
    player->_audio = audioSamples;
    player->_lengthInFrames = fileLengthInFrames;
    
    return player;
}

static long notifyPlaybackStopped(TPAudioController *audioController, long *ioParameter1, long *ioParameter2, long *ioParameter3, void *ioOpaquePtr) {
    TPAudioFilePlayer *THIS = ioOpaquePtr;
    THIS.playing = NO;
    return 0;
}

static OSStatus renderCallback(TPAudioFilePlayer *THIS, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
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

        // A pointer to the next audio to play
        char *ptr = THIS->_audio + THIS->_playhead * bytesPerFrame;
        
        // Fill each buffer with the audio
        for ( int i=0; i<audio->mNumberBuffers; i++ ) {
            memcpy(audioPtrs[i], ptr, framesToCopy * bytesPerFrame);
            
            // Advance the output buffers
            audioPtrs[i] += framesToCopy * bytesPerFrame;
            
            // Advance the audio pointer to the next channel, if we're non-interleaved
            ptr += THIS->_lengthInFrames * bytesPerFrame;
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
                TPAudioControllerSendAsynchronousMessageToMainThread(THIS->_audioController, &notifyPlaybackStopped, 0, 0, 0, THIS);
                break;
            }
        }
    }
    
    return noErr;
}

-(TPAudioControllerRenderCallback)renderCallback {
    return &renderCallback;
}

@end
