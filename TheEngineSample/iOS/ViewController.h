//
//  ViewController.h
//  Audio Controller Test Suite
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "RMSLevelsView.h"

@class AEAudioController;
@interface ViewController : UITableViewController

- (id)initWithAudioController:(AEAudioController*)audioController;

@property (nonatomic, strong) AEAudioController *audioController;

@property (nonatomic, weak) IBOutlet RMSLevelsView *levelsViewL;
@property (nonatomic, weak) IBOutlet RMSLevelsView *levelsViewR;

@end
