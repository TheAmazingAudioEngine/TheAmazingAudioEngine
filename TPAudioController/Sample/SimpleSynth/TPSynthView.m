//
//  TPSynthView.m
//  SimpleSynth
//
//  Created by Michael Tyson on 11/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "TPSynthView.h"
#import "TPSynthGenerator.h"
#import <QuartzCore/QuartzCore.h>

@implementation TPSynthView
@synthesize sampleSynth=_sampleSynth;

- (id)initWithFrame:(CGRect)frame {
    if ( !(self = [super initWithFrame:frame]) ) return nil;
    self.multipleTouchEnabled = YES;
    
    UIImage *background = [UIImage imageNamed:@"Default.png"];
    CALayer *imageLayer = [CALayer layer];
    imageLayer.contents = (id)[background CGImage];
    imageLayer.frame = CGRectMake(0, 0, [background size].width, [background size].height);
    [self.layer addSublayer:imageLayer];
    
    return self;
}

-(void)triggerNotesWithTouches:(NSSet *)touches {
    for ( UITouch *touch in touches ) {
        CGPoint point = [touch locationInView:self];
        
        CGFloat vol = (point.y / self.bounds.size.height) * 0.5;
        vol = vol*vol;
        
        // Trigger the note
        if ( ![_sampleSynth triggerNoteWithPitch:100 + 1000*(point.x / self.bounds.size.width) 
                                          volume:vol] ) return;
        
        
        // Some visual feedback
        UIImage *note = [UIImage imageNamed:@"Note.png"];
        CALayer *noteLayer = [CALayer layer];
        noteLayer.contents = (id)[note CGImage];
        noteLayer.frame = CGRectMake(0, 0, [note size].width, [note size].height);
        noteLayer.position = point;
        
        CABasicAnimation *scaleAnimation = [CABasicAnimation animationWithKeyPath:@"transform"];
        scaleAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        scaleAnimation.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(0.1, 0.1, 0.1)];
        scaleAnimation.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.0, 1.0, 1.0)];
        scaleAnimation.duration = 1.5;
        
        CABasicAnimation *fadeAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fadeAnimation.fromValue = [NSNumber numberWithFloat:1.0];
        fadeAnimation.toValue = [NSNumber numberWithFloat:0.0];
        fadeAnimation.beginTime = 0.75;
        fadeAnimation.duration = 0.75;
        
        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = [NSArray arrayWithObjects:scaleAnimation, fadeAnimation, nil];
        group.duration = 1.5;
        group.delegate = self;
        group.fillMode = kCAFillModeForwards;
        group.removedOnCompletion = NO;
        
        [self.layer addSublayer:noteLayer];
        [noteLayer addAnimation:group forKey:@"animation"];
    }
}

-(void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self triggerNotesWithTouches:touches];
}

-(void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [self triggerNotesWithTouches:touches];
}

-(void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    
}

-(void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    
}

-(void)animationDidStop:(CAAnimation *)anim finished:(BOOL)flag {
    // Remove the finished note layer
    for ( CALayer *sublayer in self.layer.sublayers ) {
        if ( anim == [sublayer animationForKey:@"animation"] ) {
            [sublayer removeFromSuperlayer];
            break;
        }
    }
}

@end
