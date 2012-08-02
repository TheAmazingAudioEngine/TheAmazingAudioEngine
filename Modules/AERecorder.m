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

NSString * AERecorderDidEncounterErrorNotification = @"AERecorderDidEncounterErrorNotification";
NSString * kAERecorderErrorKey = @"error";

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
    self.mixer = [[[AEMixerBuffer alloc] initWithAudioDescription:audioController.audioDescription] autorelease];
    self.writer = [[[AEAudioFileWriter alloc] initWithAudioDescription:audioController.audioDescription] autorelease];
    if ( audioController.inputAudioDescription.mChannelsPerFrame != audioController.audioDescription.mChannelsPerFrame ) {
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

struct reportError_t { AERecorder *THIS; OSStatus result; };
static void reportError(AEAudioController *audioController, void *userInfo, int length) {
    struct reportError_t *arg = userInfo;
    NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain 
                                         code:arg->result
                                     userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:NSLocalizedString(@"Error while saving audio: Code %d", @""), arg->result]
                                                                          forKey:NSLocalizedDescriptionKey]];
    [[NSNotificationCenter defaultCenter] postNotificationName:AERecorderDidEncounterErrorNotification
                                                        object:arg->THIS
                                                      userInfo:[NSDictionary dictionaryWithObject:error forKey:kAERecorderErrorKey]];
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
    
    // Let the mixer buffer provide the audio buffer
    UInt32 bufferLength = kProcessChunkSize;
    for ( int i=0; i<THIS->_buffer->mNumberBuffers; i++ ) {
        THIS->_buffer->mBuffers[i].mData = NULL;
        THIS->_buffer->mBuffers[i].mDataByteSize = 0;
    }
    
    AEMixerBufferDequeue(THIS->_mixer, THIS->_buffer, &bufferLength, NULL);
    
    if ( bufferLength > 0 ) {
        OSStatus status = AEAudioFileWriterAddAudio(THIS->_writer, THIS->_buffer, bufferLength);
        if ( status != noErr ) {
            AEAudioControllerSendAsynchronousMessageToMainThread(audioController, 
                                                                 reportError, 
                                                                 &(struct reportError_t) { .THIS = THIS, .result = status }, 
                                                                 sizeof(struct reportError_t));
        }
    }
}

-(AEAudioControllerAudioCallback)receiverCallback {
    return audioCallback;
}

@end
