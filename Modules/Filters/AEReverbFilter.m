//
//  AEReverbFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AEReverbFilter.h"

#import "AEAudioController.h"

@implementation AEReverbFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_Effect, kAudioUnitSubType_Reverb2, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)dryWetMix {
    return [self getParameterValueForId:kReverb2Param_DryWetMix];
}

- (double)gain {
    return [self getParameterValueForId:kReverb2Param_Gain];
}

- (double)minDelayTime {
    return [self getParameterValueForId:kReverb2Param_MinDelayTime];
}

- (double)maxDelayTime {
    return [self getParameterValueForId:kReverb2Param_MaxDelayTime];
}

- (double)decayTimeAt0Hz {
    return [self getParameterValueForId:kReverb2Param_DecayTimeAt0Hz];
}

- (double)decayTimeAtNyquist {
    return [self getParameterValueForId:kReverb2Param_DecayTimeAtNyquist];
}

- (double)randomizeReflections {
    return [self getParameterValueForId:kReverb2Param_RandomizeReflections];
}

- (double)filterFrequency {
    return [self getParameterValueForId:kReverbParam_FilterFrequency];
}

- (double)filterBandwidth {
    return [self getParameterValueForId:kReverbParam_FilterBandwidth];
}

- (double)filterGain {
    return [self getParameterValueForId:kReverbParam_FilterGain];
}


#pragma mark - Setters

- (void)setDryWetMix:(double)dryWetMix {
    [self setParameterValue: dryWetMix
                      forId: kReverb2Param_DryWetMix];
}

- (void)setGain:(double)gain {
    [self setParameterValue: gain
                      forId: kReverb2Param_Gain];
}

- (void)setMinDelayTime:(double)minDelayTime {
    [self setParameterValue: minDelayTime
                      forId: kReverb2Param_MinDelayTime];
}

- (void)setMaxDelayTime:(double)maxDelayTime {
    [self setParameterValue: maxDelayTime
                      forId: kReverb2Param_MaxDelayTime];
}

- (void)setDecayTimeAt0Hz:(double)decayTimeAt0Hz {
    [self setParameterValue: decayTimeAt0Hz
                      forId: kReverb2Param_DecayTimeAt0Hz];
}

- (void)setDecayTimeAtNyquist:(double)decayTimeAtNyquist {
    [self setParameterValue: decayTimeAtNyquist
                      forId: kReverb2Param_DecayTimeAtNyquist];
}

- (void)setRandomizeReflections:(double)randomizeReflections {
    [self setParameterValue: randomizeReflections
                      forId: kReverb2Param_RandomizeReflections];
}

- (void)setFilterFrequency:(double)filterFrequency {
    [self setParameterValue: filterFrequency
                      forId: kReverbParam_FilterFrequency];
}

- (void)setFilterBandwidth:(double)filterBandwidth {
    [self setParameterValue: filterBandwidth
                      forId: kReverbParam_FilterBandwidth];
}

- (void)setFilterGain:(double)filterGain {
    [self setParameterValue: filterGain
                      forId: kReverbParam_FilterGain];
}

@end
