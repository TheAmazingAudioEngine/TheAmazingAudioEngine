//
//  AEExpanderFilter.m
//  Loopy
//
//  Created by Michael Tyson on 09/07/2011.
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

#import "AEExpanderFilter.h"
#import <Accelerate/Accelerate.h>
#import "AEFloatConverter.h"
#import <libkern/OSAtomic.h>
#import "AEUtilities.h"

typedef enum {
    kStateClosed,
    kStateOpening,
    kStateOpen,
    kStateClosing
} AEExpanderFilterState;

static inline int min(int a, int b) { return (a>b ? b : a); }
static inline double ratio_from_db(float db) { return pow(10.0, db / 10.0); };
static inline double db_from_ratio(float value) { return 10.0 * log10(value); };
static inline double db_from_value(UInt16 value) { return db_from_ratio((double)value / INT16_MAX); };

#define kScratchBufferLength 8192
#define kCalibrationTime 2.0
#define kCalibrationThresholdOffset 3.0 // dB
#define kMaxAutoThreshold -5.0

typedef void (^AECalibrateCompletionBlock)(void);

@interface AEExpanderFilter ()  {
    AudioStreamBasicDescription _clientFormat;
    float        _maxValue;
    float      **_scratchBuffer;
    UInt16       _threshold;
    UInt16       _offThreshold;
    double       _thresholdOffset;
    double       _hysteresis_db;
    AEExpanderFilterPreset _preset;
    float        _multiplier;
    AEExpanderFilterState  _state;
    int          _calibrationMaxValue;
    uint64_t     _calibrationStartTime;
}

@property (nonatomic, copy) AECalibrateCompletionBlock calibrateCompletionBlock;
@property (nonatomic, strong) AEFloatConverter *floatConverter;
@property (nonatomic, weak) AEAudioController *audioController;
@end

@implementation AEExpanderFilter
@synthesize ratio = _ratio, attack = _attack, decay = _decay, calibrateCompletionBlock = _calibrateCompletionBlock, floatConverter = _floatConverter, audioController = _audioController;
@dynamic threshold, hysteresis;

- (id)initWithAudioController:(AEAudioController *)audioController {
    if ( !(self = [super init]) ) return nil;
    
    self.audioController = audioController;
    _clientFormat = audioController.audioDescription;
    
    self.floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:_clientFormat];
    
    _scratchBuffer = (float**)malloc(sizeof(float*) * _clientFormat.mChannelsPerFrame);
    assert(_scratchBuffer);
    for ( int i=0; i<_clientFormat.mChannelsPerFrame; i++ ) {
        _scratchBuffer[i] = malloc(sizeof(float) * kScratchBufferLength);
        assert(_scratchBuffer[i]);
    }
    
    self.threshold = -13.0;
    
    [self assignPreset:AEExpanderFilterPresetPercussive];
    
    _state = kStateClosed;
    _multiplier = 0.0;
    
    return self;
}

- (void)dealloc {
    for ( int i=0; i<_clientFormat.mChannelsPerFrame; i++ ) {
        free(_scratchBuffer[i]);
    }
    free(_scratchBuffer);
}

-(void)setClientFormat:(AudioStreamBasicDescription)clientFormat {
    
    AEFloatConverter *floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:clientFormat];
    
    float **scratchBuffer = (float**)malloc(sizeof(float*) * clientFormat.mChannelsPerFrame);
    assert(scratchBuffer);
    for ( int i=0; i<clientFormat.mChannelsPerFrame; i++ ) {
        scratchBuffer[i] = malloc(sizeof(float) * kScratchBufferLength);
        assert(scratchBuffer[i]);
    }
    
    float** oldScratchBuffer = _scratchBuffer;
    AudioStreamBasicDescription oldClientFormat = _clientFormat;
    
    [_audioController performSynchronousMessageExchangeWithBlock:^{
        _floatConverter = floatConverter;
        _scratchBuffer = scratchBuffer;
        _clientFormat = clientFormat;
    }];
    
    for ( int i=0; i<oldClientFormat.mChannelsPerFrame; i++ ) {
        free(oldScratchBuffer[i]);
    }
    free(oldScratchBuffer);
}

- (void)assignPreset:(AEExpanderFilterPreset)preset {
    _preset = preset;
    switch ( _preset ) {
        case AEExpanderFilterPresetSmooth:
            _ratio = 1.0/3.0;
            _hysteresis_db = 5.0;
            _thresholdOffset = ratio_from_db(10);
            self.attack = 0.005;
            self.decay = 0.05;
            break;
            
        case AEExpanderFilterPresetMedium:
            _ratio = 1.0/8.0;
            _hysteresis_db = 5.0;
            _thresholdOffset = ratio_from_db(0);
            self.attack = 0.005;
            self.decay = 0.1;
            break;
            
        case AEExpanderFilterPresetPercussive:
            _ratio = AEExpanderFilterRatioGateMode;
            _hysteresis_db = 5.0;
            _thresholdOffset = ratio_from_db(0);
            self.attack = 0.001;
            self.decay = 0.175;
            break;
            
        case AEExpanderFilterPresetNone:
            _thresholdOffset = ratio_from_db(0);
            break;
    }
}

- (void)startCalibratingWithCompletionBlock:(void (^)(void))block {
    self.calibrateCompletionBlock = block;
    _calibrationMaxValue = 2;
    OSMemoryBarrier();
    _calibrationStartTime = AECurrentTimeInHostTicks();
}

- (void)setRatio:(float)ratio {
    _ratio = ratio;
    _preset = AEExpanderFilterPresetNone;
}

-(void)setAttack:(NSTimeInterval)attack {
    _attack = attack;
    _preset = AEExpanderFilterPresetNone;
}

-(void)setDecay:(NSTimeInterval)decay {
    _decay = decay;
    _preset = AEExpanderFilterPresetNone;
}

-(void)setThreshold:(double)threshold {
    _thresholdOffset = ratio_from_db(0);
    _threshold = ratio_from_db(threshold) * INT16_MAX;
    _offThreshold = ratio_from_db(threshold - _hysteresis_db) * INT16_MAX;
}

-(double)threshold {
    double value = db_from_value(_threshold);
    if ( _thresholdOffset != 1.0 ) {
        value = MIN(kMaxAutoThreshold, value + db_from_ratio(_thresholdOffset));
    }
    return value;
}

-(void)setHysteresis:(double)hysteresis {
    _hysteresis_db = hysteresis;
    double threshold = db_from_value(_threshold);
    _offThreshold = ratio_from_db(threshold - _hysteresis_db) * INT16_MAX;
    _preset = AEExpanderFilterPresetNone;
}

-(double)hysteresis {
    return _hysteresis_db;
}

static void completeCalibration(AEAudioController *audioController, void *userInfo, int len) {
    __unsafe_unretained AEExpanderFilter *THIS = (__bridge AEExpanderFilter*)*(void**)userInfo;
    THIS->_threshold = min((THIS->_calibrationMaxValue + kCalibrationThresholdOffset),
                           ratio_from_db(kMaxAutoThreshold) * INT16_MAX) * THIS->_thresholdOffset;
    double threshold_db = db_from_value(THIS->_threshold);
    THIS->_offThreshold = ratio_from_db(threshold_db - THIS->_hysteresis_db) * INT16_MAX;
    
    THIS->_calibrateCompletionBlock();
    THIS->_calibrateCompletionBlock = nil;
}

static OSStatus filterCallback(__unsafe_unretained AEExpanderFilter *THIS,
                               __unsafe_unretained AEAudioController *audioController,
                               AEAudioControllerFilterProducer producer,
                               void                     *producerToken,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    
    OSStatus status = producer(producerToken, audio, &frames);
    if ( status != noErr ) return status;
    
    // Convert audio to floats on scratch buffer for processing, and find maxima
    float max = 0;
    for ( int i=0; i<audio->mNumberBuffers; i++ ) {
        vDSP_vflt16((SInt16*)audio->mBuffers[i].mData, 1, THIS->_scratchBuffer[i], 1, frames);
        float vmax = 0;
        vDSP_maxmgv(THIS->_scratchBuffer[i], 1, &vmax, frames);
        if ( vmax > max ) max = vmax;
    }
    
    
    if ( THIS->_calibrationStartTime ) {
        // Calibrating
        if ( max > THIS->_calibrationMaxValue ) THIS->_calibrationMaxValue = max;
        
        if ( AECurrentTimeInHostTicks()-THIS->_calibrationStartTime >= AEHostTicksFromSeconds(kCalibrationTime) ) {
            THIS->_calibrationStartTime = 0;
            AEAudioControllerSendAsynchronousMessageToMainThread(audioController, completeCalibration, &THIS, sizeof(AEExpanderFilter*));
            return noErr;
        }
    }
    
    // Update state for block
    switch ( THIS->_state ) {
        case kStateClosed:
        case kStateClosing:
            if ( max > THIS->_threshold / THIS->_thresholdOffset ) {
                THIS->_state = kStateOpening;
            }
            break;
            
        case kStateOpen:
        case kStateOpening:
            if ( max < THIS->_offThreshold / THIS->_thresholdOffset ) {
                THIS->_state = kStateClosing;
            }
            break;
    }
    
    // Apply to audio
    switch ( THIS->_state ) {
        case kStateOpen:
            return noErr;
            break;
        case kStateClosed:
            for ( int i=0; i<audio->mNumberBuffers; i++ ) {
                vDSP_vsmul(THIS->_scratchBuffer[i], 1, &THIS->_ratio, THIS->_scratchBuffer[i], 1, frames);
            }
            break;
            
        case kStateClosing: {
            // Apply a ramp to the first part of the buffer
            long decayFrames = AEConvertSecondsToFrames(audioController, THIS->_decay);
            int rampDuration = min(THIS->_multiplier * decayFrames, frames);
            float multiplierStart = (THIS->_multiplier * (1.0-THIS->_ratio)) + THIS->_ratio;
            float multiplierStep = -(1.0 / decayFrames) * (1.0-THIS->_ratio);
            if ( audio->mNumberBuffers == 2 ) {
                vDSP_vrampmul2(THIS->_scratchBuffer[0], THIS->_scratchBuffer[1], 1, &multiplierStart, &multiplierStep, THIS->_scratchBuffer[0], THIS->_scratchBuffer[1], 1, rampDuration);
            } else {
                for ( int i=0; i<audio->mNumberBuffers; i++ ) {
                    float mul = multiplierStart;
                    vDSP_vrampmul(THIS->_scratchBuffer[i], 1, &mul, &multiplierStep, THIS->_scratchBuffer[i], 1, rampDuration);
                }
            }
            
            THIS->_multiplier -= (1.0 / decayFrames) * rampDuration;
            if ( THIS->_multiplier < 1.0e-3 ) {
                THIS->_multiplier = 0.0;
                THIS->_state = kStateClosed;
            }
            
            // Then multiply by the ratio
            if ( decayFrames < frames ) {
                for ( int i=0; i<audio->mNumberBuffers; i++ ) {
                    vDSP_vsmul(THIS->_scratchBuffer[i]+decayFrames, 1, &THIS->_ratio, THIS->_scratchBuffer[i], 1, frames-decayFrames);
                }
            }
            break;
        }
            
        case kStateOpening: {
            // Apply a ramp to the first part of the buffer
            long attackFrames = AEConvertSecondsToFrames(audioController, THIS->_attack);
            int rampDuration = min((1.0-THIS->_multiplier) * attackFrames, frames);
            float multiplierStart = (THIS->_multiplier * (1.0-THIS->_ratio)) + THIS->_ratio;
            float multiplierStep = (1.0 / attackFrames) * (1.0-THIS->_ratio);
            if ( audio->mNumberBuffers == 2 ) {
                vDSP_vrampmul2(THIS->_scratchBuffer[0], THIS->_scratchBuffer[1], 1, &multiplierStart, &multiplierStep, THIS->_scratchBuffer[0], THIS->_scratchBuffer[1], 1, rampDuration);
            } else {
                for ( int i=0; i<audio->mNumberBuffers; i++ ) {
                    float mul = multiplierStart;
                    vDSP_vrampmul(THIS->_scratchBuffer[i], 1, &mul, &multiplierStep, THIS->_scratchBuffer[i], 1, rampDuration);
                }
            }
            
            THIS->_multiplier += (1.0 / attackFrames) * rampDuration;
            if ( THIS->_multiplier > 1.0-1.0e-3 ) {
                THIS->_multiplier = 1.0;
                THIS->_state = kStateOpen;
            }
                
            break;
        }
    }
    
    // Copy audio back to buffers
    for ( int i=0; i<audio->mNumberBuffers; i++ ) {
        vDSP_vfix16(THIS->_scratchBuffer[i], 1, (SInt16*)audio->mBuffers[i].mData, 1, frames);
    }
    
    return noErr;
}

-(AEAudioControllerFilterCallback)filterCallback {
    return filterCallback;
}

@end
