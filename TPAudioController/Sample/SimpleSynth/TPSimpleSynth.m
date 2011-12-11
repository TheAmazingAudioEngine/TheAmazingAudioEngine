//
//  TPSimpleSynth.m
//  SimpleSynth
//
//  Created by Michael Tyson on 11/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "TPSimpleSynth.h"
#import <mach/mach_time.h>
#import <libkern/OSAtomic.h>

#define kNoteMicrofadeInFrames 1024
#define kNoteDecayTime 1.0

static double timeBaseRatio;

@implementation TPSimpleSynth

+(void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    timeBaseRatio = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
}

- (id)init {
    if ( !(self = [super init]) ) return nil;
    _notes = [NSArray array];
    return self;
}

- (void)dealloc {
    [_notes release];
    _notes = nil;
    [super dealloc];
}

- (void)triggerNoteWithPitch:(CGFloat)pitch volume:(CGFloat)volume {
    NSArray *oldNotes = _notes;
    _notes = [[_notes arrayByAddingObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                          [NSNumber numberWithFloat:pitch], @"pitch", 
                                          [NSNumber numberWithFloat:volume], @"volume", 
                                          [NSNumber numberWithUnsignedLongLong:mach_absolute_time()], @"startTime",
                                          nil]] retain];
    OSMemoryBarrier();
    [oldNotes release];
}

- (void)finishedNote:(NSDictionary*)note {
    NSMutableArray *mutableNotes = [_notes mutableCopy];
    [mutableNotes removeObject:note];
    NSArray *oldNotes = _notes;
    _notes = mutableNotes;
    OSMemoryBarrier();
    [oldNotes release];
}

-(void)audioController:(TPAudioController *)controller needsBuffer:(SInt16 *)buffer ofLength:(NSUInteger)frames time:(const AudioTimeStamp *)time {
    unsigned int totalNoteTimeInFrames = kNoteDecayTime * 44100.0;
    
    NSArray *notes = [_notes retain];
    for ( NSDictionary *note in notes ) {
        float pitch = [[note objectForKey:@"pitch"] floatValue];
        float volume = [[note objectForKey:@"volume"] floatValue];
        uint64_t start = [[note objectForKey:@"startTime"] unsignedLongLongValue];
        
        // Render the audio (a sin wave with a simple amplitude envelope to mimic decay)
        unsigned int timeInFrames = (time->mHostTime-start) * timeBaseRatio * 44100.0;
        for ( int i=0, sample=0, t=timeInFrames; i<frames && t<totalNoteTimeInFrames; i++, t++ ) {
            float amplitude = t <= kNoteMicrofadeInFrames ? (float)t / kNoteMicrofadeInFrames : 1.0 - ((float)t/(totalNoteTimeInFrames-kNoteMicrofadeInFrames));
            SInt16 value = INT16_MAX * volume * amplitude * sin(pitch * (t/44100.0) * 2*M_PI);
            buffer[sample++] += value;
            buffer[sample++] += value; // Stereo
        }
        
        if ( timeInFrames+frames >= totalNoteTimeInFrames ) {
            [self performSelectorOnMainThread:@selector(finishedNote:) withObject:note waitUntilDone:NO];
        }
    }
    
    [notes release];
}

@end
