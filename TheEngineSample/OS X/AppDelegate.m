//
//  AppDelegate.m
//  TheEngineSampleOSX
//
//  Created by Steve Rubin on 8/5/15.
//  Copyright (c) 2015 A Tasty Pixel. All rights reserved.
//

#import "AppDelegate.h"
#import "TheAmazingAudioEngine.h"
#import "ViewController.h"

@interface AppDelegate ()

@property (weak) IBOutlet NSWindow *window;
@property (nonatomic, strong) ViewController *viewController;
@property (nonatomic, strong) AEAudioController *audioController;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {    
    // Create an instance of the audio controller, set it up and start it running
    AudioStreamBasicDescription asbd = [AEAudioController nonInterleavedFloatStereoAudioDescription];
    
    self.audioController = [[AEAudioController alloc] initWithAudioDescription:asbd inputEnabled:YES];
    self.audioController.preferredBufferDuration = 0.005;
    [self.audioController start:NULL];
    
    // Create and display view controller
    self.viewController = [[ViewController alloc] initWithAudioController:self.audioController];
    self.window.contentViewController = self.viewController;
    self.window.contentView = self.viewController.view;
    self.window.backgroundColor = [NSColor whiteColor];
    [self.window setStyleMask:[self.window styleMask] & ~NSResizableWindowMask];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

@end
