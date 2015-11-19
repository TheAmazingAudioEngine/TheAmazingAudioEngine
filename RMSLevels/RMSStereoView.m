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
	if (self.bounds.origin.x == 0.0)
	{ [self centerBounds]; }
	
	[[self bckColor] set];
	NSRectFill(self.bounds);
	
	[[self hldColor] set];
	NSRectFill([self computeHldR]);

	[[self maxColor] set];
	NSRectFill([self computeMaxR]);

	[[self avgColor] set];
	NSRectFill([self computeAvgR]);
	
	[self drawBalanceIndicator];
}

////////////////////////////////////////////////////////////////////////////////

- (void) drawBalanceIndicator
{
	NSRect R = self.bounds;
	R.origin.x += 0.5*R.size.width;
	R.origin.x -= 0.5;
	R.size.width = 1.0;

	[[NSColor blackColor] set];
	NSRectFill(R);
	
	R = [self computeAvgR];
	R.origin.x += R.origin.x + R.size.width;
	R.origin.x -= 0.5;
	R.size.width = 1.0;

	[[NSColor redColor] set];
	NSRectFill(R);
}

////////////////////////////////////////////////////////////////////////////////

- (void) centerBounds
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
	
	B.origin.x = -L * 0.5 * B.size.width;
	B.size.width = +R * 0.5 * B.size.width - B.origin.x;
	return B;
}

- (NSRect) computeHldR
{ return RMSStereoRectWithLR(self.bounds, mResultL.mHld, mResultR.mHld); }

- (NSRect) computeMaxR
{ return RMSStereoRectWithLR(self.bounds, mResultL.mMax, mResultR.mMax); }

- (NSRect) computeAvgR
{ return RMSStereoRectWithLR(self.bounds, mResultL.mAvg, mResultR.mAvg); }

////////////////////////////////////////////////////////////////////////////////
@end
////////////////////////////////////////////////////////////////////////////////
