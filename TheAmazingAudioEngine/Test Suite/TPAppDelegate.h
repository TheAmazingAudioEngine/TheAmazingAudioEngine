//
//  TPAppDelegate.h
//  Audio Controller Test Suite
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <UIKit/UIKit.h>
@class TPViewController;
@class AEAudioController;

@interface TPAppDelegate : UIResponder <UIApplicationDelegate>

@property (retain, nonatomic) UIWindow *window;
@property (retain, nonatomic) TPViewController *viewController;
@property (retain, nonatomic) AEAudioController *audioController;
@end
