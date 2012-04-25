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

static inline long align16bit(long val) {
    if ( val & 0xF ) {
        return val + (0x10 - (val & 0xF));
    }
    return val;
}

static inline long min(long a, long b) {
    return a > b ? b : a;
}

AudioBufferList *TPCircularBufferPrepareEmptyAudioBufferList(TPCircularBuffer *buffer, int numberOfBuffers, int bytesPerBuffer, const AudioTimeStamp *inTimestamp) {
    int bufferListSize = sizeof(AudioBufferList) + ((numberOfBuffers-1) * sizeof(AudioBuffer));
    
    int32_t availableBytes;
    AudioTimeStamp *timestamp = (AudioTimeStamp*)TPCircularBufferHead(buffer, &availableBytes);
    if ( availableBytes < sizeof(AudioTimeStamp) + sizeof(UInt32) + bufferListSize ) return NULL;
    
    // Store timestamp, followed by a UInt32 defining the number of bytes from the start of the buffer list to the end of the segment, then the buffer list
    if ( inTimestamp ) {
        *timestamp = *inTimestamp;
    } else {
        memset(timestamp, 0, sizeof(AudioTimeStamp));
    }
    
    UInt32 *totalLengthInBytes = (UInt32*)(timestamp+1);
    
    AudioBufferList *list = (AudioBufferList*)(totalLengthInBytes+1);
    
    memset(list, 0, bufferListSize);
    
    list->mNumberBuffers = numberOfBuffers;
    
    char *dataPtr = (char*)list + bufferListSize;
    for ( int i=0; i<numberOfBuffers; i++ ) {
        // Find the next 16-byte aligned memory area
        dataPtr = (char*)align16bit((long)dataPtr);
        
        if ( (dataPtr + bytesPerBuffer) - (char*)timestamp > availableBytes ) {
            return NULL;
        }
        
        list->mBuffers[i].mData = dataPtr;
        list->mBuffers[i].mDataByteSize = bytesPerBuffer;
        list->mBuffers[i].mNumberChannels = 1;
        
        dataPtr += bytesPerBuffer;
    }
    
    *totalLengthInBytes = (dataPtr - (char*)list);
    
    return list;
}

void TPCircularBufferProduceAudioBufferList(TPCircularBuffer *buffer) {
    int32_t availableBytes;
    AudioTimeStamp *timestamp = (AudioTimeStamp*)TPCircularBufferHead(buffer, &availableBytes);
    UInt32 *totalLengthInBytes = (UInt32*)(timestamp+1);

    AudioBufferList *list = (AudioBufferList*)(totalLengthInBytes+1);
    UInt32 calculatedLength = ((char*)list->mBuffers[list->mNumberBuffers-1].mData + list->mBuffers[list->mNumberBuffers-1].mDataByteSize) - (char*)list;
    assert(calculatedLength < *totalLengthInBytes && sizeof(AudioTimeStamp)+sizeof(UInt32)+calculatedLength <= availableBytes);
    
    *totalLengthInBytes = calculatedLength;
    
    TPCircularBufferProduce(buffer, 
                            sizeof(AudioTimeStamp) +
                            sizeof(UInt32) +
                            *totalLengthInBytes);
}

bool TPCircularBufferCopyAudioBufferList(TPCircularBuffer *buffer, const AudioBufferList *bufferList, const AudioTimeStamp *inTimestamp) {
    int bufferListSize = sizeof(AudioBufferList) + ((bufferList->mNumberBuffers-1) * sizeof(AudioBuffer));
    
    int32_t availableBytes;
    AudioTimeStamp *timestamp = (AudioTimeStamp*)TPCircularBufferHead(buffer, &availableBytes);
    if ( availableBytes < sizeof(AudioTimeStamp) + bufferListSize ) return false;
    
    // Store timestamp, followed by buffer list
    if ( inTimestamp ) {
        *timestamp = *inTimestamp;
    } else {
        memset(timestamp, 0, sizeof(AudioTimeStamp));
    }
    
    UInt32 *totalLengthInBytes = (UInt32*)(timestamp+1);
    
    AudioBufferList *list = (AudioBufferList*)(totalLengthInBytes+1);
    
    memcpy(list, bufferList, bufferListSize);
    
    char *dataPtr = (char*)list + bufferListSize;
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        // Find the next 16-byte aligned memory area
        dataPtr = (char*)align16bit((long)dataPtr);
        
        if ( (dataPtr + bufferList->mBuffers[i].mDataByteSize) - (char*)timestamp > availableBytes ) {
            return false;
        }
        
        assert(bufferList->mBuffers[i].mData != NULL);
        
        list->mBuffers[i].mData = dataPtr;
        memcpy(dataPtr, bufferList->mBuffers[i].mData, bufferList->mBuffers[i].mDataByteSize);
        dataPtr += bufferList->mBuffers[i].mDataByteSize;
    }
    
    *totalLengthInBytes = (dataPtr-(char*)list);
    
    TPCircularBufferProduce(buffer, dataPtr-(char*)timestamp);
    
    return true;
}

AudioBufferList *TPCircularBufferNextBufferListAfter(TPCircularBuffer *buffer, AudioBufferList *bufferList, AudioTimeStamp *outTimestamp) {
    int32_t availableBytes;
    AudioTimeStamp *firstTimestamp = TPCircularBufferTail(buffer, &availableBytes);
    void *end = (char*)firstTimestamp + availableBytes;
    
    assert((void*)bufferList > (void*)firstTimestamp && (void*)bufferList < end);
    
    UInt32 *len = ((UInt32*)bufferList)-1;
    
    AudioTimeStamp *timestamp = (AudioTimeStamp*)((char*)bufferList + *len);
    if ( (void*)timestamp >= end ) return NULL;
    
    if ( outTimestamp ) {
        *outTimestamp = *timestamp;
    }
    
    return (AudioBufferList*)(((char*)timestamp)+sizeof(AudioTimeStamp)+sizeof(UInt32));
}

void TPCircularBufferConsumeNextBufferListPartial(TPCircularBuffer *buffer, int framesToConsume, AudioStreamBasicDescription *audioFormat) {
    int32_t dontcare;
    AudioTimeStamp *timestamp = TPCircularBufferTail(buffer, &dontcare);
    if ( !timestamp ) return;
    
    int bytesToConsume = framesToConsume * audioFormat->mBytesPerFrame;
    
    AudioBufferList *bufferList = (AudioBufferList*)(((char*)timestamp)+sizeof(AudioTimeStamp)+sizeof(UInt32));
    
    if ( bytesToConsume == bufferList->mBuffers[0].mDataByteSize ) {
        TPCircularBufferConsumeNextBufferList(buffer);
        return;
    }
    
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        bufferList->mBuffers[i].mData = (char*)bufferList->mBuffers[i].mData + bytesToConsume;
        bufferList->mBuffers[i].mDataByteSize -= bytesToConsume;
    }
    
    if ( timestamp->mFlags & kAudioTimeStampSampleTimeValid ) timestamp->mSampleTime += framesToConsume;
    if ( timestamp->mFlags & kAudioTimeStampHostTimeValid ) {
        if ( !__secondsToHostTicks ) {
            mach_timebase_info_data_t tinfo;
            mach_timebase_info(&tinfo);
            __secondsToHostTicks = 1.0 / ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
        }
        timestamp->mHostTime += ((double)framesToConsume / audioFormat->mSampleRate) * __secondsToHostTicks;
    }
}

void TPCircularBufferConsumeBufferListFrames(TPCircularBuffer *buffer, UInt32 *ioLengthInFrames, AudioBufferList *outputBufferList, AudioTimeStamp *outTimestamp, AudioStreamBasicDescription *audioFormat) {
    bool hasTimestamp = false;
    UInt32 bytesToGo = *ioLengthInFrames * audioFormat->mBytesPerFrame;
    UInt32 bytesCopied = 0;
    while ( bytesToGo > 0 ) {
        AudioBufferList *bufferList = TPCircularBufferNextBufferList(buffer, hasTimestamp ? outTimestamp : NULL);
        hasTimestamp = true;
        if ( !bufferList ) break;
        
        UInt32 bytesToCopy = min(bytesToGo, bufferList->mBuffers[0].mDataByteSize);
        
        if ( outputBufferList ) {
            for ( int i=0; i<outputBufferList->mNumberBuffers; i++ ) {
                memcpy((char*)outputBufferList->mBuffers[i].mData + bytesCopied, bufferList->mBuffers[i].mData, bytesToCopy);
            }
        }
        
        if ( bytesToCopy == bufferList->mBuffers[0].mDataByteSize ) {
            TPCircularBufferConsumeNextBufferList(buffer);
        } else {
            TPCircularBufferConsumeNextBufferListPartial(buffer, bytesToCopy/audioFormat->mBytesPerFrame, audioFormat);
        }
        
        bytesToGo -= bytesToCopy;
        bytesCopied += bytesToCopy;
    }
    
    *ioLengthInFrames -= bytesToGo / audioFormat->mBytesPerFrame;
}

UInt32 TPCircularBufferPeek(TPCircularBuffer *buffer, AudioTimeStamp *outTimestamp, AudioStreamBasicDescription *audioFormat) {
    UInt32 frameCount = 0;
    
    int32_t availableBytes;
    AudioTimeStamp *timestamp = TPCircularBufferTail(buffer, &availableBytes);
    if ( timestamp && outTimestamp ) {
        *outTimestamp = *timestamp;
    }
    
    if ( !timestamp ) return 0;
    
    void *end = (char*)timestamp + availableBytes;
    
    while ( (void*)timestamp < end ) {
        UInt32 *lengthInBytes = (UInt32*)(timestamp+1);
        AudioBufferList *bufferList = (AudioBufferList*)(lengthInBytes+1);
        frameCount += bufferList->mBuffers[0].mDataByteSize / audioFormat->mBytesPerFrame;
        timestamp = (AudioTimeStamp*)((char*)(lengthInBytes+1) + *lengthInBytes);
    }
    
    return frameCount;
}
