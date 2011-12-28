//
//  TPAppDelegate.h
//  SimpleSynth
//
//  Created by Michael Tyson on 11/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import <UIKit/UIKit.h>

@class TPSimpleSynthViewController;
@class TPAudioController;
@class TPSynthGenerator;

@interface TPAppDelegate : UIResponder <UIApplicationDelegate>

@property (retain, nonatomic) UIWindow *window;
@property (retain, nonatomic) TPSimpleSynthViewController *viewController;
@property (retain, nonatomic) TPAudioController *audioController;
@property (retain, nonatomic) TPSynthGenerator *sampleSynth;
@end
