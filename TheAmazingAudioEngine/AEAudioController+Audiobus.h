//
//  AEAudioController+Audiobus.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 06/05/2012.
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

#ifdef __cplusplus
extern "C" {
#endif

#import <Foundation/Foundation.h>
#import "AEAudioController.h"
#import <AudioToolbox/AudioToolbox.h>

@class ABReceiverPort;
@class ABSenderPort;

@interface AEAudioController (AudiobusAdditions)

/*!
 * Set an Audiobus sender port to send audio from a particular channel
 *
 *  When assigned to a channel and connected via Audiobus, audio for the given channel
 *  will be sent out the Audiobus sender port.
 *
 * @param senderPort The Audiobus sender port, or nil to remove the port
 * @param channel    Channel for the sender port
 */
- (void)setAudiobusSenderPort:(ABSenderPort*)senderPort forChannel:(id<AEAudioPlayable>)channel;

/*!
 * Set an Audiobus sender port to send audio from a particular channel group
 *
 *  When assigned to a channel and connected via Audiobus, audio for the given group
 *  will be sent out the Audiobus sender port.
 *
 * @param senderPort The Audiobus sender port, or nil to remove the port
 * @param channelGroup Channel group for the sender port
 */
- (void)setAudiobusSenderPort:(ABSenderPort*)senderPort forChannelGroup:(AEChannelGroupRef)channelGroup;

/*!
 * Audiobus receiver port
 *
 *  Set this property to an Audiobus receiver port to receive audio
 *  from this port instead of the system audio input.
 */
@property (nonatomic, retain) ABReceiverPort *audiobusReceiverPort;

/*!
 * Audiobus sender port
 *
 *  Set this property to an Audiobus sender port to send system
 *  output out this port.
 *
 *  Generally speaking, it's more efficient to not use this property, and
 *  instead use ABSenderPort's audio unit initializer (using 
 *  AEAudioController's [audioUnit](@ref AEAudioController::audioUnit) property.
 *
 *  However, there are certain circumstances where it's preferable to
 *  use the audiobusSenderPort property instead: Namely, where you are
 *  using multiple ABSenderPorts, or where you intend to provide an
 *  ABReceiverPort with the ability to connect to your own ABSenderPort
 *  (ABAudiobusController's 'allowsConnectionsToSelf') for feeding your
 *  input with your own output. These tricky cases require special 
 *  handling, which TAAE can do for you.
 *
 *  Note that you cannot initialise ABSenderPort with TAAE's audio unit,
 *  then use the sender port with this property.
 */
@property (nonatomic, retain) ABSenderPort *audiobusSenderPort;

@end

#ifdef __cplusplus
}
#endif