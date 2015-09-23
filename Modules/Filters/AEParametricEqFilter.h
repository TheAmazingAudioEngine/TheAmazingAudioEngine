//
//  AEParametricEqFilter.h
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "AEAudioUnitFilter.h"

@interface AEParametricEqFilter : AEAudioUnitFilter

- (instancetype)init;

// range is from 20Hz to ($SAMPLERATE/2) Hz. Default is 2000 Hz.
@property (nonatomic) double centerFrequency;

// range is from 0.1Hz to 20Hz. Default is 1.0Hz.
@property (nonatomic) double qFactor;

// range is from -20dB to 20dB. Default is 0dB.
@property (nonatomic) double gain;

@end
