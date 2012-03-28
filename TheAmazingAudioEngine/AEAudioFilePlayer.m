//
//  AEAudioFilePlayer.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEAudioFilePlayer.h"

#define checkStatus(status) \
    if ( (status) != noErr ) {\
        NSLog(@"Error: %ld -> %s:%d", (status), __FILE__, __LINE__);\
    }

@interface AEAudioFilePlayer () {
    AudioBufferList              *_audio;
    int                           _lengthInFrames;
    AudioStreamBasicDescription   _audioDescription;
    int                           _playhead;
    AEAudioController            *_audioController;
}
@end

@implementation AEAudioFilePlayer
@synthesize loop=_loop, volume=_volume, pan=_pan, playing=_playing, muted=_muted, removeUponFinish=_removeUponFinish;

+ (id)audioFilePlayerWithURL:(NSURL*)url audioController:(AEAudioController *)audioController error:(NSError **)error {
    
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
    
    // Prepare buffers
    int bufferCount = (audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? audioDescription.mChannelsPerFrame : 1;
    int channelsPerBuffer = (audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : audioDescription.mChannelsPerFrame;
    AudioBufferList *bufferList = (AudioBufferList*)malloc(sizeof(AudioBufferList) + (bufferCount-1)*sizeof(AudioBuffer));
    bufferList->mNumberBuffers = bufferCount;
    char* audioDataPtr[bufferCount];
    for ( int i=0; i<bufferCount; i++ ) {
        int bufferSize = fileLengthInFrames * (audioDescription.mBitsPerChannel/8) * channelsPerBuffer;
        audioDataPtr[i] = malloc(bufferSize);
        if ( !audioDataPtr[i] ) {
            ExtAudioFileDispose(audioFile);
            for ( int j=0; j<i; j++ ) free(audioDataPtr[j]);
            free(bufferList);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                                  userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:
                                                                                               NSLocalizedString(@"Not enough memory to open file", @""),
                                                                                               status]
                                                                                       forKey:NSLocalizedDescriptionKey]];
            return nil;
        }
        
        bufferList->mBuffers[i].mData = audioDataPtr[i];
        bufferList->mBuffers[i].mDataByteSize = bufferSize;
        bufferList->mBuffers[i].mNumberChannels = channelsPerBuffer;
    }

    char audioBufferListSpace[sizeof(AudioBufferList)+sizeof(AudioBuffer)];
    AudioBufferList *scratchBufferList = (AudioBufferList*)audioBufferListSpace;
    
    scratchBufferList->mNumberBuffers = bufferCount;

    // Perform read in multiple small chunks (otherwise ExtAudioFileRead crashes when performing sample rate conversion)
    UInt64 remainingFrames = fileLengthInFrames;
    while ( remainingFrames > 0 ) {
        for ( int i=0; i<scratchBufferList->mNumberBuffers; i++ ) {
            scratchBufferList->mBuffers[i].mNumberChannels = channelsPerBuffer;
            scratchBufferList->mBuffers[i].mData = audioDataPtr[i];
            scratchBufferList->mBuffers[i].mDataByteSize = MIN(16384, remainingFrames * audioDescription.mBytesPerFrame);
        }
        
        // Perform read
        UInt32 numberOfPackets = (UInt32)(scratchBufferList->mBuffers[0].mDataByteSize / audioDescription.mBytesPerFrame);
        status = ExtAudioFileRead(audioFile, &numberOfPackets, scratchBufferList);
        
        if ( numberOfPackets == 0 ) {
            // Termination condition
            break;
        }
        
        if ( status != noErr ) {
            ExtAudioFileDispose(audioFile);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                                  userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:
                                                                                               NSLocalizedString(@"Couldn't read the audio file (error %d)", @""),
                                                                                               status]
                                                                                       forKey:NSLocalizedDescriptionKey]];
            return nil;
        }
        
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            audioDataPtr[i] += numberOfPackets * audioDescription.mBytesPerFrame;
        }
        remainingFrames -= numberOfPackets;
    }
    
    // Clean up        
    ExtAudioFileDispose(audioFile);
    
    AEAudioFilePlayer *player = [[[AEAudioFilePlayer alloc] init] autorelease];
    player->_volume = 1.0;
    player->_playing = YES;
    player->_audioController = audioController;
    player->_audioDescription = audioDescription;
    player->_audio = bufferList;
    player->_lengthInFrames = fileLengthInFrames;
    
    return player;
}

static long notifyPlaybackStopped(AEAudioController *audioController, long *ioParameter1, long *ioParameter2, long *ioParameter3, void *ioOpaquePtr) {
    AEAudioFilePlayer *THIS = ioOpaquePtr;
    THIS.playing = NO;
    
    if ( THIS->_removeUponFinish ) {
        [audioController removeChannels:[NSArray arrayWithObject:THIS]];
    }
    
    return 0;
}

static OSStatus renderCallback(AEAudioFilePlayer *THIS, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
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
                AEAudioControllerSendAsynchronousMessageToMainThread(THIS->_audioController, &notifyPlaybackStopped, 0, 0, 0, THIS);
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
