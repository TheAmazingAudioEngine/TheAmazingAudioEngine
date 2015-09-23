//
//  AEHighShelfFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AEHighShelfFilter.h"

@implementation AEHighShelfFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_Effect, kAudioUnitSubType_HighShelfFilter, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)cutoffFrequency {
    return [self getParameterValueForId:kHighShelfParam_CutOffFrequency];
}

- (double)gain {
    return [self getParameterValueForId:kHighShelfParam_Gain];
}


#pragma mark - Setters

- (void)setCutoffFrequency:(double)cutoffFrequency {
    [self setParameterValue: cutoffFrequency
                      forId: kHighShelfParam_CutOffFrequency];
}

- (void)setGain:(double)gain {
    [self setParameterValue: gain
                      forId: kHighShelfParam_Gain];
}

@end
