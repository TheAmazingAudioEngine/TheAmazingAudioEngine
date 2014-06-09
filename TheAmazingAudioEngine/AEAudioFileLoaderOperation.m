//
//  AEAudioFileLoaderOperation.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 17/04/2012.
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
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
static const int kMaxAudioFileReadSize = 16384;

@interface AEAudioFileLoaderOperation ()
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, assign) AudioStreamBasicDescription targetAudioDescription;
@property (nonatomic, readwrite) AudioBufferList *bufferList;
@property (nonatomic, readwrite) UInt32 lengthInFrames;
@property (nonatomic, strong, readwrite) NSError *error;
@end

@implementation AEAudioFileLoaderOperation
@synthesize url = _url, targetAudioDescription = _targetAudioDescription, audioReceiverBlock = _audioReceiverBlock, bufferList = _bufferList, lengthInFrames = _lengthInFrames, error = _error;

+ (BOOL)infoForFileAtURL:(NSURL*)url audioDescription:(AudioStreamBasicDescription*)audioDescription lengthInFrames:(UInt32*)lengthInFrames error:(NSError**)error {
    if ( audioDescription ) memset(audioDescription, 0, sizeof(AudioStreamBasicDescription));
    
    ExtAudioFileRef audioFile;
    OSStatus status;
    
    // Open file
    status = ExtAudioFileOpenURL((__bridge CFURLRef)url, &audioFile);
    if ( !checkResult(status, "ExtAudioFileOpenURL") ) {
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't open the audio file", @"")}];
        return NO;
    }
        
    if ( audioDescription ) {
        // Get data format
        UInt32 size = sizeof(AudioStreamBasicDescription);
        status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &size, audioDescription);
        if ( !checkResult(status, "ExtAudioFileGetProperty") ) {
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                                  userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
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
                                                  userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
            return NO;
        }
        *lengthInFrames = (UInt32)fileLengthInFrames;
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


-(void)main {
    ExtAudioFileRef audioFile;
    OSStatus status;
    
    // Open file
    status = ExtAudioFileOpenURL((__bridge CFURLRef)_url, &audioFile);
    if ( !checkResult(status, "ExtAudioFileOpenURL") ) {
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't open the audio file", @"")}];
        return;
    }
    
    // Get file data format
    AudioStreamBasicDescription fileAudioDescription;
    UInt32 size = sizeof(fileAudioDescription);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &size, &fileAudioDescription);
    if ( !checkResult(status, "ExtAudioFileGetProperty(kExtAudioFileProperty_FileDataFormat)") ) {
        ExtAudioFileDispose(audioFile);
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
        return;
    }
    
    // Apply client format
    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(_targetAudioDescription), &_targetAudioDescription);
    if ( !checkResult(status, "ExtAudioFileSetProperty(kExtAudioFileProperty_ClientDataFormat)") ) {
        ExtAudioFileDispose(audioFile);
        int fourCC = CFSwapInt32HostToBig(status);
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't convert the audio file (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
        return;
    }
    
    if ( _targetAudioDescription.mChannelsPerFrame > fileAudioDescription.mChannelsPerFrame ) {
        // More channels in target format than file format - set up a map to duplicate channel
        SInt32 channelMap[8];
        AudioConverterRef converter;
        checkResult(ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_AudioConverter, &size, &converter),
                    "ExtAudioFileGetProperty(kExtAudioFileProperty_AudioConverter)");
        for ( int outChannel=0, inChannel=0; outChannel < _targetAudioDescription.mChannelsPerFrame; outChannel++ ) {
            channelMap[outChannel] = inChannel;
            if ( inChannel+1 < fileAudioDescription.mChannelsPerFrame ) inChannel++;
        }
        checkResult(AudioConverterSetProperty(converter, kAudioConverterChannelMap, sizeof(SInt32)*_targetAudioDescription.mChannelsPerFrame, channelMap),
                    "AudioConverterSetProperty(kAudioConverterChannelMap)");
        CFArrayRef config = NULL;
        checkResult(ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ConverterConfig, sizeof(CFArrayRef), &config),
                    "ExtAudioFileSetProperty(kExtAudioFileProperty_ConverterConfig)");
    }
    
    // Determine length in frames (in original file's sample rate)
    UInt64 fileLengthInFrames;
    size = sizeof(fileLengthInFrames);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &size, &fileLengthInFrames);
    if ( !checkResult(status, "ExtAudioFileGetProperty(kExtAudioFileProperty_FileLengthFrames)") ) {
        ExtAudioFileDispose(audioFile);
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
        return;
    }
    
    // Calculate the true length in frames, given the original and target sample rates
    fileLengthInFrames = ceil(fileLengthInFrames * (_targetAudioDescription.mSampleRate / fileAudioDescription.mSampleRate));
    
    // Prepare buffers
    int bufferCount = (_targetAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? _targetAudioDescription.mChannelsPerFrame : 1;
    int channelsPerBuffer = (_targetAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : _targetAudioDescription.mChannelsPerFrame;
    AudioBufferList *bufferList = AEAllocateAndInitAudioBufferList(_targetAudioDescription, _audioReceiverBlock ? kIncrementalLoadBufferSize : (UInt32)fileLengthInFrames);
    if ( !bufferList ) {
        ExtAudioFileDispose(audioFile);
        self.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM 
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Not enough memory to open file", @"")}];
        return;
    }
    
    AudioBufferList *scratchBufferList = AEAllocateAndInitAudioBufferList(_targetAudioDescription, 0);
    
    // Perform read in multiple small chunks (otherwise ExtAudioFileRead crashes when performing sample rate conversion)
    UInt64 readFrames = 0;
    while ( readFrames < fileLengthInFrames && ![self isCancelled] ) {
        if ( _audioReceiverBlock ) {
            memcpy(scratchBufferList, bufferList, sizeof(AudioBufferList)+(bufferCount-1)*sizeof(AudioBuffer));
            for ( int i=0; i<scratchBufferList->mNumberBuffers; i++ ) {
                scratchBufferList->mBuffers[i].mDataByteSize = (UInt32)MIN(kIncrementalLoadBufferSize * _targetAudioDescription.mBytesPerFrame,
                                                                   (fileLengthInFrames-readFrames) * _targetAudioDescription.mBytesPerFrame);
            }
        } else {
            for ( int i=0; i<scratchBufferList->mNumberBuffers; i++ ) {
                scratchBufferList->mBuffers[i].mNumberChannels = channelsPerBuffer;
                scratchBufferList->mBuffers[i].mData = (char*)bufferList->mBuffers[i].mData + readFrames*_targetAudioDescription.mBytesPerFrame;
                scratchBufferList->mBuffers[i].mDataByteSize = (UInt32)MIN(kMaxAudioFileReadSize, (fileLengthInFrames-readFrames) * _targetAudioDescription.mBytesPerFrame);
            }
        }
        
        // Perform read
        UInt32 numberOfPackets = (UInt32)(scratchBufferList->mBuffers[0].mDataByteSize / _targetAudioDescription.mBytesPerFrame);
        status = ExtAudioFileRead(audioFile, &numberOfPackets, scratchBufferList);
        
        if ( status != noErr ) {
            ExtAudioFileDispose(audioFile);
            int fourCC = CFSwapInt32HostToBig(status);
            self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't read the audio file (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
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
        _lengthInFrames = (UInt32)fileLengthInFrames;
    }
}

@end
