//
//  TPTrialModeController.m
//  TPAudioController
//
//  Created by Michael Tyson on 11/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "TPTrialModeController.h"

@interface TPTrialModeController () {
    NSTimer *_timeout;
    UIView  *_display;
}
@end

#define kLabelTag 23452
static NSString * kAnimationName = @"scroller";

@implementation TPTrialModeController

- (id)init {
    if ( !(self = [super init]) ) return nil;
    
    _timeout = [NSTimer scheduledTimerWithTimeInterval:20 target:self selector:@selector(initialTimeoutFired:) userInfo:nil repeats:NO];
    
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if ( _display ) {
        [_display removeFromSuperview];
        [_display release];
    }
    if ( _timeout ) {
        [_timeout invalidate];
    }
    [super dealloc];
}

- (void)initialTimeoutFired:(NSTimer*)timer {
    _timeout = nil;
    
    UIView *topView = [[[UIApplication sharedApplication] windows] lastObject];
    
    _display = [[UIView alloc] initWithFrame:CGRectMake(0, [[UIApplication sharedApplication] statusBarFrame].size.height - 20, topView.frame.size.width, 20)];
    _display.userInteractionEnabled = NO; 
    _display.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _display.backgroundColor = [UIColor blackColor];
    
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.tag = kLabelTag;
    label.font = [UIFont systemFontOfSize:14.0];
    label.textColor = [UIColor whiteColor];
    label.text = @"This product uses a trial version of TPAudioController. See http://atastypixel.com/code/TPAudioController for info.";
    label.backgroundColor = [UIColor blackColor];
    [label sizeToFit];
    label.frame = CGRectMake(_display.bounds.size.width, 0, label.frame.size.width, label.frame.size.height);
    
    [_display addSubview:label];
    [topView addSubview:_display];
    
    [UIView animateWithDuration:8.0 delay:0.0 options:UIViewAnimationOptionRepeat|UIViewAnimationOptionCurveLinear|UIViewAnimationOptionAllowUserInteraction animations:^{ label.frame = CGRectMake(-label.frame.size.width, 0, label.frame.size.width, label.frame.size.height); } completion:NULL];
    [UIView animateWithDuration:0.3 animations:^ { _display.frame = CGRectOffset(_display.frame, 0, 20); }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidResume:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statusBarChanged:) name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
}

- (void)appDidResume:(NSNotification*)notification {
    UILabel *label = (UILabel*)[_display viewWithTag:kLabelTag];
    label.frame = CGRectMake(_display.bounds.size.width, 0, label.frame.size.width, label.frame.size.height);
    [UIView animateWithDuration:8.0 delay:0.0 options:UIViewAnimationOptionRepeat|UIViewAnimationOptionCurveLinear|UIViewAnimationOptionAllowUserInteraction animations:^{ label.frame = CGRectMake(-label.frame.size.width, 0, label.frame.size.width, label.frame.size.height); } completion:NULL];
}

- (void)statusBarChanged:(NSNotification*)notification {
    if ( [[UIApplication sharedApplication] statusBarOrientation] == UIInterfaceOrientationPortrait ) {
        _display.frame = CGRectMake(0, [[UIApplication sharedApplication] statusBarFrame].size.height, _display.frame.size.width, 20);
    } else {
        _display.frame = CGRectMake(0, 0, _display.frame.size.width, 20);
    }
}

@end
