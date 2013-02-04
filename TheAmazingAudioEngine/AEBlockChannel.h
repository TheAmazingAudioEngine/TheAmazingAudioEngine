//
//  AEBlockChannel.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 20/12/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

typedef void (^AEBlockChannelBlock)(const AudioTimeStamp     *time,
                                    UInt32                    frames,
                                    AudioBufferList          *audio);

/*!
 * Block channel: Utility class to allow use of a block to generate audio
 */
@interface AEBlockChannel : NSObject <AEAudioPlayable>

/*!
 * Create a new channel with a given block
 *
 * @param block Block to use for audio generation
 */
+ (AEBlockChannel*)channelWithBlock:(AEBlockChannelBlock)block;

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
@property (nonatomic, assign) AudioStreamBasicDescription audioDescription;

@end
