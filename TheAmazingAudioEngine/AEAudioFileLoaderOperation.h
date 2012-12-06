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
 *  If you wish to load a file synchronously, then you can simply start
 *  the operation yourself, like so:
 *
 *  @code
 *  AEAudioFileLoaderOperation *operation = [[AEAudioFileLoaderOperation alloc] initWithFileURL:url 
 *                                                                       targetAudioDescription:audioDescription];
 *  [operation start];
 *
 *  if ( operation.error ) {
 *     // Load failed! Clean up, report error, etc.
 *  } else {
 *     // Load finished - grab the audio
 *     _bufferList = operation.bufferList;
 *     _lengthInFrames = operation.lengthInFrames;
 *  }
 *  
 *  [operation release]; // If not using ARC
 *  @endcode
 *
 *  Note that this class is not suitable for use with large audio files, 
 *  which should be loaded incrementally as playback occurs.
 */
@interface AEAudioFileLoaderOperation : NSOperation

/*!
 * Get info for a file
 *
 * @param url               URL to the file
 * @param audioDescription  On output, if not NULL, will be filled with the file's audio description
 * @param lengthInFrames    On output, if not NULL, will indicated the file length in frames
 * @param error             If not NULL, and an error occurs, this contains the error that occurred
 * @return YES if file info was loaded successfully
 */
+ (BOOL)infoForFileAtURL:(NSURL*)url audioDescription:(AudioStreamBasicDescription*)audioDescription lengthInFrames:(UInt32*)lengthInFrames error:(NSError**)error;

/*!
 * Initializer
 *
 * @param url URL to the file to load
 * @param audioDescription The target audio description
 * @param completionBlock The block to invoke upon completion or error
 */
- (id)initWithFileURL:(NSURL*)url targetAudioDescription:(AudioStreamBasicDescription)audioDescription;

/*!
 * A block to use to receive audio
 *
 *  If this is set, then audio will be provided via this block as it is
 *  loaded, instead of stored within @link bufferList @endlink.
 */
@property (nonatomic, copy) void (^audioReceiverBlock)(AudioBufferList *audio, UInt32 lengthInFrames);

/*!
 * The loaded audio, once operation has completed, unless @link audioReceiverBlock @endlink is set.
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
