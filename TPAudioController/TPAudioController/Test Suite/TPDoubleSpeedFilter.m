//
//  TPDoubleSpeedFilter.m
//  TPAudioController
//
//  Created by Michael Tyson on 25/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "TPDoubleSpeedFilter.h"

#define kDoubleSpeedFilterBufferLength 4096 // samples

@interface TPDoubleSpeedFilter () {
    SInt16         *_scratchBuffer[2];
    AudioStreamBasicDescription _audioDescription;
}
@end

@implementation TPDoubleSpeedFilter
@dynamic filterCallback;

- (id)initWithAudioController:(TPAudioController*)audioController {
    if ( !(self = [super init]) ) return nil;
    _audioDescription = audioController.audioDescription;
    if ( _audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ) {
        for ( int i=0; i<_audioDescription.mChannelsPerFrame; i++ ) {
            _scratchBuffer[i] = malloc(sizeof(SInt16) * kDoubleSpeedFilterBufferLength);
        }
    } else {
        _scratchBuffer[0] = malloc(sizeof(SInt16) * kDoubleSpeedFilterBufferLength * _audioDescription.mChannelsPerFrame);
    }
    return self;
}

- (void)dealloc {
    if ( _scratchBuffer[0] ) free(_scratchBuffer[0]);
    if ( _scratchBuffer[1] ) free(_scratchBuffer[1]);
    [super dealloc];
}

static void doubleSpeedFilter(id                        filter,
                              TPAudioControllerVariableSpeedFilterProducer producer,
                              void                     *producerToken,
                              const AudioTimeStamp     *time,
                              UInt32                    frames,
                              AudioBufferList          *audio) {
    TPDoubleSpeedFilter *THIS = (TPDoubleSpeedFilter*)filter;
    
    int framesToGet = frames * 2;
    
    char audioBufferListSpace[sizeof(AudioBufferList)+sizeof(AudioBuffer)];
    AudioBufferList *bufferList = (AudioBufferList*)audioBufferListSpace;
    bufferList->mNumberBuffers = THIS->_audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? THIS->_audioDescription.mChannelsPerFrame : 1;
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        bufferList->mBuffers[i].mData = THIS->_scratchBuffer[i];
        bufferList->mBuffers[i].mNumberChannels = THIS->_audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : THIS->_audioDescription.mChannelsPerFrame;
    }
    
    while ( framesToGet > 0 ) {
        int block = MIN(framesToGet, 256);
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mDataByteSize = block * THIS->_audioDescription.mBytesPerFrame;
        }

        producer(producerToken, bufferList, block);
        
        framesToGet -= block;
        
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mData = (char*)bufferList->mBuffers[i].mData + (block * THIS->_audioDescription.mBytesPerFrame);
        }
    }
    
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        bufferList->mBuffers[i].mData = THIS->_scratchBuffer[i];
        bufferList->mBuffers[i].mDataByteSize = framesToGet * THIS->_audioDescription.mBytesPerFrame;
    }
    
    if ( bufferList->mNumberBuffers == 2 ) {
        for ( int i=0; i<frames; i++ ) {
            ((SInt16*)audio->mBuffers[0].mData)[i] = THIS->_scratchBuffer[0][2*i];
            ((SInt16*)audio->mBuffers[1].mData)[i] = THIS->_scratchBuffer[1][2*i];
        }
    } else {
        int channels = THIS->_audioDescription.mChannelsPerFrame;
        for ( int i=0; i<frames; i++ ) {
            ((SInt16*)audio->mBuffers[0].mData)[i*channels] = THIS->_scratchBuffer[0][2*i*channels];
            if ( channels == 2 ) {
                ((SInt16*)audio->mBuffers[0].mData)[i*channels+1] = THIS->_scratchBuffer[0][2*i*channels+1];
            }
        }
    }
}

-(TPAudioControllerVariableSpeedFilterCallback)filterCallback {
    return &doubleSpeedFilter;
}

@end
