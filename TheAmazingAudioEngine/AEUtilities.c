//
//  AEUtilities.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 23/03/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#include "AEUtilities.h"

int ABGetNumberOfFramesInAudioBufferList(AudioBufferList *list, AudioStreamBasicDescription *audioFormat, int *oNumberOfChannels) {
    int channelCount = audioFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved ? list->mNumberBuffers : list->mBuffers[0].mNumberChannels;
    if ( oNumberOfChannels ) {
        *oNumberOfChannels = channelCount;
    }
    return list->mBuffers[0].mDataByteSize / ((audioFormat->mBitsPerChannel/8) * channelCount);
}

void ABInitAudioBufferList(AudioBufferList *list, int listSize, AudioStreamBasicDescription *audioFormat, void *data, int dataSize) {
    list->mNumberBuffers = audioFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved ? audioFormat->mChannelsPerFrame : 1;
    assert(list->mNumberBuffers == 1 || listSize > (sizeof(AudioBufferList)+sizeof(AudioBuffer)) );
    
    for ( int i=0; i<list->mNumberBuffers; i++ ) {
        list->mBuffers[0].mNumberChannels = audioFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : audioFormat->mChannelsPerFrame;
        list->mBuffers[0].mData = (char*)data + (i * (dataSize/list->mNumberBuffers));
        list->mBuffers[0].mDataByteSize = dataSize/list->mNumberBuffers;
    }
}