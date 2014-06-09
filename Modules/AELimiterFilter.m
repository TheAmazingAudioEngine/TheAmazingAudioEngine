//
//  AELimiterFilter.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/04/2012.
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

#import "AELimiterFilter.h"
#import "AELimiter.h"
#import "AEFloatConverter.h"
#import <Accelerate/Accelerate.h>

const int kScratchBufferLength = 8192;

@interface AELimiterFilter () {
    float **_scratchBuffer;
}
@property (nonatomic, strong) AEFloatConverter *floatConverter;
@property (nonatomic, strong) AELimiter *limiter;
@property (nonatomic, weak) AEAudioController *audioController;
@end

@implementation AELimiterFilter
@synthesize floatConverter = _floatConverter, limiter = _limiter, clientFormat = _clientFormat, audioController = _audioController;
@dynamic hold, attack, decay, level;

- (id)initWithAudioController:(AEAudioController *)audioController {
    if ( !(self = [super init]) ) return nil;
    
    self.audioController = audioController;
    _clientFormat = audioController.audioDescription;
    self.floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:_clientFormat];
    self.limiter = [[AELimiter alloc] initWithNumberOfChannels:_clientFormat.mChannelsPerFrame sampleRate:_clientFormat.mSampleRate];
    
    _scratchBuffer = (float**)malloc(sizeof(float*) * _clientFormat.mChannelsPerFrame);
    assert(_scratchBuffer);
    for ( int i=0; i<_clientFormat.mChannelsPerFrame; i++ ) {
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
    self.audioController = nil;
}

-(void)setClientFormat:(AudioStreamBasicDescription)clientFormat {
    
    AEFloatConverter *floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:clientFormat];
    
    float **scratchBuffer = (float**)malloc(sizeof(float*) * clientFormat.mChannelsPerFrame);
    assert(scratchBuffer);
    for ( int i=0; i<clientFormat.mChannelsPerFrame; i++ ) {
        scratchBuffer[i] = malloc(sizeof(float) * kScratchBufferLength);
        assert(scratchBuffer[i]);
    }
    
    AELimiter *limiter = [[AELimiter alloc] initWithNumberOfChannels:clientFormat.mChannelsPerFrame sampleRate:clientFormat.mSampleRate];
    float** oldScratchBuffer = _scratchBuffer;
    AudioStreamBasicDescription oldClientFormat = _clientFormat;
    
    [_audioController performSynchronousMessageExchangeWithBlock:^{
        _limiter = limiter;
        _floatConverter = floatConverter;
        _scratchBuffer = scratchBuffer;
        _clientFormat = clientFormat;
    }];
    
    for ( int i=0; i<oldClientFormat.mChannelsPerFrame; i++ ) {
        free(oldScratchBuffer[i]);
    }
    free(oldScratchBuffer);
}


-(void)setHold:(UInt32)hold {
    _limiter.hold = hold;
}

-(UInt32)hold {
    return _limiter.hold;
}

-(void)setAttack:(UInt32)attack {
    _limiter.attack = attack;
}

-(UInt32)attack {
    return _limiter.attack;
}

-(void)setDecay:(UInt32)decay {
    _limiter.decay = decay;
}

-(UInt32)decay {
    return _limiter.decay;
}

-(void)setLevel:(float)level {
    _limiter.level = level;
}

-(float)level {
    return _limiter.level;
}

static OSStatus filterCallback(__unsafe_unretained AELimiterFilter *THIS,
                               __unsafe_unretained AEAudioController *audioController,
                               AEAudioControllerFilterProducer producer,
                               void                     *producerToken,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    
    assert(frames < kScratchBufferLength);
    
    OSStatus status = producer(producerToken, audio, &frames);
    if ( status != noErr ) return status;
    
    // Copy buffer into floating point scratch buffer
    AEFloatConverterToFloat(THIS->_floatConverter, audio, THIS->_scratchBuffer, frames);
    
    AELimiterEnqueue(THIS->_limiter, THIS->_scratchBuffer, frames, NULL);
    AELimiterDequeue(THIS->_limiter, THIS->_scratchBuffer, &frames, NULL);
    
    if ( frames > 0 ) {
        // Convert back to buffer
        AEFloatConverterFromFloat(THIS->_floatConverter, THIS->_scratchBuffer, audio, frames);
    }
    
    return noErr;
}

-(AEAudioControllerFilterCallback)filterCallback {
    return filterCallback;
}

@end
