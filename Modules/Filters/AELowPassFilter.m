//
//  AELowPassFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AELowPassFilter.h"

@implementation AELowPassFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_Effect, kAudioUnitSubType_LowPassFilter, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)cutoffFrequency {
    return [self getParameterValueForId:kLowPassParam_CutoffFrequency];
}

- (double)resonance {
    return [self getParameterValueForId:kLowPassParam_Resonance];
}


#pragma mark - Setters

- (void)setCutoffFrequency:(double)cutoffFrequency {
    [self setParameterValue: cutoffFrequency
                      forId: kLowPassParam_CutoffFrequency];
}

- (void)setResonance:(double)resonance {
    [self setParameterValue: resonance
                      forId: kLowPassParam_Resonance];
}

@end
