//
//  TPDoubleSpeedFilter.h
//  AEAudioController
//
//  Created by Michael Tyson on 25/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <TheAmazingAudioEngine/TheAmazingAudioEngine.h>

@interface TPDoubleSpeedFilter : NSObject <AEAudioVariableSpeedFilter>
- (id)initWithAudioController:(AEAudioController*)audioController;
@property (nonatomic, readonly) AEAudioControllerVariableSpeedFilterCallback filterCallback;
@end
