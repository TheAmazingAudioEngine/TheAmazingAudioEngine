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
#define ABMetadataBlockList void*
void ABInputPortReceive(ABInputPort *inputPort, ABPort *sourcePortOrNil, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, uint64_t *outTimestamp, ABMetadataBlockList *ioMetadataBlockList);
UInt32 ABInputPortPeek(ABInputPort *inputPort, uint64_t *outNextTimestamp);
BOOL ABInputPortIsConnected(ABInputPort *inputPort);
BOOL ABOutputPortSendAudio(ABOutputPort* outputPort, const AudioBufferList *audio, UInt32 lengthInFrames, UInt64 hostTime, ABMetadataBlockList *metadata);

typedef void (^ABInputPortAudioInputBlock)(ABInputPort *inputPort, UInt32 lengthInFrames, uint64_t nextTimestamp, ABPort *sourcePortOrNil);

@interface ABInputPort : NSObject
@property (nonatomic, copy) ABInputPortAudioInputBlock audioInputBlock;
@property (nonatomic, assign) AudioStreamBasicDescription clientFormat;
@end

enum {
    ABInputPortAttributeNone            = 0x0,//!< No attributes
    ABInputPortAttributePlaysLiveAudio  = 0x1  //!< The receiver will play the received audio out loud, live.
                                               //!< Connected senders should mute their output.
};

@interface ABOutputPort : NSObject
@property (nonatomic, assign) AudioStreamBasicDescription clientFormat;
@property (nonatomic, readonly) NSInteger connectedPortAttributes;
@end