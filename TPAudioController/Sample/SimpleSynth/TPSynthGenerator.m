//
//  TPSynthGenerator.m
//  Simply Synth
//
//  Created by Michael Tyson on 03/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "TPSynthGenerator.h"
#import <mach/mach_time.h>
#import <libkern/OSAtomic.h>

#define kMaxSimultaneousNotes 10
#define kNoteMicrofadeInFrames 1024
#define kNoteDecayTime 44100

typedef struct {
    float pitch;
    float volume;
    int position;
} note_t;

static double timeBaseRatio;

@implementation TPSynthGenerator

+(void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    timeBaseRatio = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
}

- (id)init {
    if ( !(self = [super init]) ) return nil;
    TPCircularBufferInit(&_notes, kMaxSimultaneousNotes * sizeof(note_t));
    return self;
}

- (void)dealloc {
    TPCircularBufferCleanup(&_notes);
    [super dealloc];
}

- (BOOL)triggerNoteWithPitch:(CGFloat)pitch volume:(CGFloat)volume {
    if ( _notes.fillCount/sizeof(note_t) > kMaxSimultaneousNotes ) return NO;
    
    int32_t availableBytes;
    note_t *note = TPCircularBufferHead(&_notes, &availableBytes);
    
    if ( availableBytes == 0 ) return NO;
    
    note->pitch = pitch;
    note->volume = volume;
    note->position = 0;
    
    TPCircularBufferProduce(&_notes, sizeof(note_t));
    return YES;
}

-(void)audioController:(TPAudioController *)controller needsBuffer:(SInt16 *)buffer ofLength:(NSUInteger)frames time:(const AudioTimeStamp *)time {
    int32_t noteCount;
    note_t *note = TPCircularBufferTail(&_notes, &noteCount);
    noteCount /= sizeof(note_t);
    
    for ( int i=0; i<noteCount; i++, note++ ) {
        // Render the audio (a sin wave with a simple amplitude envelope to mimic decay)
        for ( int i=0, sample=0; i<frames && note->position<kNoteDecayTime; i++, note->position++ ) {
            float amplitude = note->position <= kNoteMicrofadeInFrames ? (float)note->position / kNoteMicrofadeInFrames : 1.0 - ((float)(note->position-kNoteMicrofadeInFrames)/(kNoteDecayTime-kNoteMicrofadeInFrames));
            SInt16 value = INT16_MAX * note->volume * amplitude * sin(note->pitch * (note->position/44100.0) * 2*M_PI);
            buffer[sample++] += value;
            buffer[sample++] += value; // Stereo
        }
        
        if ( note->position+frames >= kNoteDecayTime ) {
            TPCircularBufferConsume(&_notes, sizeof(note_t));
        }
    }
}

@end
