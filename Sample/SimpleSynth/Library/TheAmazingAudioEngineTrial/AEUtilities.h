//
//  AEUtilities.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 23/03/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

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
int ABGetNumberOfFramesInAudioBufferList(AudioBufferList *list, AudioStreamBasicDescription *audioFormat, int *oNumberOfChannels);

/*!
 * Initialize an audio buffer list structure
 *
 *  Uses info from the given audio format to populate the fields in the given
 *  audio buffer list.
 *
 *  Sample usage:
 *  
 *  <code>
 *  char audioBufferListSpace[sizeof(AudioBufferList)+sizeof(AudioBuffer)];
 *  AudioBufferList *bufferList = (AudioBufferList*)audioBufferListSpace;
 *  ABInitAudioBufferList(bufferList, sizeof(audioBufferListSpace), &THIS->_audioFormat, THIS->_audioBuffer, kAudioBufferSize);
 *  </code>
 *
 * @param list          Audio buffer list to initialize
 * @param listSize      Size of buffer list structure (eg. "sizeof(list)")
 * @param audioFormat   Pointer to audio format describing audio to be stored in buffer list
 * @param data          Optional pointer to a buffer to point the mData pointers within buffer list to.
 *                      If audio format is stereo and non-interleaved, the second channel will point to the mid-point of the data buffer (data + dataSize/2)
 * @param dataSize      Size of 'data' buffer, in bytes.
 */
void ABInitAudioBufferList(AudioBufferList *list, int listSize, AudioStreamBasicDescription *audioFormat, void *data, int dataSize);
    
#ifdef __cplusplus
}
#endif