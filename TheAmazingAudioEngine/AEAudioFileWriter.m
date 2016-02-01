//
//  AEAudioFileWriter.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 20/03/2012.
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

#import "AEAudioFileWriter.h"
#import "TheAmazingAudioEngine.h"

NSString * const AEAudioFileWriterErrorDomain = @"com.theamazingaudioengine.AEAudioFileWriterErrorDomain";

@interface AEAudioFileWriter () {
    BOOL                        _writing;
    ExtAudioFileRef             _audioFile;
    AudioStreamBasicDescription _audioDescription;
}

@property (nonatomic, strong, readwrite) NSString *path;
@end

@implementation AEAudioFileWriter
@synthesize path = _path;

+ (BOOL)AACEncodingAvailable {
#if !TARGET_OS_IPHONE
    return YES;
#else
    static BOOL available;
    static BOOL available_set = NO;
    
    if ( available_set ) return available;
    
    // get an array of AudioClassDescriptions for all installed encoders for the given format 
    // the specifier is the format that we are interested in - this is 'aac ' in our case
    UInt32 encoderSpecifier = kAudioFormatMPEG4AAC;
    UInt32 size;
    
    if ( !AECheckOSStatus(AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size),
                      "AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders") ) return NO;
    
    UInt32 numEncoders = size / sizeof(AudioClassDescription);
    AudioClassDescription encoderDescriptions[numEncoders];
    
    if ( !AECheckOSStatus(AudioFormatGetProperty(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size, encoderDescriptions),
                      "AudioFormatGetProperty(kAudioFormatProperty_Encoders") ) {
        available_set = YES;
        available = NO;
        return NO;
    }
    
    for (UInt32 i=0; i < numEncoders; ++i) {
        if ( encoderDescriptions[i].mSubType == kAudioFormatMPEG4AAC && encoderDescriptions[i].mManufacturer == kAppleSoftwareAudioCodecManufacturer ) {
            available_set = YES;
            available = YES;
            return YES;
        }
    }
    
    available_set = YES;
    available = NO;
    return NO;
#endif
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription {
    if ( !(self = [super init]) ) return nil;
    _audioDescription = audioDescription;
    return self;
}

- (void)dealloc {
    if ( _writing ) {
        [self finishWriting];
    }
}

- (BOOL)beginWritingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType error:(NSError**)error {
    return [self beginWritingToFileAtPath:path fileType:fileType bitDepth:16 channels:0 error:error];
}

- (BOOL)beginWritingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType bitDepth:(UInt32)bits error:(NSError**)error {
    return [self beginWritingToFileAtPath:path fileType:fileType bitDepth:bits channels:0 error:error];
}

- (BOOL)beginWritingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType bitDepth:(UInt32)bits channels:(UInt32)channels error:(NSError**)error
{

    OSStatus status;

    if (channels == 0) {
        channels = _audioDescription.mChannelsPerFrame;
    }

    if ( fileType == kAudioFileM4AType ) {
        if ( ![AEAudioFileWriter AACEncodingAvailable] ) {
            if ( error ) *error = [NSError errorWithDomain:AEAudioFileWriterErrorDomain 
                                                      code:kAEAudioFileWriterFormatError 
                                                  userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"AAC Encoding not available", @"")}];
            
            return NO;
        }
        
        // Get the output audio description
        AudioStreamBasicDescription destinationFormat;
        memset(&destinationFormat, 0, sizeof(destinationFormat));
        destinationFormat.mChannelsPerFrame = channels;
        destinationFormat.mSampleRate = _audioDescription.mSampleRate;
        destinationFormat.mFormatID = kAudioFormatMPEG4AAC;
        UInt32 size = sizeof(destinationFormat);
        status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &size, &destinationFormat);
        if ( !AECheckOSStatus(status, "AudioFormatGetProperty(kAudioFormatProperty_FormatInfo") ) {
            int fourCC = CFSwapInt32HostToBig(status);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain 
                                                      code:status 
                                                  userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't prepare the output format (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
            return NO;
        }
        
        // Create the file
        status = ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], 
                                           kAudioFileM4AType, 
                                           &destinationFormat, 
                                           NULL, 
                                           kAudioFileFlags_EraseFile, 
                                           &_audioFile);
        
        if ( !AECheckOSStatus(status, "ExtAudioFileCreateWithURL") ) {
            int fourCC = CFSwapInt32HostToBig(status);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain 
                                                      code:status 
                                                  userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't open the output file (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
            return NO;
        }

#if TARGET_OS_IPHONE
        UInt32 codecManfacturer = kAppleSoftwareAudioCodecManufacturer;
        status = ExtAudioFileSetProperty(_audioFile, kExtAudioFileProperty_CodecManufacturer, sizeof(UInt32), &codecManfacturer);
        
        if ( !AECheckOSStatus(status, "ExtAudioFileSetProperty(kExtAudioFileProperty_CodecManufacturer") ) {
            int fourCC = CFSwapInt32HostToBig(status);
            if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                                    code:status
                                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't set audio codec (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
            ExtAudioFileDispose(_audioFile);
            return NO;
        }
#endif
    } else {
        
        // Derive the output audio description from the client format, but with interleaved, big endian (if AIFF) signed integers.
        AudioStreamBasicDescription audioDescription = _audioDescription;
        audioDescription.mFormatFlags = (fileType == kAudioFileAIFFType ? kLinearPCMFormatFlagIsBigEndian : 0) | kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        audioDescription.mFormatID = kAudioFormatLinearPCM;
        audioDescription.mBitsPerChannel = bits;
        audioDescription.mChannelsPerFrame = channels;
        audioDescription.mBytesPerPacket =
        audioDescription.mBytesPerFrame = channels * (audioDescription.mBitsPerChannel/8);
        audioDescription.mFramesPerPacket = 1;
        
        // Create the file
        status = ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], 
                                           fileType, 
                                           &audioDescription, 
                                           NULL, 
                                           kAudioFileFlags_EraseFile, 
                                           &_audioFile);
        
        if ( !AECheckOSStatus(status, "ExtAudioFileCreateWithURL") ) {
            int fourCC = CFSwapInt32HostToBig(status);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain 
                                                      code:status 
                                                  userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't open the output file (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
            return NO;
        }
    }
    
    // Set up the converter
    status = ExtAudioFileSetProperty(_audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(AudioStreamBasicDescription), &_audioDescription);
    if ( !AECheckOSStatus(status, "ExtAudioFileSetProperty(kExtAudioFileProperty_ClientDataFormat") ) {
        int fourCC = CFSwapInt32HostToBig(status);
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain 
                                                  code:status 
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't configure the converter (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
        ExtAudioFileDispose(_audioFile);
        return NO;
    }
    
    self.path = path;
    _writing = YES;
    
    return YES;
}

- (void)finishWriting {
    if ( !_writing ) return;

    _writing = NO;
    
    AECheckOSStatus(ExtAudioFileDispose(_audioFile), "AudioFileClose");
}

OSStatus AEAudioFileWriterAddAudio(__unsafe_unretained AEAudioFileWriter* THIS, AudioBufferList *bufferList, UInt32 lengthInFrames) {
    return ExtAudioFileWriteAsync(THIS->_audioFile, lengthInFrames, bufferList);
}

OSStatus AEAudioFileWriterAddAudioSynchronously(__unsafe_unretained AEAudioFileWriter* THIS, AudioBufferList *bufferList, UInt32 lengthInFrames) {
    return ExtAudioFileWrite(THIS->_audioFile, lengthInFrames, bufferList);
}

@end
