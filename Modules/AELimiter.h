//
//  AELimiter.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 20/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@interface AELimiter : NSObject

BOOL AELimiterEnqueue(AELimiter *limiter, float** buffers, int numberOfBuffers, UInt32 length, AudioTimeStamp *timestamp);
void AELimiterDequeue(AELimiter *limiter, float** buffers, int numberOfBuffers, UInt32 *ioLength, AudioTimeStamp *timestamp);
UInt32 AELimiterFillCount(AELimiter *limiter);

void AELimiterReset(AELimiter *limiter);

@property (nonatomic, assign) UInt32 hold;
@property (nonatomic, assign) UInt32 attack;
@property (nonatomic, assign) UInt32 decay;
@property (nonatomic, assign) float level;
@end
