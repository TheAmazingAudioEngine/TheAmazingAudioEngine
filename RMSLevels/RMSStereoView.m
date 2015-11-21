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
	rmsresult_t mResultL;
	rmsresult_t mResultR;
}
@end


////////////////////////////////////////////////////////////////////////////////
@implementation RMSStereoView
////////////////////////////////////////////////////////////////////////////////

- (void) timerDidFire:(NSTimer *)timer
{
	mResultL = RMSEngineFetchResult(self.enginePtrL);
	mResultR = RMSEngineFetchResult(self.enginePtrR);
	[self setNeedsDisplayInRect:self.bounds];
}

////////////////////////////////////////////////////////////////////////////////

- (void)drawRect:(NSRect)R
{
	// Set x = 0 at center of frame
	if (self.bounds.origin.x == 0.0)
	{ [self adjustOrigin]; }
	
	[[self bckColor] set];
	NSRectFill(self.bounds);
	
	[[self hldColor] set];
	NSRectFill([self computeHldRect]);

	[[self maxColor] set];
	NSRectFill([self computeMaxRect]);

	[[self avgColor] set];
	NSRectFill([self computeAvgRect]);
	
	[self drawBalanceIndicator];
	[self drawClippingIndicatorL];
}

////////////////////////////////////////////////////////////////////////////////

- (void) adjustOrigin
{
	NSRect B = self.bounds;
	B.origin.x -= 0.5 * B.size.width;
	self.bounds = B;
}

////////////////////////////////////////////////////////////////////////////////

static inline NSRect RMSStereoRectWithLR(NSRect B, double L, double R)
{
	L = 0.8 * sqrt(L);
	R = 0.8 * sqrt(R);
	
	L *= 0.5*B.size.width;
	R *= 0.5*B.size.width;
	
	B.origin.x = -L;
	B.size.width = +R;
	B.size.width -= B.origin.x;
	
	return B;
}

- (NSRect) computeHldRect
{ return RMSStereoRectWithLR(self.bounds, mResultL.mHld, mResultR.mHld); }

- (NSRect) computeMaxRect
{ return RMSStereoRectWithLR(self.bounds, mResultL.mMax, mResultR.mMax); }

- (NSRect) computeAvgRect
{ return RMSStereoRectWithLR(self.bounds, mResultL.mAvg, mResultR.mAvg); }

////////////////////////////////////////////////////////////////////////////////

- (void) drawBalanceIndicator
{
	NSRect R = self.bounds;
	R.origin.x = -0.5;
	R.size.width = +1.0;

	[[NSColor blackColor] set];
	NSRectFill(R);
	
	R = [self computeAvgRect];
	R.origin.x += R.origin.x + R.size.width;
	R.origin.x -= 0.5;
	R.size.width = 1.0;

	[[NSColor redColor] set];
	NSRectFill(R);
}

////////////////////////////////////////////////////////////////////////////////
#define HSBCLR(h, s, b, a) \
NSColor colorWithHue:h/360.0 saturation:s brightness:b alpha:a

- (void) drawClippingIndicatorL
{
	NSRect R = self.bounds;

	R.size.width *= 0.5 * 0.2;

	if (mResultL.mHld < 1.0)
	{
		[[HSBCLR(0.0, 1.0, 0.5, 1.0)] set];
	}
	else
	{
		[[HSBCLR(0.0, 1.0, 1.0, 0.5)] set];
	}
	
	NSRectFillUsingOperation(R, NSCompositeSourceOver);
}

////////////////////////////////////////////////////////////////////////////////
@end
////////////////////////////////////////////////////////////////////////////////
