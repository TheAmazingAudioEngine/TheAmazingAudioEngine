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

#define kBufferLength 2048 // In frames; higher values mean oscilloscope spans more time
#define kMaxConversionSize 4096
#define kSkipFrames 16     // Frames to skip - higher value means faster render time, but rougher display

#if CGFLOAT_IS_DOUBLE
#define SAMPLETYPE double
#define VRAMP vDSP_vrampD
#define VSMUL vDSP_vsmulD
static void VRAMPMUL(const SAMPLETYPE *__vDSP_I, vDSP_Stride __vDSP_IS, SAMPLETYPE *__vDSP_Start, const SAMPLETYPE *__vDSP_Step, SAMPLETYPE *__vDSP_O, vDSP_Stride __vDSP_OS, vDSP_Length __vDSP_N) {
    // No double version of vDSP_vrampmul, so do it sample by sample
    int idx=0;
    SAMPLETYPE *iptr = (SAMPLETYPE*)__vDSP_I;
    SAMPLETYPE *optr = (SAMPLETYPE*)__vDSP_O;
    for ( ; idx<__vDSP_N; iptr+=__vDSP_IS, optr+=__vDSP_OS, idx++ ) {
        *optr = *iptr * (*__vDSP_Start += *__vDSP_Step);
    }
}
#define VSADD vDSP_vsaddD
#else
#define SAMPLETYPE float
#define VRAMP vDSP_vramp
#define VSMUL vDSP_vsmul
#define VRAMPMUL vDSP_vrampmul
#define VSADD vDSP_vsadd
#endif

@interface TPOscilloscopeLayer () {
    id           _timer;
    SAMPLETYPE  *_buffer;
    CGPoint     *_scratchBuffer;
    int          _buffer_head;
    AudioBufferList *_conversionBuffer;
}
@property (nonatomic, strong) AEFloatConverter *floatConverter;
@end

@implementation TPOscilloscopeLayer

- (id)initWithAudioController:(AEAudioController*)audioController {
    if ( !(self = [super init]) ) return nil;

    self.floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:audioController.audioDescription];
    _conversionBuffer = AEAllocateAndInitAudioBufferList(_floatConverter.floatingPointAudioDescription, kMaxConversionSize);
    _buffer = (SAMPLETYPE*)calloc(kBufferLength, sizeof(SAMPLETYPE));
    _scratchBuffer = (CGPoint*)malloc(kBufferLength * sizeof(CGPoint));
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
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 target:self selector:@selector(setNeedsDisplay) userInfo:nil repeats:YES];
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
    if ( _buffer ) {
        free(_buffer);
    }
    if ( _scratchBuffer ) {
        free(_scratchBuffer);
    }
    if ( _conversionBuffer ) {
        AEFreeAudioBufferList(_conversionBuffer);
    }
}

#pragma mark - Rendering

-(void)drawInContext:(CGContextRef)ctx {
    CGContextSetShouldAntialias(ctx, false);
    
    // Render ring buffer as path
    CGContextSetLineWidth(ctx, 2);
    CGContextSetStrokeColorWithColor(ctx, [_lineColor CGColor]);
    
    int frames = kBufferLength-1;
    int tail = (_buffer_head+1) % kBufferLength;
    SAMPLETYPE x = 0;
    SAMPLETYPE xIncrement = (self.bounds.size.width / (float)(frames-1)) * (float)(kSkipFrames+1);
    SAMPLETYPE multiplier = self.bounds.size.height / 2.0;
    
    // Generate samples
    SAMPLETYPE *scratchPtr = (SAMPLETYPE*)_scratchBuffer;
    while ( frames > 0 ) {
        int framesToRender = MIN(frames, kBufferLength - tail);
        int samplesToRender = framesToRender / kSkipFrames;
        
        VRAMP(&x, &xIncrement, (SAMPLETYPE*)scratchPtr, 2, samplesToRender);
        VSMUL(&_buffer[tail], kSkipFrames, &multiplier, ((SAMPLETYPE*)scratchPtr)+1, 2, samplesToRender);
        
        scratchPtr += 2 * samplesToRender;
        x += (samplesToRender-1)*xIncrement;
        tail += framesToRender;
        if ( tail == kBufferLength ) tail = 0;
        frames -= framesToRender;
    }
    
    int sampleCount = (kBufferLength-1) / kSkipFrames;
    
    // Apply an envelope
    SAMPLETYPE start = 0.0;
    int envelopeLength = sampleCount / 2;
    SAMPLETYPE step = 1.0 / (float)envelopeLength;
    VRAMPMUL((SAMPLETYPE*)_scratchBuffer + 1, 2, &start, &step, (SAMPLETYPE*)_scratchBuffer + 1, 2, envelopeLength);
    
    start = 1.0;
    step = -step;
    VRAMPMUL((SAMPLETYPE*)_scratchBuffer + 1 + (envelopeLength*2), 2, &start, &step, (SAMPLETYPE*)_scratchBuffer + 1 + (envelopeLength*2), 2, envelopeLength);
    
    // Assign midpoint
    SAMPLETYPE midpoint = self.bounds.size.height / 2.0;
    VSADD((SAMPLETYPE*)_scratchBuffer+1, 2, &midpoint, (SAMPLETYPE*)_scratchBuffer+1, 2, sampleCount);
    
    // Render lines
    CGContextBeginPath(ctx);
    CGContextAddLines(ctx, (CGPoint*)_scratchBuffer, sampleCount);
    CGContextStrokePath(ctx);
}

#pragma mark - Callback

static void audioCallback(__unsafe_unretained TPOscilloscopeLayer *THIS,
                          __unsafe_unretained AEAudioController *audioController,
                          void *source,
                          const AudioTimeStamp *time,
                          UInt32 frames,
                          AudioBufferList *audio) {
    // Convert audio
    AEFloatConverterToFloatBufferList(THIS->_floatConverter, audio, THIS->_conversionBuffer, frames);
    
    // Get a pointer to the audio buffer that we can advance
    float *audioPtr = THIS->_conversionBuffer->mBuffers[0].mData;
    
    // Copy in contiguous segments, wrapping around if necessary
    int remainingFrames = frames;
    while ( remainingFrames > 0 ) {
        int framesToCopy = MIN(remainingFrames, kBufferLength - THIS->_buffer_head);
        
#if CGFLOAT_IS_DOUBLE
        vDSP_vspdp(audioPtr, 1, THIS->_buffer + THIS->_buffer_head, 1, framesToCopy);
#else
        memcpy(THIS->_buffer + THIS->_buffer_head, audioPtr, framesToCopy * sizeof(float));
#endif
        audioPtr += framesToCopy;
        
        int buffer_head = THIS->_buffer_head + framesToCopy;
        if ( buffer_head == kBufferLength ) buffer_head = 0;
        OSMemoryBarrier();
        THIS->_buffer_head = buffer_head;
        remainingFrames -= framesToCopy;
    }
}

@end
