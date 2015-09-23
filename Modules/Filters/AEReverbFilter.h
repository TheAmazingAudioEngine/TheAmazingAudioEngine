//
//  AEReverbFilter.h
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AEAudioUnitFilter.h"

@interface AEReverbFilter : AEAudioUnitFilter

- (instancetype)init;

// range is from 0 to 100 (percentage). Default is 0.
@property (nonatomic) double dryWetMix;

// range is from -20dB to 20dB. Default is 0dB.
@property (nonatomic) double gain;

// range is from 0.0001 to 1.0 seconds. Default is 0.008 seconds.
@property (nonatomic) double minDelayTime;

// range is from 0.0001 to 1.0 seconds. Default is 0.050 seconds.
@property (nonatomic) double maxDelayTime;

// range is from 0.001 to 20.0 seconds. Default is 1.0 seconds.
@property (nonatomic) double decayTimeAt0Hz;

// range is from 0.001 to 20.0 seconds. Default is 0.5 seconds.
@property (nonatomic) double decayTimeAtNyquist;

// range is from 1 to 1000 (unitless). Default is 1.
@property (nonatomic) double randomizeReflections;

// range is from 10Hz to 20000Hz. Default is 800Hz.
@property (nonatomic) double filterFrequency;

// range is from 0.05 to 4.0 octaves. Default is 3.0 octaves.
@property (nonatomic) double filterBandwidth;

// range is from -18dB to 18dB. Default is 0.0dB.
@property (nonatomic) double filterGain;

@end
