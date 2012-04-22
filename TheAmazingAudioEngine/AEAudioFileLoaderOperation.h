//
//  AEAudioFileLoaderOperation.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 17/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@class AEAudioFileLoaderOperation;

/*!
 * Audio file loader operation
 *
 *  This in an NSOperation object that is used to load an arbitraty
 *  audio file into memory.  Use it by creating an instance, passing in
 *  the file URL to the audio file, the audio description for the format
 *  you the loaded audio in, optionally setting a completion block, and 
 *  adding the operation to an operation queue.
 *
 *  If you wish to load a file synchronously, then you can create an
 *  operation queue, then wait upon it, like so:
 *
 *  @code
 *  AEAudioFileLoaderOperation *operation = [[AEAudioFileLoaderOperation alloc] initWithFileURL:url targetAudioDescription:audioDescription];
 *  NSOperationQueue *queue = [[NSOperationQueue alloc] init];
 *  [queue addOperation:operation];
 *  [queue waitUntilAllOperationsAreFinished];
 *  
 *  if ( operation.error ) {
 *     // Load failed! Clean up, report error, etc.
 *  } else {
 *     // Load finished - grab the audio
 *     _bufferList = operation.bufferList;
 *     _lengthInFrames = operation.lengthInFrames;
 *  }
 *  
 *  [operation release];
 *  [queue release];
 *  @endcode
 *
 *  Note that this is not suitable for large audio files, which should
 *  be loaded incrementally as playback occurs.
 */
@interface AEAudioFileLoaderOperation : NSOperation

/*!
 * Get the audio format of a file
 *
 * @param url URL to the file
 * @param error If not NULL, and an error occurs, this contains the error that occurred
 * @return The AudioStreamBasicDescription describing the audio format in the file
 */
+ (AudioStreamBasicDescription)audioDescriptionForFileAtURL:(NSURL*)url error:(NSError**)error;

/*!
 * Initializer
 *
 * @param url URL to the file to load
 * @param audioDescription The target audio description
 * @param completionBlock The block to invoke upon completion or error
 */
- (id)initWithFileURL:(NSURL*)url targetAudioDescription:(AudioStreamBasicDescription)audioDescription;

/*!
 * The loaded audio, once operation has completed
 *
 *  You are responsible for freeing both the memory pointed to by each mData pointer,
 *  as well as the buffer list itself. If an error occurred, this will be NULL.
 */
@property (nonatomic, readonly) AudioBufferList *bufferList;

/*!
 * The length of the audio file
 */
@property (nonatomic, readonly) UInt32 lengthInFrames;

/*!
 * The error, if one occurred
 */
@property (nonatomic, retain, readonly) NSError *error;

@end
