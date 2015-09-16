//
//  AEAsyncMessageQueue.h
//  Extracted and modified from AEAudioController of Michael Tysons 'TheAmazingAudioEngine'
//
//  Created by Jonatan Liljedahl on 8/26/15.
//  Copyright (c) 2015 Jonatan Liljedahl.
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

#import <Foundation/Foundation.h>

@class AEAsyncMessageQueue;

/*!
 * Main thread message handler function
 *
 * @param messageQueue      The message queue
 * @param userInfo          Pointer to your data
 * @param userInfoLength    Length of userInfo in bytes
 */
typedef void (*AEAsyncMessageQueueMessageHandler)(AEAsyncMessageQueue *messageQueue, void *userInfo, int userInfoLength);

@interface AEAsyncMessageQueue : NSObject

/*!
 * Timeout for when realtime message blocks should be executed automatically
 *
 *  If greater than zero and AEAsyncMessageQueueProcessMessagesOnRealtimeThread hasn't been called
 *  in this many seconds, process the messages anyway on an internal thread. Default is zero.
 *
 */
@property (nonatomic, assign) NSTimeInterval autoProcessTimeout;

/*!
 * Process pending messages on realtime thread
 *
 *  Call this periodically from the realtime thread to process pending message blocks.
 *
 */
void AEAsyncMessageQueueProcessMessagesOnRealtimeThread(__unsafe_unretained AEAsyncMessageQueue *THIS);

/*!
 * Initialize with specified message buffer length
 *
 *  The true buffer length will be multiples of the device page size (e.g. 4096 bytes)
 *
 * @param numBytes      The message buffer length in bytes.
 */
- (instancetype)initWithMessageBufferLength:(int32_t)numBytes;

/*!
 * Start polling for messages from realtime thread to main thread
 *
 *  Call this after or right before starting the realtime thread that calls AEAsyncMessageQueueProcessMessagesOnRealtimeThread() periodically.
 *  The polling must be active for freeing up message resources, even if you don't
 *  explicitly use any responseBlocks or AEAsyncMessageQueueSendMessageToMainThread().
 *
 */
- (void)startPolling;

/*!
 * Stop polling for messages from realtime thread to main thread
 *
 */
- (void)stopPolling;

/*!
 * Send a message to the realtime thread asynchronously, optionally receiving a response via a block
 *
 *  This is a synchronization mechanism that allows you to schedule actions to be performed 
 *  on the realtime thread without any locking mechanism required. Pass in a block, and
 *  the block will be performed on the realtime thread at the next call to 
 *  AEAsyncMessageQueueProcessMessagesOnRealtimeThread().
 *
 *  Important: Do not interact with any Objective-C objects inside your block, or hold locks, allocate
 *  memory or interact with the BSD subsystem, as all of these may result in audio glitches due
 *  to priority inversion. Also beware of not copying or capturing ARC managed objects inside the block.
 *
 *  If provided, the response block will be called on the main thread after the message has
 *  been processed on the realtime thread. You may exchange information from the realtime thread to the main thread via a
 *  shared data structure (such as a struct, allocated on the heap in advance), or a __block variable.
 *
 * @param block         A block to be performed on the realtime thread.
 * @param responseBlock A block to be performed on the main thread after the handler has been run, or nil.
 */
- (void)performAsynchronousMessageExchangeWithBlock:(void (^)())block
                                      responseBlock:(void (^)())responseBlock;

/*!
 * Send a message to the realtime thread synchronously
 *
 *  This is a synchronization mechanism that allows you to schedule actions to be performed 
 *  on the realtime thread without any locking mechanism required. Pass in a block, and
 *  the block will be performed on the realtime thread at the next call to 
 *  AEAsyncMessageQueueProcessMessagesOnRealtimeThread().
 *
 *  Important: Do not interact with any Objective-C objects inside your block, or hold locks, allocate
 *  memory or interact with the BSD subsystem, as all of these may result in audio glitches due
 *  to priority inversion. Also beware of not copying or capturing ARC managed objects inside the block.
 *
 *  This method will block the current thread until the block has been processed on the realtime thread.
 *  You may pass information from the realtime thread to the calling thread via the use of __block variables.
 *
 * @param block         A block to be performed on the realtime thread.
 * @return              YES if the block could be performed, NO otherwise.
 */
- (BOOL)performSynchronousMessageExchangeWithBlock:(void (^)())block;

/*!
 * Send a message to the main thread asynchronously
 *
 *  This is a synchronization mechanism that allows the realtime thread to schedule actions to be performed
 *  on the main thread, without any locking or memory allocation.  Pass in a function pointer and
 *  optionally a pointer to data to be copied and passed to the handler, and the function will 
 *  be called on the main thread at the next polling interval.
 *
 * @param audioController The audio controller.
 * @param handler         A pointer to a function to call on the main thread.
 * @param userInfo        Pointer to user info data to pass to handler - this will be copied.
 * @param userInfoLength  Length of userInfo in bytes.
 */
void AEAsyncMessageQueueSendMessageToMainThread(AEAsyncMessageQueue               *messageQueue,
                                                AEAsyncMessageQueueMessageHandler  handler,
                                                void                              *userInfo,
                                                int                                userInfoLength);

@end
