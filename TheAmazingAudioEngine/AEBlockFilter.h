//
//  AEBlockFilter.h
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

/*!
 * Filter processing block
 *
 *  A filter implementation must call the function pointed to by the *producer* argument,
 *  passing *producerToken*, *audio*, and *frames* as arguments, in order to produce as much
 *  audio is required to produce *frames* frames of output audio:
 *
 *          OSStatus status = producer(producerToken, audio, &frames);
 *          if ( status != noErr ) return status;
 *
 *  Then the audio can be processed as desired.
 *
 * @param producer A function to be called to produce audio for filtering
 * @param producerToken An opaque pointer to be passed to *producer* when producing audio
 * @param time      The time the output audio will be played or the time input audio was received, automatically compensated for hardware latency.
 * @param frames    The length of the required audio, in frames
 * @param audio     The audio buffer list to write output audio to
 */
typedef void (^AEBlockFilterBlock)(AEAudioFilterProducer producer,
                                   void                     *producerToken,
                                   const AudioTimeStamp     *time,
                                   UInt32                    frames,
                                   AudioBufferList          *audio);

/*!
 * Block filter: Utility class to allow use of a block to filter audio
 */
@interface AEBlockFilter : NSObject <AEAudioFilter>

/*!
 * Create a new filter with a given block
 *
 * @param block Block to use for audio generation
 */
+ (AEBlockFilter*)filterWithBlock:(AEBlockFilterBlock)block;

/*
 * The audio format for this filter
 */
@property (nonatomic, assign) AudioStreamBasicDescription audioDescription;

@end

#ifdef __cplusplus
}
#endif