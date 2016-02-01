//
//  AEAudioBufferManager.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 30/11/2015.
//  Copyright © 2015 A Tasty Pixel. All rights reserved.
//

#import "AEAudioBufferManager.h"
#import "AEUtilities.h"

@implementation AEAudioBufferManager {
    AudioBufferList * _bufferList;
    pthread_rwlock_t _lock;
}

- (instancetype)initWithBufferList:(AudioBufferList *)bufferList {
    if ( !(self = [super init]) ) return nil;
    _bufferList = bufferList;
    pthread_rwlock_init(&_lock, NULL);
    return self;
}

- (void)dealloc {
    AEAudioBufferListFree(_bufferList);
    pthread_rwlock_destroy(&_lock);
}

AudioBufferList * AEAudioBufferManagerGetBuffer(__unsafe_unretained AEAudioBufferManager * THIS) {
    if ( !THIS ) return NULL;
    return THIS->_bufferList;
}

pthread_rwlock_t * AEAudioBufferManagerGetLock(__unsafe_unretained AEAudioBufferManager * THIS) {
    if ( !THIS ) return NULL;
    return &THIS->_lock;
}

@end
