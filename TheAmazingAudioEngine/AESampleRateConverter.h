//
//  AESampleRateConverter.h
//  TheAmazingAudioEngine
//
//  Created by Steve Rubin on 8/14/15.
//  Copyright (c) 2015 A Tasty Pixel. All rights reserved.
//

#ifdef __cplusplus
extern "C" {
#endif

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

/*!
 * Universal sample rate converter
 *
 *  Use this class to easily convert audio sample rates.
 */
@interface AESampleRateConverter : NSObject

/*!
 * Initialize
 *
 * @param sourceFormat The source audio format to use
 */
- (id)initWithSourceFormat:(AudioStreamBasicDescription)sourceFormat;

/*!
 * Convert audio to audio with a different sample rate
 *
 *  This C function, safe to use in a Core Audio realtime thread context, will take
 *  an audio buffer list of audio in the format you provided at initialisation, and
 *  convert it into a noninterleaved float array.
 *
 * @param converter         Pointer to the converter object.
 * @param sourceBuffer      An audio buffer list containing the source audio.
 * @param targetBuffers     An array of floating-point arrays to store the resampled audio into.
 *                          Note that you must provide the correct number of arrays, to match the number of channels.
 * @param inFrames          The number of frames to convert.
 * @param outFrames         The number of converted frames in the target buffers, after resampling
 * @return YES on success; NO on failure
 */
BOOL AESampleRateConverterToBuffers(AESampleRateConverter* converter, AudioBufferList *sourceBuffer, float * const * targetBuffers, UInt32 inFrames, UInt32 *outFrames);

/*!
 * Convert audio to audio with a different sample rate, in a buffer list
 *
 *  This C function, safe to use in a Core Audio realtime thread context, will take
 *  an audio buffer list of audio in the format you provided at initialisation, and
 *  convert its sample rate to the rate specified in destFormat.
 *
 * @param converter         Pointer to the converter object.
 * @param sourceBuffer      An audio buffer list containing the source audio.
 * @param targetBuffer      An audio buffer list to store the audio with new destFormat sample rate
 * @param inFrames          The number of frames to convert.
 * @param outFrames         The number of converted frames in the target buffer, after resampling
 * @return YES on success; NO on failure
 */
BOOL AESampleRateConverterToBufferList(AESampleRateConverter* converter, AudioBufferList *sourceBuffer,  AudioBufferList *targetBuffer, UInt32 inFrames, UInt32 *outFrames);

/*!
 * The AudioStreamBasicDescription representing the resampled format
 */
@property (nonatomic, assign) AudioStreamBasicDescription destFormat;

/*!
 * The source audio format set at initialization
 */
@property (nonatomic, assign) AudioStreamBasicDescription sourceFormat;


@end

    
#ifdef __cplusplus
}
#endif
