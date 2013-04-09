//
//  AELimiter.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 20/04/2012.
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "AELimiter.h"
#import "TheAmazingAudioEngine.h"
#import "TPCircularBuffer.h"
#import "TPCircularBuffer+AudioBufferList.h"
#import <Accelerate/Accelerate.h>

const int kBufferSize = 88200; /* Bytes per channel */
const UInt32 kNoValue = INT_MAX;

typedef enum {
    kStateIdle,
    kStateAttacking,
    kStateHolding,
    kStateDecaying
} AELimiterState;

typedef struct {
    float value;
    int index;
} element_t;

static inline int min(int a, int b) { return a>b ? b : a; }

@interface AELimiter () {
    TPCircularBuffer _buffer;
    float            _gain;
    AELimiterState   _state;
    int              _framesSinceLastTrigger;
    int              _framesToNextTrigger;
    float            _triggerValue;
    AudioStreamBasicDescription _audioDescription;
}
static void _AELimiterDequeue(AELimiter *THIS, float** buffers, UInt32 *ioLength, AudioTimeStamp *timestamp);
static inline void advanceTime(AELimiter *THIS, UInt32 frames);
static element_t findMaxValueInRange(AELimiter *THIS, AudioBufferList *dequeuedBufferList, int dequeuedBufferListOffset, NSRange range);
static element_t findNextTriggerValueInRange(AELimiter *THIS, AudioBufferList *dequeuedBufferList, int dequeuedBufferListOffset, NSRange range);
@end

@implementation AELimiter
@synthesize hold = _hold, attack = _attack, decay = _decay, level = _level;

- (id)initWithNumberOfChannels:(NSInteger)numberOfChannels sampleRate:(Float32)sampleRate {
    if ( !(self = [super init]) ) return nil;
    
    TPCircularBufferInit(&_buffer, kBufferSize*numberOfChannels);
    self.hold = 22050;
    self.decay = 44100;
    self.attack = 2048;
    _level = 0.2;
    _gain = 1.0;
    _framesSinceLastTrigger = kNoValue;
    _framesToNextTrigger = kNoValue;
    
    _audioDescription.mFormatID          = kAudioFormatLinearPCM;
    _audioDescription.mFormatFlags       = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    _audioDescription.mChannelsPerFrame  = numberOfChannels;
    _audioDescription.mBytesPerPacket    = sizeof(float);
    _audioDescription.mFramesPerPacket   = 1;
    _audioDescription.mBytesPerFrame     = sizeof(float);
    _audioDescription.mBitsPerChannel    = 8 * sizeof(float);
    _audioDescription.mSampleRate        = sampleRate;

    return self;
}

BOOL AELimiterEnqueue(AELimiter *THIS, float** buffers, UInt32 length, const AudioTimeStamp *timestamp) {
    int numberOfBuffers = THIS->_audioDescription.mChannelsPerFrame;
    
    char audioBufferListBytes[sizeof(AudioBufferList)+(numberOfBuffers-1)*sizeof(AudioBuffer)];
    AudioBufferList *bufferList = (AudioBufferList*)audioBufferListBytes;
    bufferList->mNumberBuffers = numberOfBuffers;
    for ( int i=0; i<numberOfBuffers; i++ ) {
        bufferList->mBuffers[i].mData = buffers[i];
        bufferList->mBuffers[i].mDataByteSize = sizeof(float) * length;
        bufferList->mBuffers[i].mNumberChannels = 1;
    }
    
    return TPCircularBufferCopyAudioBufferList(&THIS->_buffer, bufferList, timestamp, kTPCircularBufferCopyAll, NULL);
}

void AELimiterDequeue(AELimiter *THIS, float** buffers, UInt32 *ioLength, AudioTimeStamp *timestamp) {
    *ioLength = min(*ioLength, AELimiterFillCount(THIS, NULL, NULL));
    _AELimiterDequeue(THIS, buffers, ioLength, timestamp);
}

void AELimiterDrain(AELimiter *THIS, float** buffers, UInt32 *ioLength, AudioTimeStamp *timestamp) {
    _AELimiterDequeue(THIS, buffers, ioLength, timestamp);
}

static void _AELimiterDequeue(AELimiter *THIS, float** buffers, UInt32 *ioLength, AudioTimeStamp *timestamp) {
    // Dequeue the audio
    int numberOfBuffers = THIS->_audioDescription.mChannelsPerFrame;
    char audioBufferListBytes[sizeof(AudioBufferList)+(numberOfBuffers-1)*sizeof(AudioBuffer)];
    AudioBufferList *bufferList = (AudioBufferList*)audioBufferListBytes;
    bufferList->mNumberBuffers = numberOfBuffers;
    for ( int i=0; i<numberOfBuffers; i++ ) {
        bufferList->mBuffers[i].mData = buffers[i];
        bufferList->mBuffers[i].mDataByteSize = sizeof(float) * *ioLength;
        bufferList->mBuffers[i].mNumberChannels = 1;
    }
    THIS->_audioDescription.mChannelsPerFrame = numberOfBuffers;
    TPCircularBufferDequeueBufferListFrames(&THIS->_buffer, ioLength, bufferList, timestamp, &THIS->_audioDescription);
    
    // Now apply limiting
    int frameNumber = 0;
    while ( frameNumber < *ioLength ) {
        
        // Examine buffer, update and act on state
        int stateDuration = *ioLength - frameNumber;
        switch ( THIS->_state ) {
            case kStateIdle: {
                if ( THIS->_framesToNextTrigger == kNoValue ) {
                    // See if there's a trigger up ahead
                    element_t trigger = findNextTriggerValueInRange(THIS, bufferList, frameNumber, NSMakeRange(0, (*ioLength-frameNumber)+THIS->_attack));
                    if ( trigger.value ) {
                        THIS->_framesToNextTrigger = trigger.index;
                        THIS->_triggerValue = trigger.value;
                    }
                }
                
                if ( THIS->_framesToNextTrigger <= THIS->_attack ) {
                    // We're within the attack duration - start attack now
                    THIS->_state = kStateAttacking;
                    continue;
                } else {
                    // Some time until attack, stay idle until then
                    stateDuration = min(stateDuration, THIS->_framesToNextTrigger - THIS->_attack);
                    
                    if ( stateDuration == THIS->_framesToNextTrigger - THIS->_attack ) {
                        THIS->_state = kStateAttacking;
                    }
                }
                break;
            }
            case kStateAttacking: {
                // See if there's a higher value in the next block
                element_t value = findMaxValueInRange(THIS, bufferList, frameNumber, NSMakeRange(THIS->_framesToNextTrigger, THIS->_framesToNextTrigger+THIS->_attack));
                if ( value.value > THIS->_triggerValue ) {
                    // Re-adjust target hold level to higher value
                    THIS->_triggerValue = value.value;
                }
                
                // Continue attack up to next trigger value
                stateDuration = min(THIS->_framesToNextTrigger, stateDuration);
#ifdef DEBUG
                assert(stateDuration >= 0);
#endif
                
                if ( stateDuration > 0 ) {
                    // Apply ramp
                    float step = ((THIS->_level/THIS->_triggerValue)-THIS->_gain) / THIS->_framesToNextTrigger;
                    if ( numberOfBuffers == 2 ) {
                        vDSP_vrampmul2(buffers[0]+frameNumber, buffers[1]+frameNumber, 1, &THIS->_gain, &step, buffers[0]+frameNumber, buffers[1]+frameNumber, 1, stateDuration);
                    } else {
                        float gain = THIS->_gain;
                        for ( int channel=0; channel<numberOfBuffers; channel++ ) {
                            gain = THIS->_gain;
                            vDSP_vrampmul(buffers[channel]+frameNumber, 1, &gain, &step, buffers[channel]+frameNumber, 1, stateDuration);
                        }
                        THIS->_gain = gain;
                    }
                } else {
                    THIS->_gain = THIS->_level / THIS->_triggerValue;
                }
                
                if ( stateDuration == THIS->_framesToNextTrigger ) {
                    THIS->_state = kStateHolding;
                }
                
                break;
            }
            case kStateHolding: {
                // See if there's a higher value within the remaining hold interval or following attack frames
                stateDuration = THIS->_framesToNextTrigger != kNoValue 
                                        ? THIS->_framesToNextTrigger + THIS->_hold 
                                        : MAX(0, (int)THIS->_hold - THIS->_framesSinceLastTrigger);

                element_t value = findMaxValueInRange(THIS, bufferList, frameNumber, NSMakeRange(0, stateDuration + THIS->_attack));
                if ( value.value > THIS->_triggerValue ) {
                    // Target attack to this new value
                    THIS->_framesToNextTrigger = value.index;
                    THIS->_triggerValue = value.value;
                    stateDuration = min(stateDuration, THIS->_framesToNextTrigger - THIS->_attack);
                    if ( stateDuration == THIS->_framesToNextTrigger - THIS->_attack ) {
                        THIS->_state = kStateAttacking;
                    }
                } else if ( value.value >= THIS->_level ) {
                    // Extend hold up to this value
                    THIS->_framesToNextTrigger = value.index;
                    stateDuration = min(stateDuration, MAX(THIS->_framesToNextTrigger, (int)THIS->_hold - THIS->_framesSinceLastTrigger));
                } else {
                    // Prepare to decay
                    if ( stateDuration == (int)THIS->_hold - THIS->_framesSinceLastTrigger ) {
                        THIS->_state = kStateDecaying;
                    }
                }
                
                stateDuration = min(*ioLength-frameNumber, stateDuration);
#ifdef DEBUG
                assert(stateDuration >= 0);
#endif
                
                // Apply gain
                for ( int i=0; i<numberOfBuffers; i++ ) {
                    vDSP_vsmul(buffers[i] + frameNumber, 1, &THIS->_gain, buffers[i] + frameNumber, 1, stateDuration);
                }
                
                break;
            }
            case kStateDecaying: {
                // See if there's a trigger up ahead
                stateDuration = min(stateDuration, THIS->_decay - (THIS->_framesSinceLastTrigger - THIS->_hold));
                element_t trigger = findNextTriggerValueInRange(THIS, bufferList, frameNumber, NSMakeRange(0, stateDuration+THIS->_attack));
                if ( trigger.value ) {
                    THIS->_framesToNextTrigger = trigger.index;
                    THIS->_triggerValue = trigger.value;
                    
                    stateDuration = min(stateDuration, trigger.index - THIS->_attack);
                    
                    if ( stateDuration == trigger.index - THIS->_attack ) {
                        THIS->_state = kStateAttacking;
                    }
                } else {
                    // Prepare to idle
                    if ( stateDuration == THIS->_decay - (THIS->_framesSinceLastTrigger - THIS->_hold) ) {
                        THIS->_state = kStateIdle;
                    }
                }
                
#ifdef DEBUG
                assert(stateDuration >= 0);
#endif
                
                if ( stateDuration > 0 ) {
                    // Apply ramp
                    float step = (1.0-THIS->_gain) / (THIS->_decay - (THIS->_framesSinceLastTrigger - THIS->_hold));
                    if ( numberOfBuffers == 2 ) {
                        vDSP_vrampmul2(buffers[0] + frameNumber, buffers[1] + frameNumber, 1, &THIS->_gain, &step, buffers[0] + frameNumber, buffers[1] + frameNumber, 1, stateDuration);
                    } else {
                        float gain = THIS->_gain;
                        for ( int channel=0; channel<numberOfBuffers; channel++ ) {
                            gain = THIS->_gain;
                            vDSP_vrampmul(buffers[channel] + frameNumber, 1, &THIS->_gain, &step, buffers[channel] + frameNumber, 1, stateDuration);
                        }
                        THIS->_gain = gain;
                    }
                } else {
                    THIS->_gain = 1;
                }

                break;
            }
        }
        
        frameNumber += stateDuration;
        advanceTime(THIS, stateDuration);
    }
}

UInt32 AELimiterFillCount(AELimiter *THIS, AudioTimeStamp *timestamp, UInt32 *trueFillCount) {
    if ( timestamp ) memset(timestamp, 0, sizeof(AudioTimeStamp));
    int fillCount = 0;
    AudioBufferList *bufferList = TPCircularBufferNextBufferList(&THIS->_buffer, timestamp);
    while ( bufferList ) {
        fillCount += bufferList->mBuffers[0].mDataByteSize / sizeof(float);
        bufferList = TPCircularBufferNextBufferListAfter(&THIS->_buffer, bufferList, NULL);
    }
    if ( trueFillCount ) *trueFillCount = fillCount;
    return MAX(0, fillCount - (int)THIS->_attack);
}

void AELimiterReset(AELimiter *THIS) {
    THIS->_gain = 1.0;
    THIS->_state = kStateIdle;
    THIS->_framesSinceLastTrigger = kNoValue;
    THIS->_framesToNextTrigger = kNoValue;
    THIS->_triggerValue = 0;
    TPCircularBufferClear(&THIS->_buffer);
}

static inline void advanceTime(AELimiter *THIS, UInt32 frames) {
    if ( THIS->_framesSinceLastTrigger != kNoValue ) {
        THIS->_framesSinceLastTrigger += frames;
        if ( THIS->_framesSinceLastTrigger > THIS->_hold+THIS->_decay ) {
            THIS->_framesSinceLastTrigger = kNoValue;
        }
    }
    if ( THIS->_framesToNextTrigger != kNoValue ) {
        THIS->_framesToNextTrigger -= frames;
        if ( THIS->_framesToNextTrigger <= 0 ) {
            THIS->_framesSinceLastTrigger = -THIS->_framesToNextTrigger;
            THIS->_framesToNextTrigger = kNoValue;
        }
    }
}


static element_t findNextTriggerValueInRange(AELimiter *THIS, AudioBufferList *dequeuedBufferList, int dequeuedBufferListOffset, NSRange range) {
    int framesSeen = 0;
    AudioBufferList *buffer = dequeuedBufferList;
    while ( framesSeen < range.location+range.length && buffer ) {
        int bufferOffset = buffer == dequeuedBufferList ? dequeuedBufferListOffset : 0;
        if ( framesSeen < range.location ) {
            int skip = min((buffer->mBuffers[0].mDataByteSize/sizeof(float))-bufferOffset, range.location-framesSeen);
            framesSeen += skip;
            bufferOffset += skip;
        }
        
        if ( framesSeen >= range.location && bufferOffset < (buffer->mBuffers[0].mDataByteSize/sizeof(float)) ) {
            // Find the first value greater than the limit
            for ( int i=0; i<buffer->mNumberBuffers; i++ ) {
                float *start = (float*)buffer->mBuffers[i].mData + bufferOffset;
                float *end = (float*)((char*)buffer->mBuffers[i].mData + buffer->mBuffers[i].mDataByteSize);
                end = MIN(end, start + ((range.location+range.length) - framesSeen));
                float *v=start;
                for ( ; v<end && fabsf(*v) < THIS->_level; v++ );
                if ( v != end ) {
                    return (element_t){ .value = fabsf(*v), .index = framesSeen + (v-start) };
                }
            }
            framesSeen += (buffer->mBuffers[0].mDataByteSize / sizeof(float)) - bufferOffset;
        }
        
        buffer = buffer == dequeuedBufferList 
            ? TPCircularBufferNextBufferList(&THIS->_buffer, NULL) :
              TPCircularBufferNextBufferListAfter(&THIS->_buffer, buffer, NULL);
    }
    
    return (element_t) {0, 0};
}

static element_t findMaxValueInRange(AELimiter *THIS, AudioBufferList *dequeuedBufferList, int dequeuedBufferListOffset, NSRange range) {
    vDSP_Length index = 0;
    float max = 0.0;
    int framesSeen = 0;
    AudioBufferList *buffer = dequeuedBufferList;
    while ( framesSeen < range.location+range.length && buffer ) {
        int bufferOffset = buffer == dequeuedBufferList ? dequeuedBufferListOffset : 0;
        if ( framesSeen < range.location ) {
            int skip = min((buffer->mBuffers[0].mDataByteSize/sizeof(float))-bufferOffset, range.location-framesSeen);
            framesSeen += skip;
            bufferOffset += skip;
        }
        
        if ( framesSeen >= range.location && bufferOffset < (buffer->mBuffers[0].mDataByteSize/sizeof(float)) ) {
            // Find max value
            for ( int i=0; i<buffer->mNumberBuffers; i++ ) {
                float *position = (float*)buffer->mBuffers[i].mData + bufferOffset;
                int length = (buffer->mBuffers[i].mDataByteSize / sizeof(float)) - bufferOffset;
                length = MIN(length, ((range.location+range.length) - framesSeen));
                
                vDSP_Length buffer_max_index;
                float buffer_max = max;
                for ( int i=0; i<buffer->mNumberBuffers; i++ ) {
                    vDSP_maxmgvi(position, 1, &buffer_max, &buffer_max_index, length);
                }
                
                if ( buffer_max > max ) {
                    max = buffer_max;
                    index = framesSeen + buffer_max_index;
                }
            }
            framesSeen += (buffer->mBuffers[0].mDataByteSize / sizeof(float)) - bufferOffset;
        }
        
        buffer = buffer == dequeuedBufferList 
            ? TPCircularBufferNextBufferList(&THIS->_buffer, NULL) :
              TPCircularBufferNextBufferListAfter(&THIS->_buffer, buffer, NULL);
    }
    
    return (element_t) { .value = max, .index = index};
}

@end
