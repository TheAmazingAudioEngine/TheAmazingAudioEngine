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
