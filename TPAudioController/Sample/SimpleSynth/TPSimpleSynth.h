//
//  TPSimpleSynth.h
//  SimpleSynth
//
//  Created by Michael Tyson on 11/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <TPAudioController/TPAudioController.h>

@interface TPSimpleSynth : NSObject <TPAudioPlayable> {
    NSArray *_notes;
}

- (void)triggerNoteWithPitch:(CGFloat)pitch volume:(CGFloat)volume;

@end
