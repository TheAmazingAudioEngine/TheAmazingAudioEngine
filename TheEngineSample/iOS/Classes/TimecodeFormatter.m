//
//  TimecodeFormatter.m
//  TheEngineSample
//
//  Created by Jeschke, Mark on 3/10/16.
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
//

#import "TimecodeFormatter.h"

@implementation TimecodeFormatter

- (NSString *)timeFormatted:(int)totalSeconds
{
    int seconds = totalSeconds % 60;
    int minutes = (totalSeconds / 60) % 60;
    int hours = totalSeconds / 3600;
    return [NSString stringWithFormat:@"%02d:%02d:%02d",hours, minutes, seconds];
}

@end
