//
//  AEParametricEqFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AEParametricEqFilter.h"

@implementation AEParametricEqFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_Effect, kAudioUnitSubType_ParametricEQ, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)centerFrequency {
    return [self getParameterValueForId:kParametricEQParam_CenterFreq];
}

- (double)qFactor {
    return [self getParameterValueForId:kParametricEQParam_Q];
}

- (double)gain {
    return [self getParameterValueForId:kParametricEQParam_Gain];
}


#pragma mark - Setters

- (void)setCenterFrequency:(double)centerFrequency {
    [self setParameterValue: centerFrequency
                      forId: kParametricEQParam_CenterFreq];
}

- (void)setQFactor:(double)qFactor {
    [self setParameterValue: qFactor
                      forId: kParametricEQParam_Q];
}

- (void)setGain:(double)gain {
    [self setParameterValue: gain
                      forId: kParametricEQParam_Gain];
}

@end
