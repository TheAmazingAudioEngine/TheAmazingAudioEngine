//
//  TPOscilloscopeLayer.m
//  Audio Manager Demo
//
//  Created by Michael Tyson on 27/07/2011.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "TPOscilloscopeLayer.h"
#import <TheAmazingAudioEngine/TheAmazingAudioEngine.h>
#import <Accelerate/Accelerate.h>
#include <libkern/OSAtomic.h>

#define kBufferLength 128 // In frames; higher values mean oscilloscope spans more time

@interface TPOscilloscopeLayer () {
    id           _timer;
    SInt16      *_buffer;
    float       *_scratchBuffer;
    int          _buffer_head;
}
@end

static void audioCallback(id THIS, AEAudioController *audioController, void *source, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio);

@implementation TPOscilloscopeLayer
@synthesize lineColor=_lineColor;

-(id)init {
    if ( !(self = [super init]) ) return nil;

    _buffer = (SInt16*)calloc(kBufferLength, sizeof(SInt16));
    _scratchBuffer = (float*)malloc(kBufferLength * sizeof(float) * 2);
    self.contentsScale = [[UIScreen mainScreen] scale];
    self.lineColor = [UIColor blackColor];
    
    // Disable animating view refreshes
    self.actions = [NSDictionary dictionaryWithObject:[NSNull null] forKey:@"contents"];
    
    return self;
}

- (void)start {
    if ( _timer ) return;
    
    if ( NSClassFromString(@"CADisplayLink") ) {
        _timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(setNeedsDisplay)];
        ((CADisplayLink*)_timer).frameInterval = 2;
        [_timer addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    } else {
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 target:self selector:@selector(setNeedsLayout) userInfo:nil repeats:YES];
    }
}

- (void)stop {
    if ( !_timer ) return;
    [_timer invalidate];
    _timer = nil;
}

-(AEAudioControllerAudioCallback)receiverCallback {
    return &audioCallback;
}

-(void)dealloc {
    [self stop];
    self.lineColor = nil;
    free(_buffer);
    [super dealloc];
}

#pragma mark - Rendering

-(void)drawInContext:(CGContextRef)ctx {
    // Render ring buffer as path
    CGContextSetLineWidth(ctx, 2);
    CGContextSetStrokeColorWithColor(ctx, [_lineColor CGColor]);

    float multiplier = self.bounds.size.height / (INT16_MAX-INT16_MIN);
    float midpoint = self.bounds.size.height / 2.0;
    float xIncrement = self.bounds.size.width / kBufferLength;
    
    // Render in contiguous segments, wrapping around if necessary
    int remainingFrames = kBufferLength-1;
    int tail = (_buffer_head+1) % kBufferLength;
    float x = 0;
    
    CGContextBeginPath(ctx);

    while ( remainingFrames > 0 ) {
        int framesToRender = MIN(remainingFrames, kBufferLength - tail);
        
        vDSP_vramp(&x, &xIncrement, _scratchBuffer, 2, framesToRender);
        vDSP_vflt16(&_buffer[tail], 1, _scratchBuffer+1, 2, framesToRender);
        vDSP_vsmul(_scratchBuffer+1, 2, &multiplier, _scratchBuffer+1, 2, framesToRender);
        vDSP_vsadd(_scratchBuffer+1, 2, &midpoint, _scratchBuffer+1, 2, framesToRender);
        
        CGContextAddLines(ctx, (CGPoint*)_scratchBuffer, framesToRender);
        
        x += (framesToRender-1)*xIncrement;
        tail += framesToRender;
        if ( tail == kBufferLength ) tail = 0;
        remainingFrames -= framesToRender;
    }
    
    CGContextStrokePath(ctx);
}

#pragma mark - Callback

static void audioCallback(id THISptr, AEAudioController *audioController, void *source, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
    TPOscilloscopeLayer *THIS = (TPOscilloscopeLayer*)THISptr;
    
    // Get a pointer to the audio buffer that we can advance
    SInt16 *audioPtr = audio->mBuffers[0].mData;
    
    // Copy in contiguous segments, wrapping around if necessary
    int remainingFrames = frames;
    while ( remainingFrames > 0 ) {
        int framesToCopy = MIN(remainingFrames, kBufferLength - THIS->_buffer_head);
        
        if ( audio->mNumberBuffers == 2 || audio->mBuffers[0].mNumberChannels == 1 ) {
            // Mono, or non-interleaved; just memcpy
            memcpy(THIS->_buffer + THIS->_buffer_head, audioPtr, framesToCopy * sizeof(SInt16));
            audioPtr += framesToCopy;
        } else {
            // Interleaved stereo: Copy every second sample
            SInt16 *buffer = &THIS->_buffer[THIS->_buffer_head];
            for ( int i=0; i<framesToCopy; i++ ) {
                *buffer = *audioPtr;
                audioPtr += 2;
                buffer++;
            }
        }
        
        int buffer_head = THIS->_buffer_head + framesToCopy;
        if ( buffer_head == kBufferLength ) buffer_head = 0;
        OSMemoryBarrier();
        THIS->_buffer_head = buffer_head;
        remainingFrames -= framesToCopy;
    }
}

@end
