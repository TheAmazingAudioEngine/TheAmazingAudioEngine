//
//  AEAudioFilePlayer.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 13/02/2012.
//
//  Contributions by Ryan King and Jeremy Huff of Hello World Engineering, Inc on 7/15/15.
//      Copyright (c) 2015 Hello World Engineering, Inc. All rights reserved.
//  Contributions by Ryan Holmes
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

#import "AEAudioUnitChannel.h"

/*!
 * Audio file player
 *
 *  This class allows you to play audio files, either as one-off samples, or looped.
 *  It will play any audio file format supported by iOS.
 *
 *  To use, create an instance, then add it to the audio controller.
 */

@interface AEAudioFilePlayer : AEAudioUnitChannel

/*!
 * Create a new player instance
 *
 * @param url               URL to the file to load
 * @param error             If not NULL, the error on output
 * @return The audio player, ready to be @link AEAudioController::addChannels: added @endlink to the audio controller.
 */
+ (instancetype)audioFilePlayerWithURL:(NSURL *)url error:(NSError **)error;

/*!
 * Default initialiser
 *
 * @param url               URL to the file to load
 * @param error             If not NULL, the error on output
 */
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;

/*!
 * Schedule playback for a particular time
 *
 *  This causes the player to emit silence up until the given timestamp
 *  is reached. Use this method to synchronize playback with other audio
 *  generators.
 *
 *  Note: When you call this method, the property channelIsPlaying will be
 *  set to YES, to enable playback when the start time is reached.
 *
 * @param time The time, in host ticks, at which to begin playback
 */
- (void)playAtTime:(uint64_t)time;

/*!
 * Get playhead position, in frames
 *
 *  For use on the realtime thread.
 *
 * @param filePlayer The player
 */
UInt32 AEAudioFilePlayerGetPlayhead(__unsafe_unretained AEAudioFilePlayer * filePlayer);

@property (nonatomic, strong, readonly) NSURL *url;         //!< Original media URL
@property (nonatomic, readonly) NSTimeInterval duration;    //!< Length of audio, in seconds
@property (nonatomic, assign) NSTimeInterval currentTime;   //!< Current playback position, in seconds
@property (nonatomic, readwrite) BOOL loop;                 //!< Whether to loop this track
@property (nonatomic, readwrite) BOOL removeUponFinish;     //!< Whether the track automatically removes itself from the audio controller after playback completes
@property (nonatomic, copy) void(^completionBlock)();       //!< A block to be called when playback finishes
@end

#ifdef __cplusplus
}
#endif