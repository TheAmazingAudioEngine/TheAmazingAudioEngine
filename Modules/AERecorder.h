//
//  AERecorder.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 23/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

extern NSString * AERecorderDidEncounterErrorNotification;
extern NSString * kAERecorderErrorKey;

/*!
 * Recorder utility, used for recording live audio to disk
 *
 *  This can be used to record just the microphone input, or the output of the
 *  audio system, just one channel, or a combination of all three. Simply add an
 *  instance of this class as an audio receiver for the particular audio you wish
 *  to record, using AEAudioController's [addInputReceiver:](@ref AEAudioController::addInputReceiver:),
 *  [addOutputReceiver:](@ref AEAudioController::addOutputReceiver:),
 *  [addOutputReceiver:forChannel:](@ref AEAudioController::addOutputReceiver:forChannel:), etc, and all 
 *  streams will be mixed together and recorded.
 *
 *  See the sample app for a demonstration.
 */
@interface AERecorder : NSObject <AEAudioReceiver>

/*!
 * Determine whether AAC encoding is possible on this device
 */
+ (BOOL)AACEncodingAvailable;

/*!
 * Initialise
 *
 * @param audioController The Audio Controller
 */
- (id)initWithAudioController:(AEAudioController*)audioController;

/*!
 * Start recording
 *
 * @param path The path to record to
 * @param fileType The kind of file to create
 * @param error The error, if not NULL and if an error occurs
 * @return YES on success, NO on failure.
 */
- (BOOL)beginRecordingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType error:(NSError**)error;

/*!
 * Finish recording and close file
 */
- (void)finishRecording;

/*!
 * The path
 */
@property (nonatomic, retain, readonly) NSString *path;
@end
