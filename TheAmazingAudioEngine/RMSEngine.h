//
//  RMSEngine.h
//  TheEngineSample
//
//  Created by 32BT on 16/11/15.
//  Copyright © 2015 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "rmslevels_t.h"

@interface RMSEngine : NSObject

- (instancetype) initWithSampleRate:(double)sampleRate;
- (void) addSample:(double)sample;
- (rmslevels_t) getLevels;

@end
