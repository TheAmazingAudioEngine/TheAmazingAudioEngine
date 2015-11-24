//
//  AEPlaythroughChannel.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/04/2012.
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

#import "AEPlaythroughChannel.h"
#import "TPCircularBuffer.h"
#import "TPCircularBuffer+AudioBufferList.h"
#import "AEAudioController+Audiobus.h"
#import "AEAudioController+AudiobusStub.h"

static const int kAudioBufferLength = 16384;
static const int kSkipThreshold = 2;
static const int kAudiobusReceiverPortConnectedToSelfChanged;

@interface AEPlaythroughChannel () {
    TPCircularBuffer _buffer;
    BOOL _audiobusConnectedToSelf;
}
@property (nonatomic, weak) AEAudioController *audioController;
@end

@implementation AEPlaythroughChannel

+(NSSet *)keyPathsForValuesAffectingAudioDescription {
    return [NSSet setWithObject:@"audioController.inputAudioDescription"];
}

- (id)initWithAudioController:(AEAudioController*)audioController {
    return [self init];
}

- (id)init {
    if ( !(self = [super init]) ) return nil;
    TPCircularBufferInit(&_buffer, kAudioBufferLength);
    _volume = 1.0;
    return self;
}

- (void)dealloc {
    TPCircularBufferCleanup(&_buffer);
    self.audioController = nil;
}

- (void)setupWithAudioController:(AEAudioController *)audioController {
    self.audioController = audioController;
}

- (void)teardown {
    self.audioController = nil;
}

-(void)setAudioController:(AEAudioController *)audioController {
    if ( _audioController ) {
        [_audioController removeObserver:self forKeyPath:@"audiobusReceiverPort.connectedToSelf"];
    }
    
    _audioController = audioController;

    if ( _audioController ) {
        [_audioController addObserver:self forKeyPath:@"audiobusReceiverPort.connectedToSelf" options:0 context:(void*)&kAudiobusReceiverPortConnectedToSelfChanged];
        [self updateAudiobusConnectedToSelf];
    }
}

static void inputCallback(__unsafe_unretained AEPlaythroughChannel *THIS,
                          __unsafe_unretained AEAudioController *audioController,
                          void                     *source,
                          const AudioTimeStamp     *time,
                          UInt32                    frames,
                          AudioBufferList          *audio) {

    if ( THIS->_audiobusConnectedToSelf ) return;
    TPCircularBufferCopyAudioBufferList(&THIS->_buffer, audio, time, kTPCircularBufferCopyAll, NULL);
}

-(AEAudioReceiverCallback)receiverCallback {
    return inputCallback;
}

static OSStatus renderCallback(__unsafe_unretained AEPlaythroughChannel *THIS,
                               __unsafe_unretained AEAudioController *audioController,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    while ( 1 ) {
        // Discard any buffers with an incompatible format, in the event of a format change
        AudioBufferList *nextBuffer = TPCircularBufferNextBufferList(&THIS->_buffer, NULL);
        if ( !nextBuffer ) break;
        if ( nextBuffer->mNumberBuffers == audio->mNumberBuffers ) break;
        TPCircularBufferConsumeNextBufferList(&THIS->_buffer);
    }
    
    UInt32 fillCount = TPCircularBufferPeek(&THIS->_buffer, NULL, AEAudioControllerAudioDescription(audioController));
    if ( fillCount > frames+kSkipThreshold ) {
        UInt32 skip = fillCount - frames;
        TPCircularBufferDequeueBufferListFrames(&THIS->_buffer,
                                                &skip,
                                                NULL,
                                                NULL,
                                                AEAudioControllerAudioDescription(audioController));
    }
    
    TPCircularBufferDequeueBufferListFrames(&THIS->_buffer,
                                            &frames,
                                            audio,
                                            NULL,
                                            AEAudioControllerAudioDescription(audioController));

    return noErr;
}

-(AEAudioRenderCallback)renderCallback {
    return renderCallback;
}

-(AudioStreamBasicDescription)audioDescription {
    return _audioController.inputAudioDescription;
}

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ( context == &kAudiobusReceiverPortConnectedToSelfChanged ) {
        [self updateAudiobusConnectedToSelf];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

-(void)updateAudiobusConnectedToSelf {
    if ( _audioController.audiobusReceiverPort
            && [(id)_audioController.audiobusReceiverPort respondsToSelector:@selector(connectedToSelf)]
            && [(id)_audioController.audiobusReceiverPort respondsToSelector:@selector(setAutomaticMonitoring:)] ) {
        // Handle loopback connections: Pass monitoring responsibilities over to Audiobus SDK, and prepare to mute our own input
        _audiobusConnectedToSelf = [(id<AEAudiobusForwardDeclarationsProtocol>)_audioController.audiobusReceiverPort connectedToSelf];
        [(id<AEAudiobusForwardDeclarationsProtocol>)_audioController.audiobusReceiverPort setAutomaticMonitoring:_audiobusConnectedToSelf];
    }
}

@end


