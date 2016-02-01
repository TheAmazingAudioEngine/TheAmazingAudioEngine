//
//  AEVarispeedFilter.h
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/26/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "AEAudioUnitFilter.h"

@interface AEVarispeedFilter : AEAudioUnitFilter

- (instancetype)init;

// documented range is from 0.25 to 4.0, but empircal testing shows it to be 0.25 to 2.0. Default is 1.0.
@property (nonatomic) double playbackRate;

// range is from -2400 to 2400. Default is 0.0.
@property (nonatomic) double playbackCents;

@end
