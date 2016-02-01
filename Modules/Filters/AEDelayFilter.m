//
//  AEDelayFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AEDelayFilter.h"

@implementation AEDelayFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_Effect, kAudioUnitSubType_Delay, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)wetDryMix {
    return [self getParameterValueForId:kDelayParam_WetDryMix];
}

- (double)delayTime {
    return [self getParameterValueForId:kDelayParam_DelayTime];
}

- (double)feedback {
    return [self getParameterValueForId:kDelayParam_Feedback];
}

- (double)lopassCutoff {
    return [self getParameterValueForId:kDelayParam_LopassCutoff];
}


#pragma mark - Setters

- (void)setWetDryMix:(double)wetDryMix {
    [self setParameterValue: wetDryMix
                      forId: kDelayParam_WetDryMix];
}

- (void)setDelayTime:(double)delayTime {
    [self setParameterValue: delayTime
                      forId: kDelayParam_DelayTime];
}

- (void)setFeedback:(double)feedback {
    [self setParameterValue: feedback
                      forId: kDelayParam_Feedback];
}

- (void)setLopassCutoff:(double)lopassCutoff {
    [self setParameterValue: lopassCutoff
                      forId: kDelayParam_LopassCutoff];
}

@end
