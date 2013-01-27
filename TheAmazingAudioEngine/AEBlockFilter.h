//
//  AEBlockFilter.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 20/12/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

typedef void (^AEBlockFilterBlock)(void                     *source,
                                   const AudioTimeStamp     *time,
                                   UInt32                    frames,
                                   AudioBufferList          *audio);

/*!
 * Block filter: Utility class to allow use of a block to filter audio
 */
@interface AEBlockFilter : NSObject <AEAudioFilter>

/*!
 * Create a new filter with a given block
 *
 * @param block Block to use for audio generation
 */
+ (AEBlockFilter*)filterWithBlock:(AEBlockFilterBlock)block;

/*
 * The audio format for this filter
 */
@property (nonatomic, assign) AudioStreamBasicDescription audioDescription;

@end
