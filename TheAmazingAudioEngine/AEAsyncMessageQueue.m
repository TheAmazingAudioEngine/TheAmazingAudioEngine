//
//  AsyncMessageQueue.m
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


#import "AEAsyncMessageQueue.h"
#import "TPCircularBuffer.h"
#import <mach/mach_time.h>
#import <pthread.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

/*!
 * Message
 */
typedef struct {
    void                           *block;
    void                           *responseBlock;
    AEAsyncMessageQueueMessageHandler handler;
    void                           *userInfoByReference;
    int                             userInfoLength;
    pthread_t                       sourceThread;
    BOOL                            replyServiced;
} message_t;

static const int kDefaultMessageBufferLength             = 8192;
static const NSTimeInterval kIdleMessagingPollDuration   = 0.1;
static const NSTimeInterval kActiveMessagingPollDuration = 0.01;

@interface AEAsyncMessageQueuePollThread : NSThread

- (id)initWithMessageQueue:(AEAsyncMessageQueue*)messageQueue;

@property (nonatomic, assign) NSTimeInterval pollInterval;

@end

@interface AEAsyncMessageQueue ()

@property (nonatomic, readonly) uint64_t lastProcessTime;

@end

@implementation AEAsyncMessageQueue
{
    TPCircularBuffer    _realtimeThreadMessageBuffer;
    TPCircularBuffer    _mainThreadMessageBuffer;
    AEAsyncMessageQueuePollThread *_pollThread;
    int                 _pendingResponses;
}

+ (void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    __hostTicksToSeconds = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
    __secondsToHostTicks = 1.0 / __hostTicksToSeconds;
}

- (instancetype)initWithMessageBufferLength:(int32_t)numBytes {
    self = [super init];
    if(self) {
        TPCircularBufferInit(&_realtimeThreadMessageBuffer, numBytes);
        TPCircularBufferInit(&_mainThreadMessageBuffer, numBytes);
    }
    return self;
}

- (instancetype)init {
    return [self initWithMessageBufferLength:kDefaultMessageBufferLength];
}

- (void)dealloc {
    TPCircularBufferCleanup(&_realtimeThreadMessageBuffer);
    TPCircularBufferCleanup(&_mainThreadMessageBuffer);
    [self stopPolling];
}

- (void)startPolling {
    if ( !_pollThread ) {
        // Start messaging poll thread
        _lastProcessTime = mach_absolute_time();
        _pollThread = [[AEAsyncMessageQueuePollThread alloc] initWithMessageQueue:self];
        _pollThread.pollInterval = kIdleMessagingPollDuration;
        OSMemoryBarrier();
        [_pollThread start];
    }
}

- (void)stopPolling {
    if ( _pollThread ) {
        [_pollThread cancel];
        while ( [_pollThread isExecuting] ) {
            [NSThread sleepForTimeInterval:0.01];
        }
        _pollThread = nil;
    }
}

void AEAsyncMessageQueueProcessMessagesOnRealtimeThread(__unsafe_unretained AEAsyncMessageQueue *THIS) {
    // Only call this from the Realtime thread, or the main thread if audio system is not yet running

    THIS->_lastProcessTime = mach_absolute_time();

    int32_t availableBytes;
    message_t *buffer = TPCircularBufferTail(&THIS->_realtimeThreadMessageBuffer, &availableBytes);
    message_t *end = (message_t*)((char*)buffer + availableBytes);
    message_t message;
    
    while ( buffer < end ) {
        assert(buffer->userInfoLength == 0);
        
        memcpy(&message, buffer, sizeof(message));
        TPCircularBufferConsume(&THIS->_realtimeThreadMessageBuffer, sizeof(message_t));
        
        if ( message.block ) {
            ((__bridge void(^)())message.block)();
        }

        int32_t availableBytes;
        message_t *reply = TPCircularBufferHead(&THIS->_mainThreadMessageBuffer, &availableBytes);
        assert(availableBytes >= sizeof(message_t));
        memcpy(reply, &message, sizeof(message_t));
        TPCircularBufferProduce(&THIS->_mainThreadMessageBuffer, sizeof(message_t));
        
        buffer++;
    }
}

-(void)pollForMessageResponses {
    pthread_t thread = pthread_self();
    BOOL isMainThread = [NSThread isMainThread];

    while ( 1 ) {
        message_t *message = NULL;
        @synchronized ( self ) {
            // Look for pending messages
            int32_t availableBytes;
            message_t *buffer = TPCircularBufferTail(&_mainThreadMessageBuffer, &availableBytes);
            if ( !buffer ) {
                break;
            }
            
            message_t *bufferEnd = (message_t*)(((char*)buffer)+availableBytes);
            BOOL hasUnservicedMessages = NO;
            
            // Look through pending messages
            while ( buffer < bufferEnd && !message ) {
                int messageLength = sizeof(message_t) + (buffer->userInfoLength && !buffer->userInfoByReference ? buffer->userInfoLength : 0);

                if ( !buffer->replyServiced ) {
                    // This is a message that hasn't yet been serviced
                    
                    if ( (buffer->sourceThread && buffer->sourceThread != thread) && (buffer->sourceThread == NULL && !isMainThread) ) {
                        // Skip this message, it's for a different thread
                        hasUnservicedMessages = YES;
                    } else {
                        // Service this message
                        message = (message_t*)malloc(messageLength);
                        memcpy(message, buffer, messageLength);
                        buffer->replyServiced = YES;
                    }
                }
                
                // Advance to next message
                buffer = (message_t*)(((char*)buffer)+messageLength);
                
                if ( !hasUnservicedMessages ) {
                    // If we're done with all message records so far, free up the buffer
                    TPCircularBufferConsume(&_mainThreadMessageBuffer, messageLength);
                }
            }
        }
        
        if ( !message ) {
            break;
        }
        
        if ( message->responseBlock ) {
            ((__bridge void(^)())message->responseBlock)();
            CFBridgingRelease(message->responseBlock);
            
            _pendingResponses--;
            if ( _pollThread && _pendingResponses == 0 ) {
                _pollThread.pollInterval = kIdleMessagingPollDuration;
            }
        } else if ( message->handler ) {
            message->handler(self, 
                             message->userInfoLength > 0
                             ? (message->userInfoByReference ? message->userInfoByReference : message+1) 
                             : NULL, 
                             message->userInfoLength);
        }
        
        if ( message->block ) {
            CFBridgingRelease(message->block);
        }
        
        free(message);
    }
}

- (void)performAsynchronousMessageExchangeWithBlock:(void (^)())block
                                      responseBlock:(void (^)())responseBlock
                                       sourceThread:(pthread_t)sourceThread {
    @synchronized ( self ) {

        int32_t availableBytes;
        message_t *message = TPCircularBufferHead(&_realtimeThreadMessageBuffer, &availableBytes);
        
        if ( availableBytes < sizeof(message_t) ) {
            NSLog(@"AEAsyncMessageQueue: Unable to perform message exchange - queue is full.");
            return;
        }
        
        if ( responseBlock ) {
            _pendingResponses++;
            
            if ( _pollThread.pollInterval == kIdleMessagingPollDuration ) {
                // Perform more rapid active polling while we expect a response
                _pollThread.pollInterval = kActiveMessagingPollDuration;
            }
        }
        
        memset(message, 0, sizeof(message_t));
        message->block         = block ? (__bridge_retained void*)[block copy] : NULL;
        message->responseBlock = responseBlock ? (__bridge_retained void*)[responseBlock copy] : NULL;
        message->sourceThread  = sourceThread; // Used only for synchronous message exchange
        
        TPCircularBufferProduce(&_realtimeThreadMessageBuffer, sizeof(message_t));
        
    }
}


- (void)performAsynchronousMessageExchangeWithBlock:(void (^)())block responseBlock:(void (^)())responseBlock {
    [self performAsynchronousMessageExchangeWithBlock:block responseBlock:responseBlock sourceThread:NULL];
}

- (BOOL)performSynchronousMessageExchangeWithBlock:(void (^)())block {
    __block BOOL finished = NO;
    [self performAsynchronousMessageExchangeWithBlock:block
                                        responseBlock:^{ finished = YES; }
                                         sourceThread:pthread_self()];

    // Wait for response
    uint64_t giveUpTime = mach_absolute_time() + (1.0 * __secondsToHostTicks);
    while ( !finished && mach_absolute_time() < giveUpTime ) {
        [self pollForMessageResponses];
        if ( finished ) break;
        [NSThread sleepForTimeInterval: kActiveMessagingPollDuration];
    }
    
    if ( !finished ) {
        NSLog(@"AEAsyncMessageQueue: Timed out while performing synchronous message exchange");
    }
    return finished;
}

void AEAsyncMessageQueueSendMessageToMainThread(__unsafe_unretained AEAsyncMessageQueue *THIS,
                                                          AEAsyncMessageQueueMessageHandler        handler,
                                                          void                                    *userInfo,
                                                          int                                      userInfoLength) {
    
    int32_t availableBytes;
    message_t *message = TPCircularBufferHead(&THIS->_mainThreadMessageBuffer, &availableBytes);
    assert(availableBytes >= sizeof(message_t) + userInfoLength);
    memset(message, 0, sizeof(message_t));
    message->handler                = handler;
    message->userInfoLength         = userInfoLength;
    
    if ( userInfoLength > 0 ) {
        memcpy((message+1), userInfo, userInfoLength);
    }
    
    TPCircularBufferProduce(&THIS->_mainThreadMessageBuffer, sizeof(message_t) + userInfoLength);
}

static BOOL AEAsyncMessageQueueHasPendingMainThreadMessages(__unsafe_unretained AEAsyncMessageQueue *THIS) {
    int32_t ignore;
    return TPCircularBufferTail(&THIS->_mainThreadMessageBuffer, &ignore) != NULL;
}

@end


@implementation AEAsyncMessageQueuePollThread
{
    __weak AEAsyncMessageQueue *_messageQueue;

}
- (id)initWithMessageQueue:(AEAsyncMessageQueue *)messageQueue {
    if ( !(self = [super init]) ) return nil;
    _messageQueue = messageQueue;
    return self;
}
- (void)main {
    @autoreleasepool {
        pthread_setname_np("com.kymatica.AEAsyncMessageQueuePollThread");
        while ( ![self isCancelled] ) {
            @autoreleasepool {
                if ( _messageQueue.autoProcessTimeout > 0 && (mach_absolute_time() - _messageQueue.lastProcessTime) * __hostTicksToSeconds > _messageQueue.autoProcessTimeout ) {
                    AEAsyncMessageQueueProcessMessagesOnRealtimeThread(_messageQueue);
                }
                if ( AEAsyncMessageQueueHasPendingMainThreadMessages(_messageQueue) ) {
                    [_messageQueue performSelectorOnMainThread:@selector(pollForMessageResponses) withObject:nil waitUntilDone:NO];
                }
                usleep(_pollInterval*1.0e6);
            }
        }
    }
}
@end