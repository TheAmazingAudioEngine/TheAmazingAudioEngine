//
//  AEBlockFilter.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 20/12/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEBlockFilter.h"

@interface AEBlockFilter ()
@property (nonatomic, copy) AEBlockFilterBlock block;
@end

@implementation AEBlockFilter
@synthesize block = _block;

- (id)initWithBlock:(AEBlockFilterBlock)block {
    if ( !(self = [super init]) ) self = nil;
    self.block = block;
    return self;
}

+ (AEBlockFilter*)filterWithBlock:(AEBlockFilterBlock)block {
    return [[[AEBlockFilter alloc] initWithBlock:block] autorelease];
}

-(void)dealloc {
    self.block = nil;
    [super dealloc];
}

static void filterCallback(id                        filter,
                           AEAudioController        *audioController,
                           void                     *source,
                           const AudioTimeStamp     *time,
                           UInt32                    frames,
                           AudioBufferList          *audio) {
    AEBlockFilter *THIS = (AEBlockFilter*)filter;
    THIS->_block(source, time, frames, audio);
}

-(AEAudioControllerAudioCallback)filterCallback {
    return filterCallback;
}

@end
