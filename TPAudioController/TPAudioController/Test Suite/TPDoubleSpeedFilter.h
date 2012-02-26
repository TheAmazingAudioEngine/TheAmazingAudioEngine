//
//  TPDoubleSpeedFilter.h
//  TPAudioController
//
//  Created by Michael Tyson on 25/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TPAudioController.h"

@interface TPDoubleSpeedFilter : NSObject <TPAudioVariableSpeedFilter>
- (id)initWithAudioController:(TPAudioController*)audioController;
@property (nonatomic, readonly) TPAudioControllerVariableSpeedFilterCallback filterCallback;
@end
