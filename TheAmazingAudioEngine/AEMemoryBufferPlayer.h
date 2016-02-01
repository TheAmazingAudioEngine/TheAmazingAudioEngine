//
//  AEMemoryBufferPlayer.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 13/02/2012.
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
#import "AEAudioController.h"

/*!
 * Memory buffer player
 *
 *  This class allows you to play a buffer containing audio, either as one-off samples, or looped.
 *  It can load any audio file format supported by iOS.
 *
 *  To use, create an instance, then add it to the audio controller.
 */
@interface AEMemoryBufferPlayer : NSObject <AEAudioPlayable>

/*!
 * Initialise with audio loaded from a file
 *
 *  This method will asynchronously load the given audio file into memory,
 *  and create an AEMemoryBufferPlayer instance when it is finished.
 *
 * @param url               URL to the file to load into memory
 * @param audioDescription  The target audio description to use (usually the same as AEAudioController's)
 * @param completionBlock   Block to call when the load operation has finished
 */
+ (void)beginLoadingAudioFileAtURL:(NSURL*)url
                  audioDescription:(AudioStreamBasicDescription)audioDescription
                   completionBlock:(void(^)(AEMemoryBufferPlayer *, NSError *))completionBlock;

/*!
 * Initialise with a memory buffer
 *
 * @param buffer            Audio buffer
 * @param audioDescription  The description of the audio provided
 * @param freeWhenDone      Whether to free the audio buffer when this class is deallocated
 */
- (instancetype)initWithBuffer:(AudioBufferList *)buffer
              audioDescription:(AudioStreamBasicDescription)audioDescription
                  freeWhenDone:(BOOL)freeWhenDone;

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

@property (nonatomic, readonly) AudioBufferList * buffer;   //!< The audio buffer
@property (nonatomic, readonly) NSTimeInterval duration;    //!< Length of audio, in seconds
@property (nonatomic, assign) NSTimeInterval currentTime;   //!< Current playback position, in seconds
@property (nonatomic, readonly) AudioStreamBasicDescription audioDescription; //!< The client audio format
@property (nonatomic, readwrite) BOOL loop;                 //!< Whether to loop this track
@property (nonatomic, readwrite) float volume;              //!< Track volume
@property (nonatomic, readwrite) float pan;                 //!< Track pan
@property (nonatomic, readwrite) BOOL channelIsPlaying;     //!< Whether the track is playing
@property (nonatomic, readwrite) BOOL channelIsMuted;       //!< Whether the track is muted
@property (nonatomic, readwrite) BOOL removeUponFinish;     //!< Whether the track automatically removes itself from the audio controller after playback completes
@property (nonatomic, copy) void(^completionBlock)();       //!< A block to be called when playback finishes
@property (nonatomic, copy) void(^startLoopBlock)();        //!< A block to be called when the loop restarts in loop mode
@end

#ifdef __cplusplus
}
#endif