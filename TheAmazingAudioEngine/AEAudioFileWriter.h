//
//  AEAudioFileWriter.h
//  The Amazing Audio Engine (Extras)
//
//  Created by Michael Tyson on 20/03/2012.
//  Copyright 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

extern NSString * AEAudioFileWriterErrorDomain;

enum {
    kAEAudioFileWriterFormatError
};

@class AEAudioController;

/*!
 * Audio file writer
 *
 *  Provides an easy-to-use interface to the ExtAudioFile API, allowing
 *  asynchronous, Core Audio thread-safe writing of arbitrary audio formats.
 */
@interface AEAudioFileWriter : NSObject
+ (BOOL)AACEncodingAvailable;

/*!
 * Initialise, with a given audio description to use
 *
 * @param audioDescription The audio format of audio that will be fed to this class
 *                         via the AddAudio functions.
 */
- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription;

/*!
 * Begin write operation
 *
 *  This will create the output file and prepare internal structures for writing.
 *
 * @param path The path to the file to create
 * @param fileType A file type
 * @param error On output, if not NULL, the error if one occurred
 * @return YES on success; NO on error
 */
- (BOOL)beginWritingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType error:(NSError**)error;

/*!
 * Complete writing operation
 *
 *  Finishes write, closes the file and cleans up internal resources.
 */
- (void)finishWriting;

/*!
 * Add audio to be written
 *
 *  This C function, safe to be used in a Core Audio realtime thread context, is used to
 *  feed audio to this class to be written to the file.
 *
 *  It runs asynchronously, and will never block.
 *
 * @param writer A pointer to the writer object
 * @param bufferList An AudioBufferList containing the audio in the format you provided upon initialization
 * @param lengthInFrames The length of the audio in the buffer list, in frames
 * @return A status code; noErr on success
 */
OSStatus AEAudioFileWriterAddAudio(AEAudioFileWriter* writer, AudioBufferList *bufferList, UInt32 lengthInFrames);

/*!
 * Add audio to be written, synchronously
 *
 *  This C function allows you to synchronously add audio - it will block until the audio is written to the
 *  file. Note that due to the fact that it will block, this function is not to be used from a Core Audio
 *  realtime thread.
 *
 * @param writer A pointer to the writer object
 * @param bufferList An AudioBufferList containing the audio in the format you provided upon initialization
 * @param lengthInFrames The length of the audio in the buffer list, in frames
 * @return A status code; noErr on success
 */
OSStatus AEAudioFileWriterAddAudioSynchronously(AEAudioFileWriter* writer, AudioBufferList *bufferList, UInt32 lengthInFrames);

/*!
 * The path to the file being written
 */
@property (nonatomic, retain, readonly) NSString *path;

@end
