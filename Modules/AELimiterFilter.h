//
//  AELimiterFilter.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

/*!
 * A wrapper around the @link AELimiter @endlink class that allows it
 * to be used as an AEAudioFilter.
 *
 * See the AELimiter documentation for descriptions of the parameters.
 */
@interface AELimiterFilter : NSObject <AEAudioFilter>

/*!
 * Initialise
 *
 * @param audioController The Audio Controller
 * @param clientFormat The audio format to use
 */
- (id)initWithAudioController:(AEAudioController*)audioController clientFormat:(AudioStreamBasicDescription)clientFormat;

@property (nonatomic, assign) UInt32 hold;
@property (nonatomic, assign) UInt32 attack;
@property (nonatomic, assign) UInt32 decay;
@property (nonatomic, assign) float level;

@property (nonatomic, assign) AudioStreamBasicDescription clientFormat;

@end
