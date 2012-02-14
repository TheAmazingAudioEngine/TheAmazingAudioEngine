//
//  TPAudioFilePlayer.h
//  TPAudioController
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <TPAudioController/TPAudioController.h>

@interface TPAudioFilePlayer : NSObject <TPAudioPlayable>
+ (id)audioFilePlayerWithURL:(NSURL*)url audioController:(TPAudioController*)audioController error:(NSError**)error;

@property (nonatomic, readwrite) BOOL loop;
@property (nonatomic, readwrite) float volume;
@property (nonatomic, readwrite) float pan;
@property (nonatomic, readwrite) BOOL playing;
@property (nonatomic, readwrite) BOOL muted;
@end
