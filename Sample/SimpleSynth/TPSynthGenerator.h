//
//  TPSynthGenerator.h
//  Simple Synth
//
//  Created by Michael Tyson on 03/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"
#import "TPCircularBuffer.h"

@interface TPSynthGenerator : NSObject <AEAudioPlayable> {
    TPCircularBuffer _notes;
}

- (BOOL)triggerNoteWithPitch:(CGFloat)pitch volume:(CGFloat)volume;

@end
