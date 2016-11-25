//
//  TimecodeFormatter.h
//  TheEngineSample
//
//  Created by Jeschke, Mark on 3/10/16.
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface TimecodeFormatter : NSObject

- (NSString *)timeFormatted:(int)totalSeconds;

@end
