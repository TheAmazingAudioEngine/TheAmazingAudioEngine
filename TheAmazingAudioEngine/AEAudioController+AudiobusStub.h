//
//  AEAudioController+AudiobusStub.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 07/05/2012.
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

#import <Foundation/Foundation.h>

@class ABInputPort;
@class ABOutputPort;
@class ABPort;

extern NSString * ABConnectionsChangedNotification;

#define ABMetadataBlockList void*
typedef NSUInteger ABInputPortAttributes;
void ABInputPortReceive(ABInputPort *inputPort, ABPort *sourcePortOrNil, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, AudioTimeStamp *outTimestamp, ABMetadataBlockList *ioMetadataBlockList);
void ABInputPortReceiveLive(ABInputPort *inputPort, AudioBufferList *bufferList, UInt32 lengthInFrames, AudioTimeStamp *outTimestamp);
UInt32 ABInputPortPeek(ABInputPort *inputPort, AudioTimeStamp *outNextTimestamp);
BOOL ABInputPortIsConnected(ABInputPort *inputPort);
BOOL ABOutputPortSendAudio(ABOutputPort* outputPort, const AudioBufferList *audio, UInt32 lengthInFrames, const AudioTimeStamp *timestamp, ABMetadataBlockList *metadata);
BOOL ABOutputPortIsConnected(ABOutputPort *outputPort);
ABInputPortAttributes ABOutputPortGetConnectedPortAttributes(ABOutputPort *outputPort);
NSTimeInterval ABOutputPortGetAverageLatency(ABOutputPort *outputPort);
typedef void (^ABInputPortAudioInputBlock)(ABInputPort *inputPort, UInt32 lengthInFrames, AudioTimeStamp nextTimestamp, ABPort *sourcePortOrNil);

@interface NSObject ()
- (AudioStreamBasicDescription)clientFormat;
- (void)setClientFormat:(AudioStreamBasicDescription)clientFormat;
- (void)setAudioInputBlock:(ABInputPortAudioInputBlock)audioInputBlock;
- (void)setConnectedPortAttributes:(NSInteger)connectedPortAttributes;
- (void)setMuteLiveAudioInputWhenConnectedToSelf:(BOOL)self;
- (BOOL)connectedToSelf;
@end

enum {
    ABInputPortAttributeNone            = 0x0,//!< No attributes
    ABInputPortAttributePlaysLiveAudio  = 0x1  //!< The receiver will play the received audio out loud, live.
                                               //!< Connected senders should mute their output.
};
