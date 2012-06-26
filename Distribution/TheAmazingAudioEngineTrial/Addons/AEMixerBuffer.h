//
//  AEMixerBuffer.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 12/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

/*!
 * A source identifier, for use with [AEMixerBufferEnqueue](@ref AEMixerBuffer::AEMixerBufferEnqueue).
 *
 * This can be anything you like, as long as it is not NULL, and is unique to each source.
 */
typedef void* AEMixerBufferSource;

/*!
 * Source render callback
 *
 *      This is called by AEMixerBuffer when audio for the source is required, if you have provided callbacks
 *      for the source via [AEMixerBufferSetSourceCallbacks](@ref AEMixerBuffer::AEMixerBufferSetSourceCallbacks).
 *
 * @param source            The source. This can be anything you like, as long as it is not NULL, and is unique to each source.
 * @param frames            The number of frames required.
 * @param audio             The audio buffer list - audio should be copied into the provided buffers. May be NULL, in which case your render callback should simply discard the requested audio.
 * @param userInfo          The opaque pointer passed to [AEMixerBufferSetSourceCallbacks](@ref AEMixerBuffer::AEMixerBufferSetSourceCallbacks).
 */
typedef void (*AEMixerBufferSourceRenderCallback) (AEMixerBufferSource  source,
                                                        UInt32                    frames,
                                                        AudioBufferList          *audio,
                                                        void                     *userInfo);

/*!
 * Source peek callback
 *
 *      This is called by AEMixerBuffer when it needs to know the status of the source, if you have
 *      provided callbacks for the source via
 *      [AEMixerBufferSetSourceCallbacks](@ref AEMixerBuffer::AEMixerBufferSetSourceCallbacks).
 *
 * @param source            The source. This can be anything you like, as long as it is not NULL, and is unique to each source.
 * @param outTimestamp      On output, the timestamp of the next audio from the source.
 * @param userInfo          The opaque pointer passed to [AEMixerBufferSetSourceCallbacks](@ref AEMixerBuffer::AEMixerBufferSetSourceCallbacks).
 * @return The number of available frames
 */
typedef UInt32 (*AEMixerBufferSourcePeekCallback) (AEMixerBufferSource  source,
                                                        uint64_t                 *outTimestamp,
                                                        void                     *userInfo);


/*!
 * Mixer buffer
 *
 *  This class performs mixing of multiple audio sources, using the timestamps corresponding
 *  to each audio packet from each source to synchronise all sources together.
 *
 *  To use it, create an instance, passing in the AudioStreamBasicDescription of your audio,
 *  then provide data for each source by calling @link AEMixerBufferEnqueue @endlink. Or,
 *  provide callbacks for one or more sources with @link AEMixerBufferSetSourceCallbacks @endlink,
 *  which will cause this class to call your callbacks when data is needed.
 *
 *  Then, call @link AEMixerBufferDequeue @endlink to consume mixed and synchronised audio
 *  ready for playback, recording, etc.
 */
@interface AEMixerBuffer : NSObject

/*!
 * Initialiser
 *
 * @param audioDescription  The AudioStreamBasicDescription defining the audio format used
 */
- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription;

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
 * @param mixerBuffer    The mixer buffer.
 * @param source         The audio source. This can be anything you like, as long as it is not NULL, and is unique to each source.
 * @param audio          The audio buffer list.
 * @param lengthInFrames The length of audio.
 * @param hostTime       The timestamp, in host ticks, associated with the audio.
 */
void AEMixerBufferEnqueue(AEMixerBuffer *mixerBuffer, AEMixerBufferSource source, AudioBufferList *audio, UInt32 lengthInFrames, uint64_t hostTime);

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
 * @param mixerBuffer       The mixer buffer.
 * @param bufferList        The buffer list to write audio to. The mData pointers 
 *                          may be NULL, in which case an internal buffer will be provided.
 *                          You may also pass a NULL value, which will simply discard the given
 *                          number of frames.
 * @param ioLengthInFrames  On input, the number of frames of audio to dequeue. On output, 
 *                          the number of frames returned.
 * @param outTimestamp      On output, the timestamp of the first audio sample
 */
void AEMixerBufferDequeue(AEMixerBuffer *mixerBuffer, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, uint64_t *outTimestamp);

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
void AEMixerBufferDequeueSingleSource(AEMixerBuffer *mixerBuffer, AEMixerBufferSource source, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, uint64_t *outTimestamp);

/*!
 * Peek the audio buffer
 *
 *  Use this to determine how much audio is currently buffered, and the corresponding next timestamp.
 *
 * @param mixerBuffer       The mixer buffer
 * @param outNextTimestamp  If not NULL, the timestamp in host ticks of the next available audio
 * @return Number of frames of available audio, in the specified audio format.
 */
UInt32 AEMixerBufferPeek(AEMixerBuffer *mixerBuffer, uint64_t *outNextTimestamp);

/*!
 * Set a different AudioStreamBasicDescription for a source
 */
- (void)setAudioDescription:(AudioStreamBasicDescription*)audioDescription forSource:(AEMixerBufferSource)source;

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
 * How long to wait for empty sources before assuming they are idle
 *
 *  AEMixerBufferDequeue will return 0 frames for this duration if any sources are
 *  currently empty, before assuming the source is idle and continuing.
 *
 *  Set to 0.0 to avoid waiting on idle sources.
 */
@property (nonatomic, assign) NSTimeInterval sourceIdleThreshold;

@end
