//
//  TPSynthView.h
//  SimpleSynth
//
//  Created by Michael Tyson on 11/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>

@class TPSynthGenerator;
@interface TPSynthView : UIView

@property (nonatomic, retain) TPSynthGenerator *sampleSynth;
@end
