//
//  AEExpanderFilter.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 09/07/2011.
//  Copyright 2011 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

#define AEExpanderFilterRatioGateMode 0

typedef enum {
    AEExpanderFilterPresetNone=-1,
    AEExpanderFilterPresetSmooth=0,
    AEExpanderFilterPresetMedium=1,
    AEExpanderFilterPresetPercussive=2
} AEExpanderFilterPreset;

@interface AEExpanderFilter : NSObject <AEAudioFilter>
- (void)assignPreset:(AEExpanderFilterPreset)preset;

- (void)startCalibratingWithCompletionBlock:(void (^)(void))block;

@property (nonatomic, assign) float ratio;
@property (nonatomic, assign) double threshold;
@property (nonatomic, assign) double hysteresis;
@property (nonatomic, assign) NSTimeInterval attack;
@property (nonatomic, assign) NSTimeInterval decay;

@end
