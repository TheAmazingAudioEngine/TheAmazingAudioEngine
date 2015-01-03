//
//  AEFadeFilter.h
//  TheAmazingAudioEngine
//
//  Created by Mark Wise on 01/01/2015.
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
//

#ifdef __cplusplus
extern "C" {
#endif

#import <Foundation/Foundation.h>
#import "AEAudioController.h"
#import "AEBlockFilter.h"

@protocol AEFadeFilterDelegate;

/*!
 * Audio fade filter class
 *
 * This class allows you to fade audio in or out over a specified duration.
 * It is a subclass of AEBlockFilter. To use it, create an instance of the
 * filter and then add it with @link AEAudioController::addFilter: @endlink
 * , @link AEAudioController::addFilter:toChannel: @endlink or
 * @link AEAudioController::addFilter:toChannel: @endlink.
 *
 */
@interface AEFadeFilter : AEBlockFilter <AEAudioFilter>

/*!
 * Create a new fade filter instance
 *
 * @param audioController     The AEAudioController instance
 * @return The fade filter instance
 */
+ (AEBlockFilter*)initWithAudioController:(AEAudioController*)audioController;


/*!
 * Begin fade in
 *
 *  Start fading audio from the instance's current adjustment level to full
 *  volume.
 *
 * @param milliseconds    The duration of the fade
 */
- (void)startFadeIn:(int)milliseconds;

/*!
 * Begin fade in
 *
 *  Start fading audio from the instance's current adjustment level to silience.
 *
 * @param milliseconds    The duration of the fade
 */
- (void)startFadeOut:(int)milliseconds;

/*!
 * Delegate object
 *
 * Will be notified when fades are complete
 */
@property (nonatomic, weak) id<AEFadeFilterDelegate> delegate;

/*!
 * The AEAudioController instance
 */
@property (nonatomic, assign) AEAudioController *audioController;

@end

/*!
 * Fade filter delegate protocol
 *
 * Implements methods to receive notifications when an AEFadeFilter has
 * completed fading audio in or out.
 *
 */
@protocol AEFadeFilterDelegate <NSObject>

@optional

/*!
 * Fade in completion handler
 *
 * If specified, this selector will be performed on the delegate when a fade in
 * has completed.
 *
 */
-(void)onFadeInComplete;

/*!
 * Fade out completion handler
 *
 * If specified, this selector will be performed on the delegate when a fade out
 * has completed.
 *
 */
-(void)onFadeOutComplete;

@end

#ifdef __cplusplus
}
#endif
