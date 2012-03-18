//
//  AEAudioFilePlayer.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AEAudioController.h"

@interface AEAudioFilePlayer : NSObject <AEAudioPlayable>
+ (id)audioFilePlayerWithURL:(NSURL*)url audioController:(AEAudioController*)audioController error:(NSError**)error;

@property (nonatomic, readwrite) BOOL loop;
@property (nonatomic, readwrite) float volume;
@property (nonatomic, readwrite) float pan;
@property (nonatomic, readwrite) BOOL playing;
@property (nonatomic, readwrite) BOOL muted;
@property (nonatomic, readwrite) BOOL removeUponFinish;
@end
