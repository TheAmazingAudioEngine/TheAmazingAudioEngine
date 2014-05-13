//
//  AEMixerBuffer.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 12/04/2012.
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
 * A source identifier, for use with [AEMixerBufferEnqueue](@ref AEMixerBuffer::AEMixerBufferEnqueue).
 *
 * This can be anything you like, as long as it is not NULL, and is unique to each source.
 */
typedef void* AEMixerBufferSource;

/*!
 * A frame count value indicating an inactive source
 */
#define AEMixerBufferSourceInactive (UINT32_MAX-1)

/*!
 * Source render callback
 *
 * This is called by AEMixerBuffer when audio for the source is required, if you have provided callbacks
 * for the source via @link AEMixerBuffer::setRenderCallback:peekCallback:userInfo:forSource: setRenderCallback:peekCallback:userInfo:forSource: @endlink.
 *
 * @param source            The source. This can be anything you like, as long as it is not NULL, and is unique to each source.
 * @param frames            The number of frames required.
 * @param audio             The audio buffer list - audio should be copied into the provided buffers. May be NULL, in which case your render callback should simply discard the requested audio.
 * @param inTimeStamp       The timestamp that is expected to correspond to the audio rendered.
 * @param userInfo          The opaque pointer passed to @link AEMixerBuffer::setRenderCallback:peekCallback:userInfo:forSource: setRenderCallback:peekCallback:userInfo:forSource: @endlink.
 */
typedef void (*AEMixerBufferSourceRenderCallback) (AEMixerBufferSource       source,
                                                   UInt32                    frames,
                                                   AudioBufferList          *audio,
                                                   const AudioTimeStamp     *inTimeStamp,
                                                   void                     *userInfo);

/*!
 * Source peek callback
 *
 * This is called by AEMixerBuffer when it needs to know the status of the source, if you have
 * provided callbacks for the source via
 * @link AEMixerBuffer::setRenderCallback:peekCallback:userInfo:forSource: setRenderCallback:peekCallback:userInfo:forSource: @endlink.
 *
 * @param source            The source. This can be anything you like, as long as it is not NULL, and is unique to each source.
 * @param outTimestamp      On output, the timestamp of the next audio from the source.
 * @param userInfo          The opaque pointer passed to @link AEMixerBuffer::setRenderCallback:peekCallback:userInfo:forSource: setRenderCallback:peekCallback:userInfo:forSource: @endlink.
 * @return The number of available frames. Return the special value AEMixerBufferSourceInactive to indicate an inactive source.
 */
typedef UInt32 (*AEMixerBufferSourcePeekCallback) (AEMixerBufferSource  source,
                                                   AudioTimeStamp      *outTimestamp,
                                                   void                *userInfo);


/*!
 * Mixer buffer
 *
 *  This class performs mixing of multiple audio sources, using the timestamps corresponding
 *  to each audio packet from each source to synchronise all sources together.
 *
 *  To use it, create an instance, passing in the AudioStreamBasicDescription of your audio,
 *  then provide data for each source by calling @link AEMixerBufferEnqueue @endlink. Or,
 *  provide callbacks for one or more sources with 
 *  [setRenderCallback:peekCallback:userInfo:forSource:](@ref setRenderCallback:peekCallback:userInfo:forSource:),
 *  which will cause this class to call your callbacks when data is needed.
 *
 *  Then, call @link AEMixerBufferDequeue @endlink to consume mixed and synchronised audio
 *  ready for playback, recording, etc.
 */
@interface AEMixerBuffer : NSObject

/*!
 * Initialiser
 *
 * @param clientFormat  The AudioStreamBasicDescription defining the audio format used
 */
- (id)initWithClientFormat:(AudioStreamBasicDescription)clientFormat;

/*!
 * Enqueue audio
 *
 *  Feed the buffer with audio blocks. Identify each source via the `source` parameter. You
 *  may use any identifier you like - pointers, numbers, etc (just cast to AEMixerBufferSource).
 *
 *  When you enqueue audio from a new source (that is, the `source` value is one that hasn't been
 *  seen before, this class will automatically reconfigure itself to start mixing the new source.
 *  However, this will happen at some point in the near future, not immediately, so one or two buffers
 *  may be lost. If this is a problem, then call this function first on the main thread, for each source,
 *  with a NULL audio buffer, and a lengthInFrames value of 0.
 *
 *  This function can safely be used in a different thread from the dequeue function. It can also be used
 *  in a different thread from other calls to enqueue, given two conditions: No two threads enqueue the 
 *  same source, and no two threads call enqueue for a new source simultaneously.
 *
 * @param mixerBuffer    The mixer buffer.
 * @param source         The audio source. This can be anything you like, as long as it is not NULL, and is unique to each source.
 * @param audio          The audio buffer list.
 * @param lengthInFrames The length of audio.
 * @param timestamp      The timestamp associated with the audio.
 */
void AEMixerBufferEnqueue(AEMixerBuffer *mixerBuffer, AEMixerBufferSource source, AudioBufferList *audio, UInt32 lengthInFrames, const AudioTimeStamp *timestamp);

/*!
 * Assign callbacks for a source
 *
 *  Rather than providing audio for a source using @link AEMixerBufferEnqueue @endlink, you may
 *  provide callbacks which will be called by the mixer as required. You must either provide audio via
 *  @link AEMixerBufferEnqueue @endlink, or via this method, but never both.
 *
 * @param renderCallback    The render callback, used to receive audio.
 * @param peekCallback      The peek callback, used to get info about the source's buffer status.
 * @param userInfo          An opaque pointer that will be provided to the callbacks.
 * @param source            The audio source.
 */
- (void)setRenderCallback:(AEMixerBufferSourceRenderCallback)renderCallback peekCallback:(AEMixerBufferSourcePeekCallback)peekCallback userInfo:(void *)userInfo forSource:(AEMixerBufferSource)source;

/*!
 * Dequeue audio
 *
 *  Call this function to receive synchronised and mixed audio.
 *
 *  This can safely be used in a different thread from the enqueue function.
 *
 * @param mixerBuffer       The mixer buffer.
 * @param bufferList        The buffer list to write audio to. The mData pointers 
 *                          may be NULL, in which case an internal buffer will be provided.
 *                          You may also pass a NULL value, which will simply discard the given
 *                          number of frames.
 * @param ioLengthInFrames  On input, the number of frames of audio to dequeue. On output, 
 *                          the number of frames returned.
 * @param outTimestamp      On output, the timestamp of the first audio sample
 */
void AEMixerBufferDequeue(AEMixerBuffer *mixerBuffer, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, AudioTimeStamp *outTimestamp);

/*!
 * Dequeue a single source
 *
 *  Normally not used, but if you wish to simply use this class to synchronise the audio across
 *  a number of sources, rather than mixing the sources together also, then this function allows you
 *  to access the synchronized audio for each source.
 *
 *  Do not use this function together with AEMixerBufferDequeue.
 *
 * @param mixerBuffer       The mixer buffer.
 * @param source            The audio source.
 * @param bufferList        The buffer list to write audio to. The mData pointers 
 *                          may be NULL, in which case an internal buffer will be provided.
 * @param ioLengthInFrames  On input, the number of frames of audio to dequeue. On output, 
 *                          the number of frames returned.
 * @param outTimestamp      On output, the timestamp of the first audio sample
 */
void AEMixerBufferDequeueSingleSource(AEMixerBuffer *mixerBuffer, AEMixerBufferSource source, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, AudioTimeStamp *outTimestamp);

/*!
 * Peek the audio buffer
 *
 *  Use this to determine how much audio is currently buffered, and the corresponding next timestamp.
 *
 * @param mixerBuffer       The mixer buffer
 * @param outNextTimestamp  If not NULL, the timestamp of the next available audio
 * @return Number of frames of available audio, in the specified audio format.
 */
UInt32 AEMixerBufferPeek(AEMixerBuffer *mixerBuffer, AudioTimeStamp *outNextTimestamp);

/*!
 * Mark end of time interval
 *
 *  When receiving each audio source separately via AEMixerBufferDequeueSingleSource (instead of mixed
 *  with AEMixerBufferDequeue), you must call this function at the end of each time interval in order
 *  to inform the mixer that you are finished with that audio segment. Any sources that have not
 *  been dequeued will have their audio discarded in order to retain synchronization.
 *
 * @param mixerBuffer       The mixer buffer.
 */
void AEMixerBufferEndTimeInterval(AEMixerBuffer *mixerBuffer);

/*!
 * Mark the given source as idle
 *
 *  Normally, if the mixer buffer doesn't receive any audio for a given source within
 *  the time interval given by the sourceIdleThreshold property, the buffer will wait,
 *  allowing no frames to be dequeued until either further audio is received for the
 *  source, or the sourceIdleThreshold limit is met.
 *
 *  To avoid this delay and immediately mark a given source as idle, use this function.
 *
 * @param mixerBuffer       The mixer buffer
 * @param source            The source to mark as idle
 */
void AEMixerBufferMarkSourceIdle(AEMixerBuffer *mixerBuffer, AEMixerBufferSource source);

/*!
 * Set a different AudioStreamBasicDescription for a source
 *
 *  Important: Do not change this property while using enqueue/dequeue.
 *  You must stop enqueuing or dequeuing audio first.
 */
- (void)setAudioDescription:(AudioStreamBasicDescription)audioDescription forSource:(AEMixerBufferSource)source;

/*!
 * Set volume for source
 */
- (void)setVolume:(float)volume forSource:(AEMixerBufferSource)source;

/*!
 * Get volume for source
 */
- (float)volumeForSource:(AEMixerBufferSource)source;

/*!
 * Set pan for source
 */
- (void)setPan:(float)pan forSource:(AEMixerBufferSource)source;

/*!
 * Get pan for source
 */
- (float)panForSource:(AEMixerBufferSource)source;

/*!
 * Force the mixer to unregister a source
 *
 *  After this function is called, the mixer will have reconfigured to stop
 *  mixing the given source. If callbacks for the source were provided, these
 *  will never be called again after this function returns.
 *
 *  Use of this function is entirely optional - the mixer buffer will automatically
 *  unregister sources it is no longer receiving audio for, and will clean up when
 *  deallocated.
 *
 * @param source            The audio source.
 */
- (void)unregisterSource:(AEMixerBufferSource)source;

/*!
 * Client audio format
 *
 *  Important: Do not change this property while using enqueue/dequeue.
 *  You must stop enqueuing or dequeuing audio first.
 */
@property (nonatomic, assign) AudioStreamBasicDescription clientFormat;

/*!
 * How long to wait for empty sources before assuming they are idle
 *
 *  AEMixerBufferDequeue will return 0 frames for this duration if any sources are
 *  currently empty, before assuming the source is idle and continuing.
 *
 *  Set to 0.0 to avoid waiting on idle sources.
 */
@property (nonatomic, assign) NSTimeInterval sourceIdleThreshold;

/*!
 * Whether to assume sources have infinite capacity
 *
 *  Setting this to YES will make the mixer assume the frame count
 *  for each source is infinite, and will render sources regardless
 *  of the frame count returned by the peek callback.
 *
 *  Note that the results of AEMixerBufferPeek will still return a frame
 *  count derived by the true frame count returned by the peek callback,
 *  but calling AEMixerBufferRender will assume that the available
 *  frame count across all sources is infinite.
 *
 *  This property is useful when using sources that generate audio
 *  on demand.
 */
@property (nonatomic, assign) BOOL assumeInfiniteSources;

/*!
 * Debug level
 */
@property (nonatomic, assign) int debugLevel;

@end

#ifdef __cplusplus
}
#endif