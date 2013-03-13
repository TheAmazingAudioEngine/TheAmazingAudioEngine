//
//  AEPlaythroughChannel.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

/*!
 * Playthrough channel, used for live monitoring of input
 */
@interface AEPlaythroughChannel : NSObject <AEAudioPlayable, AEAudioReceiver>

/*!
 * Initialise
 *
 * @param audioController The Audio Controller
 */
- (id)initWithAudioController:(AEAudioController*)audioController;

@property (nonatomic, readonly) float volume;
@property (nonatomic, readonly) AudioStreamBasicDescription audioDescription;
@end
