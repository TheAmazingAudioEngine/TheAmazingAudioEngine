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

@interface AEAudioFileWriter : NSObject
+ (BOOL)AACEncodingAvailable;

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription;

- (BOOL)beginWritingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType error:(NSError**)error;
- (void)finishWriting;

OSStatus AEAudioFileWriterAddAudio(AEAudioFileWriter* writer, AudioBufferList *bufferList, UInt32 lengthInFrames);
OSStatus AEAudioFileWriterAddAudioSynchronously(AEAudioFileWriter* THIS, AudioBufferList *bufferList, UInt32 lengthInFrames);

@property (nonatomic, retain, readonly) NSString *path;
@end
