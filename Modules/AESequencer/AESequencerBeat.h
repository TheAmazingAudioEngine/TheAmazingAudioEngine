//
//  AESequencerBeat.h
//  The Amazing Audio Engine
//
//  Created by Ariel Elkin on 24/02/2015.
//

#import <Foundation/Foundation.h>

@interface AESequencerBeat : NSObject

/*!
 * Initializes and returns an individual SequencerBeat
 * with a specified onset and a velocity.
 *
 */
+ (instancetype)beatWithOnset:(float)onset
                     velocity:(float)velocity;


/*!
 * Initializes and returns an individual SequencerBeat
 * with a specified onset and velocity 1.
 *
 */
+ (instancetype)beatWithOnset:(float)onset;


/*!
 * The onset of the beat in relation to the sequence. 
 * 
 * @discussion Must be between 0 and 1. A value of 0 means the beat will
 * sound at the very beginning of the sequence, a value of 1 means
 * it will sound at the very end of it.
 *
 */
@property (nonatomic) float onset;

/*!
 * The velocity of the beat.
 * 
 * @discussion Must be between 0 and 1. A value of 0 means the beat will
 * be silent, a value of 1 means the beat will play at its
 * normal volume.
 *
 */
@property (nonatomic) float velocity;


/*!
 * A struct that represents an individual beat.
 *
 */
typedef struct SequencerBeatCRepresentation {
    float onset;
    float velocity;
} BEAT;

@end