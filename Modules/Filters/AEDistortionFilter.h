//
//  AEDistortionFilter.h
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "AEAudioUnitFilter.h"

@interface AEDistortionFilter : AEAudioUnitFilter

- (instancetype)init;

// range is from 0.1 to 500 milliseconds. Default is 0.1.
@property (nonatomic) double delay;

// range is from 0.1 to 50 (rate). Default is 1.0.
@property (nonatomic) double decay;

// range is from 0 to 100 (percentage). Default is 50.
@property (nonatomic) double delayMix;



// range is from 0% to 100%.
@property (nonatomic) double decimation;

// range is from 0% to 100%. Default is 0%.
@property (nonatomic) double rounding;

// range is from 0% to 100%. Default is 50%.
@property (nonatomic) double decimationMix;



// range is from 0 to 1 (linear gain). Default is 1.
@property (nonatomic) double linearTerm;

// range is from 0 to 20 (linear gain). Default is 0.
@property (nonatomic) double squaredTerm;

// range is from 0 to 20 (linear gain). Default is 0.
@property (nonatomic) double cubicTerm;

// range is from 0% to 100%. Default is 50%.
@property (nonatomic) double polynomialMix;



// range is from 0.5Hz to 8000Hz. Default is 100Hz.
@property (nonatomic) double ringModFreq1;

// range is from 0.5Hz to 8000Hz. Default is 100Hz.
@property (nonatomic) double ringModFreq2;

// range is from 0% to 100%. Default is 50%.
@property (nonatomic) double ringModBalance;

// range is from 0% to 100%. Default is 0%.
@property (nonatomic) double ringModMix;



// range is from -80dB to 20dB. Default is -6dB.
@property (nonatomic) double softClipGain;



// range is from 0% to 100%. Default is 50%.
@property (nonatomic) double finalMix;

@end
