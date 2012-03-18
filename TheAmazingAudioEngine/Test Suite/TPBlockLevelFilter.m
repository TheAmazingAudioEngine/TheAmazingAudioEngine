//
//  TPBlockLevelFilter.m
//
//  Created by Michael Tyson on 11/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "TPBlockLevelFilter.h"
#import <Accelerate/Accelerate.h>
#import "TPCircularBuffer.h"

#define kTwoChannelsPerFrame 2

// Per-channel filter record structure
struct filter_rec_t {
    TPCircularBuffer inputBuffer;
    TPCircularBuffer outputBuffer;
};

@interface TPBlockLevelFilter () {
    AEAudioController              *_audioController;
    struct filter_rec_t             _channelRecord[kTwoChannelsPerFrame];
    float                          *_scratchBuffer;
    int                             _initialProcessingBlockSize;
    TPBlockLevelFilterAudioCallback _blockProcessingCallback;
}
@end

@implementation TPBlockLevelFilter
@synthesize stereo=_stereo, processingBlockSizeInFrames=_processingBlockSizeInFrames;
@dynamic filterCallback;

- (id)initWithAudioController:(AEAudioController *)audioController processingBlockSize:(int)processingBlockSizeInFrames blockProcessingCallback:(TPBlockLevelFilterAudioCallback)callback {
    if ( !(self = [super init]) ) return nil;
    
    _audioController = audioController;
    _initialProcessingBlockSize = _processingBlockSizeInFrames = processingBlockSizeInFrames;
    _blockProcessingCallback = callback;
    
    _scratchBuffer = (float*)malloc(sizeof(float) * 2048);
    
    for ( int i=0; i<kTwoChannelsPerFrame; i++ ) {
        TPCircularBufferInit(&_channelRecord[i].inputBuffer, (_processingBlockSizeInFrames + 2048 /* A little extra to store overflow */) * sizeof(float));
        TPCircularBufferInit(&_channelRecord[i].outputBuffer, (_processingBlockSizeInFrames + 2048 /* A little extra to store overflow */) * sizeof(float));
        
        // Pad input with silence
        int32_t availableBytes;
        float *input = (float*)TPCircularBufferHead(&_channelRecord[i].inputBuffer, &availableBytes);
        memset(input, 0, sizeof(float) * _processingBlockSizeInFrames);
        TPCircularBufferProduce(&_channelRecord[i].inputBuffer, sizeof(float) * _processingBlockSizeInFrames);
    }
    
    _stereo = YES;
    
    return self;
}

-(void)dealloc {
    for ( int i=0; i<kTwoChannelsPerFrame; i++ ) {
        TPCircularBufferCleanup(&_channelRecord[i].inputBuffer);
        TPCircularBufferCleanup(&_channelRecord[i].outputBuffer);
    }
    free(_scratchBuffer);
    
    [super dealloc];
}

int TPBlockLevelFilterGetProcessingBlockSize(TPBlockLevelFilter* filter) {
    return filter->_processingBlockSizeInFrames;
}

void TPBlockLevelFilterSetProcessingBlockSize(TPBlockLevelFilter* THIS, int processingBlockSizeInFrames) {
    assert(processingBlockSizeInFrames <= THIS->_initialProcessingBlockSize);
    
    THIS->_processingBlockSizeInFrames = THIS->_processingBlockSizeInFrames;
    
    // Pad input with silence
    for ( int i=0; i<kTwoChannelsPerFrame; i++ ) {
        int32_t filledBytes;
        (void)TPCircularBufferTail(&THIS->_channelRecord[i].inputBuffer, &filledBytes);
        
        int32_t availableBytes;
        float *input = (float*)TPCircularBufferHead(&THIS->_channelRecord[i].inputBuffer, &availableBytes);
        
        int framesToPad = THIS->_processingBlockSizeInFrames - (filledBytes / sizeof(float));
        if ( framesToPad > 0 ) {
            memset(input, 0, sizeof(float) * framesToPad);
            TPCircularBufferProduce(&THIS->_channelRecord[i].inputBuffer, sizeof(float) * framesToPad);
        }
    }
}

static long setProcessingBlockSize(AEAudioController *audioController, long *ioParameter1, long *ioParameter2, long *ioParameter3, void *ioOpaquePtr) {
    TPBlockLevelFilterSetProcessingBlockSize(ioOpaquePtr, *ioParameter1);
    return 0;
}

-(void)setProcessingBlockSizeInFrames:(int)processingBlockSizeInFrames {
    [_audioController performSynchronousMessageExchangeWithHandler:&setProcessingBlockSize parameter1:processingBlockSizeInFrames parameter2:0 parameter3:0 ioOpaquePtr:self];
}

static void filterCallback(id filter, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
    TPBlockLevelFilter *THIS = (TPBlockLevelFilter*)filter;
    
    BOOL inputIsStereo = audio->mNumberBuffers == 2 || audio->mBuffers[0].mNumberChannels == 2;
    BOOL inputIsNonInterleaved = audio->mNumberBuffers == 2;
    
    BOOL stereo = THIS->_stereo && inputIsStereo;
    
    // Accumulate new samples in buffer, as float values
    if ( stereo ) {
        // Stereo mode
        for ( int i=0; i<kTwoChannelsPerFrame; i++ ) {
            int32_t availableBytes;
            float *buffer = (float*)TPCircularBufferHead(&THIS->_channelRecord[i].inputBuffer, &availableBytes);
            assert(availableBytes > frames*sizeof(float));
            
            if ( inputIsNonInterleaved ) {
                // Non-interleaved audio
                vDSP_vflt16(audio->mBuffers[i].mData, 1, buffer, 1, frames);
            } else {
                // Interleaved audio
                vDSP_vflt16(((SInt16*)audio->mBuffers[i].mData)+i, 2 /* every second sample */, buffer, 1, frames);
            }
            
            TPCircularBufferProduce(&THIS->_channelRecord[i].inputBuffer, frames*sizeof(float));
        }
    } else {
        // Mono mode
        int32_t availableBytes;
        float *buffer = (float*)TPCircularBufferHead(&THIS->_channelRecord[0].inputBuffer, &availableBytes);
        assert(availableBytes > frames*sizeof(float));
        
        if ( inputIsStereo ) {
            // Mix stereo down to mono
            if ( inputIsNonInterleaved ) {
                // Non-interleaved audio
                float scale = 0.5;
                vDSP_vflt16((SInt16*)audio->mBuffers[0].mData, 1, buffer, 1, frames);
                vDSP_vsmul(buffer, 1, &scale, buffer, 1, frames);
                vDSP_vflt16((SInt16*)audio->mBuffers[1].mData, 1, THIS->_scratchBuffer, 1, frames);
                vDSP_vsma(THIS->_scratchBuffer, 1, &scale, buffer, 1, buffer, 1, frames);
            } else {
                // Interleaved audio
                float scale = 0.5;
                vDSP_vflt16(((SInt16*)audio->mBuffers[0].mData), 2, buffer, 1, frames);
                vDSP_vsmul(buffer, 1, &scale, buffer, 1, frames);
                vDSP_vflt16(((SInt16*)audio->mBuffers[0].mData)+1, 2, THIS->_scratchBuffer, 1, frames);
                vDSP_vsma(THIS->_scratchBuffer, 1, &scale, buffer, 1, buffer, 1, frames);
            }
        } else {
            vDSP_vflt16((SInt16*)audio->mBuffers[0].mData, 1, buffer, 1, frames);
        }
        
        TPCircularBufferProduce(&THIS->_channelRecord[0].inputBuffer, frames*sizeof(float));
    }
    
    char outputAudioBufferListSpace[sizeof(AudioBufferList)+sizeof(AudioBuffer)];
    AudioBufferList *output = (AudioBufferList*)outputAudioBufferListSpace;
    char inputAudioBufferListSpace[sizeof(AudioBufferList)+sizeof(AudioBuffer)];
    AudioBufferList *input = (AudioBufferList*)inputAudioBufferListSpace;
            
    input->mNumberBuffers = output->mNumberBuffers = stereo ? 2 : 1;
    output->mBuffers[0].mNumberChannels = input->mBuffers[0].mNumberChannels = 1;
    output->mBuffers[1].mNumberChannels = input->mBuffers[1].mNumberChannels = 1;
    
    while ( 1 ) {
        // The input signal (left/mono channel)...
        int32_t availableInputBytes;
        input->mBuffers[0].mData = TPCircularBufferTail(&THIS->_channelRecord[0].inputBuffer, &availableInputBytes);
        input->mBuffers[0].mDataByteSize = availableInputBytes;

        int availableInputFrames = availableInputBytes / sizeof(float);
        if ( availableInputFrames < THIS->_processingBlockSizeInFrames ) break;

        // If we have enough input data
        
        // Prepare to write to the output buffer (left/mono channel)...
        int32_t availableOutputBytes;
        output->mBuffers[0].mData = TPCircularBufferHead(&THIS->_channelRecord[0].outputBuffer, &availableOutputBytes);
        output->mBuffers[0].mDataByteSize = availableOutputBytes;
        assert(availableOutputBytes > THIS->_processingBlockSizeInFrames*sizeof(float));
        
        // The input signal (right channel)
        if ( stereo ) {
            input->mBuffers[1].mData = TPCircularBufferTail(&THIS->_channelRecord[1].inputBuffer, &availableInputBytes);
            input->mBuffers[1].mDataByteSize = availableInputBytes;
            assert(availableInputBytes >= THIS->_processingBlockSizeInFrames*sizeof(float));
            
            output->mBuffers[1].mData = TPCircularBufferHead(&THIS->_channelRecord[1].outputBuffer, &availableOutputBytes);
            output->mBuffers[1].mDataByteSize = availableOutputBytes;
            assert(availableOutputBytes > THIS->_processingBlockSizeInFrames*sizeof(float));
        }
        
        // Perform processing
        int consumedFrames = THIS->_processingBlockSizeInFrames;
        int producedFrames = THIS->_processingBlockSizeInFrames;
        
        THIS->_blockProcessingCallback(THIS, time, THIS->_processingBlockSizeInFrames, input, output, &consumedFrames, &producedFrames);
        
        TPCircularBufferProduce(&THIS->_channelRecord[0].outputBuffer, producedFrames * sizeof(float));
        TPCircularBufferConsume(&THIS->_channelRecord[0].inputBuffer, consumedFrames * sizeof(float));
        
        if ( stereo ) {
            TPCircularBufferProduce(&THIS->_channelRecord[1].outputBuffer, producedFrames * sizeof(float));
            TPCircularBufferConsume(&THIS->_channelRecord[1].inputBuffer, consumedFrames * sizeof(float));
        }
    }
    
    // Now consume processed audio from the output buffers
    int32_t availableOutputBytes;
    float *buffer, *bufferStart;
    
    // The left/mono output buffer...
    bufferStart = buffer = (float*)TPCircularBufferTail(&THIS->_channelRecord[0].outputBuffer, &availableOutputBytes);
    int availableOutputFrames = availableOutputBytes / sizeof(float);
    
    if ( availableOutputFrames < frames ) {
        // Not enough frames to output yet - just output silence
        for ( int i=0; i<audio->mNumberBuffers; i++ ) {
            memset(audio->mBuffers[0].mData, 0, audio->mBuffers[0].mDataByteSize);
        }
        return;
    }
    
    if ( stereo ) {
        // Copy processed left channel...
        if ( inputIsNonInterleaved ) {
            vDSP_vfix16(buffer, 1, (SInt16*)audio->mBuffers[0].mData, 1, frames);
        } else {
            vDSP_vfixr16(buffer, 1, (SInt16*)audio->mBuffers[0].mData, 2 /* every second sample */, frames);
        }
        vDSP_vclr(bufferStart, 1, frames);
        TPCircularBufferConsume(&THIS->_channelRecord[0].outputBuffer, frames * sizeof(float));
        
        // Copy processed right channel...
        bufferStart = buffer = (float*)TPCircularBufferTail(&THIS->_channelRecord[1].outputBuffer, &availableOutputBytes);
        assert(availableOutputBytes >= frames * sizeof(float));
        if ( inputIsNonInterleaved ) {
            vDSP_vfix16(buffer, 1, (SInt16*)audio->mBuffers[1].mData, 1, frames);
        } else {
            vDSP_vfixr16(buffer, 1, ((SInt16*)audio->mBuffers[0].mData)+1 /* start from second sample */, 2 /* every second sample */, frames);
        }
        vDSP_vclr(bufferStart, 1, frames);
        TPCircularBufferConsume(&THIS->_channelRecord[1].outputBuffer, frames * sizeof(float));
        
    } else {
        if ( inputIsStereo ) {
            // Copy mono channel, duplicated to both output channels
            if ( inputIsNonInterleaved ) {
                vDSP_vfix16(buffer, 1, (SInt16*)audio->mBuffers[0].mData, 1, frames);
                memcpy(audio->mBuffers[1].mData, audio->mBuffers[0].mData, frames * sizeof(SInt16));
            } else {
                vDSP_vfixr16(buffer, 1, (SInt16*)audio->mBuffers[0].mData, 2 /* every second sample */, frames);
                vDSP_vfixr16(buffer, 1, ((SInt16*)audio->mBuffers[0].mData)+1 /* start from second sample */, 2 /* every second sample */, frames);
            }
        } else {
            vDSP_vfix16(buffer, 1, (SInt16*)audio->mBuffers[0].mData, 1, frames);
        }

        vDSP_vclr(bufferStart, 1, frames);
        TPCircularBufferConsume(&THIS->_channelRecord[0].outputBuffer, frames * sizeof(float));
    }
}

-(AEAudioControllerAudioCallback)filterCallback {
    return &filterCallback;
}

@end
