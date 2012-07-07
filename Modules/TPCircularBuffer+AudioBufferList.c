//
//  TPCircularBuffer+AudioBufferList.c
//  Circular/Ring buffer implementation
//
//  Created by Michael Tyson on 20/03/2012.
//  Copyright 2012 A Tasty Pixel. All rights reserved.
//

#include "TPCircularBuffer+AudioBufferList.h"
#import <mach/mach_time.h>

static double __secondsToHostTicks = 0.0;

static inline long align16byte(long val) {
    if ( val & (16-1) ) {
        return val + (16 - (val & (16-1)));
    }
    return val;
}

static inline long min(long a, long b) {
    return a > b ? b : a;
}

AudioBufferList *TPCircularBufferPrepareEmptyAudioBufferList(TPCircularBuffer *buffer, int numberOfBuffers, int bytesPerBuffer, const AudioTimeStamp *inTimestamp) {
    int32_t availableBytes;
    TPCircularBufferABLBlockHeader *block = (TPCircularBufferABLBlockHeader*)TPCircularBufferHead(buffer, &availableBytes);
    if ( availableBytes < sizeof(TPCircularBufferABLBlockHeader)+((numberOfBuffers-1)*sizeof(AudioBuffer))+(numberOfBuffers*bytesPerBuffer) ) return NULL;
    
    assert(!((unsigned long)block & 0xF) /* Beware unaligned accesses */);
    
    // Store timestamp, followed by a UInt32 defining the number of bytes from the start of the buffer list to the end of the segment, then the buffer list
    if ( inTimestamp ) {
        memcpy(&block->timestamp, inTimestamp, sizeof(AudioTimeStamp));
    } else {
        memset(&block->timestamp, 0, sizeof(AudioTimeStamp));
    }
    
    memset(&block->bufferList, 0, sizeof(AudioBufferList)+((numberOfBuffers-1)*sizeof(AudioBuffer)));
    block->bufferList.mNumberBuffers = numberOfBuffers;
    
    char *dataPtr = (char*)&block->bufferList + sizeof(AudioBufferList)+((numberOfBuffers-1)*sizeof(AudioBuffer));
    for ( int i=0; i<numberOfBuffers; i++ ) {
        // Find the next 16-byte aligned memory area
        dataPtr = (char*)align16byte((long)dataPtr);
        
        if ( (dataPtr + bytesPerBuffer) - (char*)block > availableBytes ) {
            return NULL;
        }
        
        block->bufferList.mBuffers[i].mData = dataPtr;
        block->bufferList.mBuffers[i].mDataByteSize = bytesPerBuffer;
        block->bufferList.mBuffers[i].mNumberChannels = 1;
        
        dataPtr += bytesPerBuffer;
    }
    
    // Make sure whole buffer (including timestamp and length value) is 16-byte aligned in length
    block->totalLength = align16byte(dataPtr - (char*)block);
    if ( block->totalLength > availableBytes ) {
        return NULL;
    }
    
    return &block->bufferList;
}

void TPCircularBufferProduceAudioBufferList(TPCircularBuffer *buffer) {
    int32_t availableBytes;
    TPCircularBufferABLBlockHeader *block = (TPCircularBufferABLBlockHeader*)TPCircularBufferHead(buffer, &availableBytes);
    
    assert(!((unsigned long)block & 0xF) /* Beware unaligned accesses */);
    
    UInt32 calculatedLength = ((char*)block->bufferList.mBuffers[block->bufferList.mNumberBuffers-1].mData + block->bufferList.mBuffers[block->bufferList.mNumberBuffers-1].mDataByteSize) - (char*)block;

    // Make sure whole buffer (including timestamp and length value) is 16-byte aligned in length
    calculatedLength = align16byte(calculatedLength);
    
    assert(calculatedLength <= block->totalLength && calculatedLength <= availableBytes);
    
    block->totalLength = calculatedLength;
    
    TPCircularBufferProduce(buffer, block->totalLength);
}

bool TPCircularBufferCopyAudioBufferList(TPCircularBuffer *buffer, const AudioBufferList *inBufferList, const AudioTimeStamp *inTimestamp, UInt32 frames, AudioStreamBasicDescription *audioDescription) {

    int byteCount = inBufferList->mBuffers[0].mDataByteSize;
    if ( frames != kTPCircularBufferCopyAll ) {
        byteCount = frames * audioDescription->mBytesPerFrame;
        assert(byteCount <= inBufferList->mBuffers[0].mDataByteSize);
    }
    
    AudioBufferList *bufferList = TPCircularBufferPrepareEmptyAudioBufferList(buffer, inBufferList->mNumberBuffers, byteCount, inTimestamp);
    if ( !bufferList ) return false;
    
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        memcpy(bufferList->mBuffers[i].mData, inBufferList->mBuffers[i].mData, byteCount);
    }
    
    TPCircularBufferProduceAudioBufferList(buffer);
    
    return true;
}

AudioBufferList *TPCircularBufferNextBufferListAfter(TPCircularBuffer *buffer, AudioBufferList *bufferList, AudioTimeStamp *outTimestamp) {
    int32_t availableBytes;
    void *tail = TPCircularBufferTail(buffer, &availableBytes);
    void *end = (char*)tail + availableBytes;
    assert((void*)bufferList > (void*)tail && (void*)bufferList < end);
    
    TPCircularBufferABLBlockHeader *originalBlock = (TPCircularBufferABLBlockHeader*)((char*)bufferList - offsetof(TPCircularBufferABLBlockHeader, bufferList));
    assert(!((unsigned long)originalBlock & 0xF) /* Beware unaligned accesses */);
    
    
    TPCircularBufferABLBlockHeader *nextBlock = (TPCircularBufferABLBlockHeader*)((char*)originalBlock + originalBlock->totalLength);
    if ( (void*)nextBlock >= end ) return NULL;
    assert(!((unsigned long)nextBlock & 0xF) /* Beware unaligned accesses */);
    
    if ( outTimestamp ) {
        memcpy(outTimestamp, &nextBlock->timestamp, sizeof(AudioTimeStamp));
    }
    
    return &nextBlock->bufferList;
}

void TPCircularBufferConsumeNextBufferListPartial(TPCircularBuffer *buffer, int framesToConsume, AudioStreamBasicDescription *audioFormat) {
    assert(framesToConsume >= 0);
    
    int32_t dontcare;
    TPCircularBufferABLBlockHeader *block = (TPCircularBufferABLBlockHeader*)TPCircularBufferTail(buffer, &dontcare);
    if ( !block ) return;
    assert(!((unsigned long)block & 0xF)); // Beware unaligned accesses
    
    int bytesToConsume = framesToConsume * audioFormat->mBytesPerFrame;
    
    if ( bytesToConsume == block->bufferList.mBuffers[0].mDataByteSize ) {
        TPCircularBufferConsumeNextBufferList(buffer);
        return;
    }
    
    for ( int i=0; i<block->bufferList.mNumberBuffers; i++ ) {
        assert(bytesToConsume <= block->bufferList.mBuffers[i].mDataByteSize && (char*)block->bufferList.mBuffers[i].mData + bytesToConsume <= (char*)block+block->totalLength);
        
        block->bufferList.mBuffers[i].mData = (char*)block->bufferList.mBuffers[i].mData + bytesToConsume;
        block->bufferList.mBuffers[i].mDataByteSize -= bytesToConsume;
    }
    
    if ( block->timestamp.mFlags & kAudioTimeStampSampleTimeValid ) {
        block->timestamp.mSampleTime += framesToConsume;
    }
    if ( block->timestamp.mFlags & kAudioTimeStampHostTimeValid ) {
        if ( !__secondsToHostTicks ) {
            mach_timebase_info_data_t tinfo;
            mach_timebase_info(&tinfo);
            __secondsToHostTicks = 1.0 / (((double)tinfo.numer / tinfo.denom) * 1.0e-9);
        }

        block->timestamp.mHostTime += ((double)framesToConsume / audioFormat->mSampleRate) * __secondsToHostTicks;
    }
}

void TPCircularBufferDequeueBufferListFrames(TPCircularBuffer *buffer, UInt32 *ioLengthInFrames, AudioBufferList *outputBufferList, AudioTimeStamp *outTimestamp, AudioStreamBasicDescription *audioFormat) {
    bool hasTimestamp = false;
    UInt32 bytesToGo = *ioLengthInFrames * audioFormat->mBytesPerFrame;
    UInt32 bytesCopied = 0;
    while ( bytesToGo > 0 ) {
        AudioBufferList *bufferList = TPCircularBufferNextBufferList(buffer, !hasTimestamp ? outTimestamp : NULL);
        UInt32 *totalSize = bufferList ? ((UInt32*)bufferList)-1 : NULL;
        hasTimestamp = true;
        if ( !bufferList ) break;
        
        UInt32 bytesToCopy = min(bytesToGo, bufferList->mBuffers[0].mDataByteSize);
        
        if ( outputBufferList ) {
            for ( int i=0; i<outputBufferList->mNumberBuffers; i++ ) {
                assert((char*)outputBufferList->mBuffers[i].mData + bytesCopied + bytesToCopy <= (char*)outputBufferList->mBuffers[i].mData + outputBufferList->mBuffers[i].mDataByteSize);
                assert((char*)bufferList->mBuffers[i].mData + bytesToCopy <= (char*)bufferList+*totalSize);
                
                memcpy((char*)outputBufferList->mBuffers[i].mData + bytesCopied, bufferList->mBuffers[i].mData, bytesToCopy);
            }
        }
        
        TPCircularBufferConsumeNextBufferListPartial(buffer, bytesToCopy/audioFormat->mBytesPerFrame, audioFormat);
        
        bytesToGo -= bytesToCopy;
        bytesCopied += bytesToCopy;
    }
    
    *ioLengthInFrames -= bytesToGo / audioFormat->mBytesPerFrame;
}

static UInt32 _TPCircularBufferPeek(TPCircularBuffer *buffer, AudioTimeStamp *outTimestamp, AudioStreamBasicDescription *audioFormat, bool contiguous) {
    int32_t availableBytes;
    TPCircularBufferABLBlockHeader *block = (TPCircularBufferABLBlockHeader*)TPCircularBufferTail(buffer, &availableBytes);
    if ( !block ) return 0;
    assert(!((unsigned long)block & 0xF) /* Beware unaligned accesses */);
    
    if ( outTimestamp ) {
        memcpy(outTimestamp, &block->timestamp, sizeof(AudioTimeStamp));
    }
    
    void *end = (char*)block + availableBytes;
    
    UInt32 byteCount = 0;
    
    while ( 1 ) {
        byteCount += block->bufferList.mBuffers[0].mDataByteSize;
        TPCircularBufferABLBlockHeader *nextBlock = (TPCircularBufferABLBlockHeader*)((char*)block + block->totalLength);
        if ( (void*)nextBlock >= end || (contiguous && nextBlock->timestamp.mSampleTime != block->timestamp.mSampleTime + (block->bufferList.mBuffers[0].mDataByteSize / audioFormat->mBytesPerFrame)) ) {
            break;
        }
        assert(!((unsigned long)nextBlock & 0xF) /* Beware unaligned accesses */);
        block = nextBlock;
    }
    
    return byteCount / audioFormat->mBytesPerFrame;
}

UInt32 TPCircularBufferPeek(TPCircularBuffer *buffer, AudioTimeStamp *outTimestamp, AudioStreamBasicDescription *audioFormat) {
    return _TPCircularBufferPeek(buffer, outTimestamp, audioFormat, false);
}

UInt32 TPCircularBufferPeekContiguous(TPCircularBuffer *buffer, AudioTimeStamp *outTimestamp, AudioStreamBasicDescription *audioFormat) {
    return _TPCircularBufferPeek(buffer, outTimestamp, audioFormat, true);
}
