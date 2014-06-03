//
//  TPOscilloscopeLayer.m
//  Audio Manager Demo
//
//  Created by Michael Tyson on 27/07/2011.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "TPOscilloscopeLayer.h"
#import "TheAmazingAudioEngine.h"
#import <Accelerate/Accelerate.h>
#include <libkern/OSAtomic.h>

#define kRingBufferLength 128 // In frames; higher values mean oscilloscope spans more time
#define kMaxConversionSize 4096

@interface TPOscilloscopeLayer () {
    id           _timer;
    float       *_scratchBuffer;
    AudioBufferList *_conversionBuffer;
    float       *_ringBuffer;
    int          _ringBufferHead;
}
@property (nonatomic, assign) AEAudioController *audioController;
@property (nonatomic, retain) AEFloatConverter *floatConverter;
@end

static void audioCallback(id THIS, AEAudioController *audioController, void *source, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio);

@implementation TPOscilloscopeLayer
@synthesize lineColor=_lineColor, floatConverter=_floatConverter;

- (id)initWithAudioController:(AEAudioController*)audioController {
    if ( !(self = [super init]) ) return nil;

    self.audioController = audioController;
    self.floatConverter = [[[AEFloatConverter alloc] initWithSourceFormat:audioController.audioDescription] autorelease];
    _conversionBuffer = AEAllocateAndInitAudioBufferList(_floatConverter.floatingPointAudioDescription, kMaxConversionSize);
    _ringBuffer = (float*)calloc(kRingBufferLength, sizeof(float));
    _scratchBuffer = (float*)malloc(kRingBufferLength * sizeof(float) * 2);
    self.contentsScale = [[UIScreen mainScreen] scale];
    self.lineColor = [UIColor blackColor];
    
    // Disable animating view refreshes
    self.actions = @{@"contents": [NSNull null]};
    
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
    if ( _ringBuffer ) {
        free(_ringBuffer);
    }
    if ( _conversionBuffer ) {
        AEFreeAudioBufferList(_conversionBuffer);
    }
    self.floatConverter = nil;
    self.audioController = nil;
    [super dealloc];
}

#pragma mark - Rendering

-(void)drawInContext:(CGContextRef)ctx {
    // Render ring buffer as path
    CGContextSetLineWidth(ctx, 2);
    CGContextSetStrokeColorWithColor(ctx, [_lineColor CGColor]);

    float multiplier = self.bounds.size.height;
    float midpoint = self.bounds.size.height / 2.0;
    float xIncrement = self.bounds.size.width / kRingBufferLength;
    
    // Render in contiguous segments, wrapping around if necessary
    int remainingFrames = kRingBufferLength-1;
    int tail = (_ringBufferHead+1) % kRingBufferLength;
    float x = 0;
    
    CGContextBeginPath(ctx);

    while ( remainingFrames > 0 ) {
        int framesToRender = MIN(remainingFrames, kRingBufferLength - tail);
        
        vDSP_vramp(&x, &xIncrement, _scratchBuffer, 2, framesToRender);
        vDSP_vsmul(&_ringBuffer[tail], 1, &multiplier, _scratchBuffer+1, 2, framesToRender);
        vDSP_vsadd(_scratchBuffer+1, 2, &midpoint, _scratchBuffer+1, 2, framesToRender);
        
        CGContextAddLines(ctx, (CGPoint*)_scratchBuffer, framesToRender);
        
        x += (framesToRender-1)*xIncrement;
        tail += framesToRender;
        if ( tail == kRingBufferLength ) tail = 0;
        remainingFrames -= framesToRender;
    }
    
    CGContextStrokePath(ctx);
}

#pragma mark - Callback

static void audioCallback(id THISptr, AEAudioController *audioController, void *source, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio) {
    TPOscilloscopeLayer *THIS = (TPOscilloscopeLayer*)THISptr;
    
    // Convert audio
    AEFloatConverterToFloatBufferList(THIS->_floatConverter, audio, THIS->_conversionBuffer, frames);
    
    // Get a pointer to the audio buffer that we can advance
    float *audioPtr = THIS->_conversionBuffer->mBuffers[0].mData;
    
    // Copy in contiguous segments, wrapping around if necessary
    int remainingFrames = frames;
    while ( remainingFrames > 0 ) {
        int framesToCopy = MIN(remainingFrames, kRingBufferLength - THIS->_ringBufferHead);
        
        memcpy(THIS->_ringBuffer + THIS->_ringBufferHead, audioPtr, framesToCopy * sizeof(float));
        audioPtr += framesToCopy;
        
        int buffer_head = THIS->_ringBufferHead + framesToCopy;
        if ( buffer_head == kRingBufferLength ) buffer_head = 0;
        OSMemoryBarrier();
        THIS->_ringBufferHead = buffer_head;
        remainingFrames -= framesToCopy;
    }
}

@end
