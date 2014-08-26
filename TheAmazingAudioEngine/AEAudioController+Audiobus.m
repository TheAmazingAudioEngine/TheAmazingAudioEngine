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

__attribute__((weak)) void ABReceiverPortReceive(ABReceiverPort *receiverPort, ABPort *sourcePortOrNil, AudioBufferList *bufferList, UInt32 lengthInFrames, AudioTimeStamp *outTimestamp) {
    printf("ABReceiverPortReceive stub called\n");
}

__attribute__((weak)) BOOL ABReceiverPortIsConnected(ABReceiverPort *receiverPort) {
    printf("ABReceiverPortIsConnected stub called\n");
    return NO;
}

__attribute__((weak)) BOOL ABFilterPortIsConnected(ABFilterPort *filterPort) {
    printf("ABFilterPortIsConnected stub called\n");
    return NO;
}

__attribute__((weak)) BOOL ABSenderPortSend(ABSenderPort* senderPort, const AudioBufferList *audio, UInt32 lengthInFrames, const AudioTimeStamp *timestamp) {
    printf("ABSenderPortSend stub called\n");
    return NO;
}

__attribute__((weak)) BOOL ABSenderPortIsConnected(ABSenderPort *senderPort) {
    printf("ABSenderPortIsConnected stub called\n");
    return NO;
}

__attribute__((weak)) BOOL ABSenderPortIsMuted(ABSenderPort *senderPort) {
    printf("ABSenderPortIsMuted stub called\n");
    return NO;
}

__attribute__((weak)) NSTimeInterval ABSenderPortGetAverageLatency(ABSenderPort *senderPort) {
    printf("ABSenderPortGetAverageLatency stub called\n");
    return 0;
}

__attribute__((weak)) NSString * ABConnectionsChangedNotification = @"ABConnectionsChangedNotification";
