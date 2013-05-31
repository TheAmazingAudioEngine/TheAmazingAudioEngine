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

#ifdef __cplusplus
}
#endif