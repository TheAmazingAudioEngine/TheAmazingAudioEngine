//
//  AEFloatConverter.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 25/10/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>


@interface AEFloatConverter : NSObject
- (id)initWithSourceFormat:(AudioStreamBasicDescription)sourceFormat;

BOOL AEFloatConverterToFloat(AEFloatConverter* converter, AudioBufferList *sourceBuffer, float* targetBuffers[2], UInt32 frames);
BOOL AEFloatConverterFromFloat(AEFloatConverter* converter, float* sourceBuffers[2], AudioBufferList *targetBuffer, UInt32 frames);
@end
