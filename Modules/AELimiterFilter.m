//
//  AELimiterFilter.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AELimiterFilter.h"
#import "AELimiter.h"
#import "AEFloatConverter.h"
#import <Accelerate/Accelerate.h>

const int kScratchBufferLength = 8192;

@interface AELimiterFilter () {
    float **_scratchBuffer;
}
@property (nonatomic, retain) AEFloatConverter *floatConverter;
@property (nonatomic, retain) AELimiter *limiter;
@property (nonatomic, assign) AEAudioController *audioController;
@end

@implementation AELimiterFilter
@synthesize floatConverter = _floatConverter, hold = _hold, attack = _attack, decay = _decay, level = _level, limiter = _limiter, clientFormat = _clientFormat, audioController = _audioController;

- (id)initWithAudioController:(AEAudioController *)audioController clientFormat:(AudioStreamBasicDescription)clientFormat {
    if ( !(self = [super init]) ) return nil;

    self.audioController = audioController;
    _clientFormat = clientFormat;
    self.floatConverter = [[[AEFloatConverter alloc] initWithSourceFormat:clientFormat] autorelease];
    self.limiter = [[[AELimiter alloc] init] autorelease];
    _hold = _limiter.hold;
    _attack = _limiter.attack;
    _decay = _limiter.decay;
    _level = _limiter.level;
    
    _scratchBuffer = (float**)malloc(sizeof(float**) * clientFormat.mChannelsPerFrame);
    assert(_scratchBuffer);
    for ( int i=0; i<clientFormat.mChannelsPerFrame; i++ ) {
        _scratchBuffer[i] = malloc(sizeof(float) * kScratchBufferLength);
        assert(_scratchBuffer[i]);
    }
    
    return self;
}

-(void)dealloc {
    for ( int i=0; i<_clientFormat.mChannelsPerFrame; i++ ) {
        free(_scratchBuffer[i]);
    }
    free(_scratchBuffer);
    self.floatConverter = nil;
    self.limiter = nil;
    self.audioController = nil;
    [super dealloc];
}

-(void)setClientFormat:(AudioStreamBasicDescription)clientFormat {
    
    AEFloatConverter *floatConverter = [[[AEFloatConverter alloc] initWithSourceFormat:clientFormat] autorelease];
    
    float **scratchBuffer = (float**)malloc(sizeof(float**) * clientFormat.mChannelsPerFrame);
    assert(scratchBuffer);
    for ( int i=0; i<clientFormat.mChannelsPerFrame; i++ ) {
        scratchBuffer[i] = malloc(sizeof(float) * kScratchBufferLength);
        assert(scratchBuffer[i]);
    }
    
    AEFloatConverter *oldFloatConverter = _floatConverter;
    float** oldScratchBuffer = _scratchBuffer;
    AudioStreamBasicDescription oldClientFormat = _clientFormat;
    
    [_audioController performSynchronousMessageExchangeWithBlock:^{
        _floatConverter = floatConverter;
        _scratchBuffer = scratchBuffer;
        _clientFormat = clientFormat;
    }];
    
    [oldFloatConverter release];
    for ( int i=0; i<oldClientFormat.mChannelsPerFrame; i++ ) {
        free(oldScratchBuffer[i]);
    }
    free(oldScratchBuffer);
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
    AELimiterFilter *THIS = receiver;
    
    // Copy buffer into floating point scratch buffer
    AEFloatConverterToFloat(THIS->_floatConverter, audio, THIS->_scratchBuffer, frames);
    
    AELimiterEnqueue(THIS->_limiter, THIS->_scratchBuffer, THIS->_clientFormat.mChannelsPerFrame, frames, NULL);
    AELimiterDequeue(THIS->_limiter, THIS->_scratchBuffer, THIS->_clientFormat.mChannelsPerFrame, &frames, NULL);
    
    if ( frames > 0 ) {
        // Convert back to buffer
        AEFloatConverterFromFloat(THIS->_floatConverter, THIS->_scratchBuffer, audio, frames);
    }
}

-(AEAudioControllerAudioCallback)filterCallback {
    return filterCallback;
}

@end
