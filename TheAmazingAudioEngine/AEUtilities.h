//
//  AEUtilities.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 23/03/2012.
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

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - AudioBufferList Utilities
/** @name AudioBufferList Utilities */
///@{

/*!
 * Allocate an audio buffer list and the associated mData pointers.
 *
 *  Note: Do not use this utility from within the Core Audio thread (such as inside a render
 *  callback). It may cause the thread to block, inducing audio stutters.
 *
 * @param audioFormat       Audio format describing audio to be stored in buffer list
 * @param frameCount        The number of frames to allocate space for (or 0 to just allocate the list structure itself)
 * @return The allocated and initialised audio buffer list
 */
AudioBufferList *AEAudioBufferListCreate(AudioStreamBasicDescription audioFormat, int frameCount);
#define AEAllocateAndInitAudioBufferList AEAudioBufferListCreate // Legacy alias

/*!
 * Create an audio buffer list on the stack
 *
 *  This is useful for creating buffers for temporary use, without needing to perform any
 *  memory allocations. It will create a local AudioBufferList* variable on the stack, with 
 *  a name given by the first argument, and initialise the buffer according to the given
 *  audio format.
 *
 *  The created buffer will have NULL mData pointers and 0 mDataByteSize: you will need to 
 *  assign these to point to a memory buffer.
 *
 * @param name Name of the variable to create on the stack
 * @param audioFormat The audio format to use
 */
#define AEAudioBufferListCreateOnStack(name, audioFormat) \
    int name ## _numberBuffers = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved \
                                    ? audioFormat.mChannelsPerFrame : 1; \
    char name ## _bytes[sizeof(AudioBufferList)+(sizeof(AudioBuffer)*(name ## _numberBuffers-1))]; \
    memset(&name ## _bytes, 0, sizeof(name ## _bytes)); \
    AudioBufferList * name = (AudioBufferList*)name ## _bytes; \
    name->mNumberBuffers = name ## _numberBuffers;

/*!
 * Create a stack copy of the given audio buffer list and offset mData pointers
 *
 *  This is useful for creating buffers that point to an offset into the original buffer,
 *  to fill later regions of the buffer. It will create a local AudioBufferList* variable 
 *  on the stack, with a name given by the first argument, copy the original AudioBufferList 
 *  structure values, and offset the mData and mDataByteSize variables.
 *
 *  Note that only the AudioBufferList structure itself will be copied, not the data to
 *  which it points.
 *
 * @param name Name of the variable to create on the stack
 * @param sourceBufferList The original buffer list to copy
 * @param offsetBytes Number of bytes to offset mData/mDataByteSize members
 */
#define AEAudioBufferListCopyOnStack(name, sourceBufferList, offsetBytes) \
    char name ## _bytes[sizeof(AudioBufferList)+(sizeof(AudioBuffer)*(sourceBufferList->mNumberBuffers-1))]; \
    memcpy(name ## _bytes, sourceBufferList, sizeof(name ## _bytes)); \
    AudioBufferList * name = (AudioBufferList*)name ## _bytes; \
    for ( int i=0; i<name->mNumberBuffers; i++ ) { \
        name->mBuffers[i].mData = (char*)name->mBuffers[i].mData + offsetBytes; \
        name->mBuffers[i].mDataByteSize -= offsetBytes; \
    }

/*!
 * Create a copy of an audio buffer list
 *
 *  Note: Do not use this utility from within the Core Audio thread (such as inside a render
 *  callback). It may cause the thread to block, inducing audio stutters.
 *
 * @param original          The original AudioBufferList to copy
 * @return The new, copied audio buffer list
 */
AudioBufferList *AEAudioBufferListCopy(AudioBufferList *original);
#define AECopyAudioBufferList AEAudioBufferListCopy // Legacy alias

/*!
 * Free a buffer list and associated mData buffers
 *
 *  Note: Do not use this utility from within the Core Audio thread (such as inside a render
 *  callback). It may cause the thread to block, inducing audio stutters.
 */
void AEAudioBufferListFree(AudioBufferList *bufferList);
#define AEFreeAudioBufferList AEAudioBufferListFree // Legacy alias

/*!
 * Get the number of frames in a buffer list
 *
 *  Calculates the frame count in the buffer list based on the given
 *  audio format. Optionally also provides the channel count.
 *
 * @param bufferList    Pointer to an AudioBufferList containing audio
 * @param audioFormat   Audio format describing the audio in the buffer list
 * @param oNumberOfChannels If not NULL, will be set to the number of channels of audio in 'list'
 * @return Number of frames in the buffer list
 */
UInt32 AEAudioBufferListGetLength(AudioBufferList *bufferList,
                                  AudioStreamBasicDescription audioFormat,
                                  int *oNumberOfChannels);
#define AEGetNumberOfFramesInAudioBufferList AEAudioBufferListGetLength // Legacy alias

/*!
 * Set the number of frames in a buffer list
 *
 *  Calculates the frame count in the buffer list based on the given
 *  audio format, and assigns it to the buffer list members.
 *
 * @param bufferList    Pointer to an AudioBufferList containing audio
 * @param audioFormat   Audio format describing the audio in the buffer list
 * @param frames        The number of frames to set
 */
void AEAudioBufferListSetLength(AudioBufferList *bufferList,
                                AudioStreamBasicDescription audioFormat,
                                UInt32 frames);

/*!
 * Offset the pointers in a buffer list
 *
 *  Increments the mData pointers in the buffer list by the given number
 *  of frames. This is useful for filling a buffer in incremental stages.
 *
 * @param bufferList    Pointer to an AudioBufferList containing audio
 * @param audioFormat   Audio format describing the audio in the buffer list
 * @param frames        The number of frames to offset the mData pointers by
 */
void AEAudioBufferListOffset(AudioBufferList *bufferList,
                             AudioStreamBasicDescription audioFormat,
                             UInt32 frames);

/*!
 * Silence an audio buffer list (zero out frames)
 *
 * @param bufferList    Pointer to an AudioBufferList containing audio
 * @param audioFormat   Audio format describing the audio in the buffer list
 * @param offset        Offset into buffer
 * @param length        Number of frames to silence (0 for whole buffer)
 */
void AEAudioBufferListSilence(AudioBufferList *bufferList,
                              AudioStreamBasicDescription audioFormat,
                              UInt32 offset,
                              UInt32 length);
    
/*!
 * Get the size of an AudioBufferList structure
 *
 *  Use this method when doing a memcpy of AudioBufferLists, for example.
 *
 *  Note: This method returns the size of the AudioBufferList structure itself, not the
 *  audio bytes it points to.
 *
 * @param bufferList    Pointer to an AudioBufferList
 * @return Size of the AudioBufferList structure
 */
static inline size_t AEAudioBufferListGetStructSize(AudioBufferList *bufferList) {
    return sizeof(AudioBufferList) + (bufferList->mNumberBuffers-1) * sizeof(AudioBuffer);
}

///@}
#pragma mark - AudioStreamBasicDescription Utilities
/** @name AudioStreamBasicDescription Utilities */
///@{

/*!
 * 32-bit floating-point PCM audio description, non-interleaved, 44.1kHz
 */
extern const AudioStreamBasicDescription AEAudioStreamBasicDescriptionNonInterleavedFloatStereo;

/*!
 * 16-bit stereo PCM audio description, non-interleaved, 44.1kHz
 */
extern const AudioStreamBasicDescription AEAudioStreamBasicDescriptionNonInterleaved16BitStereo;

/*!
 * 16-bit stereo PCM audio description, interleaved, 44.1kHz
 */
extern const AudioStreamBasicDescription AEAudioStreamBasicDescriptionInterleaved16BitStereo;
    
/*!
 * Types of samples, for use with AEAudioStreamBasicDescriptionMake
 */
typedef enum {
    AEAudioStreamBasicDescriptionSampleTypeFloat32, //!< 32-bit floating point
    AEAudioStreamBasicDescriptionSampleTypeInt16,   //!< Signed 16-bit integer
    AEAudioStreamBasicDescriptionSampleTypeInt32    //!< Signed 32-bit integer
} AEAudioStreamBasicDescriptionSampleType;

/*!
 * Create a custom AudioStreamBasicDescription
 *
 * @param sampleType Kind of samples
 * @param interleaved Whether samples are interleaved within the same buffer, or in separate buffers for each channel
 * @param numberOfChannels Channel count
 * @param sampleRate The sample rate, in Hz (e.g. 44100)
 * @return A new AudioStreamBasicDescription describing the audio format
 */
AudioStreamBasicDescription AEAudioStreamBasicDescriptionMake(AEAudioStreamBasicDescriptionSampleType sampleType,
                                                              BOOL interleaved,
                                                              int numberOfChannels,
                                                              double sampleRate);
    
/*!
 * Assign a channel count to an AudioStreamBasicDescription
 *
 *  This method ensures that the mBytesPerFrame/mBytesPerPacket value is updated
 *  correctly for both interleaved and non-interleaved audio.
 */
void AEAudioStreamBasicDescriptionSetChannelsPerFrame(AudioStreamBasicDescription *audioDescription, int numberOfChannels);

///@}
#pragma mark - Time Utilities
/** @name Time Utilities */
///@{

/*!
 * Get current global timestamp, in host ticks
 */
uint64_t AECurrentTimeInHostTicks(void);

/*!
 * Get current global timestamp, in seconds
 */
double AECurrentTimeInSeconds(void);

/*!
 * Convert time in seconds to host ticks
 *
 * @param seconds The time in seconds
 * @return The time in host ticks
 */
uint64_t AEHostTicksFromSeconds(double seconds);

/*!
 * Convert time in host ticks to seconds
 *
 * @param ticks The time in host ticks
 * @return The time in seconds
 */
double AESecondsFromHostTicks(uint64_t ticks);

///@}
#pragma mark - Other Utilities
/** @name Other Utilities */
///@{

/*!
 * Create an AudioComponentDescription structure
 *
 * @param manufacturer  The audio component manufacturer (e.g. kAudioUnitManufacturer_Apple)
 * @param type          The type (e.g. kAudioUnitType_Generator)
 * @param subtype       The subtype (e.g. kAudioUnitSubType_AudioFilePlayer)
 * @returns An AudioComponentDescription structure with the given attributes
 */
AudioComponentDescription AEAudioComponentDescriptionMake(OSType manufacturer, OSType type, OSType subtype);

/*!
 * Rate limit an operation
 *
 *  This can be used to prevent spamming error messages to the console
 *  when something goes wrong.
 */
BOOL AERateLimit(void);

/*!
 * Check an OSStatus condition
 *
 * @param result The result
 * @param operation A description of the operation, for logging purposes
 */
#define AECheckOSStatus(result,operation) (_AECheckOSStatus((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _AECheckOSStatus(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        if ( AERateLimit() ) {
            int fourCC = CFSwapInt32HostToBig(result);
            if ( isascii(((char*)&fourCC)[0]) && isascii(((char*)&fourCC)[1]) && isascii(((char*)&fourCC)[2]) ) {
                NSLog(@"%s:%d: %s: '%4.4s' (%d)", file, line, operation, (char*)&fourCC, (int)result);
            } else {
                NSLog(@"%s:%d: %s: %d", file, line, operation, (int)result);
            }
        }
        return NO;
    }
    return YES;
}
    
///@}
    
#ifdef __cplusplus
}
#endif