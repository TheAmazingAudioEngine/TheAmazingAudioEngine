//
//  AEHighPassFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AEHighPassFilter.h"

@implementation AEHighPassFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_Effect, kAudioUnitSubType_HighPassFilter, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)cutoffFrequency {
    return [self getParameterValueForId:kHipassParam_CutoffFrequency];
}

- (double)resonance {
    return [self getParameterValueForId:kHipassParam_Resonance];
}


#pragma mark - Setters

- (void)setCutoffFrequency:(double)cutoffFrequency {
    [self setParameterValue: cutoffFrequency
                      forId: kHipassParam_CutoffFrequency];
}

- (void)setResonance:(double)resonance {
    [self setParameterValue: resonance
                      forId: kHipassParam_Resonance];
}

@end
