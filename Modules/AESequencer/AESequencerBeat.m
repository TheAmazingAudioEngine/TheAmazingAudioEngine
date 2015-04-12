//
//  AESequencerBeat.m
//  The Amazing Audio Engine
//
//  Created by Ariel Elkin on 24/02/2015.
//

#import "AESequencerBeat.h"

@implementation AESequencerBeat

+ (instancetype)beatWithOnset:(float)onset
                     velocity:(float)velocity {

    AESequencerBeat *beat = [[self alloc] init];
    beat.onset = onset;
    beat.velocity = velocity;
    return beat;
}

- (void)setOnset:(float)onset {
    if (onset >= 0) {
        _onset = onset;
    }
    else {
        NSLog(@"%s onset can't be < 0, setting to 0", __PRETTY_FUNCTION__);
        _onset = 0;
    }
}

- (void)setVelocity:(float)velocity {
    if(velocity >= 0 && velocity <= 1) {
        _velocity = velocity;
    }
    else if (velocity < 0) {
        NSLog(@"%s velocity can't be < 0, setting to 0", __PRETTY_FUNCTION__);
        _velocity = 0;
    }
    else if (velocity > 1) {
        NSLog(@"%s velocity can't be > 1, setting to 1", __PRETTY_FUNCTION__);
        _velocity = 1;
    }
}

+ (instancetype)beatWithOnset:(float)onset {
    return [self beatWithOnset:onset velocity:1.0];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"Onset: %.3f ||| Velocity: %.3f", self.onset, self.velocity];
}

@end
