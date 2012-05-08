//
//  AEAudioFileLoaderOperation.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 17/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEAudioFileLoaderOperation.h"
#import "AEUtilities.h"

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
        return NO;
    }
    return YES;
}

static const int kIncrementalLoadBufferSize = 4096;

@interface AEAudioFileLoaderOperation ()
@property (nonatomic, retain) NSURL *url;
@property (nonatomic, assign) AudioStreamBasicDescription targetAudioDescription;
@property (nonatomic, readwrite) AudioBufferList *bufferList;
@property (nonatomic, readwrite) UInt32 lengthInFrames;
@property (nonatomic, retain, readwrite) NSError *error;
@end

@implementation AEAudioFileLoaderOperation
@synthesize url = _url, targetAudioDescription = _targetAudioDescription, audioReceiverBlock = _audioReceiverBlock, bufferList = _bufferList, lengthInFrames = _lengthInFrames, error = _error;

+ (BOOL)infoForFileAtURL:(NSURL*)url audioDescription:(AudioStreamBasicDescription*)audioDescription lengthInFrames:(UInt32*)lengthInFrames error:(NSError**)error {
    if ( audioDescription ) memset(audioDescription, 0, sizeof(AudioStreamBasicDescription));
    
    ExtAudioFileRef audioFile;
    OSStatus status;
    
    // Open file
    status = ExtAudioFileOpenURL((CFURLRef)url, &audioFile);
    if ( !checkResult(status, "ExtAudioFileOpenURL") ) {
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't open the audio file", @"") 
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return NO;
    }
        
    if ( audioDescription ) {
        // Get data format
        UInt32 size = sizeof(AudioStreamBasicDescription);
        status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &size, audioDescription);
        if ( !checkResult(status, "ExtAudioFileGetProperty") ) {
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                                  userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the audio file", @"") 
                                                                                       forKey:NSLocalizedDescriptionKey]];
            return NO;
        }
    }    
    
    if ( lengthInFrames ) {
        // Get length
        UInt64 fileLengthInFrames = 0;
        UInt32 size = sizeof(fileLengthInFrames);
        status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &size, &fileLengthInFrames);
        if ( !checkResult(status, "ExtAudioFileGetProperty(kExtAudioFileProperty_FileLengthFrames)") ) {
            ExtAudioFileDispose(audioFile);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                                  userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the audio file", @"") 
                                                                                       forKey:NSLocalizedDescriptionKey]];
            return NO;
        }
        *lengthInFrames = fileLengthInFrames;
    }
    
    ExtAudioFileDispose(audioFile);
    
    return YES;
}

-(id)initWithFileURL:(NSURL *)url targetAudioDescription:(AudioStreamBasicDescription)audioDescription {
    if ( !(self = [super init]) ) return nil;
    
    self.url = url;
    self.targetAudioDescription = audioDescription;
    
    return self;
}

-(void)dealloc {
    self.audioReceiverBlock = nil;
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
    AudioBufferList *bufferList = AEAllocateAndInitAudioBufferList(_targetAudioDescription, _audioReceiverBlock ? kIncrementalLoadBufferSize : fileLengthInFrames);
    if ( !bufferList ) {
        ExtAudioFileDispose(audioFile);
        self.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM 
                                     userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Not enough memory to open file", @"")
                                                                          forKey:NSLocalizedDescriptionKey]];
        return;
    }
    
    AudioBufferList *scratchBufferList = AEAllocateAndInitAudioBufferList(_targetAudioDescription, 0);
    
    // Perform read in multiple small chunks (otherwise ExtAudioFileRead crashes when performing sample rate conversion)
    UInt64 readFrames = 0;
    while ( readFrames < fileLengthInFrames && ![self isCancelled] ) {
        if ( _audioReceiverBlock ) {
            memcpy(scratchBufferList, bufferList, sizeof(AudioBufferList)+(bufferCount-1)*sizeof(AudioBuffer));
            for ( int i=0; i<scratchBufferList->mNumberBuffers; i++ ) {
                scratchBufferList->mBuffers[i].mDataByteSize = MIN(kIncrementalLoadBufferSize * _targetAudioDescription.mBytesPerFrame,
                                                                   (fileLengthInFrames-readFrames) * _targetAudioDescription.mBytesPerFrame);
            }
        } else {
            for ( int i=0; i<scratchBufferList->mNumberBuffers; i++ ) {
                scratchBufferList->mBuffers[i].mNumberChannels = channelsPerBuffer;
                scratchBufferList->mBuffers[i].mData = (char*)bufferList->mBuffers[i].mData + readFrames*_targetAudioDescription.mBytesPerFrame;
                scratchBufferList->mBuffers[i].mDataByteSize = MIN(16384, (fileLengthInFrames-readFrames) * _targetAudioDescription.mBytesPerFrame);
            }
        }
        
        // Perform read
        UInt32 numberOfPackets = (UInt32)(scratchBufferList->mBuffers[0].mDataByteSize / _targetAudioDescription.mBytesPerFrame);
        status = ExtAudioFileRead(audioFile, &numberOfPackets, scratchBufferList);
        
        if ( status != noErr ) {
            ExtAudioFileDispose(audioFile);
            self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                         userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:NSLocalizedString(@"Couldn't read the audio file (error %d)", @""), status]
                                                                              forKey:NSLocalizedDescriptionKey]];
            return;
        }
        
        if ( numberOfPackets == 0 ) {
            // Termination condition
            break;
        }
        
        if ( _audioReceiverBlock ) {
            _audioReceiverBlock(bufferList, numberOfPackets);
        }
        
        readFrames += numberOfPackets;
    }
    
    if ( _audioReceiverBlock ) {
        AEFreeAudioBufferList(bufferList);
        bufferList = NULL;
    }
    
    free(scratchBufferList);
    
    // Clean up        
    ExtAudioFileDispose(audioFile);
    
    if ( [self isCancelled] ) {
        if ( bufferList ) {
            for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
                free(bufferList->mBuffers[i].mData);
            }
            free(bufferList);
            bufferList = NULL;
        }
    } else {
        _bufferList = bufferList;
        _lengthInFrames = fileLengthInFrames;
    }
}

@end
