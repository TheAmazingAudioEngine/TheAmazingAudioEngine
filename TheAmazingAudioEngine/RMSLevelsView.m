////////////////////////////////////////////////////////////////////////////////
/*
	RMSLevelsView.m
	
	Created by 32BT on 15/11/15.
	Copyright © 2015 32BT. All rights reserved.
*/
////////////////////////////////////////////////////////////////////////////////

#import "RMSLevelsView.h"
#import "RMSEngine.h"
/*
	considerations:
	Audio thread should do as little as possible, therefore
	View updates periodically and polls engine
	
	Fetching engine values is threadsafe
	
	
	
	
	
	
	
*/

@interface RMSLevelsView ()
{
	NSTimer *mTimer;
	
	rmslevels_t mLevels;
}
@end

////////////////////////////////////////////////////////////////////////////////
@implementation RMSLevelsView
////////////////////////////////////////////////////////////////////////////////

- (void) setEnginePtr:(rmsengine_t *)engine
{
	if (_enginePtr != engine)
	{
		_enginePtr = engine;
		[self startUpdating];
	}
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark
#pragma mark Timer Management
////////////////////////////////////////////////////////////////////////////////

- (void) startUpdating
{
	if (mTimer == nil)
	{
		// set timer to appr 25 updates per second
		mTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/25.0
		target:self selector:@selector(timerDidFire:) userInfo:nil repeats:YES];
		
		// add tolerance down to appr 24 updates per second
		[mTimer setTolerance:(1.0/24.0)-(1.0/25.0)];
	}
}

////////////////////////////////////////////////////////////////////////////////

- (void) stopUpdating
{
	if (mTimer != nil)
	{
		[mTimer invalidate];
		mTimer = nil;
	}
}

////////////////////////////////////////////////////////////////////////////////

- (void) timerDidFire:(NSTimer *)timer
{
	if (_enginePtr == nil)
	{ [self stopUpdating]; }
	
	[self setLevels:RMSEngineGetLevels(_enginePtr)];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark

- (void) setLevels:(rmslevels_t)levels
{
	mLevels = levels;
	[self setNeedsDisplayInRect:self.bounds];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark
#pragma mark Drawing
////////////////////////////////////////////////////////////////////////////////

#define HSBCLR(h, s, b) \
[NSColor colorWithHue:h/360.0 saturation:s brightness:b alpha:1.0];

- (NSColor *) bckColor
{
	if (_bckColor == nil)
	{ _bckColor = HSBCLR(0.0, 0.0, 0.5); }
	return _bckColor;
}

- (NSColor *) avgColor
{
	if (_avgColor == nil)
	{ _avgColor = HSBCLR(240.0, 0.6, 0.9); }
	return _avgColor;
}

- (NSColor *) maxColor
{
	if (_maxColor == nil)
	{ _maxColor = HSBCLR(240.0, 0.5, 1.0); }
	return _maxColor;
}

- (NSColor *) hldColor
{
	if (_hldColor == nil)
	{ _hldColor = HSBCLR(0.0, 0.0, 0.25); }
	return _hldColor;
}

- (NSColor *) clpColor
{
	if (_clpColor == nil)
	{ _clpColor = HSBCLR(0.0, 1.0, 1.0); }
	return _clpColor;
}

////////////////////////////////////////////////////////////////////////////////
#if !TARGET_OS_IOS
- (BOOL) isOpaque
{ return !(self.bckColor.alphaComponent < 1.0); }
#endif

- (void)drawRect:(NSRect)rect
{
	NSRect frame = self.bounds;
	[[self bckColor] set];
	NSRectFill(frame);

	rmslevels_t levels = mLevels;

	if (levels.mHld > 0.0)
	{
		if (levels.mHld > 1.0)
			[[self clpColor] set];
		else
			[[self hldColor] set];
		frame = [self boundsWithRatio:levels.mHld];
		NSRectFill(frame);

		//if (levels.mHld > 1.0)
		{
			[[self clpColor] set];
			NSRectFillUsingOperation(self.clippingRegion, NSCompositeMultiply);
		}
		
		[[self maxColor] set];
		frame = [self boundsWithRatio:levels.mMax];
		NSRectFill(frame);
		
		[[self avgColor] set];
		frame = [self boundsWithRatio:levels.mAvg];
		NSRectFill(frame);

	}
}

- (NSRect) clippingRegion
{
	NSRect bounds = self.bounds;

	if (_direction & 0x01)
	{
		bounds.size.width *= 0.2;
		if ((_direction & 0x02)==0)
		bounds.origin.x += self.bounds.size.width - bounds.size.width;
	}
	else
	{
		bounds.size.height *= 0.2;
		if ((_direction & 0x02)==0)
		bounds.origin.y += self.bounds.size.height - bounds.size.height;
	}
	
	return bounds;
}

- (NSRect) boundsWithRatio:(double)ratio
{
	NSRect bounds = self.bounds;

	// Adjust for display scale
	ratio = 0.8 * sqrt(ratio);

	if (ratio < 1.0)
	{
		if (_direction == 0)
		{ _direction = (bounds.size.width > bounds.size.height) ? 1 : 4; }
		
		if (_direction & 0x01)
		{
			bounds.size.width *= ratio;
			if (_direction & 0x02)
			bounds.origin.x += self.bounds.size.width - bounds.size.width;
		}
		else
		{
			bounds.size.height *= ratio;
			if (_direction & 0x02)
			bounds.origin.y += self.bounds.size.height - bounds.size.height;
		}
	}
	
	return bounds;
}

////////////////////////////////////////////////////////////////////////////////
@end
////////////////////////////////////////////////////////////////////////////////






