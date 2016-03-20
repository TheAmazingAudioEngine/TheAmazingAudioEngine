//
//  TransformToReadableFilesize.m
//  TheEngineSample
//
//  Created by Jeschke, Mark on 3/10/16.
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
//

#import "FilesizeFormatter.h"

@implementation FilesizeFormatter

- (id)transformedValue:(id)value
{
    double convertedValue = [value doubleValue];
    int multiplyFactor = 0;
    
    NSArray *tokens = @[@"bytes",@"KB",@"MB",@"GB",@"TB"];
    
    while (convertedValue > 1024) {
        convertedValue /= 1024;
        multiplyFactor++;
    }
    
    return [NSString stringWithFormat:@"%4.1f %@",convertedValue, tokens[multiplyFactor]];
}

@end
