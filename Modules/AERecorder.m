//
//  AERecorder.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 23/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AERecorder.h"
#import "AEMixerBuffer.h"
#import "AEAudioFileWriter.h"

#define kProcessChunkSize 8192

@interface AERecorder () {
    BOOL _recording;
    AudioBufferList *_buffer;
}
@property (nonatomic, retain) AEMixerBuffer *mixer;
@property (nonatomic, retain) AEAudioFileWriter *writer;
@end

@implementation AERecorder
@synthesize mixer = _mixer, writer = _writer;
@dynamic path;

+ (BOOL)AACEncodingAvailable {
    return [AEAudioFileWriter AACEncodingAvailable];
}

- (id)initWithAudioController:(AEAudioController*)audioController {
    if ( !(self = [super init]) ) return nil;
    self.mixer = [[[AEMixerBuffer alloc] initWithAudioDescription:*audioController.audioDescription] autorelease];
    self.writer = [[[AEAudioFileWriter alloc] initWithAudioDescription:*audioController.audioDescription audioController:audioController] autorelease];
    if ( audioController.inputAudioDescription->mChannelsPerFrame != audioController.audioDescription->mChannelsPerFrame ) {
        [_mixer setAudioDescription:AEAudioControllerInputAudioDescription(audioController) forSource:AEAudioSourceInput];
    }
    _buffer = AEAllocateAndInitAudioBufferList(audioController.audioDescription, 0);
    
    return self;
}

-(void)dealloc {
    free(_buffer);
    self.mixer = nil;
    self.writer = nil;
    [super dealloc];
}

- (BOOL)beginRecordingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType error:(NSError**)error {
    BOOL result = [_writer beginWritingToFileAtPath:path fileType:fileType error:error];
    if ( result ) _recording = YES;
    return result;
}

- (void)finishRecording {
    _recording = NO;
    [_writer finishWriting];
}

-(NSString *)path {
    return _writer.path;
}

static void audioCallback(id                        receiver,
                          AEAudioController        *audioController,
                          void                     *source,
                          const AudioTimeStamp     *time,
                          UInt32                    frames,
                          AudioBufferList          *audio) {
    AERecorder *THIS = receiver;
    if ( !THIS->_recording ) return;
    
    AEMixerBufferEnqueue(THIS->_mixer, source, audio, frames, time->mHostTime);
    printf("%lu in (%p)\n", frames, source);
    
    // Let the mixer buffer provide the audio buffer
    UInt32 bufferLength = kProcessChunkSize;
    for ( int i=0; i<THIS->_buffer->mNumberBuffers; i++ ) {
        THIS->_buffer->mBuffers[i].mData = NULL;
        THIS->_buffer->mBuffers[i].mDataByteSize = 0;
    }
    
    AEMixerBufferDequeue(THIS->_mixer, THIS->_buffer, &bufferLength);
    printf("%lu out\n", bufferLength);
    
    if ( bufferLength > 0 ) {
        AEAudioFileWriterAddAudio(THIS->_writer, THIS->_buffer, bufferLength);
    }
}

-(AEAudioControllerAudioCallback)receiverCallback {
    return audioCallback;
}

@end
