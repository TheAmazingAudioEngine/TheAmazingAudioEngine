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
AudioBufferList *AEAllocateAndInitAudioBufferList(AudioStreamBasicDescription audioFormat, int frameCount);
    
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
#define AECreateStackCopyOfAudioBufferList(name, sourceBufferList, offsetBytes) \
    char name_bytes[sizeof(AudioBufferList)+(sizeof(AudioBuffer)*(sourceBufferList->mNumberBuffers-1))]; \
    memcpy(name_bytes, sourceBufferList, sizeof(name_bytes)); \
    AudioBufferList * name = (AudioBufferList*)name_bytes; \
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
AudioBufferList *AECopyAudioBufferList(AudioBufferList *original);
    
/*!
 * Free a buffer list and associated mData buffers
 *
 *  Note: Do not use this utility from within the Core Audio thread (such as inside a render
 *  callback). It may cause the thread to block, inducing audio stutters.
 */
void AEFreeAudioBufferList(AudioBufferList *bufferList);

/*!
 * Get the number of frames in a buffer list
 *
 *  Calculates the frame count in the buffer list based on the given
 *  audio format. Optionally also provides the channel count.
 *
 * @param list          Pointer to an AudioBufferList containing audio
 * @param audioFormat   Audio format describing the audio in the buffer list
 * @param oNumberOfChannels If not NULL, will be set to the number of channels of audio in 'list'
 * @return Number of frames in the buffer list
 */
int AEGetNumberOfFramesInAudioBufferList(AudioBufferList *list,
                                         AudioStreamBasicDescription audioFormat,
                                         int *oNumberOfChannels);

/*!
 * Get the size of an AudioBufferList structure
 *
 *  Use this method when doing a memcpy of AudioBufferLists, for example.
 *
 *  Note: This method returns the size of the AudioBufferList structure itself, not the
 *  audio bytes it points to.
 *
 * @param list          Pointer to an AudioBufferList
 * @return Size of the AudioBufferList structure
 */
static inline size_t AEGetAudioBufferListSize(AudioBufferList *list) {
    return sizeof(AudioBufferList) + (list->mNumberBuffers-1) * sizeof(AudioBuffer);
}

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
 * Assign a channel count to an AudioStreamBasicDescription
 *
 *  This method ensures that the mBytesPerFrame/mBytesPerPacket value is updated
 *  correctly for interleaved audio.
 */
void AEAudioStreamBasicDescriptionSetChannelsPerFrame(AudioStreamBasicDescription *audioDescription, int numberOfChannels);

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
    
#ifdef __cplusplus
}
#endif