//
//  AEAudioFileWriter.h
//  The Amazing Audio Engine (Extras)
//
//  Created by Michael Tyson on 20/03/2012.
//  Copyright 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

extern NSString * AEAudioFileWriterDidEncounterErrorNotification;

extern NSString * kAEAudioFileWriterErrorKey;
extern NSString * AEAudioFileWriterErrorDomain;
enum {
    AEAudioFileWriterFormatError
};

@class AEAudioController;

@interface AEAudioFileWriter : NSObject
+ (BOOL)AACEncodingAvailable;

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription audioController:(AEAudioController*)audioController;

- (BOOL)beginWritingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType error:(NSError**)error;
- (void)finishWriting;

void AEAudioFileWriterAddAudio(AEAudioFileWriter* recorder, AudioBufferList *bufferList, UInt32 lengthInFrames);

@property (nonatomic, retain, readonly) NSString *path;
@end
