//
//  ViewController.h
//  TheEngineSample
//
//  Created by Steve Rubin on 8/5/15.
//  Copyright (c) 2015 A Tasty Pixel. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class AEAudioController;

@interface ViewController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>

- (instancetype)initWithAudioController:(AEAudioController *)audioController;

@end
