//
//  AEPeakLimiterFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AEPeakLimiterFilter.h"

@implementation AEPeakLimiterFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_Effect, kAudioUnitSubType_PeakLimiter, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)attackTime {
    return [self getParameterValueForId:kLimiterParam_AttackTime];
}

- (double)decayTime {
    return [self getParameterValueForId:kLimiterParam_DecayTime];
}

- (double)preGain {
    return [self getParameterValueForId:kLimiterParam_PreGain];
}


#pragma mark - Setters

- (void)setAttackTime:(double)attackTime {
    [self setParameterValue: attackTime
                      forId: kLimiterParam_AttackTime];
}

- (void)setDecayTime:(double)decayTime {
    [self setParameterValue: decayTime
                      forId: kLimiterParam_DecayTime];
}

- (void)setPreGain:(double)preGain {
    [self setParameterValue: preGain
                      forId: kLimiterParam_PreGain];
}

@end
