//
//  TPSynthGenerator.m
//  Simply Synth
//
//  Created by Michael Tyson on 03/12/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//

#import "TPSynthGenerator.h"

#define kMaxSimultaneousNotes 10
#define kNoteMicrofadeInFrames 1024
#define kNoteDurationInFrames 44100

typedef struct {
    float rate;
    float volume;
    float position;
    int time;
} note_t;

@implementation TPSynthGenerator

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
    
    note->rate = pitch / 44100.0;
    note->volume = volume;
    note->position = 0;
    note->time = 0;
    
    TPCircularBufferProduce(&_notes, sizeof(note_t));
    return YES;
}

/*!
 * Render callback
 *
 *      This is called when audio for the channel is required. As this is called from Core Audio's
 *      realtime thread, you should not wait on locks, allocate memory, or call any Objective-C or BSD
 *      code from this callback.
 *      The channel object is passed through as a parameter.  You should not send it Objective-C
 *      messages, but if you implement the callback within your channel's \@implementation block, you 
 *      can gain direct access to the instance variables of the channel ("channel->myInstanceVariable").
 *
 * @param channel   The channel object
 * @param time      The time the buffer will be played
 * @param frames    The number of frames required
 * @param audio     The audio buffer list - audio should be copied into the provided buffers
 */
static OSStatus renderCallback (TPSynthGenerator         *THIS,
                                const AudioTimeStamp     *time,
                                UInt32                    frames,
                                AudioBufferList          *audio) {

    memset(audio->mBuffers[0].mData, 0, audio->mBuffers[0].mDataByteSize);
    
    int32_t noteCount;
    note_t *note = TPCircularBufferTail(&THIS->_notes, &noteCount);
    noteCount /= sizeof(note_t);
    
    SInt16 *bufferEnd = (SInt16*)audio->mBuffers[0].mData + frames*2;
    
    for ( int i=0; i<noteCount; i++, note++ ) {
        // Render the audio (a sin wave with a simple amplitude envelope to mimic decay)
        SInt16 *buffer = (SInt16*)audio->mBuffers[0].mData;
        float multiplier = INT16_MAX * note->volume;
        for ( ; buffer<bufferEnd && note->time < kNoteDurationInFrames; note->time++ ) {
            // Quick sin-esque oscillator
            float x = note->position;
            x *= x; x -= 1.0; x *= x; x *= 2.0; x -= 1.0; // x now in the range -1...1
            note->position += note->rate;
            if ( note->position > 1.0 ) note->position -= 2.0;
            
            float amplitude = note->time <= kNoteMicrofadeInFrames 
                                    ? (float)note->time / (float)kNoteMicrofadeInFrames 
                                    : 1.0 - ((float)(note->time-kNoteMicrofadeInFrames) / (float)(kNoteDurationInFrames-kNoteMicrofadeInFrames));
            SInt16 value = multiplier * amplitude * x;
            *buffer++ += value;
            *buffer++ += value; // Stereo
        }
        
        if ( note->time >= kNoteDurationInFrames ) {
            TPCircularBufferConsume(&THIS->_notes, sizeof(note_t));
        }
    }
    
    return noErr;
}


-(AEAudioControllerRenderCallback)renderCallback {
    return &renderCallback;
}

@end
