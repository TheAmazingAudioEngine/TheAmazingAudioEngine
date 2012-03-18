//
//  TPBlockLevelFilter.h
//
//  Created by Michael Tyson on 11/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <TheAmazingAudioEngine/TheAmazingAudioEngine.h>

@class TPBlockLevelFilter;

/*!
 * Block-level filter callback
 *
 *      Provides audio to be processed, as blocks of floats of the pre-set block size.
 *      If less than the full block size has been consumed or produced, you must update
 *      the consumedInputFrames or producedOutputFrames variables accordingly.
 *
 * @param filter Pointer to filter class (do not call Objective-C methods, however)
 * @param time Timestamp of audio
 * @param frames Number of frames
 * @param input Non-interlaced buffer list containing input audio (as floats)
 * @param output Non-interlaced buffer list for output audio (as floats)
 * @param consumedInputFrames On output, the number of frames consumed
 * @param producedOutputFrames On output, the number of frames produced
 */
typedef void (*TPBlockLevelFilterAudioCallback) (TPBlockLevelFilter      *filter,
                                                 const AudioTimeStamp    *time,
                                                 UInt32                   frames,
                                                 AudioBufferList         *input,
                                                 AudioBufferList         *output,
                                                 int                     *consumedInputFrames,
                                                 int                     *producedOutputFrames);


/*!
 * Get processing block size
 *
 *      This function provides a C interface to getting the block size.
 */
int TPBlockLevelFilterGetProcessingBlockSize(TPBlockLevelFilter* filter);

/*!
 * Set processing block size
 *
 *      This function provides a C interface to setting the block size.
 */
void TPBlockLevelFilterSetProcessingBlockSize(TPBlockLevelFilter* filter, int processingBlockSizeInFrames);

/*!
 * Block-level filter
 *
 *      Processes audio in blocks of a fixed size, in float format. Suitable
 *      for filters involving FFTs, for instance.
 */
@interface TPBlockLevelFilter : NSObject <AEAudioFilter>

/*!
 * Initialise with a given block size, and a function pointer for block processing
 */
- (id)initWithAudioController:(AEAudioController*)audioController processingBlockSize:(int)processingBlockSizeInFrames blockProcessingCallback:(TPBlockLevelFilterAudioCallback)callback;

@property (nonatomic, readonly) AEAudioControllerAudioCallback filterCallback;
@property (nonatomic, assign) BOOL stereo;
@property (nonatomic, assign) int processingBlockSizeInFrames;
@end
