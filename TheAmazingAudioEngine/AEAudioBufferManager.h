//
//  AEAudioBufferManager.h
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 30/11/2015.
//  Copyright © 2015 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>

/*!
 * Audio buffer manager class
 *
 *  This class allows you to apply normal Objective-C memory management techniques
 *  to an AudioBufferList structure, which can simply buffer management tasks.
 *
 *  Create an instance of this class, passing in an already-initialized AudioBufferList,
 *  and the class will manage the remaining life-cycle of the buffer list.
 */
@interface AEAudioBufferManager : NSObject

/*!
 * Create an instance
 *
 * @param bufferList An initialized AudioBufferList structure (see @link AEAudioBufferListCreate @endlink)
 */
- (instancetype)initWithBufferList:(AudioBufferList *)bufferList;

/*!
 * Get the audio buffer list
 *
 *  This method is safe for use on the realtime audio thread.
 */
AudioBufferList * AEAudioBufferManagerGetBuffer(__unsafe_unretained AEAudioBufferManager * buffer);

/*!
 * Access the read/write lock
 *
 *  Use this when you need to manage multiple threads with access to the buffer list.
 *
 *  Important: Never hold locks on the audio thread. If mutual exclusion is necessary,
 *  use a try lock, which is non-blocking.
 */
pthread_rwlock_t * AEAudioBufferManagerGetLock(__unsafe_unretained AEAudioBufferManager * buffer);

@end
