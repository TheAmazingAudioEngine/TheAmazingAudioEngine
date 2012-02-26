//
//  TPAppDelegate.m
//  Audio Controller Test Suite
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "TPAppDelegate.h"
#import "TPViewController.h"
#import <TPAudioController/TPAudioController.h>

@implementation TPAppDelegate

@synthesize window = _window;
@synthesize viewController = _viewController;
@synthesize audioController = _audioController;

- (void)dealloc
{
    [_window release];
    [_viewController release];
    [super dealloc];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    
    // Create an instance of the audio controller, set it up and start it running
    self.audioController = [[[TPAudioController alloc] initWithAudioDescription:[TPAudioController nonInterleaved16BitStereoAudioDescription] inputEnabled:YES useVoiceProcessing:YES] autorelease];
    [_audioController start];
    
    // Create and display view controller
    self.viewController = [[[TPViewController alloc] initWithAudioController:_audioController] autorelease];
    self.window.rootViewController = self.viewController;
    [self.window makeKeyAndVisible];
    
    return YES;
}

@end
