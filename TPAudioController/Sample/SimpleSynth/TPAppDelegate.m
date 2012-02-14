//
//  TPAppDelegate.m
//  SimpleSynth
//
//  Created by Michael Tyson on 11/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "TPAppDelegate.h"
#import "TPSimpleSynthViewController.h"
#import <TPAudioController/TPAudioController.h>
#import "TPSynthGenerator.h"

@implementation TPAppDelegate

@synthesize window = _window;
@synthesize viewController = _viewController;
@synthesize audioController = _audioController;
@synthesize sampleSynth = _sampleSynth;

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
    self.audioController = [[[TPAudioController alloc] initWithAudioDescription:[TPAudioController interleaved16BitStereoAudioDescription]] autorelease];
    [_audioController start];
    
    // Create an instance of our synth, and add it as a channel to the audio controller
    self.sampleSynth = [[[TPSynthGenerator alloc] init] autorelease];
    [_audioController addChannels:[NSArray arrayWithObject:_sampleSynth]];

    // Create and display view controller
    self.viewController = [[[TPSimpleSynthViewController alloc] init] autorelease];
    _viewController.sampleSynth = _sampleSynth;
    self.window.rootViewController = self.viewController;
    [self.window makeKeyAndVisible];
    
    return YES;
}

@end
