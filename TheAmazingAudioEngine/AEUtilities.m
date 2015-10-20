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

#import "AEUtilities.h"
#import <mach/mach_time.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

AudioBufferList *AEAudioBufferListCreate(AudioStreamBasicDescription audioFormat, int frameCount) {
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

AudioBufferList *AEAudioBufferListCopy(AudioBufferList *original) {
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

void AEAudioBufferListFree(AudioBufferList *bufferList ) {
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        if ( bufferList->mBuffers[i].mData ) free(bufferList->mBuffers[i].mData);
    }
    free(bufferList);
}

UInt32 AEAudioBufferListGetLength(AudioBufferList *bufferList,
                                  AudioStreamBasicDescription audioFormat,
                                  int *oNumberOfChannels) {
    int channelCount = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved
        ? bufferList->mNumberBuffers : bufferList->mBuffers[0].mNumberChannels;
    if ( oNumberOfChannels ) {
        *oNumberOfChannels = channelCount;
    }
    return bufferList->mBuffers[0].mDataByteSize / ((audioFormat.mBitsPerChannel/8) * channelCount);
}

void AEAudioBufferListSetLength(AudioBufferList *bufferList,
                                          AudioStreamBasicDescription audioFormat,
                                          UInt32 frames) {
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        bufferList->mBuffers[i].mDataByteSize = frames * audioFormat.mBytesPerFrame;
    }
}

void AEAudioBufferListOffset(AudioBufferList *bufferList,
                             AudioStreamBasicDescription audioFormat,
                             UInt32 frames) {
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        bufferList->mBuffers[i].mData = (char*)bufferList->mBuffers[i].mData + frames * audioFormat.mBytesPerFrame;
        bufferList->mBuffers[i].mDataByteSize -= frames * audioFormat.mBytesPerFrame;
    }
}

void AEAudioBufferListSilence(AudioBufferList *bufferList,
                              AudioStreamBasicDescription audioFormat,
                              UInt32 offset,
                              UInt32 length) {
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        memset((char*)bufferList->mBuffers[i].mData + offset * audioFormat.mBytesPerFrame,
               0,
               length ? length * audioFormat.mBytesPerFrame
                      : bufferList->mBuffers[i].mDataByteSize - offset * audioFormat.mBytesPerFrame);
    }
}

AudioStreamBasicDescription const AEAudioStreamBasicDescriptionNonInterleavedFloatStereo = {
    .mFormatID          = kAudioFormatLinearPCM,
    .mFormatFlags       = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    .mChannelsPerFrame  = 2,
    .mBytesPerPacket    = sizeof(float),
    .mFramesPerPacket   = 1,
    .mBytesPerFrame     = sizeof(float),
    .mBitsPerChannel    = 8 * sizeof(float),
    .mSampleRate        = 44100.0,
};

AudioStreamBasicDescription const AEAudioStreamBasicDescriptionNonInterleaved16BitStereo = {
    .mFormatID          = kAudioFormatLinearPCM,
    .mFormatFlags       = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsNonInterleaved,
    .mChannelsPerFrame  = 2,
    .mBytesPerPacket    = sizeof(SInt16),
    .mFramesPerPacket   = 1,
    .mBytesPerFrame     = sizeof(SInt16),
    .mBitsPerChannel    = 8 * sizeof(SInt16),
    .mSampleRate        = 44100.0,
};

AudioStreamBasicDescription const AEAudioStreamBasicDescriptionInterleaved16BitStereo = {
    .mFormatID          = kAudioFormatLinearPCM,
    .mFormatFlags       = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
    .mChannelsPerFrame  = 2,
    .mBytesPerPacket    = sizeof(SInt16)*2,
    .mFramesPerPacket   = 1,
    .mBytesPerFrame     = sizeof(SInt16)*2,
    .mBitsPerChannel    = 8 * sizeof(SInt16),
    .mSampleRate        = 44100.0,
};

AudioStreamBasicDescription AEAudioStreamBasicDescriptionMake(AEAudioStreamBasicDescriptionSampleType sampleType,
                                                              BOOL interleaved,
                                                              int numberOfChannels,
                                                              double sampleRate) {
    int sampleSize = sampleType == AEAudioStreamBasicDescriptionSampleTypeFloat32 ? 4 :
                     sampleType == AEAudioStreamBasicDescriptionSampleTypeInt16 ? 2 :
                     sampleType == AEAudioStreamBasicDescriptionSampleTypeInt32 ? 4 : 0;
    NSCAssert(sampleSize, @"Unrecognized sample type");
    
    return (AudioStreamBasicDescription) {
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = (sampleType == AEAudioStreamBasicDescriptionSampleTypeFloat32
                          ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian)
                        | kAudioFormatFlagIsPacked
                        | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
        .mChannelsPerFrame  = numberOfChannels,
        .mBytesPerPacket    = sampleSize * (interleaved ? numberOfChannels : 1),
        .mFramesPerPacket   = 1,
        .mBytesPerFrame     = sampleSize * (interleaved ? numberOfChannels : 1),
        .mBitsPerChannel    = 8 * sampleSize,
        .mSampleRate        = sampleRate,
    };
}

void AEAudioStreamBasicDescriptionSetChannelsPerFrame(AudioStreamBasicDescription *audioDescription, int numberOfChannels) {
    if ( !(audioDescription->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ) {
        audioDescription->mBytesPerFrame *= (float)numberOfChannels / (float)audioDescription->mChannelsPerFrame;
        audioDescription->mBytesPerPacket *= (float)numberOfChannels / (float)audioDescription->mChannelsPerFrame;
    }
    audioDescription->mChannelsPerFrame = numberOfChannels;
}

AudioComponentDescription AEAudioComponentDescriptionMake(OSType manufacturer, OSType type, OSType subtype) {
    AudioComponentDescription description;
    memset(&description, 0, sizeof(description));
    description.componentManufacturer = manufacturer;
    description.componentType = type;
    description.componentSubType = subtype;
    return description;
}

static void AETimeInit() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info_data_t tinfo;
        mach_timebase_info(&tinfo);
        __hostTicksToSeconds = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
        __secondsToHostTicks = 1.0 / __hostTicksToSeconds;
    });
}

uint64_t AECurrentTimeInHostTicks(void) {
    return mach_absolute_time();
}

double AECurrentTimeInSeconds(void) {
    if ( !__hostTicksToSeconds ) AETimeInit();
    return mach_absolute_time() * __hostTicksToSeconds;
}

uint64_t AEHostTicksFromSeconds(double seconds) {
    if ( !__secondsToHostTicks ) AETimeInit();
    assert(seconds >= 0);
    return seconds * __secondsToHostTicks;
}

double AESecondsFromHostTicks(uint64_t ticks) {
    if ( !__hostTicksToSeconds ) AETimeInit();
    return ticks * __hostTicksToSeconds;
}

BOOL AERateLimit(void) {
    static double lastMessage = 0;
    static int messageCount=0;
    double now = AECurrentTimeInSeconds();
    if ( now-lastMessage > 1 ) {
        messageCount = 0;
        lastMessage = now;
    }
    if ( ++messageCount >= 10 ) {
        if ( messageCount == 10 ) {
            NSLog(@"TAAE: Suppressing some messages");
        }
        return NO;
    }
    return YES;
}

