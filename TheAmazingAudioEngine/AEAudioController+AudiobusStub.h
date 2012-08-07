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
extern NSString * ABIsAllowedToUseRecordCategoryKey;

#define ABMetadataBlockList void*
typedef NSUInteger ABInputPortAttributes;
void ABInputPortReceive(ABInputPort *inputPort, ABPort *sourcePortOrNil, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, uint64_t *outTimestamp, ABMetadataBlockList *ioMetadataBlockList);
UInt32 ABInputPortPeek(ABInputPort *inputPort, uint64_t *outNextTimestamp);
BOOL ABInputPortIsConnected(ABInputPort *inputPort);
BOOL ABOutputPortSendAudio(ABOutputPort* outputPort, const AudioBufferList *audio, UInt32 lengthInFrames, UInt64 hostTime, ABMetadataBlockList *metadata);
ABInputPortAttributes ABOutputPortGetConnectedPortAttributes(ABOutputPort *outputPort);
NSTimeInterval ABOutputPortGetAverageLatency(ABOutputPort *outputPort);
typedef void (^ABInputPortAudioInputBlock)(ABInputPort *inputPort, UInt32 lengthInFrames, uint64_t nextTimestamp, ABPort *sourcePortOrNil);

@interface NSObject ()
- (AudioStreamBasicDescription)clientFormat;
- (void)setClientFormat:(AudioStreamBasicDescription)clientFormat;
- (void)setAudioInputBlock:(ABInputPortAudioInputBlock)audioInputBlock;
- (void)setConnectedPortAttributes:(NSInteger)connectedPortAttributes;
- (BOOL)isAllowedToUseRecordCategory;
@end

enum {
    ABInputPortAttributeNone            = 0x0,//!< No attributes
    ABInputPortAttributePlaysLiveAudio  = 0x1  //!< The receiver will play the received audio out loud, live.
                                               //!< Connected senders should mute their output.
};
