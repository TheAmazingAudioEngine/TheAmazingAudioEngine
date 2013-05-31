//
//  AEBlockScheduler.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 22/03/2013.
//  Copyright (c) 2013 A Tasty Pixel. All rights reserved.
//

#ifdef __cplusplus
extern "C" {
#endif

#import <Foundation/Foundation.h>
#import "AEAudioController.h"

/*!
 * Schedule information dictionary keys
 */
extern NSString const * AEBlockSchedulerKeyBlock;
extern NSString const * AEBlockSchedulerKeyTimestampInHostTicks;
extern NSString const * AEBlockSchedulerKeyResponseBlock;
extern NSString const * AEBlockSchedulerKeyIdentifier;
extern NSString const * AEBlockSchedulerKeyTimingContext;

/*!
 * Scheduler block format
 *
 *  Will be executed in a Core Audio thread context, so it's very important not to call
 *  any Objective-C methods, allocate or free memory, or hold locks.
 *
 * @param intervalStartTime The timestamp corresponding to the start of this time interval
 * @param offsetInFrames    The offset, in frames, of this schedule's fire timestamp into the current time interval
 */
typedef void (^AEBlockSchedulerBlock)(const AudioTimeStamp *intervalStartTime, UInt32 offsetInFrames);

/*!
 * Scheduler response block
 *
 *  Will be called on the main thread
 */
typedef void (^AEBlockSchedulerResponseBlock)();

/*!
 * Block scheduler
 *
 *  This class allows you to schedule blocks to be performed at
 *  a particular time, on the Core Audio thread.
 *
 *  To use this class, create an instance, then add it as a timing
 *  receiver using AEAudioController's @link AEAudioController::addTimingReceiver: addTimingReceiver: @endlink.
 *
 *  Then begin scheduling blocks using @link scheduleBlock:atTime:timingContext:identifier: @endlink.
 */
@interface AEBlockScheduler : NSObject <AEAudioTimingReceiver>

/*!
 * Utility: Get current time
 */
+ (uint64_t)now;

/*!
 * Utility: Convert time in seconds to host ticks
 */
+ (uint64_t)hostTicksFromSeconds:(NSTimeInterval)seconds;

/*!
 * Utility: Convert time in host ticks to seconds
 */
+ (NSTimeInterval)secondsFromHostTicks:(uint64_t)ticks;

/*!
 * Utility: Create a timestamp in host ticks the given number of seconds in the future
 */
+ (uint64_t)timestampWithSecondsFromNow:(NSTimeInterval)seconds;

/*!
 * Utility: Create a timestamp in host ticks the given number of seconds from a timestamp
 */
+ (uint64_t)timestampWithSeconds:(NSTimeInterval)seconds fromTimestamp:(uint64_t)timeStamp;

/*!
 * Utility: Determine the number of seconds until a given timestamp
 */
+ (NSTimeInterval)secondsUntilTimestamp:(uint64_t)timestamp;

/*!
 * Initialize
 *
 * @param audioController The audio controller
 */
- (id)initWithAudioController:(AEAudioController*)audioController;

/*!
 * Schedule a block for execution
 *
 *  Once scheduled, the given block will be performed at or before the given
 *  time. Depending on the [hardware buffer duration](@ref AEAudioController::preferredBufferDuration),
 *  this may occur some milliseconds before the scheduled time.
 *
 *  The actual time corresponding to the beginning of the time interval in which the
 *  scheduled block was actually invoked will be passed to the block as an argument, as well
 *  as the number of frames into the time interval that the block is scheduled.
 *
 *  Blocks that are to be performed during the same time interval will be performed in the
 *  order in which they were scheduled.
 *
 *  VERY IMPORTANT NOTE: This block will be invoked on the Core Audio thread. You must never
 *  call any Objective-C methods, allocate or free memory, or hold locks within this block,
 *  or you will cause audio glitches to occur.
 *
 * @param block Block to perform
 * @param time Time at which block will be performed, in host ticks
 * @param context Timing context
 * @param identifier An identifier used to refer to the schedule later, if necessary (may not be nil)
 */
- (void)scheduleBlock:(AEBlockSchedulerBlock)block atTime:(uint64_t)time timingContext:(AEAudioTimingContext)context identifier:(id<NSCopying>)identifier;

/*!
 * Schedule a block for execution, with a response block to be performed on the main thread
 *
 *  Once scheduled, the given block will be performed at or before the given
 *  time. Depending on the [hardware buffer duration](@ref AEAudioController::preferredBufferDuration),
 *  this may occur some milliseconds before the scheduled time.
 *
 *  The actual time corresponding to the beginning of the time interval in which the
 *  scheduled block was actually invoked will be passed to the block as an argument, as well
 *  as the number of frames into the time interval that the block is scheduled.
 *
 *  Blocks that are to be performed during the same time interval will be performed in the
 *  order in which they were scheduled.
 *
 *  VERY IMPORTANT NOTE: This block will be invoked on the Core Audio thread. You must never
 *  call any Objective-C methods, allocate or free memory, or hold locks within this block,
 *  or you will cause audio glitches to occur.
 *
 *  Once the schedule has finished, the response block will be performed on the main thread.
 *
 * @param block Block to perform
 * @param time Time at which block will be performed, in host ticks
 * @param context Timing context
 * @param identifier An identifier used to refer to the schedule later, if necessary (may not be nil)
 * @param response A block to be performed on the main thread after the main block has been performed
 */
- (void)scheduleBlock:(AEBlockSchedulerBlock)block atTime:(uint64_t)time timingContext:(AEAudioTimingContext)context identifier:(id<NSCopying>)identifier mainThreadResponseBlock:(AEBlockSchedulerResponseBlock)response;

/*!
 * Obtain a list of schedules awaiting execution
 *
 *  This will return an array of schedule identifiers, which you passed
 *  as the 'identifier' parameter when scheduling.
 *
 * @returns Array of block identifiers
 */
- (NSArray*)schedules;

/*!
 * Obtain information about a particular schedule
 *
 *  This will return a dictionary with information about the schedule associated
 *  with the given identifier.
 */
- (NSDictionary*)infoForScheduleWithIdentifier:(id<NSCopying>)identifier;

/*!
 * Cancel a given schedule, so that it will not be performed
 *
 *  Note: If you have scheduled multiple blocks with the same identifier,
 *  all of these blocks will be cancelled.
 *
 * @param identifier The schedule identifier
 */
- (void)cancelScheduleWithIdentifier:(id<NSCopying>)identifier;

@end

#ifdef __cplusplus
}
#endif