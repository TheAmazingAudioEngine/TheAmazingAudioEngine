//
//  AppDelegate.h
//  Audio Controller Test Suite
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <UIKit/UIKit.h>
@class ViewController;
@class AEAudioController;

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (retain, nonatomic) UIWindow *window;
@property (retain, nonatomic) ViewController *viewController;
@property (retain, nonatomic) AEAudioController *audioController;
@end
