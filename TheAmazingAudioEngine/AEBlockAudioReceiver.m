//
//  AEBlockAudioReceiver.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 21/02/2013.
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
    return [[AEBlockAudioReceiver alloc] initWithBlock:block];
}


static void receiverCallback(__unsafe_unretained AEBlockAudioReceiver *THIS,
                             __unsafe_unretained AEAudioController *audioController,
                             void                     *source,
                             const AudioTimeStamp     *time,
                             UInt32                    frames,
                             AudioBufferList          *audio) {
    THIS->_block(source, time, frames, audio);
}

-(AEAudioControllerAudioCallback)receiverCallback {
    return receiverCallback;
}

@end
