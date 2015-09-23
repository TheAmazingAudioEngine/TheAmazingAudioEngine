//
//  AEHighPassFilter.h
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "AEAudioUnitFilter.h"

@interface AEHighPassFilter : AEAudioUnitFilter

- (instancetype)init;

// range is from 10Hz to ($SAMPLERATE/2) Hz. Default is 6900 Hz.
@property (nonatomic) double cutoffFrequency;

// range is -20dB to 40dB. Default is 0dB.
@property (nonatomic) double resonance;

@end
