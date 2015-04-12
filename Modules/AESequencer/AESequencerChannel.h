//
//  AESequencerChannel.h
//  The Amazing Audio Engine
//
//  Created by Alejandro Santander on 26/02/2015.
//

#import <Foundation/Foundation.h>
#import "AEAudioController.h"
#import "AESequencerBeat.h"
#import "AESequencerChannelSequence.h"

@interface AESequencerChannel : NSObject <AEAudioPlayable>

+ (instancetype)sequencerChannelWithAudioFileAt:(NSURL *)url
                                audioController:(AEAudioController*)audioController
                                   withSequence:(AESequencerChannelSequence*)sequence
                    numberOfFullBeatsPerMeasure:(NSUInteger)beatsPerMeasure
                                          atBPM:(double)bpm;

@property (nonatomic) AESequencerChannelSequence *sequence;
@property (nonatomic, readwrite) float volume;
@property (nonatomic, readwrite) float pan;                 
@property bool sequenceIsPlaying;
@property double bpm;
@property (nonatomic, readonly) float playheadPosition;
@property bool muted;
@property int soloed; // 1 = soloed, -1 = not soloed, 0 = ignore

@end
