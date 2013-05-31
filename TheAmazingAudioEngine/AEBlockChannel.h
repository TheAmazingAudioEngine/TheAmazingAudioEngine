//
//  AEBlockChannel.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 20/12/2012.
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#ifdef __cplusplus
extern "C" {
#endif

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

#ifdef __cplusplus
}
#endif