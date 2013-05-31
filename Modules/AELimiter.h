//
//  AELimiter.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 20/04/2012.
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
#import <AudioToolbox/AudioToolbox.h>

/*!
 * Limiter filter
 *
 *  This class implements a lookahead audio limiter. Use it to
 *  smoothly limit output volume to a particular level.
 *
 *  The audio is delayed by the number of frames indicated by the
 *  @link attack @endlink property.
 *
 *  This class operates on non-interleaved floating point audio,
 *  as it is frequently used as part of larger audio processing operations.
 *  If your audio is not already in this format, you may wish to
 *  use it in conjunction with @link AEFloatConverter @endlink.
 *
 *  To use this as an @link AEAudioFilter @endlink, see the 
 *  @link AELimiterFilter @endlink class.
 */
@interface AELimiter : NSObject

/*!
 * Init
 * 
 * @param numberOfChannels Number of channels to use
 * @param sampleRate Sample rate to use
 */
- (id)initWithNumberOfChannels:(NSInteger)numberOfChannels sampleRate:(Float32)sampleRate;

/*!
 * Enqueue audio
 *
 *  Add audio to be processed.
 *
 *  This C function is safe to be used in a Core Audio realtime thread.
 *
 * @param limiter           A pointer to the limiter object.
 * @param buffers           An array of floating-point arrays containing noninterleaved audio to enqueue.
 * @param length            The length of the audio, in frames
 * @param timestamp         The timestamp of the audio, or NULL
 * @return YES on success, NO on failure.
 */
BOOL AELimiterEnqueue(AELimiter *limiter, float** buffers, UInt32 length, const AudioTimeStamp *timestamp);

/*!
 * Dequeue audio
 *
 *  Dequeue processed audio.
 *
 *  Note that the audio is delayed by the number of frames indicated by the
 *  @link attack @endlink property. If at the end of a processing operation
 *  you wish to dequeue all audio from the limiter, you should use 
 *  @link AELimiterDrain @endlink.
 *
 *  This C function is safe to be used in a Core Audio realtime thread.
 *
 * @param limiter           A pointer to the limiter object.
 * @param buffers           An array of floating-point arrays to store the dequeued noninterleaved audio.
 * @param ioLength          On input, the length of the audio to dequeue, in frames; on output, the amount of audio dequeued.
 * @param timestamp         On output, the timestamp of the next audio, if not NULL.
 */
void AELimiterDequeue(AELimiter *limiter, float** buffers, UInt32 *ioLength, AudioTimeStamp *timestamp);

/*!
 * Query the fill count of the limiter
 *
 *  Use this to determine how many frames can be dequeued.
 *
 * @param limiter           A pointer to the limiter object.
 * @param timestamp         On output, if not NULL, the timestamp of the next audio frames
 * @param trueFillCount     On output, if not NULL, the true fill count, including the @link attack @endlink frames held back for the lookahead algorithm.
 * @return The number of frames that can be dequeued
 */
UInt32 AELimiterFillCount(AELimiter *limiter, AudioTimeStamp *timestamp, UInt32 *trueFillCount);

/*!
 * Dequeue all audio from the limiter, including those held back for the lookahead algorithm.
 *
 *  During normal operation, the nmuber of frames given by the @link attack @endlink property are
 *  held back for the lookahead algorithm to function correctly. If you wish to finish audio processing
 *  and want to recover these frames, then you can use this function to do so. Note that the final
 *  frames may surpass the set level.
 *
 * @param limiter           A pointer to the limiter object.
 * @param buffers           An array of floating-point arrays to store the dequeued noninterleaved audio.
 * @param ioLength          On input, the length of the audio to dequeue, in frames; on output, the amount of audio dequeued.
 * @param timestamp         On output, the timestamp of the next audio, if not NULL.
 */
void AELimiterDrain(AELimiter *limiter, float** buffers, UInt32 *ioLength, AudioTimeStamp *timestamp);

/*!
 * Reset the buffer, clearing all enqueued audio
 *
 * @param limiter The limiter object.
 */
void AELimiterReset(AELimiter *limiter);

/*!
 * The hold interval, in frames
 *
 *  This is the length of time the limiter will hold the
 *  gain, when it is in the active state.
 *
 *  Default: 22050 (0.5s at 44.1kHz)
 */
@property (nonatomic, assign) UInt32 hold;

/*!
 * The attack duration, in frames
 *
 *  This is the amount of time over which the limiter will
 *  smoothly activate when an audio level greater than the
 *  set limit is seen.
 *
 *  Note that the limiter will delay the audio by this duration.
 *
 *  Default: 2048 frames (~.046s at 44.1kHz)
 */
@property (nonatomic, assign) UInt32 attack;

/*!
 * The decay duration, in frames
 *
 *  This is the amount of time over which the limiter
 *  will smoothly deactivate, moving back to a 1.0 gain level,
 *  once the hold time expires.
 *
 * Default: 44100 (1s at 44.1kHz)
 */
@property (nonatomic, assign) UInt32 decay;

/*!
 * The audio level limit
 *
 *  This is the audio level at which the limiter activates.
 *  The dequeued audio will not exceed this level, and will be
 *  smoothly gain-adjusted accordingly when a greater level is seen.
 *
 *  The value you provide here will depend on the original audio
 *  format you are working with. For example, if you are mixing
 *  a number of 16-bit signed integer streams, you may wish to use
 *  a limit value of INT16_MAX for the combined stream before
 *  converting back to 16-bit, to avoid clipping.
 *
 *  Default: INT16_MAX
 */
@property (nonatomic, assign) float level;

@end

#ifdef __cplusplus
}
#endif