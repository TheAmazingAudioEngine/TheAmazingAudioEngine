//
//  AERecorder.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 23/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

extern NSString * AEAudioFileWriterDidEncounterErrorNotification;

extern NSString * kAEAudioFileWriterErrorKey;
extern NSString * AEAudioFileWriterErrorDomain;

@interface AERecorder : NSObject <AEAudioReceiver>
+ (BOOL)AACEncodingAvailable;

- (id)initWithAudioController:(AEAudioController*)audioController;

- (BOOL)beginRecordingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType error:(NSError**)error;
- (void)finishRecording;

@property (nonatomic, retain, readonly) NSString *path;
@end
