////////////////////////////////////////////////////////////////////////////////
/*
	RMSIndexView.m
	
	Created by 32BT on 15/11/15.
	Copyright © 2015 32BT. All rights reserved.
*/
////////////////////////////////////////////////////////////////////////////////

#import "RMSIndexView.h"


// Fetch appropriate CGContext on different platforms in drawRect
static CGContextRef NSGraphicsGetCurrentContext(void)
{
#if TARGET_OS_IOS
	return UIGraphicsGetCurrentContext;
#else
	return (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
#endif
}


////////////////////////////////////////////////////////////////////////////////
@implementation RMSIndexView
////////////////////////////////////////////////////////////////////////////////

- (void)drawRect:(NSRect)dirtyRect
{
	// Reverse direction if necessary
	if (self.direction != 0)
	{
		CGContextRef context = NSGraphicsGetCurrentContext();
		CGContextTranslateCTM(context, self.bounds.size.width, 0.0);
		CGContextScaleCTM(context, -1.0, 1.0);
	}

	// Black indicators < 0dB
    [[NSColor blackColor] set];
	[self drawIndicators];
	
	// Red indicators >= 0dB
    [[NSColor redColor] set];
	[self drawClipIndicators];
}

////////////////////////////////////////////////////////////////////////////////

#define mINDICATOR(db) (0.8*pow(10, (0.5/20.0)*(db)))

////////////////////////////////////////////////////////////////////////////////

- (void) drawIndicators
{
	static const CGFloat DB[] = { -48.0, -24.0, -12.0, -6.0, -3.0, -1.5 };

	NSRect frame = self.bounds;
	CGFloat w = frame.size.width;
	frame.size.width = 1.0;
	
	NSRectFill(frame); // -inf

	for (UInt32 n=0; n!=sizeof(DB)/sizeof(CGFloat); n++)
	{
		frame.origin.x = floor(w*mINDICATOR(DB[n]));
		NSRectFill(frame);
	}
}

////////////////////////////////////////////////////////////////////////////////

- (void) drawClipIndicators
{
	static const CGFloat DB[] = { 0.0, +1.5, +3.0 };

	NSRect frame = self.bounds;
	CGFloat w = frame.size.width;
	frame.size.width = 1.0;

	for (UInt32 n=0; n!=sizeof(DB)/sizeof(CGFloat); n++)
	{
		frame.origin.x = floor(w*mINDICATOR(DB[n]));
		NSRectFill(frame);
	}
}

////////////////////////////////////////////////////////////////////////////////
@end
////////////////////////////////////////////////////////////////////////////////
