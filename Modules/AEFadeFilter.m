//
//  AEFadeFilter.h
//  TheAmazingAudioEngine
//
//  Created by Mark Wise on 01/01/2015.
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
//

#import "AEFadeFilter.h"

#define kAEFadeFilterFadeIn (0)
#define kAEFadeFilterFadeOut (1)

@interface AEFadeFilter (){
    AEBlockFilterBlock block;
    float* _sampleGainRatios;
    bool _isFading;
    int _fadeDirection;
    int _sampleGainStep;
    int _envelopeNumSamples;
    float _currentGainRatio;
    float _destinationGainRatio;
    AudioStreamBasicDescription asbd;
    UInt32 bytesPerChannel;
}
@end

static float floatToDecibel(float value);
static float const maxReduction = 60.0;

@implementation AEFadeFilter

+ (AEFadeFilter*)initWithAudioController:(AEAudioController*)inAudioController {
    return [[AEFadeFilter alloc] initWithAudioController:inAudioController];
}

- (id)initWithAudioController:(AEAudioController*)audioController {
    AEFadeFilter * __weak weakSelf = self;

    self = [self initWithBlock:^(AEAudioControllerFilterProducer producer,
                                              void                     *producerToken,
                                              const AudioTimeStamp     *time,
                                              UInt32                    frames,
                                              AudioBufferList          *audio) {
      // Pull audio
      OSStatus status = producer(producerToken, audio, &frames);
      if ( status != noErr ) return;

      for (int bufCount=0; bufCount < audio->mNumberBuffers; bufCount++) {
          AudioBuffer buf = audio->mBuffers[bufCount];
          [self processBuffer:buf frames:frames step:_sampleGainStep];
      }

      if (_isFading) {
          _sampleGainStep += (int) frames;
          if (_sampleGainStep > _envelopeNumSamples - 1) {
              if (weakSelf.delegate) {
                  if (_fadeDirection == kAEFadeFilterFadeOut && [weakSelf.delegate respondsToSelector:@selector(onFadeOutComplete)]) {
                      [weakSelf.delegate onFadeOutComplete];
                  }
                  if (_fadeDirection == kAEFadeFilterFadeIn && [weakSelf.delegate respondsToSelector:@selector(onFadeInComplete)]) {
                      [weakSelf.delegate onFadeInComplete];
                  }
              }
              if (_destinationGainRatio != -1) {
                  _currentGainRatio = _destinationGainRatio;
                  _destinationGainRatio = -1;
              }
              _isFading = NO;
          }
      }
    } audioController: audioController];

    return self;
}

- (id)initWithBlock:(AEBlockFilterBlock)inBlock audioController:(AEAudioController *)inAudioController{
    if ( !(self = [super init]) ) self = nil;

    block = inBlock;
    _audioController = inAudioController;
    asbd = _audioController.audioDescription;
    bytesPerChannel = asbd.mBytesPerFrame / asbd.mChannelsPerFrame;

    _currentGainRatio = 0.0;
    _isFading = NO;

    return self;
}

- (void)processBuffer:(AudioBuffer)buf frames:(UInt32)frames step:(int)step {
    float sample = 0;
    int currentFrame = 0;

    while ( currentFrame < frames ) {
        for (int currentChannel=0; currentChannel < buf.mNumberChannels; currentChannel++) {
            memcpy(&sample,
                buf.mData +
                  (currentFrame * asbd.mBytesPerFrame) +
                  (currentChannel * bytesPerChannel),
                sizeof(float));

            if (_isFading && step < (_envelopeNumSamples - 1) ) {
                _currentGainRatio = _sampleGainRatios[step];
            }
            sample = _currentGainRatio * sample;

            memcpy(buf.mData +
                (currentFrame * asbd.mBytesPerFrame) +
                (currentChannel * bytesPerChannel),
                &sample,
                sizeof(float));
        }
        step++;
        currentFrame++;
    }
}

- (void)freeDbGainTable {
    if (_sampleGainRatios) {
        free(_sampleGainRatios);
    }
}

- (void)prepareDbGainTable:(int)milliseconds toRatio:(float)_toRatio {
    [self freeDbGainTable];

    float sampleRate = _audioController.audioDescription.mSampleRate;
    float fadeTimeSeconds = (float) milliseconds / 1000.0;

    _envelopeNumSamples = (int) sampleRate * fadeTimeSeconds;
    _sampleGainRatios = (float*) malloc(sizeof(float) * _envelopeNumSamples);
    _destinationGainRatio = _toRatio;

    float currentDb = floatToDecibel(_currentGainRatio);
    float deltaDb = floatToDecibel(_toRatio) - currentDb;
    float dbPerStep = deltaDb / _envelopeNumSamples;

    float db, gainRatio;

    for (int step = 0; step < _envelopeNumSamples; step++) {
        db = step * dbPerStep;
        gainRatio = pow(10.0, (currentDb + db) / 20.0);
        _sampleGainRatios[step] = gainRatio;
    }

    return;
}

- (void)startFadeOut:(int)milliseconds {
    _isFading = NO;
    [self prepareDbGainTable:milliseconds toRatio: 0.0];
    _sampleGainStep = 0;
    _fadeDirection = kAEFadeFilterFadeOut;
    _isFading = YES;
}

- (void)startFadeIn:(int)milliseconds {
    _isFading = NO;
    [self prepareDbGainTable:milliseconds toRatio: 1.0];
    _sampleGainStep = 0;
    _fadeDirection = kAEFadeFilterFadeIn;
    _isFading = YES;
}

static OSStatus filterCallback(__unsafe_unretained AEFadeFilter *THIS,
                               __unsafe_unretained AEAudioController *audioController,
                               AEAudioControllerFilterProducer producer,
                               void                     *producerToken,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    THIS->block(producer, producerToken, time, frames, audio);
    return noErr;
}

- (AEAudioControllerFilterCallback)filterCallback {
    return filterCallback;
}

static float floatToDecibel(float value) {
    if (value > 0.001) {
        return 20 * log10(value);
    } else {
        return maxReduction * -1.0;
    }
}


@end
