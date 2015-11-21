////////////////////////////////////////////////////////////////////////////////
/*
	RMSLevelsView.m
	
	Created by 32BT on 15/11/15.
	Copyright © 2015 32BT. All rights reserved.
*/
////////////////////////////////////////////////////////////////////////////////

#import "RMSLevelsView.h"


@interface RMSLevelsView ()
{
	// Represented data
	rmsresult_t mLevels;
	
	// Update timer
	NSTimer *mTimer;
	
}
@end

////////////////////////////////////////////////////////////////////////////////
@implementation RMSLevelsView
////////////////////////////////////////////////////////////////////////////////

- (void) setEnginePtr:(const rmsengine_t *)engine
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
		[mTimer setTolerance:(1.0/20.0)-(1.0/25.0)];
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
	
	[self setLevels:RMSEngineFetchResult(_enginePtr)];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark

- (void) setLevels:(rmsresult_t)levels
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
	[[self bckColor] set];
	NSRectFill(self.bounds);

	rmsresult_t levels = mLevels;

	if (levels.mHld > 0.0)
	{
		if (levels.mHld > 1.0)
			[[self clpColor] set];
		else
			[[self hldColor] set];
		NSRectFill([self boundsWithRatio:levels.mHld]);
		
		[[self maxColor] set];
		NSRectFill([self boundsWithRatio:levels.mMax]);
		
		[[self avgColor] set];
		NSRectFill([self boundsWithRatio:levels.mAvg]);
	}
}

////////////////////////////////////////////////////////////////////////////////

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






