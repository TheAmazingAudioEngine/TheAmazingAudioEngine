//
//  MoreButtonIcon.m
//  TheEngineSample
//
//  Created by Jeschke, Mark on 3/2/16.
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
//

#import "MoreButtonIcon.h"

@implementation MoreButtonIcon

-(id) initWithCoder:(NSCoder *)aDecoder
{
    if ((self = [super initWithCoder:aDecoder])) {
        _red = 0.8;
        _blue = 0.8;
        _green = 0.8;
        _alpha = 1.0f;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {

    UIColor* color0 = [UIColor colorWithRed:_red/255.0f green:_green/255.0f blue:_blue/255.0f alpha:_alpha];
    
    {

        UIBezierPath* oval2Path = [UIBezierPath bezierPathWithOvalInRect: CGRectMake(45, 13, 3, 3)];
        [color0 setFill];
        [oval2Path fill];
        

        UIBezierPath* ovalPath = [UIBezierPath bezierPathWithOvalInRect: CGRectMake(45, 19, 3, 3)];
        [color0 setFill];
        [ovalPath fill];
        

        UIBezierPath* oval3Path = [UIBezierPath bezierPathWithOvalInRect: CGRectMake(45, 25, 3, 3)];
        [color0 setFill];
        [oval3Path fill];
    }
}

-(void) setRed:(CGFloat)red
{
    _red = red;
    [self setNeedsDisplay];
}

-(void) setGreen:(CGFloat)green
{
    _green = green;
    [self setNeedsDisplay];
}

-(void) setBlue:(CGFloat)blue
{
    _blue = blue;
    [self setNeedsDisplay];
}

@end