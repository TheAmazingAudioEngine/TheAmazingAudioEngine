//
//  AEAudioController+Audiobus.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 07/05/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEAudioController+Audiobus.h"
#import "AEAudioController+AudiobusStub.h"

__attribute__((weak)) void ABInputPortReceive(ABInputPort *inputPort, ABPort *sourcePortOrNil, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, uint64_t *outTimestamp, ABMetadataBlockList *ioMetadataBlockList) {
    printf("ABInputPortReceive stub called\n");
}

__attribute__((weak)) UInt32 ABInputPortPeek(ABInputPort *inputPort, uint64_t *outNextTimestamp) {
    printf("ABInputPortPeek stub called\n");
    return 0;
}

__attribute__((weak)) BOOL ABInputPortIsConnected(ABInputPort *inputPort) {
    printf("ABInputPortIsConnected stub called\n");
    return NO;
}

__attribute__((weak)) BOOL ABOutputPortSendAudio(ABOutputPort* outputPort, const AudioBufferList *audio, UInt32 lengthInFrames, UInt64 hostTime, ABMetadataBlockList *metadata) {
    printf("ABOutputPortSendAudio stub called\n");
    return NO;
}

__attribute__((weak)) ABInputPortAttributes ABOutputPortGetConnectedPortAttributes(ABOutputPort *outputPort) {
    printf("ABOutputPortGetConnectedPortAttributes stub called\n");
    return 0;
}

__attribute__((weak)) NSTimeInterval ABOutputPortGetAverageLatency(ABOutputPort *outputPort) {
    printf("ABOutputPortGetAverageLatency stub called\n");
    return 0;
}

__attribute__((weak)) NSString * ABConnectionsChangedNotification = @"ABConnectionsChangedNotification";
__attribute__((weak)) NSString * ABIsAllowedToUseRecordCategoryKey = @"isAllowedToUseRecordCategory";
