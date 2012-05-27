//
//  AEAudioController+Audiobus.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 06/05/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AEAudioController.h"
#import <AudioToolbox/AudioToolbox.h>

@class ABInputPort;
@class ABOutputPort;

@interface AEAudioController (AudiobusAdditions)

/*!
 * Set an Audiobus output port to send audio from a particular channel
 *
 *  When assigned to a channel and connected via Audiobus, audio for the given channel
 *  will be sent out the Audiobus output port.
 *
 * @param outputPort The Audiobus output port, or nil to remove the port
 * @param channel    Channel for the output port
 */
- (void)setAudiobusOutputPort:(ABOutputPort*)outputPort forChannel:(id<AEAudioPlayable>)channel;

/*!
 * Set an Audiobus output port to send audio from a particular channel group
 *
 *  When assigned to a channel and connected via Audiobus, audio for the given group
 *  will be sent out the Audiobus output port.
 *
 * @param outputPort The Audiobus output port, or nil to remove the port
 * @param channelGroup Channel group for the output port
 */
- (void)setAudiobusOutputPort:(ABOutputPort*)outputPort forChannelGroup:(AEChannelGroupRef)channelGroup;

/*!
 * Audiobus input port
 *
 *  Set this property to an Audiobus input port to receive audio
 *  from this port instead of the system audio input.
 */
@property (nonatomic, retain) ABInputPort *audiobusInputPort;

/*!
 * Audiobus output port
 *
 *  Set this property to an Audiobus output port to send system
 *  output out this port.
 */
@property (nonatomic, retain) ABOutputPort *audiobusOutputPort;

@end
