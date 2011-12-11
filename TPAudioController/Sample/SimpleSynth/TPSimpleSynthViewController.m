//
//  TPViewController.m
//  SimpleSynth
//
//  Created by Michael Tyson on 11/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "TPSimpleSynthViewController.h"
#import "TPSimpleSynth.h"
#import "TPSynthView.h"
#import <QuartzCore/QuartzCore.h>

#define kTouchMeLabelTag 2352

@implementation TPSimpleSynthViewController
@synthesize sampleSynth = _sampleSynth;

-(void)loadView {
    TPSynthView *synthView = [[[TPSynthView alloc] initWithFrame:CGRectZero] autorelease];
    self.view = synthView;
}

-(void)viewWillAppear:(BOOL)animated {
    ((TPSynthView*)self.view).sampleSynth = _sampleSynth;
    
    UILabel *touchMeLabel = [[[UILabel alloc] initWithFrame:CGRectMake(0, floor((self.view.bounds.size.height - 40)/2.0), self.view.bounds.size.width, 40)] autorelease];
    touchMeLabel.tag = kTouchMeLabelTag;
    touchMeLabel.backgroundColor = [UIColor clearColor];
    touchMeLabel.textColor = [UIColor whiteColor];
    touchMeLabel.font = [UIFont boldSystemFontOfSize:30.0];
    touchMeLabel.textAlignment = UITextAlignmentCenter;
    touchMeLabel.text = @"Touch Me";
    touchMeLabel.layer.shadowColor = [[UIColor blackColor] CGColor];
    touchMeLabel.layer.shadowOffset = CGSizeMake(0, 0);
    touchMeLabel.layer.shadowRadius = 1.0;
    touchMeLabel.layer.shadowOpacity = 1.0;
    
    [self.view addSubview:touchMeLabel];
    
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    animation.toValue = [NSNumber numberWithFloat:0.0];
    animation.duration = 10.0;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    animation.delegate = self;
    animation.fillMode = kCAFillModeForwards;
    animation.removedOnCompletion = NO;
    [touchMeLabel.layer addAnimation:animation forKey:nil];
}

-(void)animationDidStop:(CAAnimation *)anim finished:(BOOL)flag {
    [[self.view viewWithTag:kTouchMeLabelTag] removeFromSuperview];
}

@end
