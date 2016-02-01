//
//  AEAudioUnitFilter.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 05/02/2013.
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
 * @return The initialised filter
 */
- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription;

/*!
 * Create a new Audio Unit filter, with a block to run before initialization of the unit 
 *
 * @param audioComponentDescription The structure that identifies the audio unit
 * @param preInitializeBlock A block to run before the audio unit is initialized.
 *              This can be used to set some properties that needs to be set before the unit is initialized.
 * @return The initialised filter
 */
- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                preInitializeBlock:(void(^)(AudioUnit audioUnit))preInitializeBlock;

/*!
 * Retrieve audio unit reference
 *
 *  This method, for use on the realtime audio thread, allows subclasses and external
 *  classes to access the audio unit.
 *
 * @param filter The filter
 * @returns Audio unit reference
 */
AudioUnit AEAudioUnitFilterGetAudioUnit(__unsafe_unretained AEAudioUnitFilter * filter);

/*!
 * Get an audio unit parameter
 *
 * @param parameterId The audio unit parameter identifier
 * @return The value of the parameter
 */
- (double)getParameterValueForId:(AudioUnitParameterID)parameterId;

/*!
 * Set an audio unit parameter
 *
 *  Note: Parameters set via this method will be automatically assigned again if the
 *  audio unit is recreated due to removal from the audio controller, an audio controller 
 *  reload, or a media server error.
 *
 * @param value The value of the parameter to set
 * @param parameterId The audio unit parameter identifier
 */
- (void)setParameterValue:(double)value forId:(AudioUnitParameterID)parameterId;

/*!
 * The audio unit
 */
@property (nonatomic, readonly) AudioUnit audioUnit;

/*!
 * The audio graph node
 */
@property (nonatomic, readonly) AUNode audioGraphNode;

/*!
 * Audio Unit effect bypass. Default is false.
 *
 * Toggle this state at any time and it will begin taking effect on the next
 * render cycle.
 */
@property (nonatomic, assign) BOOL bypassed;

/*!
 * Whether to always use the audio unit's default input audio format.
 *
 * This can be used as a workaround for audio units that misidentify the TAAE system
 * audio description as being compatible. Audio will automatically be converted from
 * the source audio format to this format.
 *
 * Default: NO
 */
@property (nonatomic, assign) BOOL useDefaultInputFormatWorkaround;

@end

#ifdef __cplusplus
}
#endif
