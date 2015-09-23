//
//  AEVarispeedFilter.m
//  The Amazing Audio Engine
//
//  Created by Jeremy Flores on 4/26/13.
//  Copyright (c) 2015 Dream Engine Interactive, Inc and A Tasty Pixel Pty Ltd. All rights reserved.
//

#import "AEVarispeedFilter.h"

@implementation AEVarispeedFilter

- (instancetype)init {
    return [super initWithComponentDescription:(AudioComponentDescription) {
        kAudioUnitType_FormatConverter, kAudioUnitSubType_Varispeed, kAudioUnitManufacturer_Apple
    }];
}

#pragma mark - Getters

- (double)playbackRate {
    return [self getParameterValueForId:kVarispeedParam_PlaybackRate];
}

- (double)playbackCents {
    return [self getParameterValueForId:kVarispeedParam_PlaybackCents];
}


#pragma mark - Setters

- (void)setPlaybackRate:(double)playbackRate {
    [self setParameterValue: playbackRate
                      forId: kVarispeedParam_PlaybackRate];
}

- (void)setPlaybackCents:(double)playbackCents {
    [self setParameterValue: playbackCents
                      forId: kVarispeedParam_PlaybackCents];
}

@end
