//
//  AEBlockScheduler.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 22/03/2013.
//  Copyright (c) 2013 A Tasty Pixel. All rights reserved.
//

#import "AEBlockScheduler.h"
#import <libkern/OSAtomic.h>
#import <mach/mach_time.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

const int kMaximumSchedules = 100;

NSString const * AEBlockSchedulerKeyBlock = @"block";
NSString const * AEBlockSchedulerKeyTimestampInHostTicks = @"time";
NSString const * AEBlockSchedulerKeyResponseBlock = @"response";
NSString const * AEBlockSchedulerKeyIdentifier = @"identifier";
NSString const * AEBlockSchedulerKeyTimingContext = @"context";

struct _schedule_t {
    AEBlockSchedulerBlock block;
    void (^responseBlock)();
    uint64_t time;
    AEAudioTimingContext context;
    id identifier;
};

@interface AEBlockScheduler () {
    struct _schedule_t _schedule[kMaximumSchedules];
    int _head;
    int _tail;
}
@property (nonatomic, retain) NSMutableArray *scheduledIdentifiers;
@property (nonatomic, assign) AEAudioController *audioController;
@end

@implementation AEBlockScheduler
@synthesize scheduledIdentifiers = _scheduledIdentifiers;

+(void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    __hostTicksToSeconds = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
    __secondsToHostTicks = 1.0 / __hostTicksToSeconds;
}

+ (uint64_t)now {
    return mach_absolute_time();
}

+ (uint64_t)hostTicksFromSeconds:(NSTimeInterval)seconds {
    return seconds * __secondsToHostTicks;
}

+ (NSTimeInterval)secondsFromHostTicks:(uint64_t)ticks {
    return (double)ticks * __hostTicksToSeconds;
}

+ (uint64_t)timestampWithSecondsFromNow:(NSTimeInterval)seconds {
    return mach_absolute_time() + (seconds * __secondsToHostTicks);
}

+ (NSTimeInterval)secondsUntilTimestamp:(uint64_t)timestamp {
    return (timestamp - mach_absolute_time()) * __hostTicksToSeconds;
}

+ (uint64_t)timestampWithSeconds:(NSTimeInterval)seconds fromTimestamp:(uint64_t)timeStamp
{
    return (timeStamp + (seconds * __secondsToHostTicks));
}

- (id)initWithAudioController:(AEAudioController *)audioController {
    if ( !(self = [super init]) ) return nil;
    
    self.audioController = audioController;
    self.scheduledIdentifiers = [NSMutableArray array];
    
    return self;
}

-(void)dealloc {
    for ( int i=0; i<kMaximumSchedules; i++ ) {
        if ( _schedule[i].block ) {
            [_schedule[i].block release];
            if ( _schedule[i].responseBlock ) {
                [_schedule[i].responseBlock release];
            }
            [_schedule[i].identifier release];
        }
    }
    self.scheduledIdentifiers = nil;
    self.audioController = nil;
    [super dealloc];
}

-(void)scheduleBlock:(AEBlockSchedulerBlock)block atTime:(uint64_t)time timingContext:(AEAudioTimingContext)context identifier:(id<NSCopying>)identifier {
    [self scheduleBlock:block atTime:time timingContext:context identifier:identifier mainThreadResponseBlock:nil];
}

-(void)scheduleBlock:(AEBlockSchedulerBlock)block atTime:(uint64_t)time timingContext:(AEAudioTimingContext)context identifier:(id<NSCopying>)identifier mainThreadResponseBlock:(AEBlockSchedulerResponseBlock)response {
    NSAssert(identifier != nil && block != nil, @"Identifier and block must not be nil");
    
    if ( (_head+1)%kMaximumSchedules == _tail ) {
        NSLog(@"Unable to schedule block %@: No space in scheduling table.", identifier);
        return;
    }
    
    struct _schedule_t *schedule = &_schedule[_head];
    
    schedule->identifier = [(NSObject*)identifier copy];
    schedule->block = [block copy];
    schedule->responseBlock = response ? [response copy] : nil;
    schedule->time = time;
    schedule->context = context;
    
    OSMemoryBarrier();
    
    _head = (_head+1) % kMaximumSchedules;
    [_scheduledIdentifiers addObject:identifier];
}

-(NSArray *)schedules {
    return _scheduledIdentifiers;
}

-(void)cancelScheduleWithIdentifier:(id<NSCopying>)identifier {
    NSAssert(identifier != nil, @"Identifier must not be nil");
    
    struct _schedule_t *pointers[kMaximumSchedules];
    struct _schedule_t values[kMaximumSchedules];
    int scheduleCount = 0;
    
    for ( int i=_tail; i != _head; i=(i+1)%kMaximumSchedules ) {
        if ( _schedule[i].identifier && [_schedule[i].identifier isEqual:identifier] ) {
            pointers[scheduleCount] = &_schedule[i];
            values[scheduleCount] = _schedule[i];
            scheduleCount++;
        }
    }
    
    if ( scheduleCount == 0 ) return;
    
    struct _schedule_t **pointers_array = pointers;
    [_audioController performSynchronousMessageExchangeWithBlock:^{
        for ( int i=0; i<scheduleCount; i++ ) {
            memset(pointers_array[i], 0, sizeof(struct _schedule_t));
            if ( (pointers_array[i] - _schedule) == _tail ) {
                while ( !_schedule[_tail].block && _tail != _head ) {
                    _tail = (_tail + 1) % kMaximumSchedules;
                }
            }
        }
    }];

    [_scheduledIdentifiers removeObject:identifier];
    
    for ( int i=0; i<scheduleCount; i++ ) {
        [values[i].block release];
        if ( values[i].responseBlock ) {
            [values[i].responseBlock release];
        }
        [values[i].identifier release];
    }
}

- (NSDictionary*)infoForScheduleWithIdentifier:(id<NSCopying>)identifier {
    struct _schedule_t *schedule = [self scheduleWithIdentifier:identifier];
    if ( !schedule ) return nil;
    
    return [NSDictionary dictionaryWithObjectsAndKeys:
            schedule->block, AEBlockSchedulerKeyBlock,
            schedule->identifier, AEBlockSchedulerKeyIdentifier,
            schedule->responseBlock ? (id)schedule->responseBlock : [NSNull null], AEBlockSchedulerKeyResponseBlock,
            [NSNumber numberWithLongLong:schedule->time], AEBlockSchedulerKeyTimestampInHostTicks,
            [NSNumber numberWithInt:schedule->context], AEBlockSchedulerKeyTimingContext,
            nil];
}

- (struct _schedule_t*)scheduleWithIdentifier:(id<NSCopying>)identifier {
    for ( int i=_tail; i != _head; i=(i+1)%kMaximumSchedules ) {
        if ( (identifier && _schedule[i].identifier && [_schedule[i].identifier isEqual:identifier]) ) {
            return &_schedule[i];
        }
    }
    return NULL;
}

struct _timingReceiverFinishSchedule_t { struct _schedule_t schedule; AEBlockScheduler *THIS; };
static void timingReceiverFinishSchedule(AEAudioController *audioController, void *userInfo, int len) {
    struct _timingReceiverFinishSchedule_t *arg = (struct _timingReceiverFinishSchedule_t*)userInfo;
    
    if ( arg->schedule.responseBlock ) {
        arg->schedule.responseBlock();
        [arg->schedule.responseBlock release];
    }
    [arg->schedule.block release];
    
    [arg->THIS->_scheduledIdentifiers removeObject:arg->schedule.identifier];
    
    [arg->schedule.identifier release];
}

static void timingReceiver(id                        receiver,
                           AEAudioController        *audioController,
                           const AudioTimeStamp     *time,
                           UInt32 const              frames,
                           AEAudioTimingContext      context) {
    AEBlockScheduler *THIS = receiver;
    uint64_t endTime = time->mHostTime + AEConvertFramesToSeconds(audioController, frames)*__secondsToHostTicks;
    
    for ( int i=THIS->_tail; i != THIS->_head; i=(i+1)%kMaximumSchedules ) {
        if ( THIS->_schedule[i].block && THIS->_schedule[i].context == context && THIS->_schedule[i].time && endTime >= THIS->_schedule[i].time ) {
            UInt32 offset = THIS->_schedule[i].time > time->mHostTime ? AEConvertSecondsToFrames(audioController, (THIS->_schedule[i].time - time->mHostTime)*__hostTicksToSeconds) : 0;
            THIS->_schedule[i].block(time, offset);
            AEAudioControllerSendAsynchronousMessageToMainThread(audioController,
                                                                 timingReceiverFinishSchedule,
                                                                 &(struct _timingReceiverFinishSchedule_t) { .schedule = THIS->_schedule[i], .THIS = THIS },
                                                                 sizeof(struct _timingReceiverFinishSchedule_t));
            memset(&THIS->_schedule[i], 0, sizeof(struct _schedule_t));
            if ( i == THIS->_tail ) {
                while ( !THIS->_schedule[THIS->_tail].block && THIS->_tail != THIS->_head ) {
                    THIS->_tail = (THIS->_tail + 1) % kMaximumSchedules;
                }
            }
        }
    }
}

-(AEAudioControllerTimingCallback)timingReceiverCallback {
    return timingReceiver;
}

@end
