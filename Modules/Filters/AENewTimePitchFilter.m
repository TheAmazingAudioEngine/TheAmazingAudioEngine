//
//  AENewTimePitchFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/27/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AENewTimePitchFilter.h"

@implementation AENewTimePitchFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_FormatConverter, kAudioUnitSubType_NewTimePitch, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)rate {
    return [self getParameterValueForId:kNewTimePitchParam_Rate];
}

- (double)pitch {
    return [self getParameterValueForId:kNewTimePitchParam_Pitch];
}

- (double)overlap {
    return [self getParameterValueForId:kNewTimePitchParam_Overlap];
}

- (double)enablePeakLocking {
    return [self getParameterValueForId:kNewTimePitchParam_EnablePeakLocking];
}


#pragma mark - Setters

- (void)setRate:(double)rate {
    [self setParameterValue: rate
                      forId: kNewTimePitchParam_Rate];
}

- (void)setPitch:(double)pitch {
    [self setParameterValue: pitch
                      forId: kNewTimePitchParam_Pitch];
}

- (void)setOverlap:(double)overlap {
    [self setParameterValue: overlap
                      forId: kNewTimePitchParam_Overlap];
}

- (void)setEnablePeakLocking:(double)enablePeakLocking {
    [self setParameterValue: enablePeakLocking
                      forId: kNewTimePitchParam_EnablePeakLocking];
}

@end
