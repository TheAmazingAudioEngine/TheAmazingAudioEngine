//
//  AELowShelfFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AELowShelfFilter.h"

@implementation AELowShelfFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_Effect, kAudioUnitSubType_LowShelfFilter, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)cutoffFrequency {
    return [self getParameterValueForId:kAULowShelfParam_CutoffFrequency];
}

- (double)gain {
    return [self getParameterValueForId:kAULowShelfParam_Gain];
}


#pragma mark - Setters

- (void)setCutoffFrequency:(double)cutoffFrequency {
    [self setParameterValue: cutoffFrequency
                      forId: kAULowShelfParam_CutoffFrequency];
}

- (void)setGain:(double)gain {
    [self setParameterValue: gain
                      forId: kAULowShelfParam_Gain];
}

@end
