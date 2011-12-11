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

@implementation TPSimpleSynthViewController
@synthesize sampleSynth = _sampleSynth;

-(void)loadView {
    TPSynthView *synthView = [[[TPSynthView alloc] initWithFrame:CGRectZero] autorelease];
    self.view = synthView;
}

-(void)viewWillAppear:(BOOL)animated {
    ((TPSynthView*)self.view).sampleSynth = _sampleSynth;
}

@end
