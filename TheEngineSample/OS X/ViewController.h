//
//  ViewController.h
//  TheEngineSample
//
//  Created by Steve Rubin on 8/5/15.
//  Copyright (c) 2015 A Tasty Pixel. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "RMSLevelsView.h"
#import "RMSStereoView.h"

@class AEAudioController;

@interface ViewController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak) IBOutlet RMSStereoView *stereoView;


- (instancetype)initWithAudioController:(AEAudioController *)audioController;

- (IBAction) rmsEngineButton:(id)button;
- (IBAction) rmsViewButton:(id)button;

@end
