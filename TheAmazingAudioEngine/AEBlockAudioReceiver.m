//
//  AEBlockAudioReceiver.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/02/2013.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEBlockAudioReceiver.h"

@interface AEBlockAudioReceiver ()
@property (nonatomic, copy) AEBlockAudioReceiverBlock block;
@end

@implementation AEBlockAudioReceiver
@synthesize block = _block;

- (id)initWithBlock:(AEBlockAudioReceiverBlock)block {
    if ( !(self = [super init]) ) self = nil;
    self.block = block;
    return self;
}

+ (AEBlockAudioReceiver*)audioReceiverWithBlock:(AEBlockAudioReceiverBlock)block {
    return [[[AEBlockAudioReceiver alloc] initWithBlock:block] autorelease];
}

-(void)dealloc {
    self.block = nil;
    [super dealloc];
}

static void receiverCallback(id                        receiver,
                             AEAudioController        *audioController,
                             void                     *source,
                             const AudioTimeStamp     *time,
                             UInt32                    frames,
                             AudioBufferList          *audio) {
    AEBlockAudioReceiver *THIS = (AEBlockAudioReceiver*)receiver;
    THIS->_block(source, time, frames, audio);
}

-(AEAudioControllerAudioCallback)receiverCallback {
    return receiverCallback;
}

@end
