////////////////////////////////////////////////////////////////////////////////
/*
	RMSIndexView.h
	
	Created by 32BT on 15/11/15.
	Copyright © 2015 32BT. All rights reserved.
*/
////////////////////////////////////////////////////////////////////////////////

#if !TARGET_OS_IOS
#import <Cocoa/Cocoa.h>
#else
#import <UIKit/UIKit.h>
#define NSView 		UIView
#define NSColor 	UIColor
#define NSRect 		CGRect
#define NSRectFill 	UIRectFill
#endif

////////////////////////////////////////////////////////////////////////////////

@interface RMSIndexView : NSView
@property (nonatomic, assign) NSUInteger direction;
@end
