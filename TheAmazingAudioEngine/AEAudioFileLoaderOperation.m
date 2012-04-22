//
//  AEAudioFileLoaderOperation.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 17/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEAudioFileLoaderOperation.h"

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/'),__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
        return NO;
    }
    return YES;
}


@interface AEAudioFileLoaderOperation ()
@property (nonatomic, retain) NSURL *url;
@property (nonatomic, assign) AudioStreamBasicDescription targetAudioDescription;
@property (nonatomic, readwrite) AudioBufferList *bufferList;
@property (nonatomic, readwrite) UInt32 lengthInFrames;
@property (nonatomic, retain, readwrite) NSError *error;
@end

@implementation AEAudioFileLoaderOperation
@synthesize url = _url, targetAudioDescription = _targetAudioDescription, bufferList = _bufferList, lengthInFrames = _lengthInFrames, error = _error;

+ (AudioStreamBasicDescription)audioDescriptionForFileAtURL:(NSURL*)url error:(NSError **)error {
    AudioStreamBasicDescription audioDescription;
    memset(&audioDescription, 0, sizeof(audioDescription));
    
    ExtAudioFileRef audioFile;
    OSStatus status;
    
    // Open file
    status = ExtAudioFileOpenURL((CFURLRef)url, &audioFile);
    if ( !checkResult(status, "ExtAudioFileOpenURL") ) {
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't open the audio file", @"") 
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return audioDescription;
    }
        
    // Get data format
    AudioStreamBasicDescription fileAudioDescription;
    UInt32 size = sizeof(fileAudioDescription);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &size, &fileAudioDescription);
    if ( !checkResult(status, "ExtAudioFileGetProperty") ) {
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the audio file", @"") 
                                                                                   forKey:NSLocalizedDescriptionKey]];
    }
    
    ExtAudioFileDispose(audioFile);
    
    return audioDescription;
}

-(id)initWithFileURL:(NSURL *)url targetAudioDescription:(AudioStreamBasicDescription)audioDescription {
    if ( !(self = [super init]) ) return nil;
    
    self.url = url;
    self.targetAudioDescription = audioDescription;
    
    return self;
}

-(void)dealloc {
    self.url = nil;
    self.error = nil;
    [super dealloc];
}

-(void)main {
    ExtAudioFileRef audioFile;
    OSStatus status;
    
    // Open file
    status = ExtAudioFileOpenURL((CFURLRef)_url, &audioFile);
    if ( !checkResult(status, "ExtAudioFileOpenURL") ) {
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't open the audio file", @"") 
                                                                          forKey:NSLocalizedDescriptionKey]];
        return;
    }
    
    // Get file data format
    AudioStreamBasicDescription fileAudioDescription;
    UInt32 size = sizeof(fileAudioDescription);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &size, &fileAudioDescription);
    if ( !checkResult(status, "ExtAudioFileGetProperty(kExtAudioFileProperty_FileDataFormat)") ) {
        ExtAudioFileDispose(audioFile);
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the audio file", @"") 
                                                                          forKey:NSLocalizedDescriptionKey]];
        return;
    }
    
    // Apply client format
    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(_targetAudioDescription), &_targetAudioDescription);
    if ( !checkResult(status, "ExtAudioFileSetProperty(kExtAudioFileProperty_ClientDataFormat)") ) {
        ExtAudioFileDispose(audioFile);
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:NSLocalizedString(@"Couldn't convert the audio file (error %d)", @""), status]
                                                                          forKey:NSLocalizedDescriptionKey]];
        return;
    }
    
    // Determine length in frames (in original file's sample rate)
    UInt64 fileLengthInFrames;
    size = sizeof(fileLengthInFrames);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &size, &fileLengthInFrames);
    if ( !checkResult(status, "ExtAudioFileGetProperty(kExtAudioFileProperty_FileLengthFrames)") ) {
        ExtAudioFileDispose(audioFile);
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the audio file", @"") 
                                                                          forKey:NSLocalizedDescriptionKey]];
        return;
    }
    
    // Calculate the true length in frames, given the original and target sample rates
    fileLengthInFrames = ceil(fileLengthInFrames * (_targetAudioDescription.mSampleRate / fileAudioDescription.mSampleRate));
    
    // Prepare buffers
    int bufferCount = (_targetAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? _targetAudioDescription.mChannelsPerFrame : 1;
    int channelsPerBuffer = (_targetAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : _targetAudioDescription.mChannelsPerFrame;
    AudioBufferList *bufferList = (AudioBufferList*)malloc(sizeof(AudioBufferList) + (bufferCount-1)*sizeof(AudioBuffer));
    bufferList->mNumberBuffers = bufferCount;
    char* audioDataPtr[bufferCount];
    for ( int i=0; i<bufferCount; i++ ) {
        int bufferSize = fileLengthInFrames * _targetAudioDescription.mBytesPerFrame;
        audioDataPtr[i] = malloc(bufferSize);
        if ( !audioDataPtr[i] ) {
            ExtAudioFileDispose(audioFile);
            for ( int j=0; j<i; j++ ) free(audioDataPtr[j]);
            free(bufferList);
            self.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM 
                                         userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Not enough memory to open file", @"")
                                                                              forKey:NSLocalizedDescriptionKey]];
            return;
        }
        
        bufferList->mBuffers[i].mData = audioDataPtr[i];
        bufferList->mBuffers[i].mDataByteSize = bufferSize;
        bufferList->mBuffers[i].mNumberChannels = channelsPerBuffer;
    }
    
    char audioBufferListSpace[sizeof(AudioBufferList)+sizeof(AudioBuffer)];
    AudioBufferList *scratchBufferList = (AudioBufferList*)audioBufferListSpace;
    
    scratchBufferList->mNumberBuffers = bufferCount;
    
    // Perform read in multiple small chunks (otherwise ExtAudioFileRead crashes when performing sample rate conversion)
    UInt64 remainingFrames = fileLengthInFrames;
    while ( remainingFrames > 0 && ![self isCancelled] ) {
        for ( int i=0; i<scratchBufferList->mNumberBuffers; i++ ) {
            scratchBufferList->mBuffers[i].mNumberChannels = channelsPerBuffer;
            scratchBufferList->mBuffers[i].mData = audioDataPtr[i];
            scratchBufferList->mBuffers[i].mDataByteSize = MIN(16384, remainingFrames * _targetAudioDescription.mBytesPerFrame);
        }
        
        // Perform read
        UInt32 numberOfPackets = (UInt32)(scratchBufferList->mBuffers[0].mDataByteSize / _targetAudioDescription.mBytesPerFrame);
        status = ExtAudioFileRead(audioFile, &numberOfPackets, scratchBufferList);
        
        if ( numberOfPackets == 0 ) {
            // Termination condition
            break;
        }
        
        if ( status != noErr ) {
            ExtAudioFileDispose(audioFile);
            self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                         userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:NSLocalizedString(@"Couldn't read the audio file (error %d)", @""), status]
                                                                              forKey:NSLocalizedDescriptionKey]];
            return;
        }
        
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            audioDataPtr[i] += numberOfPackets * _targetAudioDescription.mBytesPerFrame;
        }
        remainingFrames -= numberOfPackets;
    }
    
    // Clean up        
    ExtAudioFileDispose(audioFile);
    
    if ( [self isCancelled] ) {
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            free(bufferList->mBuffers[i].mData);
        }
        free(bufferList);
    } else {
        _bufferList = bufferList;
        _lengthInFrames = fileLengthInFrames;
    }
}

@end
