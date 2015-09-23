//
//  AEBandpassFilter.h
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/25/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AEAudioUnitFilter.h"

@interface AEBandpassFilter : AEAudioUnitFilter

- (instancetype)init;

// range is from 20Hz to ($SAMPLERATE/2)Hz. Default is 5000Hz.
@property (nonatomic) double centerFrequency;

// range is from 100 to 12000 cents. Default is 600 cents.
@property (nonatomic) double bandwidth;

@end
