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

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
        return NO;
    }
    return YES;
}

@interface AEAudioFileWriter () {
    BOOL                        _writing;
    ExtAudioFileRef             _audioFile;
    UInt32                      _priorMixOverrideValue;
    AudioStreamBasicDescription _audioDescription;
}

@property (nonatomic, retain, readwrite) NSString *path;
@end

@implementation AEAudioFileWriter
@synthesize path = _path;

+ (BOOL)AACEncodingAvailable {
#if TARGET_IPHONE_SIMULATOR
    return YES;
#else
    static BOOL available;
    static BOOL available_set = NO;
    
    if ( available_set ) return available;
    
    // get an array of AudioClassDescriptions for all installed encoders for the given format 
    // the specifier is the format that we are interested in - this is 'aac ' in our case
    UInt32 encoderSpecifier = kAudioFormatMPEG4AAC;
    UInt32 size;
    
    if ( !checkResult(AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size),
                      "AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders") ) return NO;
    
    UInt32 numEncoders = size / sizeof(AudioClassDescription);
    AudioClassDescription encoderDescriptions[numEncoders];
    
    if ( !checkResult(AudioFormatGetProperty(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size, encoderDescriptions),
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
    self.path = nil;
    [super dealloc];
}

- (BOOL)beginWritingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType error:(NSError**)error {
    OSStatus status;
    
    if ( fileType == kAudioFileM4AType ) {
        if ( ![AEAudioFileWriter AACEncodingAvailable] ) {
            if ( error ) *error = [NSError errorWithDomain:AEAudioFileWriterErrorDomain 
                                                      code:kAEAudioFileWriterFormatError 
                                                  userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"AAC Encoding not available", @"")}];
            
            return NO;
        }
        
        // AAC won't work if the 'mix with others' session property is enabled. Disable it if it's on.
        UInt32 size = sizeof(_priorMixOverrideValue);
        checkResult(AudioSessionGetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, &size, &_priorMixOverrideValue), 
                    "AudioSessionGetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
        
        if ( _priorMixOverrideValue != NO ) {
            UInt32 allowMixing = NO;
            checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                        "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
        }

        // Get the output audio description
        AudioStreamBasicDescription destinationFormat;
        memset(&destinationFormat, 0, sizeof(destinationFormat));
        destinationFormat.mChannelsPerFrame = _audioDescription.mChannelsPerFrame;
        destinationFormat.mSampleRate = _audioDescription.mSampleRate;
        destinationFormat.mFormatID = kAudioFormatMPEG4AAC;
        size = sizeof(destinationFormat);
        status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &size, &destinationFormat);
        if ( !checkResult(status, "AudioFormatGetProperty(kAudioFormatProperty_FormatInfo") ) {
            int fourCC = CFSwapInt32HostToBig(status);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain 
                                                      code:status 
                                                  userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't prepare the output format (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
            return NO;
        }
        
        // Create the file
        status = ExtAudioFileCreateWithURL((CFURLRef)[NSURL fileURLWithPath:path], 
                                           kAudioFileM4AType, 
                                           &destinationFormat, 
                                           NULL, 
                                           kAudioFileFlags_EraseFile, 
                                           &_audioFile);
        
        if ( !checkResult(status, "ExtAudioFileCreateWithURL") ) {
            int fourCC = CFSwapInt32HostToBig(status);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain 
                                                      code:status 
                                                  userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't open the output file (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
            return NO;
        }
        
        UInt32 codecManfacturer = kAppleSoftwareAudioCodecManufacturer;
        status = ExtAudioFileSetProperty(_audioFile, kExtAudioFileProperty_CodecManufacturer, sizeof(UInt32), &codecManfacturer);
        
        if ( !checkResult(status, "ExtAudioFileSetProperty(kExtAudioFileProperty_CodecManufacturer") ) {
            int fourCC = CFSwapInt32HostToBig(status);
            if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                                    code:status
                                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't set audio codec (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
            ExtAudioFileDispose(_audioFile);
            return NO;
        }
    } else {
        
        // Derive the output audio description from the client format, but with interleaved, big endian (if AIFF) signed integers.
        AudioStreamBasicDescription audioDescription = _audioDescription;
        audioDescription.mFormatFlags = (fileType == kAudioFileAIFFType ? kLinearPCMFormatFlagIsBigEndian : 0) | kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        audioDescription.mFormatID = kAudioFormatLinearPCM;
        audioDescription.mBitsPerChannel = 16;
        audioDescription.mBytesPerPacket =
            audioDescription.mBytesPerFrame = audioDescription.mChannelsPerFrame * (audioDescription.mBitsPerChannel/8);
        audioDescription.mFramesPerPacket = 1;
        
        // Create the file
        status = ExtAudioFileCreateWithURL((CFURLRef)[NSURL fileURLWithPath:path], 
                                           fileType, 
                                           &audioDescription, 
                                           NULL, 
                                           kAudioFileFlags_EraseFile, 
                                           &_audioFile);
        
        if ( !checkResult(status, "ExtAudioFileCreateWithURL") ) {
            int fourCC = CFSwapInt32HostToBig(status);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain 
                                                      code:status 
                                                  userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't open the output file (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
            return NO;
        }
    }
    
    // Set up the converter
    status = ExtAudioFileSetProperty(_audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(AudioStreamBasicDescription), &_audioDescription);
    if ( !checkResult(status, "ExtAudioFileSetProperty(kExtAudioFileProperty_ClientDataFormat") ) {
        int fourCC = CFSwapInt32HostToBig(status);
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain 
                                                  code:status 
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't configure the converter (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
        ExtAudioFileDispose(_audioFile);
        return NO;
    }
    
    // Init the async file writing mechanism
    checkResult(ExtAudioFileWriteAsync(_audioFile, 0, NULL), "ExtAudioFileWriteAsync");
    
    self.path = path;
    _writing = YES;
    
    return YES;
}

- (void)finishWriting {
    if ( !_writing ) return;

    _writing = NO;
    
    checkResult(ExtAudioFileDispose(_audioFile), "AudioFileClose");
    
    if ( _priorMixOverrideValue ) {
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof(_priorMixOverrideValue), &_priorMixOverrideValue),
                    "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    }
}

OSStatus AEAudioFileWriterAddAudio(AEAudioFileWriter* THIS, AudioBufferList *bufferList, UInt32 lengthInFrames) {
    return ExtAudioFileWriteAsync(THIS->_audioFile, lengthInFrames, bufferList);
}

OSStatus AEAudioFileWriterAddAudioSynchronously(AEAudioFileWriter* THIS, AudioBufferList *bufferList, UInt32 lengthInFrames) {
    return ExtAudioFileWrite(THIS->_audioFile, lengthInFrames, bufferList);
}

@end
