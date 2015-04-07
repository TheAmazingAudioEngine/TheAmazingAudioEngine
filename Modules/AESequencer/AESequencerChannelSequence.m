//
//  AESequencerChannelSequence.m
//  The Amazing Audio Engine
//
//  Created by Ariel Elkin on 03/03/2015.
//

#import "AESequencerChannelSequence.h"


@implementation AESequencerChannelSequence {
    NSMutableArray *sequence;
    BEAT* _sequenceCRepresentation;
}

- (void)addBeat:(AESequencerBeat *)beat {

    if (!beat) return;

    if (!sequence) {
        sequence = [NSMutableArray array];
    }

    [sequence addObject:beat];

    [sequence sortUsingComparator:^NSComparisonResult(AESequencerBeat *beat1, AESequencerBeat *beat2) {
        return beat1.onset > beat2.onset;
    }];


    [self updateSequenceCRepresentation];
}

- (void)removeBeatAtOnset:(float)onset {
    for (int i = 0; i < sequence.count; i++) {
        AESequencerBeat *beat = sequence[i];
        if (beat.onset == onset) {
            [sequence removeObject:beat];
        }
    }

    [self updateSequenceCRepresentation];
}

- (void)setOnsetOfBeatAtOnset:(float)oldOnset to:(float)newOnset {
    AESequencerBeat *beat = [self beatAtOnset:oldOnset];
    beat.onset = newOnset;
}

- (void)setVelocityOfBeatAtOnset:(float)onset to:(float)newVelocity {
    AESequencerBeat *beat = [self beatAtOnset:onset];
    beat.velocity = newVelocity;
}

- (AESequencerBeat *)beatAtOnset:(float)onset {

    for (AESequencerBeat *beat in sequence) {
        if (beat.onset == onset) {
            return beat;
        }
    }
    return nil;
}

- (NSArray *)allBeats {
    return [NSArray arrayWithArray:sequence];
}

- (NSUInteger)count {
    return sequence.count;
}

#pragma mark -
#pragma mark C Representation

- (void)updateSequenceCRepresentation {
    NSUInteger numberOfBeats = sequence.count;

    _sequenceCRepresentation = (BEAT *)malloc(sizeof(BEAT) * numberOfBeats);

    for(int i=0; i < numberOfBeats; i++) {

        AESequencerBeat *beat = sequence[i];

        BEAT cBeat;
        cBeat.onset = beat.onset;
        cBeat.velocity = beat.velocity;

        _sequenceCRepresentation[i] = cBeat;

    }
}

- (BEAT *)sequenceCRepresentation {
    return _sequenceCRepresentation;
}


#pragma mark -
#pragma mark Description

- (NSString *)description {
    NSMutableString *description = @"Sequence Description:\n".mutableCopy;

    for (AESequencerBeat *beat in sequence) {
        [description appendFormat:@"%@\n", beat.description];
    }
    return description;
}

@end
