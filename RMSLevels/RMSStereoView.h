////////////////////////////////////////////////////////////////////////////////
/*
	RMSStereoView.h
	
	Created by 32BT on 15/11/15.
	Copyright © 2015 32BT. All rights reserved.
*/
////////////////////////////////////////////////////////////////////////////////

#import "RMSLevelsView.h"

@interface RMSStereoView : RMSLevelsView
@property (nonatomic, assign) const rmsengine_t *enginePtrL;
@property (nonatomic, assign) const rmsengine_t *enginePtrR;
@end
