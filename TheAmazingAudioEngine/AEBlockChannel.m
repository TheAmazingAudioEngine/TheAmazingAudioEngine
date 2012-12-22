//
//  AEBlockChannel.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 20/12/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEBlockChannel.h"

@interface AEBlockChannel ()
@property (nonatomic, copy) AEBlockChannelBlock block;
@end

@implementation AEBlockChannel
@synthesize block = _block;

- (id)initWithBlock:(AEBlockChannelBlock)block {
    if ( !(self = [super init]) ) self = nil;
    self.volume = 1.0;
    self.pan = 0.0;
    self.block = block;
    self.channelIsMuted = NO;
    self.channelIsPlaying = YES;
    return self;
}

+ (AEBlockChannel*)channelWithBlock:(AEBlockChannelBlock)block {
    return [[[AEBlockChannel alloc] initWithBlock:block] autorelease];
}

-(void)dealloc {
    self.block = nil;
    [super dealloc];
}

static OSStatus renderCallback(id                        channel,
                               AEAudioController        *audioController,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    AEBlockChannel *THIS = (AEBlockChannel*)channel;
    THIS->_block(time, frames, audio);
    return noErr;
}

-(AEAudioControllerRenderCallback)renderCallback {
    return renderCallback;
}

@end
