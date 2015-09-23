//
//  AEPeakLimiterFilter.h
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "AEAudioUnitFilter.h"

@interface AEPeakLimiterFilter : AEAudioUnitFilter

- (instancetype)init;

// range is from 0.001 to 0.03 seconds. Default is 0.012 seconds.
@property (nonatomic) double attackTime;

// range is from 0.001 to 0.06 seconds. Default is 0.024 seconds.
@property (nonatomic) double decayTime;

// range is from -40dB to 40dB. Default is 0dB.
@property (nonatomic) double preGain;

@end
