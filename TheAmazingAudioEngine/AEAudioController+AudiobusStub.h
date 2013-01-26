//
//  AEAudioController+AudiobusStub.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 07/05/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>

@class ABInputPort;
@class ABOutputPort;
@class ABPort;

extern NSString * ABConnectionsChangedNotification;

#define ABMetadataBlockList void*
typedef NSUInteger ABInputPortAttributes;
void ABInputPortReceive(ABInputPort *inputPort, ABPort *sourcePortOrNil, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, AudioTimeStamp *outTimestamp, ABMetadataBlockList *ioMetadataBlockList);
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
@end

enum {
    ABInputPortAttributeNone            = 0x0,//!< No attributes
    ABInputPortAttributePlaysLiveAudio  = 0x1  //!< The receiver will play the received audio out loud, live.
                                               //!< Connected senders should mute their output.
};
