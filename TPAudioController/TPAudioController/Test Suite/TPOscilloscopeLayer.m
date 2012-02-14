//
//  TPOscilloscopeLayer.m
//  Audio Manager Demo
//
//  Created by Michael Tyson on 27/07/2011.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "TPOscilloscopeLayer.h"
#import <TPAudioController/TPAudioController.h>

#define kBufferLength 256 // In frames; higher values mean oscilloscope spans more time

@interface TPOscilloscopeLayer () {
    id           _timer;
    SInt16      *_buffer;
    NSUInteger   _buffer_head;
}
@end

static OSStatus audioCallback(void *THIS, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio);

@implementation TPOscilloscopeLayer
@synthesize lineColor=_lineColor;

-(id)init {
    if ( !(self = [super init]) ) return nil;

    _buffer = (SInt16*)calloc(kBufferLength, sizeof(SInt16));
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

-(TPAudioControllerAudioCallback)callback {
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

    CGFloat multiplier = self.bounds.size.height / (INT16_MAX-INT16_MIN);
    CGFloat midpoint = self.bounds.size.height / 2.0;
    CGFloat xIncrement = self.bounds.size.width / kBufferLength;
    CGFloat x = 0;

    // Draw each point, evenly spaced along the x axis, and offset from the midpoint along the y axis by each sample
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, 0, midpoint + multiplier * _buffer[_buffer_head]);
    for ( int i=1, j=(_buffer_head+1)%kBufferLength; i<kBufferLength; i++, j=(j+1)%kBufferLength, x += xIncrement ) {
        CGContextAddLineToPoint(ctx, x, midpoint + multiplier*_buffer[j]);
    }
    CGContextStrokePath(ctx);
}

#pragma mark - Callback

static OSStatus audioCallback(void *THISptr, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
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
        
        THIS->_buffer_head += framesToCopy;
        if (  THIS->_buffer_head == kBufferLength ) THIS->_buffer_head = 0;
        remainingFrames -= framesToCopy;
    }
    
    return noErr;
}

@end
