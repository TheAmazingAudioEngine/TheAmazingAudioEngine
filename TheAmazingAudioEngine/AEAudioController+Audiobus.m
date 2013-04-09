//
//  AEAudioController+Audiobus.m
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

#import "AEAudioController+Audiobus.h"
#import "AEAudioController+AudiobusStub.h"

__attribute__((weak)) void ABInputPortReceive(ABInputPort *inputPort, ABPort *sourcePortOrNil, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, AudioTimeStamp *outTimestamp, ABMetadataBlockList *ioMetadataBlockList) {
    printf("ABInputPortReceive stub called\n");
}

__attribute__((weak)) void ABInputPortReceiveLive(ABInputPort *inputPort, AudioBufferList *bufferList, UInt32 lengthInFrames, AudioTimeStamp *outTimestamp) {
    printf("ABInputPortReceiveLive stub called\n");   
}

__attribute__((weak)) UInt32 ABInputPortPeek(ABInputPort *inputPort, AudioTimeStamp *outNextTimestamp) {
    printf("ABInputPortPeek stub called\n");
    return 0;
}

__attribute__((weak)) BOOL ABInputPortIsConnected(ABInputPort *inputPort) {
    printf("ABInputPortIsConnected stub called\n");
    return NO;
}

__attribute__((weak)) BOOL ABOutputPortSendAudio(ABOutputPort* outputPort, const AudioBufferList *audio, UInt32 lengthInFrames, const AudioTimeStamp *timestamp, ABMetadataBlockList *metadata) {
    printf("ABOutputPortSendAudio stub called\n");
    return NO;
}

__attribute__((weak)) BOOL ABOutputPortIsConnected(ABOutputPort *outputPort) {
    printf("ABOutputPortIsConnected stub called\n");
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
