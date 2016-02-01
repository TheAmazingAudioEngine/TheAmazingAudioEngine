//
//  AEDistortionFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AEDistortionFilter.h"

@implementation AEDistortionFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_Effect, kAudioUnitSubType_Distortion, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)delay {
    return [self getParameterValueForId:kDistortionParam_Delay];
}

- (double)decay {
    return [self getParameterValueForId:kDistortionParam_Decay];
}

- (double)delayMix {
    return [self getParameterValueForId:kDistortionParam_DelayMix];
}

- (double)decimation {
    return [self getParameterValueForId:kDistortionParam_Decimation];
}

- (double)rounding {
    return [self getParameterValueForId:kDistortionParam_Rounding];
}

- (double)decimationMix {
    return [self getParameterValueForId:kDistortionParam_DecimationMix];
}

- (double)linearTerm {
    return [self getParameterValueForId:kDistortionParam_LinearTerm];
}

- (double)squaredTerm {
    return [self getParameterValueForId:kDistortionParam_SquaredTerm];
}

- (double)cubicTerm {
    return [self getParameterValueForId:kDistortionParam_CubicTerm];
}

- (double)polynomialMix {
    return [self getParameterValueForId:kDistortionParam_PolynomialMix];
}

- (double)ringModFreq1 {
    return [self getParameterValueForId:kDistortionParam_RingModFreq1];
}

- (double)ringModFreq2 {
    return [self getParameterValueForId:kDistortionParam_RingModFreq2];
}

- (double)ringModBalance {
    return [self getParameterValueForId:kDistortionParam_RingModBalance];
}

- (double)ringModMix {
    return [self getParameterValueForId:kDistortionParam_RingModMix];
}

- (double)softClipGain {
    return [self getParameterValueForId:kDistortionParam_SoftClipGain];
}

- (double)finalMix {
    return [self getParameterValueForId:kDistortionParam_FinalMix];
}


#pragma mark - Setters

- (void)setDelay:(double)delay {
    [self setParameterValue: delay
                      forId: kDistortionParam_Delay];
}

- (void)setDecay:(double)decay {
    [self setParameterValue: decay
                      forId: kDistortionParam_Decay];
}

- (void)setDelayMix:(double)delayMix {
    [self setParameterValue: delayMix
                      forId: kDistortionParam_DelayMix];
}

- (void)setDecimation:(double)decimation {
    [self setParameterValue: decimation
                      forId: kDistortionParam_Decimation];
}

- (void)setRounding:(double)rounding {
    [self setParameterValue: rounding
                      forId: kDistortionParam_Rounding];
}

- (void)setDecimationMix:(double)decimationMix {
    [self setParameterValue: decimationMix
                      forId: kDistortionParam_DecimationMix];
}

- (void)setLinearTerm:(double)linearTerm {
    [self setParameterValue: linearTerm
                      forId: kDistortionParam_LinearTerm];
}

- (void)setSquaredTerm:(double)squaredTerm {
    [self setParameterValue: squaredTerm
                      forId: kDistortionParam_SquaredTerm];
}

- (void)setCubicTerm:(double)cubicTerm {
    [self setParameterValue: cubicTerm
                      forId: kDistortionParam_CubicTerm];
}

- (void)setPolynomialMix:(double)polynomialMix {
    [self setParameterValue: polynomialMix
                      forId: kDistortionParam_PolynomialMix];
}

- (void)setRingModFreq1:(double)ringModFreq1 {
    [self setParameterValue: ringModFreq1
                      forId: kDistortionParam_RingModFreq1];
}

- (void)setRingModFreq2:(double)ringModFreq2 {
    [self setParameterValue: ringModFreq2
                      forId: kDistortionParam_RingModFreq2];
}

- (void)setRingModBalance:(double)ringModBalance {
    [self setParameterValue: ringModBalance
                      forId: kDistortionParam_RingModBalance];
}

- (void)setRingModMix:(double)ringModMix {
    [self setParameterValue: ringModMix
                      forId: kDistortionParam_RingModMix];
}

- (void)setSoftClipGain:(double)softClipGain {
    [self setParameterValue: softClipGain
                      forId: kDistortionParam_SoftClipGain];
}

- (void)setFinalMix:(double)finalMix {
    [self setParameterValue: finalMix
                      forId: kDistortionParam_FinalMix];
}

@end
