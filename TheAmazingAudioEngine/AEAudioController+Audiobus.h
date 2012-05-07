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
