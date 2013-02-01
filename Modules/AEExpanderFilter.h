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

/*!
 * @enum AEExpanderFilterPreset
 *  Presets to use with the expander filter
 *
 * @var AEExpanderFilterPresetNone 
 * No preset
 * @var AEExpanderFilterPresetSmooth
 * A smooth-sounding preset with a gentle ratio
 * @var AEExpanderFilterPresetMedium
 * A medium-level preset with 1/8 ratio and 5ms attack
 * @var AEExpanderFilterPresetPercussive
 * A gate-mode preset with 1ms attack, good for persussive audio
 */
typedef enum {
    AEExpanderFilterPresetNone=-1,
    AEExpanderFilterPresetSmooth=0,
    AEExpanderFilterPresetMedium=1,
    AEExpanderFilterPresetPercussive=2
} AEExpanderFilterPreset;

/*!
 * An expander/noise gate filter
 *
 *  This class implements an expander filter, which reduces audio
 *  levels beneath a set threshold in order to hide background noise.
 */
@interface AEExpanderFilter : NSObject <AEAudioFilter>

/*!
 * Initialise
 *
 * @param audioController The Audio Controller
 * @param clientFormat The audio format to use
 */
- (id)initWithAudioController:(AEAudioController*)audioController clientFormat:(AudioStreamBasicDescription)clientFormat;


/*!
 * Apply a preset
 */
- (void)assignPreset:(AEExpanderFilterPreset)preset;

/*!
 * Calibrate the threshold
 *
 *  This method enters calibration mode, watching the input level
 *  and setting the threshold to the maximum level seen. The user
 *  should be silent during this period, to get an accurate measure
 *  of the noise floor.
 *
 * @param block Block to perform when calibration is complete
 */
- (void)startCalibratingWithCompletionBlock:(void (^)(void))block;

@property (nonatomic, assign) AudioStreamBasicDescription clientFormat;

@property (nonatomic, assign) float ratio;
@property (nonatomic, assign) double threshold;
@property (nonatomic, assign) double hysteresis;
@property (nonatomic, assign) NSTimeInterval attack;
@property (nonatomic, assign) NSTimeInterval decay;

@end
