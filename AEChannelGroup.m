////////////////////////////////////////////////////////////////////////////////
/*
	AEChannelGroup

	Created by 32BT on 30/11/15.
	Copyright © 2015 A Tasty Pixel. All rights reserved.
*/
////////////////////////////////////////////////////////////////////////////////


#import "AEChannelGroup.h"


////////////////////////////////////////////////////////////////////////////////
@implementation AEChannelGroup
////////////////////////////////////////////////////////////////////////////////

- (instancetype) initWithAudioController:(AEAudioController *)audioController
{
	return [self initWithChannelGroupRef:[audioController createChannelGroup]];
}

// designated initializer
- (instancetype) initWithChannelGroupRef:(AEChannelGroupRef)groupRef
{
	self = [super init];
	if (self != nil)
	{
		_groupRef = groupRef;
	}
	
	return self;
}

////////////////////////////////////////////////////////////////////////////////

- (void) addChannels:(NSArray*)channels
{
	AEAudioController *audioController = (__bridge AEAudioController *)
	AEChannelGroupGetAudioController(_groupRef);
	
	[audioController addChannels:channels toChannelGroup:_groupRef];
}

- (void) addOutputReceiver:(id<AEAudioReceiver>)receiver
{
	AEAudioController *audioController = (__bridge AEAudioController *)
	AEChannelGroupGetAudioController(_groupRef);
	
	[audioController addOutputReceiver:receiver forChannelGroup:_groupRef];
}

////////////////////////////////////////////////////////////////////////////////

static OSStatus renderCallback(
	__unsafe_unretained 	AEChannelGroup *THIS,
	__unsafe_unretained 	AEAudioController *audioController,
	const AudioTimeStamp 	*time,
	UInt32 					frames,
	AudioBufferList 		*audio)
{
	AEChannelGroupRef groupRef = THIS->_groupRef;
	if (groupRef == nil) return paramErr;
	
	AudioUnit audioUnit = AEChannelGroupGetAudioUnit(groupRef);
	if (audioUnit == nil) return paramErr;
		
	// Tell mixer/mixer's converter unit to render into audio
	return AudioUnitRender(audioUnit, nil, time, 0, frames, audio);
}

-(AEAudioRenderCallback)renderCallback {
return renderCallback;
}

////////////////////////////////////////////////////////////////////////////////
@end
////////////////////////////////////////////////////////////////////////////////
