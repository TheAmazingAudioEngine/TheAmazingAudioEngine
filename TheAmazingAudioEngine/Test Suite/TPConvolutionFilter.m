//
//  TPConvolutionFilter.m
//
//  Created by Michael Tyson on 24/01/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "TPConvolutionFilter.h"
#import <Accelerate/Accelerate.h>
#import "TPCircularBuffer.h"

#define kTwoChannelsPerFrame 2
#define kProcessingBlockSize 1024
#define kMaxFilterLength 2048


#define checkStatus(status) \
    if ( (status) != noErr ) {\
        NSLog(@"Error: %ld -> %s:%d", (status), __FILE__, __LINE__);\
    }

@interface TPConvolutionFilter () {
    AEAudioController   *_audioController;
    float               *_filterData[2];
    int                  _filterChannels;
    int                  _filterLength;
}
@end

@implementation TPConvolutionFilter
@synthesize filter=_filter;
@dynamic stereo;

#pragma mark - Filter kernel generation

+ (NSArray*)lowPassWindowedSincFilterWithFC:(float)fc {
    NSMutableData *filter = [NSMutableData dataWithLength:sizeof(float) * 101];
    float *buf = (float*)[filter mutableBytes];
    
    // 101 point windowed sinc lowpass filter from http://www.dspguide.com/
    // table 16-1
    int i;
    int m = 100;
    float sum = 0;
    
    for( i = 0; i < 101 ; i++ ) {
        if((i - m / 2) == 0 ) {
            buf[i] = 2 * M_PI * fc;
        }
        else {
            buf[i] = sin(2 * M_PI * fc * (i - m / 2)) / (i - m / 2);
        }
        buf[i] = buf[i] * (.54 - .46 * cos(2 * M_PI * i / m ));
    }
    
    // normalize for unity gain at dc
    for ( i = 0 ; i < 101 ; i++ ) {
        sum = sum + buf[i]; 
    }
    
    for ( i = 0 ; i < 101 ; i++ ) {
        buf[i] = buf[i] / sum;
    }
    
    return [NSArray arrayWithObject:filter];
}

+ (NSArray*)filterFromAudioFile:(NSURL*)url scale:(float)scale error:(NSError *__autoreleasing *)error {
    
    ExtAudioFileRef audioFile;
    OSStatus status;
    
    // Open file
    status = ExtAudioFileOpenURL((__bridge CFURLRef)url, &audioFile);
    checkStatus(status);
    if ( status != noErr ) {
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't open the audio file", @"") 
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    // Get file data format
    AudioStreamBasicDescription fileAudioDescription;
    UInt32 size = sizeof(fileAudioDescription);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &size, &fileAudioDescription);
    if ( status != noErr ) {
        ExtAudioFileDispose(audioFile);
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the audio file", @"") 
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    AudioStreamBasicDescription targetAudioDescription;
    memset(&targetAudioDescription, 0, sizeof(targetAudioDescription));
    targetAudioDescription.mFormatID          = kAudioFormatLinearPCM;
    targetAudioDescription.mFormatFlags       = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian;
    targetAudioDescription.mChannelsPerFrame  = fileAudioDescription.mChannelsPerFrame;
    targetAudioDescription.mFramesPerPacket   = 1;
    targetAudioDescription.mBitsPerChannel    = 8 * sizeof(SInt16);
    targetAudioDescription.mSampleRate        = 44100.0;
    targetAudioDescription.mBytesPerPacket    = sizeof(SInt16);
    targetAudioDescription.mBytesPerFrame     = sizeof(SInt16);
    
    // Apply client format
    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(targetAudioDescription), &targetAudioDescription);
    if ( status != noErr ) {
        ExtAudioFileDispose(audioFile);
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:
                                                                                           NSLocalizedString(@"Couldn't convert the audio file (error %d)", @""),
                                                                                           status]
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    // Determine length in frames (in original file's sample rate)
    UInt64 fileLengthInFrames;
    size = sizeof(fileLengthInFrames);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &size, &fileLengthInFrames);
    if ( status != noErr ) {
        ExtAudioFileDispose(audioFile);
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the audio file", @"") 
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    // Calculate the true length in frames, given the original and target sample rates
    fileLengthInFrames = ceil(fileLengthInFrames * (targetAudioDescription.mSampleRate / fileAudioDescription.mSampleRate));
    
    // Limit to the maximum filter length
    BOOL truncated = NO;
    if ( fileLengthInFrames > kMaxFilterLength ) {
        fileLengthInFrames = kMaxFilterLength;
        truncated = YES;
    }
    
    // set up buffers
    SInt16 *audioSamples = (SInt16*)malloc(fileLengthInFrames * targetAudioDescription.mBytesPerFrame * targetAudioDescription.mChannelsPerFrame);
    
    if ( !audioSamples ) {
        ExtAudioFileDispose(audioFile);
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:
                                                                                           NSLocalizedString(@"Not enough memory to open file", @""),
                                                                                           status]
                                                                                   forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    
    // Perform read in multiple small chunks (otherwise ExtAudioFileRead crashes when performing sample rate conversion)
    UInt64 remainingFrames = fileLengthInFrames;
    SInt16* audioDataPtr[targetAudioDescription.mChannelsPerFrame];
    
    audioDataPtr[0] = audioSamples;
    if ( targetAudioDescription.mChannelsPerFrame == kTwoChannelsPerFrame ) {
        audioDataPtr[1] = audioSamples + fileLengthInFrames;
    }
    
    while ( 1 ) {
        // Set up buffers
        char audioBufferListSpace[sizeof(AudioBufferList)+sizeof(AudioBuffer)];
        AudioBufferList *bufferList = (AudioBufferList*)audioBufferListSpace;
        
        bufferList->mNumberBuffers = targetAudioDescription.mChannelsPerFrame;
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mData = audioDataPtr[i];
            bufferList->mBuffers[i].mDataByteSize = MIN(16384, remainingFrames * targetAudioDescription.mBytesPerFrame);
        }
        
        // Perform read
        UInt32 numberOfPackets = (UInt32)(bufferList->mBuffers[0].mDataByteSize / targetAudioDescription.mBytesPerFrame);
        status = ExtAudioFileRead(audioFile, &numberOfPackets, bufferList);
        
        if ( numberOfPackets == 0 ) {
            // Termination condition
            break;
        }
        
        if ( status != noErr ) {
            ExtAudioFileDispose(audioFile);
            free(audioSamples);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                                  userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:
                                                                                               NSLocalizedString(@"Couldn't read the audio file (error %d)", @""),
                                                                                               status]
                                                                                       forKey:NSLocalizedDescriptionKey]];
            return nil;
        }
        
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            audioDataPtr[i] += numberOfPackets;
        }
        remainingFrames -= numberOfPackets;
    }
    
    // Clean up        
    ExtAudioFileDispose(audioFile);
    
    // Now convert loaded audio into filters for convolution
    audioDataPtr[0] = audioSamples;
    if ( targetAudioDescription.mChannelsPerFrame == kTwoChannelsPerFrame ) {
        audioDataPtr[1] = audioSamples + fileLengthInFrames;
    }
    
    NSMutableArray *filterChannels = [NSMutableArray array];
    
    for ( int i=0; i<targetAudioDescription.mChannelsPerFrame; i++ ) {
        NSMutableData *data = [NSMutableData dataWithLength:fileLengthInFrames * sizeof(float)];
        float *buffer = (float*)[data mutableBytes];
        
        // Convert audio to floats
        vDSP_vflt16(audioDataPtr[i], 1, buffer, 1, fileLengthInFrames);
        
        if ( truncated ) {
            // Add decay at the end, if we truncated
            const int framesToDecay = 2048;
            float start = 1.0, step = -1.0 / (float)framesToDecay;
            vDSP_vrampmul(buffer+(fileLengthInFrames-framesToDecay), 1, &start, &step, buffer+(fileLengthInFrames-framesToDecay), 1, framesToDecay);
        }
        
        // Scale down so that each element in in range 0-1
        float multiplier = 1.0 / (float)INT16_MAX;
        vDSP_vsmul(buffer, 1, &multiplier, buffer, 1, fileLengthInFrames);
        
        // Normalize so whole filter sums to 1 * scale
        float sum = 0;
        vDSP_svemg(buffer, 1, &sum, fileLengthInFrames);
        sum /= scale;
        vDSP_vsdiv(buffer, 1, &sum, buffer, 1, fileLengthInFrames);
        
        [filterChannels addObject:data];
    }
    
    free(audioSamples);
    
    return filterChannels;
}

#pragma mark -

static void filterBlock(TPBlockLevelFilter      *filter,
                        const AudioTimeStamp    *time,
                        UInt32                   frames,
                        AudioBufferList         *input,
                        AudioBufferList         *output,
                        int                     *consumedInputFrames,
                        int                     *producedOutputFrames) {
    
    TPConvolutionFilter *THIS = (TPConvolutionFilter*)filter;

    for ( int i=0; i<input->mNumberBuffers; i++ ) {
        // Perform convolution on each channel
        const float *filter = (float*)THIS->_filterData[i];
        vDSP_conv(input->mBuffers[i].mData, 1, filter+THIS->_filterLength-1 /* last element of filter - we work backwards */, -1 /* stride of -1: convolve */, output->mBuffers[i].mData, 1, kProcessingBlockSize, THIS->_filterLength);
    }
    
    *consumedInputFrames = kProcessingBlockSize;
    *producedOutputFrames = kProcessingBlockSize;
}

- (id)initWithAudioController:(AEAudioController *)audioController filter:(NSArray *)filter {
    if ( !(self = [super initWithAudioController:audioController processingBlockSize:kProcessingBlockSize+kMaxFilterLength blockProcessingCallback:&filterBlock]) ) return nil;
    _audioController = audioController;
    self.stereo = NO;
    
    _filter = [filter retain];
    _filterChannels = [_filter count];
    _filterLength = [[_filter objectAtIndex:0] length] / sizeof(float);
    for ( int i=0; i<_filterChannels; i++ ) {
        _filterData[i] = (float*)[[_filter objectAtIndex:i] bytes];
    }
    
    return self;
}

static long setFilter(AEAudioController *audioController, long *ioParameter1, long *ioParameter2, long *ioParameter3, void *ioOpaquePtr) {
    TPConvolutionFilter *THIS = (TPConvolutionFilter*)ioOpaquePtr;
    THIS->_filterChannels = *ioParameter1;
    THIS->_filterLength = *ioParameter2;
    for ( int i=0; i<*ioParameter1; i++ ) {
        THIS->_filterData[i] = ((float**)*ioParameter3)[i];
    }
    return 0;
}

- (void)setFilter:(NSArray*)filter {
    [filter retain];
    
    long filterChannels = [filter count];
    long filterLength = [[filter objectAtIndex:0] length] / sizeof(float);
    float *filterData[2];
    for ( int i=0; i<filterChannels; i++ ) {
        filterData[i] = (float*)[[filter objectAtIndex:i] bytes];
    }
    
    [_audioController performSynchronousMessageExchangeWithHandler:setFilter parameter1:filterChannels parameter2:filterLength parameter3:(long)filterData ioOpaquePtr:self];
    
    [_filter release];
    _filter = filter;
}

@end
