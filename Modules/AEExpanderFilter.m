//
//  AEExpanderFilter.m
//  Loopy
//
//  Created by Michael Tyson on 09/07/2011.
//  Copyright 2011 A Tasty Pixel. All rights reserved.
//

#import "AEExpanderFilter.h"
#import <Accelerate/Accelerate.h>
#import <libkern/OSAtomic.h>
#import <mach/mach_time.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

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

#define kScratchBufferSize 8192
#define kCalibrationTime 2.0
#define kCalibrationThresholdOffset 3.0 // dB
#define kMaxAutoThreshold -5.0
#define kMaxChannels 8

typedef void (^AECalibrateCompletionBlock)(void);

@interface AEExpanderFilter ()  {
    float        _maxValue;
    float       *_scratchBuffer[kMaxChannels];
    int          _configuredChannels;
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
@end

@implementation AEExpanderFilter
@synthesize ratio = _ratio, attack = _attack, decay = _decay, calibrateCompletionBlock = _calibrateCompletionBlock;
@dynamic threshold, hysteresis;

+(void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    __hostTicksToSeconds = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
    __secondsToHostTicks = 1.0 / __hostTicksToSeconds;
}

- (id)init {
    if ( !(self = [super init]) ) return nil;
    
    _scratchBuffer[0] = (float*)malloc(sizeof(float) * kScratchBufferSize);
    _scratchBuffer[1] = (float*)malloc(sizeof(float) * kScratchBufferSize);
    _configuredChannels = 2;
    
    self.threshold = -13.0;
    
    [self assignPreset:AEExpanderFilterPresetPercussive];
    
    _state = kStateClosed;
    _multiplier = 0.0;
    
    return self;
}

- (void)dealloc {
    for ( int i=0; i<_configuredChannels; i++ ) free(_scratchBuffer[i]);
    [super dealloc];
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
    _calibrationStartTime = mach_absolute_time();
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

struct reconfigureChannels_t { AEExpanderFilter *filter; int numberOfChannels; };
static void reconfigureChannels(AEAudioController *audioController, void *userInfo, int len) {
    struct reconfigureChannels_t *arg = userInfo;
    AEExpanderFilter *THIS = arg->filter;
    
    if ( THIS->_configuredChannels >= arg->numberOfChannels ) return;
    
    for ( int i=THIS->_configuredChannels; i<arg->numberOfChannels; i++ ) {
        THIS->_scratchBuffer[i] = (float*)malloc(sizeof(float) * kScratchBufferSize);
    }
    
    OSMemoryBarrier();
    
    THIS->_configuredChannels = arg->numberOfChannels;
}

static void completeCalibration(AEAudioController *audioController, void *userInfo, int len) {
    AEExpanderFilter *THIS = *(AEExpanderFilter**)userInfo;
    THIS->_threshold = min((THIS->_calibrationMaxValue + kCalibrationThresholdOffset),
                           ratio_from_db(kMaxAutoThreshold) * INT16_MAX) * THIS->_thresholdOffset;
    double threshold_db = db_from_value(THIS->_threshold);
    THIS->_offThreshold = ratio_from_db(threshold_db - THIS->_hysteresis_db) * INT16_MAX;
    
    THIS->_calibrateCompletionBlock();
    [THIS->_calibrateCompletionBlock release];
    THIS->_calibrateCompletionBlock = nil;
}

static void filterCallback(id                        receiver,
                           AEAudioController        *audioController,
                           void                     *source,
                           const AudioTimeStamp     *time,
                           UInt32                    frames,
                           AudioBufferList          *audio) {
    AEExpanderFilter *THIS = (AEExpanderFilter*)receiver;
    
    AudioStreamBasicDescription *asbd = AEAudioControllerAudioDescription(audioController);
    assert(asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    
    if ( audio->mNumberBuffers > THIS->_configuredChannels ) {
        AEAudioControllerSendAsynchronousMessageToMainThread(audioController, 
                                                             reconfigureChannels, 
                                                             &(struct reconfigureChannels_t){ .filter = THIS, .numberOfChannels = audio->mNumberBuffers}, 
                                                             sizeof(struct reconfigureChannels_t));
        return;
    }
    
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
        
        if ( mach_absolute_time()-THIS->_calibrationStartTime >= kCalibrationTime*__secondsToHostTicks ) {
            THIS->_calibrationStartTime = 0;
            AEAudioControllerSendAsynchronousMessageToMainThread(audioController, completeCalibration, &THIS, sizeof(AEExpanderFilter*));
            return;
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
            return;
            break;
        case kStateClosed:
            for ( int i=0; i<audio->mNumberBuffers; i++ ) {
                vDSP_vsmul(THIS->_scratchBuffer[i], 1, &THIS->_ratio, THIS->_scratchBuffer[i], 1, frames);
            }
            break;
            
        case kStateClosing: {
            // Apply a ramp to the first part of the buffer
            UInt32 decayFrames = AEConvertSecondsToFrames(audioController, THIS->_decay);
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
            UInt32 attackFrames = AEConvertSecondsToFrames(audioController, THIS->_attack);
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
}

- (AEAudioControllerAudioCallback)filterCallback {
    return filterCallback;
}

@end
