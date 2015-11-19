//
//  RMSEngine.m
//  TheEngineSample
//
//  Created by 32BT on 16/11/15.
//  Copyright © 2015 A Tasty Pixel. All rights reserved.
//

#import "RMSEngine.h"



@interface RMSEngine ()
{
	rmsengine_t mEngine;
}
@end



@implementation RMSEngine

- (instancetype) init
{ return [self initWithSampleRate:44100]; }

- (instancetype) initWithSampleRate:(double)sampleRate
{
	self = [super init];
	if (self != nil)
	{
		mEngine = RMSEngineInit(sampleRate);
	}
	
	return self;
}


- (void) addSample:(double)sample
{ RMSEngineAddSample(&mEngine, sample); }

- (rmslevels_t) getLevels
{ return RMSEngineGetLevels(&mEngine); }

@end







