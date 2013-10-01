//
//  AEAudioUnitChannel.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 01/02/2013.
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
- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                   audioController:(AEAudioController*)audioController
                             error:(NSError**)error;

/*!
 * Create a new Audio Unit channel, with a block to run before initialization of the unit 
 *
 * @param audioComponentDescription The structure that identifies the audio unit
 * @param audioController The audio controller
 * @param preInitializeBlock A block to run before the audio unit is initialized.
 *              This can be used to set some properties that needs to be set before the unit is initialized.
 * @param error On output, if not NULL, will point to an error if a problem occurred
 * @return The initialised channel
 */
- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                   audioController:(AEAudioController*)audioController
                preInitializeBlock:(void(^)(AudioUnit audioUnit))block
                             error:(NSError**)error;

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

/*!
 * The audio unit
 */
@property (nonatomic, readonly) AudioUnit audioUnit;

/*!
 * The audio graph node
 */
@property (nonatomic, readonly) AUNode audioGraphNode;

@end

#ifdef __cplusplus
}
#endif