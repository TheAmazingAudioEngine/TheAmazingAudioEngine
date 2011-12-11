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

@implementation TPTrialModeController

- (id)init {
    if ( !(self = [super init]) ) return nil;
    
    _timeout = [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(initialTimeoutFired:) userInfo:nil repeats:NO];
    
    return self;
}

- (void)dealloc {
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
    
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationCurve:UIViewAnimationCurveLinear];
    [UIView setAnimationDuration:8.0];
    [UIView setAnimationRepeatCount:9999];
    label.frame = CGRectMake(-label.frame.size.width, 0, label.frame.size.width, label.frame.size.height);
    [UIView commitAnimations];
    
    [UIView animateWithDuration:0.3 animations:^ { _display.frame = CGRectOffset(_display.frame, 0, 20); }];
}


@end
