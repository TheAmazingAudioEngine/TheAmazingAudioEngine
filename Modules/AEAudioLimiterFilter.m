//
//  AEAudioLimiterFilter.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEAudioLimiterFilter.h"
#import "AEAudioLimiter.h"
#import <Accelerate/Accelerate.h>

const int kScratchBufferLength = 8192;

@interface AEAudioLimiterFilter () {
    AEAudioLimiter *_limiter;
    float *_scratchBuffer[2];
}
@end

@implementation AEAudioLimiterFilter
@synthesize hold = _hold, attack = _attack, decay = _decay, level = _level;

- (id)init {
    if ( !(self = [super init]) ) return nil;
    
    _limiter = [[AEAudioLimiter alloc] init];
    _hold = _limiter.hold;
    _attack = _limiter.attack;
    _decay = _limiter.decay;
    _level = _limiter.level;
    _scratchBuffer[0] = malloc(sizeof(float) * kScratchBufferLength);
    _scratchBuffer[1] = malloc(sizeof(float) * kScratchBufferLength);
    
    return self;
}

-(void)dealloc {
    [_limiter release];
    free(_scratchBuffer[0]);
    free(_scratchBuffer[1]);
    [super dealloc];
}

-(void)setHold:(UInt32)hold {
    _limiter.hold = hold;
}

-(void)setAttack:(UInt32)attack {
    _limiter.attack = attack;
}

-(void)setDecay:(UInt32)decay {
    _limiter.decay = decay;
}

-(void)setLevel:(float)level {
    _limiter.level = level;
}

static void filterCallback(id                        receiver,
                           AEAudioController        *audioController,
                           void                     *source,
                           const AudioTimeStamp     *time,
                           UInt32                    frames,
                           AudioBufferList          *audio) {
    
    assert(frames < kScratchBufferLength);
    AEAudioLimiterFilter *THIS = receiver;
    
    // Copy buffer into floating point scratch buffer
    vDSP_vflt16(audio->mBuffers[0].mData, audio->mBuffers[0].mNumberChannels, THIS->_scratchBuffer[0], 1, frames);
    if ( audio->mBuffers[0].mNumberChannels == 2 ) {
        vDSP_vflt16((SInt16*)audio->mBuffers[0].mData+1, audio->mBuffers[0].mNumberChannels, THIS->_scratchBuffer[1], 1, frames);
    } else if ( audio->mNumberBuffers == 2 ) {
        vDSP_vflt16(audio->mBuffers[1].mData, 1, THIS->_scratchBuffer[1], 1, frames);
    }
    
    AEAudioLimiterEnqueue(THIS->_limiter, THIS->_scratchBuffer, MAX(audio->mBuffers[0].mNumberChannels, audio->mNumberBuffers), frames);
    AEAudioLimiterDequeue(THIS->_limiter, THIS->_scratchBuffer, MAX(audio->mBuffers[0].mNumberChannels, audio->mNumberBuffers), &frames);
    
    if ( frames > 0 ) {
        // Convert back to buffer
        vDSP_vfix16(THIS->_scratchBuffer[0], audio->mBuffers[0].mNumberChannels, audio->mBuffers[0].mData, 1, frames);
        if ( audio->mBuffers[0].mNumberChannels == 2 ) {
            vDSP_vfix16(THIS->_scratchBuffer[1], audio->mBuffers[0].mNumberChannels, (SInt16*)audio->mBuffers[0].mData+1, 1, frames);
        } else if ( audio->mNumberBuffers == 2 ) {
            vDSP_vfix16(THIS->_scratchBuffer[1], 1, audio->mBuffers[1].mData, 1, frames);
        }
    }
}

-(AEAudioControllerAudioCallback)filterCallback {
    return filterCallback;
}

@end
