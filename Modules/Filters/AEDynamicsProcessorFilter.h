//
//  AEDynamicsProcessorFilter.h
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "AEAudioUnitFilter.h"

@interface AEDynamicsProcessorFilter : AEAudioUnitFilter

- (instancetype)init;

// range is from -40dB to 20dB. Default is -20dB.
@property (nonatomic) double threshold;

// range is from 0.1dB to 40dB. Default is 5dB.
@property (nonatomic) double headRoom;

// range is from 1 to 50 (rate). Default is 2.
@property (nonatomic) double expansionRatio;

// Value is in dB.
@property (nonatomic) double expansionThreshold;

// range is from 0.0001 to 0.2. Default is 0.001.
@property (nonatomic) double attackTime;

// range is from 0.01 to 3. Default is 0.05.
@property (nonatomic) double releaseTime;

// range is from -40dB to 40dB. Default is 0dB.
@property (nonatomic) double masterGain;

@property (nonatomic, readonly) double compressionAmount;
@property (nonatomic, readonly) double inputAmplitude;
@property (nonatomic, readonly) double outputAmplitude;

@end
