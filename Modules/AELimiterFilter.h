//
//  AELimiterFilter.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/04/2012.
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
 * A wrapper around the @link AELimiter @endlink class that allows it
 * to be used as an AEAudioFilter.
 *
 * See the AELimiter documentation for descriptions of the parameters.
 */
@interface AELimiterFilter : NSObject <AEAudioFilter>

/*!
 * Initialise
 */
- (id)init;

@property (nonatomic, assign) UInt32 hold;
@property (nonatomic, assign) UInt32 attack;
@property (nonatomic, assign) UInt32 decay;
@property (nonatomic, assign) float level;

@property (nonatomic, assign) AudioStreamBasicDescription clientFormat;
@end

#ifdef __cplusplus
}
#endif