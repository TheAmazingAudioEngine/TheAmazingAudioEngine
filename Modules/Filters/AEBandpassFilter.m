//
//  AEBandpassFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AEBandpassFilter.h"

@implementation AEBandpassFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_Effect, kAudioUnitSubType_BandPassFilter, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)centerFrequency {
    return [self getParameterValueForId:kBandpassParam_CenterFrequency];
}

- (double)bandwidth {
    return [self getParameterValueForId:kBandpassParam_Bandwidth];
}

#pragma mark - Setters

- (void)setCenterFrequency:(double)centerFrequency {
    [self setParameterValue: centerFrequency
                      forId: kBandpassParam_CenterFrequency];
}

- (void)setBandwidth:(double)bandwidth {
    [self setParameterValue: bandwidth
                      forId: kBandpassParam_Bandwidth];
}

@end
