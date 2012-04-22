//
//  AELimiterFilter.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

@interface AELimiterFilter : NSObject <AEAudioFilter>
@property (nonatomic, assign) UInt32 hold;
@property (nonatomic, assign) UInt32 attack;
@property (nonatomic, assign) UInt32 decay;
@property (nonatomic, assign) float level;
@end
