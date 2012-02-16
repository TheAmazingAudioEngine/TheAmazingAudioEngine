//
//  TPConvolutionFilter.h
//
//  Created by Michael Tyson on 24/01/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <TPAudioController/TPAudioController.h>
#import "TPBlockLevelFilter.h"

@interface TPConvolutionFilter : TPBlockLevelFilter
+ (NSArray*)lowPassWindowedSincFilterWithFC:(float)fc;
+ (NSArray*)filterFromAudioFile:(NSURL*)audioFile scale:(float)scale error:(NSError**)error;

- (id)initWithAudioController:(TPAudioController*)audioController filter:(NSArray*)filter;

@property (nonatomic, assign) BOOL stereo;
@property (nonatomic, strong) NSArray *filter; // array of NSData containing floats (one NSData per channel)
@end
