//
//  TPOscilloscopeLayer.h
//  Audio Manager Demo
//
//  Created by Michael Tyson on 27/07/2011.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif
#import <QuartzCore/QuartzCore.h>
#import "TheAmazingAudioEngine.h"

@interface TPOscilloscopeLayer : CALayer <AEAudioReceiver>

/*!
 * Initialize
 */
- (id)initWithAudioController:(AEAudioController*)audioController;

/*!
 * Begin rendering
 *
 * Registers with the audio controller to start receiving
 * outgoing audio samples, and begins rendering.
 */
- (void)start;

/*!
 * Stop rendering
 *
 * Stops rendering, and unregisters from the audio controller.
 */
- (void)stop;

/*! The line color to render with */
#if TARGET_OS_IPHONE
@property (nonatomic, strong) UIColor *lineColor;
#else
@property (nonatomic, strong) NSColor *lineColor;
#endif

- (AEAudioControllerAudioCallback)receiverCallback;

@end
