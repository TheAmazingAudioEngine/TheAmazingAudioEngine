////////////////////////////////////////////////////////////////////////////////
/*
	RMSStereoView.m
	
	Created by 32BT on 15/11/15.
	Copyright © 2015 32BT. All rights reserved.
*/
////////////////////////////////////////////////////////////////////////////////

#import "RMSStereoView.h"


@interface RMSStereoView ()
{
	RMSLevelsView *mViewL;
	RMSLevelsView *mViewR;
	NSView *mIndicator;
}
@end


////////////////////////////////////////////////////////////////////////////////
@implementation RMSStereoView
////////////////////////////////////////////////////////////////////////////////

- (RMSLevelsView *) resultViewL
{
	if (mViewL == nil)
	{
		// Compute left side of bounds
		NSRect frame = self.bounds;
		frame.size.width *= 0.5;
		frame.size.width -= 1.0;
		
		// Create levels view with westerly drawing direction
		mViewL = [[RMSLevelsView alloc] initWithFrame:frame];
		mViewL.direction = eRMSViewDirectionW;
		
		// Add as subview
		[self addSubview:mViewL];
	}
	
	return mViewL;
}

////////////////////////////////////////////////////////////////////////////////

- (RMSLevelsView *) resultViewR
{
	if (mViewR == nil)
	{
		// Compute right side of bounds
		NSRect frame = self.bounds;
		frame.size.width *= 0.5;
		frame.size.width -= 1.0;
		frame.origin.x += frame.size.width+2.0;
		
		// Create levels view with default drawing direction
		mViewR = [[RMSLevelsView alloc] initWithFrame:frame];
		
		// Add as subview
		[self addSubview:mViewR];
	}
	
	return mViewR;
}

////////////////////////////////////////////////////////////////////////////////

- (NSView *) balanceIndicator
{
	if (mIndicator == nil)
	{
		// Create one point wide view
		NSRect frame = self.bounds;
		frame.origin.x += 0.5*frame.size.width;
		frame.origin.x -= 1.0;
		frame.size.width = 2.0;
		
		// Abuse background layer for coloring (OSX)
		mIndicator = [[NSView alloc] initWithFrame:frame];
		
		#if !TARGET_OS_IOS
		mIndicator.wantsLayer = YES;
		#endif
		mIndicator.layer.backgroundColor = [NSColor redColor].CGColor;

		// Add as subview
		[self addSubview:mIndicator];
	}
	
	return mIndicator;
}

////////////////////////////////////////////////////////////////////////////////

- (void) timerDidFire:(NSTimer *)timer
{
	rmsresult_t L = RMSEngineFetchResult(self.enginePtrL);
	rmsresult_t R = RMSEngineFetchResult(self.enginePtrR);
	
	[self.resultViewL setLevels:L];
	[self.resultViewR setLevels:R];
	[self setBalance:R.mAvg - L.mAvg];
	
}

////////////////////////////////////////////////////////////////////////////////

- (void) setBalance:(double)balance
{
	NSRect frame = self.bounds;
	frame.origin.x += 0.5*frame.size.width;
	frame.origin.x += 0.5*frame.size.width * balance;
	frame.origin.x -= 1.0;
	frame.size.width = 2.0;
	self.balanceIndicator.frame = frame;
}

////////////////////////////////////////////////////////////////////////////////

- (void) drawRect:(NSRect)rect
{
	[[NSColor blackColor] set];
	NSRectFill(rect);
}

////////////////////////////////////////////////////////////////////////////////
@end
////////////////////////////////////////////////////////////////////////////////
