//
//  AEAudioUnitFilter.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 05/02/2013.
//  Copyright (c) 2013 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

/*!
 * Audio Unit Filter
 *
 *  This class allows you to use Audio Units as filters. Provide an
 *  AudioComponentDescription that describes the audio unit, and the
 *  corresponding audio unit will be initialised, ready for use
 *
 */
@interface AEAudioUnitFilter : NSObject <AEAudioFilter>

/*!
 * Create a new Audio Unit filter
 *
 * @param audioComponentDescription The structure that identifies the audio unit
 * @param audioController The audio controller
 * @param error On output, if not NULL, will point to an error if a problem occurred
 * @return The initialised filter, or nil if an error occurred
 */
- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                   audioController:(AEAudioController*)audioController
                             error:(NSError**)error;

/*!
 * The audio unit
 */
@property (nonatomic, readonly) AudioUnit audioUnit;

@end
