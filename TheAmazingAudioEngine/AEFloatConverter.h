//
//  AEFloatConverter.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 25/10/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

/*!
 * Universal converter to float format
 *
 *  Use this class to easily convert arbitrary audio formats to floating point
 *  for use with utilities like the Accelerate framework.
 */
@interface AEFloatConverter : NSObject

/*!
 * Initialize
 *
 * @param sourceFormat The audio format to use
 */
- (id)initWithSourceFormat:(AudioStreamBasicDescription)sourceFormat;

/*!
 * Convert audio to floating-point
 *
 *  This C function, safe to use in a Core Audio realtime thread context, will take
 *  an audio buffer list of audio in the format you provided at initialisation, and
 *  convert it into a noninterleaved float array.
 *
 * @param converter         Pointer to the converter object.
 * @param sourceBuffer      An audio buffer list containing the source audio.
 * @param targetBuffers     An array of floating-point arrays to store the converted float audio into. 
 *                          Note that you must provide the correct number of arrays, to match the number of channels.
 * @param frames            The number of frames to convert.
 * @return YES on success; NO on failure
 */
BOOL AEFloatConverterToFloat(AEFloatConverter* converter, AudioBufferList *sourceBuffer, float * const * targetBuffers, UInt32 frames);

/*!
 * Convert audio to floating-point, in a buffer list
 *
 *  This C function, safe to use in a Core Audio realtime thread context, will take
 *  an audio buffer list of audio in the format you provided at initialisation, and
 *  convert it into a noninterleaved float format.
 *
 * @param converter         Pointer to the converter object.
 * @param sourceBuffer      An audio buffer list containing the source audio.
 * @param targetBuffer      An audio buffer list to store the converted floating-point audio.
 * @param frames            The number of frames to convert.
 * @return YES on success; NO on failure
 */
BOOL AEFloatConverterToFloatBufferList(AEFloatConverter* converter, AudioBufferList *sourceBuffer,  AudioBufferList *targetBuffer, UInt32 frames);

/*!
 * Convert audio from floating-point
 *
 *  This C function, safe to use in a Core Audio realtime thread context, will take
 *  an audio buffer list of audio in the format you provided at initialisation, and
 *  convert it into a float array.
 *
 * @param converter         Pointer to the converter object.
 * @param sourceBuffers     An array of floating-point arrays containing the floating-point audio to convert.
 *                          Note that you must provide the correct number of arrays, to match the number of channels.
 * @param targetBuffer      An audio buffer list to store the converted audio into.
 * @param frames            The number of frames to convert.
 * @return YES on success; NO on failure
 */
BOOL AEFloatConverterFromFloat(AEFloatConverter* converter, float * const * sourceBuffers, AudioBufferList *targetBuffer, UInt32 frames);

/*!
 * Convert audio from floating-point, in a buffer list
 *
 *  This C function, safe to use in a Core Audio realtime thread context, will take
 *  an audio buffer list of audio in the format you provided at initialisation, and
 *  convert it into a float array.
 *
 * @param converter         Pointer to the converter object.
 * @param sourceBuffers     An audio buffer list containing the source audio.
 * @param targetBuffer      An audio buffer list to store the converted audio into.
 * @param frames            The number of frames to convert.
 * @return YES on success; NO on failure
 */
BOOL AEFloatConverterFromFloatBufferList(AEFloatConverter* converter, AudioBufferList *sourceBuffer, AudioBufferList *targetBuffer, UInt32 frames);

/*!
 * The AudioStreamBasicDescription representing the converted floating-point format
 */
@property (nonatomic, readonly) AudioStreamBasicDescription floatingPointAudioDescription;

@end
