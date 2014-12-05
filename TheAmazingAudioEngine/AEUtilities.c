//
//  AEUtilities.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 23/03/2012.
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

#include "AEUtilities.h"

AudioBufferList *AEAllocateAndInitAudioBufferList(AudioStreamBasicDescription audioFormat, int frameCount) {
    int numberOfBuffers = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? audioFormat.mChannelsPerFrame : 1;
    int channelsPerBuffer = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : audioFormat.mChannelsPerFrame;
    int bytesPerBuffer = audioFormat.mBytesPerFrame * frameCount;
    
    AudioBufferList *audio = malloc(sizeof(AudioBufferList) + (numberOfBuffers-1)*sizeof(AudioBuffer));
    if ( !audio ) {
        return NULL;
    }
    audio->mNumberBuffers = numberOfBuffers;
    for ( int i=0; i<numberOfBuffers; i++ ) {
        if ( bytesPerBuffer > 0 ) {
            audio->mBuffers[i].mData = calloc(bytesPerBuffer, 1);
            if ( !audio->mBuffers[i].mData ) {
                for ( int j=0; j<i; j++ ) free(audio->mBuffers[j].mData);
                free(audio);
                return NULL;
            }
        } else {
            audio->mBuffers[i].mData = NULL;
        }
        audio->mBuffers[i].mDataByteSize = bytesPerBuffer;
        audio->mBuffers[i].mNumberChannels = channelsPerBuffer;
    }
    return audio;
}

AudioBufferList *AECopyAudioBufferList(AudioBufferList *original) {
    AudioBufferList *audio = malloc(sizeof(AudioBufferList) + (original->mNumberBuffers-1)*sizeof(AudioBuffer));
    if ( !audio ) {
        return NULL;
    }
    audio->mNumberBuffers = original->mNumberBuffers;
    for ( int i=0; i<original->mNumberBuffers; i++ ) {
        audio->mBuffers[i].mData = malloc(original->mBuffers[i].mDataByteSize);
        if ( !audio->mBuffers[i].mData ) {
            for ( int j=0; j<i; j++ ) free(audio->mBuffers[j].mData);
            free(audio);
            return NULL;
        }
        audio->mBuffers[i].mDataByteSize = original->mBuffers[i].mDataByteSize;
        audio->mBuffers[i].mNumberChannels = original->mBuffers[i].mNumberChannels;
        memcpy(audio->mBuffers[i].mData, original->mBuffers[i].mData, original->mBuffers[i].mDataByteSize);
    }
    return audio;
}

void AEFreeAudioBufferList(AudioBufferList *bufferList ) {
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        if ( bufferList->mBuffers[i].mData ) free(bufferList->mBuffers[i].mData);
    }
    free(bufferList);
}

void AEInitAudioBufferList(AudioBufferList *list, int listSize, AudioStreamBasicDescription audioFormat, void *data, int dataSize) {
    list->mNumberBuffers = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? audioFormat.mChannelsPerFrame : 1;
    assert(list->mNumberBuffers == 1 || listSize >= (sizeof(AudioBufferList)+sizeof(AudioBuffer)) );
    
    for ( int i=0; i<list->mNumberBuffers; i++ ) {
        list->mBuffers[0].mNumberChannels = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : audioFormat.mChannelsPerFrame;
        list->mBuffers[0].mData = (char*)data + (i * (dataSize/list->mNumberBuffers));
        list->mBuffers[0].mDataByteSize = dataSize/list->mNumberBuffers;
    }
}

int AEGetNumberOfFramesInAudioBufferList(AudioBufferList *list, AudioStreamBasicDescription audioFormat, int *oNumberOfChannels) {
    int channelCount = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? list->mNumberBuffers : list->mBuffers[0].mNumberChannels;
    if ( oNumberOfChannels ) {
        *oNumberOfChannels = channelCount;
    }
    return list->mBuffers[0].mDataByteSize / ((audioFormat.mBitsPerChannel/8) * channelCount);
}

AudioComponentDescription AEAudioComponentDescriptionMake(OSType manufacturer, OSType type, OSType subtype) {
    AudioComponentDescription description;
    memset(&description, 0, sizeof(description));
    description.componentManufacturer = manufacturer;
    description.componentType = type;
    description.componentSubType = subtype;
    return description;
}

void AEAudioStreamBasicDescriptionSetChannelsPerFrame(AudioStreamBasicDescription *audioDescription, int numberOfChannels) {
    if ( !(audioDescription->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ) {
        audioDescription->mBytesPerFrame *= (float)numberOfChannels / (float)audioDescription->mChannelsPerFrame;
        audioDescription->mBytesPerPacket *= (float)numberOfChannels / (float)audioDescription->mChannelsPerFrame;
    }
    audioDescription->mChannelsPerFrame = numberOfChannels;
}