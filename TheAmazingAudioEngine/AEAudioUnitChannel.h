//
//  AEAudioUnitChannel.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 01/02/2013.
//  Copyright (c) 2013 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

/*!
 * Audio Unit Channel
 *
 *  This class allows you to add Audio Units as channels. Provide an
 *  AudioComponentDescription that describes the audio unit, and the
 *  corresponding audio unit will be initialised, ready for use
 *
 */
@interface AEAudioUnitChannel : NSObject <AEAudioPlayable>

/*!
 * Create a new Audio Unit channel
 *
 * @param audioComponentDescription The structure that identifies the audio unit
 * @param audioController The audio controller
 * @param error On output, if not NULL, will point to an error if a problem occurred
 * @return The initialised channel
 */
+ (AEAudioUnitChannel*)audioUnitChannelWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                                                audioController:(AEAudioController*)audioController
                                                          error:(NSError**)error;

/*!
 * Attempt to set the audio description
 *
 *  Note that not all audio descriptions are supported by audio units.
 *
 * @param audioDescription The new audio description to use
 * @return YES if the new audio description was accepted; NO otherwise.
 */
- (BOOL)changeAudioDescription:(AudioStreamBasicDescription)audioDescription;

/*!
 * Track volume
 *
 * Range: 0.0 to 1.0
 */
@property (nonatomic, assign) float volume;

/*!
 * Track pan
 *
 * Range: -1.0 (left) to 1.0 (right)
 */
@property (nonatomic, assign) float pan;

/*
 * Whether channel is currently playing
 *
 * If this is NO, then the track will be silenced and no further render callbacks
 * will be performed until set to YES again.
 */
@property (nonatomic, assign) BOOL channelIsPlaying;

/*
 * Whether channel is muted
 *
 * If YES, track will be silenced, but render callbacks will continue to be performed.
 */
@property (nonatomic, assign) BOOL channelIsMuted;

/*
 * The audio format for this channel
 */
@property (nonatomic, readonly) AudioStreamBasicDescription audioDescription;

/*!
 * The audio unit
 */
@property (nonatomic, readonly) AudioUnit audioUnit;

@end
