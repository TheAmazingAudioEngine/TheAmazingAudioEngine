//
//  AELowShelfFilter.h
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "AEAudioUnitFilter.h"

@interface AELowShelfFilter : AEAudioUnitFilter

- (instancetype)init;

// range is from 10Hz to 200Hz. Default is 80Hz.
@property (nonatomic) double cutoffFrequency;

// range is -40dB to 40dB. Default is 0dB.
@property (nonatomic) double gain;

@end
