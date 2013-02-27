//
//  AEBlockAudioReceiver.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/02/2013.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

typedef void (^AEBlockAudioReceiverBlock)(void                     *source,
                                          const AudioTimeStamp     *time,
                                          UInt32                    frames,
                                          AudioBufferList          *audio);

/*!
 * Block audio receiver: Utility class to allow use of a block to receive audio
 */
@interface AEBlockAudioReceiver : NSObject <AEAudioReceiver>

/*!
 * Create a new audio receiver with a given block
 *
 * @param block Block to use for audio generation
 */
+ (AEBlockAudioReceiver*)audioReceiverWithBlock:(AEBlockAudioReceiverBlock)block;

@end
