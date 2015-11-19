////////////////////////////////////////////////////////////////////////////////
/*
	RMSStereoView.m
	
	Created by 32BT on 15/11/15.
	Copyright © 2015 32BT. All rights reserved.
*/
////////////////////////////////////////////////////////////////////////////////

#import "RMSStereoView.h"

@interface RMSLevelsView ()
@end

@interface RMSStereoView ()
{
}
@end


@implementation RMSStereoView


- (void) awakeFromNib
{
	self.viewL.direction = eRMSViewDirectionW;
}

- (RMSLevelsView *) viewL
{
	if (_viewL == nil)
	{
	}
	return _viewL;
}


////////////////////////////////////////////////////////////////////////////////

- (void) timerDidFire:(NSTimer *)timer
{
	rmslevels_t L = RMSLevelsZero;
	rmslevels_t R = RMSLevelsZero;
	
	if (self.enginePtr != nil)
		L = R = RMSEngineGetLevels(self.enginePtr);
	else
	{
		if (self.enginePtrL != nil)
		L = RMSEngineGetLevels(self.enginePtrL);
		if (self.enginePtrR != nil)
		R = RMSEngineGetLevels(self.enginePtrR);
	}
	
	[self.viewL setLevels:L];
	[self.viewR setLevels:R];
}

////////////////////////////////////////////////////////////////////////////////

- (void)drawRect:(NSRect)dirtyRect
{
	[[self bckColor] set];
	NSRectFill(self.bounds);
}

@end
