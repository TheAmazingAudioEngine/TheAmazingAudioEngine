//
//  ViewController.m
//  TheEngineSample
//
//  Created by Steve Rubin on 8/5/15.
//  Copyright (c) 2015 A Tasty Pixel. All rights reserved.
//

#import "ViewController.h"
#import "TheAmazingAudioEngine.h"
#import "TPOscilloscopeLayer.h"
#import "AEExpanderFilter.h"
#import "AELimiterFilter.h"
#import "AEPlaythroughChannel.h"
#import "AERecorder.h"
#import <QuartzCore/QuartzCore.h>

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        int fourCC = CFSwapInt32HostToBig(result);
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&fourCC);
        return NO;
    }
    return YES;
}

static const int kInputChannelsChangedContext;

@interface ViewController () {
    AudioFileID _audioUnitFile;
    AEChannelGroupRef _group;
    NSView *_headerView;
    NSTableView *_tableView;
    NSTableColumn *_nameColumn;
    NSTableColumn *_sliderColumn;
	
	rmsengine_t mRMSEngineL;
	rmsengine_t mRMSEngineR;
}

@property (nonatomic, strong) AEAudioController *audioController;
@property (nonatomic, strong) AEAudioFilePlayer *loop1;
@property (nonatomic, strong) AEAudioFilePlayer *loop2;
@property (nonatomic, strong) AEBlockChannel *oscillator;
@property (nonatomic, strong) AEAudioUnitChannel *audioUnitPlayer;
@property (nonatomic, strong) AEAudioFilePlayer *oneshot;
@property (nonatomic, strong) AEPlaythroughChannel *playthrough;
@property (nonatomic, strong) AELimiterFilter *limiter;
@property (nonatomic, strong) AEExpanderFilter *expander;
@property (nonatomic, strong) AEAudioUnitFilter *reverb;
@property (nonatomic, strong) TPOscilloscopeLayer *outputOscilloscope;
@property (nonatomic, strong) TPOscilloscopeLayer *inputOscilloscope;
@property (nonatomic, strong) CALayer *inputLevelLayer;
@property (nonatomic, strong) CALayer *outputLevelLayer;
@property (nonatomic, weak) NSTimer *levelsTimer;
@property (nonatomic, strong) AERecorder *recorder;
@property (nonatomic, strong) AEAudioFilePlayer *player;
@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) NSButton *recordButton;



@end

@implementation ViewController
/*
- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 500)];
}
*/

- (NSString *)nibName
{ return @"MainView"; }

- (void)viewDidLoad {
    [super viewDidLoad];

	// Initialize RMS engines using samplerate
	Float64 sampleRate = _audioController.audioDescription.mSampleRate;
	mRMSEngineL = RMSEngineInit(sampleRate);
	mRMSEngineR = RMSEngineInit(sampleRate);
	
	// Attach engines to RMSStereoView and start updating
	[self.stereoView setEnginePtrL:&mRMSEngineL];
	[self.stereoView setEnginePtrR:&mRMSEngineR];
	[self.stereoView startUpdating];

	// Add an output receiver
	[_audioController addOutputReceiver:
	[AEBlockAudioReceiver audioReceiverWithBlock:^
	(
		void *source,
		const AudioTimeStamp *time,
		UInt32 frames,
		AudioBufferList *audio
	)
	{
		// Process first output buffer through left engine
		if (audio->mNumberBuffers > 0)
		{
			Float32 *srcPtr = audio->mBuffers[0].mData;
			RMSEngineAddSamples32(&self->mRMSEngineL, srcPtr, frames);
		}
		
		// Process second output through right engine
		if (audio->mNumberBuffers > 1)
		{
			Float32 *srcPtr = audio->mBuffers[1].mData;
			RMSEngineAddSamples32(&self->mRMSEngineR, srcPtr, frames);
		}
	}]];
	
//	[_audioController addOutputReceiver:receiver];
//*/

/*
    self.outputOscilloscope = [[TPOscilloscopeLayer alloc] initWithAudioDescription:_audioController.audioDescription];
    _outputOscilloscope.frame = NSMakeRect(0, 10, _headerView.bounds.size.width, 80);
    [_headerView.layer addSublayer:_outputOscilloscope];
    [_audioController addOutputReceiver:_outputOscilloscope];
    [_outputOscilloscope start];
    
    self.inputOscilloscope = [[TPOscilloscopeLayer alloc] initWithAudioDescription:_audioController.audioDescription];
    _inputOscilloscope.frame = NSMakeRect(0, 10, _headerView.bounds.size.width, 80);
    _inputOscilloscope.lineColor = [NSColor colorWithWhite:0.0 alpha:0.3];
    [_headerView.layer addSublayer:_inputOscilloscope];
    [_audioController addInputReceiver:_inputOscilloscope];
    [_inputOscilloscope start];
    
    self.inputLevelLayer = [CALayer layer];
    _inputLevelLayer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.3] CGColor];
    _inputLevelLayer.frame = NSMakeRect(_headerView.bounds.size.width/2.0 - 5.0, 0, 50, 10);
    [_headerView.layer addSublayer:_inputLevelLayer];
    
    self.outputLevelLayer = [CALayer layer];
    _outputLevelLayer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.3] CGColor];
    _outputLevelLayer.frame = NSMakeRect(_headerView.bounds.size.width/2.0 + 5.0, 0, 50, 10);
    [_headerView.layer addSublayer:_outputLevelLayer];
 */
 
 
	
	
    _tableView = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 75, self.view.bounds.size.width, 300)];
    [self.view addSubview:_tableView];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.backgroundColor = [NSColor whiteColor];
    
    _nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"nameColumn"];
    _nameColumn.width = 395 / 2.0;
    [_tableView addTableColumn:_nameColumn];

    _sliderColumn = [[NSTableColumn alloc] initWithIdentifier:@"sliderColumn"];
    _sliderColumn.width = 395 / 2.0;
    [_tableView addTableColumn:_sliderColumn];
    
    NSView *footerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, self.view.bounds.size.width, 80)];

    self.recordButton = [[NSButton alloc] init];
    self.recordButton.bezelStyle = NSRegularSquareBezelStyle;
    [self.recordButton setButtonType:NSPushOnPushOffButton];
    self.recordButton.title = @"Record";
    self.recordButton.action = @selector(record:);
    self.recordButton.target = self;
    self.recordButton.frame = NSMakeRect(20, 10, (footerView.bounds.size.width - 50) / 2, footerView.bounds.size.height - 20);
    
    self.playButton = [[NSButton alloc] init];
    self.playButton.bezelStyle = NSRegularSquareBezelStyle;
    [self.playButton setButtonType:NSPushOnPushOffButton];
    self.playButton.title = @"Play";
    self.playButton.action = @selector(play:);
    self.playButton.target = self;
    self.playButton.frame = NSMakeRect(CGRectGetMaxX(self.recordButton.frame) + 10, 10, ((footerView.bounds.size.width - 50) / 2), footerView.bounds.size.height - 20);
    
    [footerView addSubview:self.recordButton];
    [footerView addSubview:self.playButton];

    [self.view addSubview:footerView];
}

- (instancetype)initWithAudioController:(AEAudioController *)audioController {
    if ( !(self = [super init]) ) return nil;
    
    self.audioController = audioController;
    
    // Create the first loop player
    self.loop1 = [AEAudioFilePlayer
                  audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"Southern Rock Drums" withExtension:@"m4a"]
                  error:NULL];
    _loop1.volume = 1.0;
    _loop1.channelIsMuted = YES;
    _loop1.loop = YES;
    
    // Create the second loop player
    self.loop2 = [AEAudioFilePlayer
                  audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"Southern Rock Organ" withExtension:@"m4a"]
                  error:NULL];
    _loop2.volume = 1.0;
    _loop2.channelIsMuted = YES;
    _loop2.loop = YES;
    
    // Create a block-based channel, with an implementation of an oscillator
    __block float oscillatorPosition = 0;
    __block float oscillatorRate = 622.0/44100.0;
    self.oscillator = [AEBlockChannel channelWithBlock:^(const AudioTimeStamp  *time,
                                                         UInt32           frames,
                                                         AudioBufferList *audio) {
        for ( int i=0; i<frames; i++ ) {
            // Quick sin-esque oscillator
            float x = oscillatorPosition;
            x *= x; x -= 1.0; x *= x;       // x now in the range 0...1
			//x = x*x*(3-x+x);
			x -= 0.5;
            oscillatorPosition += oscillatorRate;
            if ( oscillatorPosition > 1.0 ) oscillatorPosition -= 1.0;
            ((float *)audio->mBuffers[0].mData)[i] = x;
            ((float *)audio->mBuffers[1].mData)[i] = x;
        }
    }];
    _oscillator.audioDescription = audioController.audioDescription;
    _oscillator.channelIsMuted = YES;
    
    // Create an audio unit channel (a file player)
    self.audioUnitPlayer = [[AEAudioUnitChannel alloc] initWithComponentDescription:AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Generator, kAudioUnitSubType_AudioFilePlayer)];
    
    // Create a group for loop1, loop2 and oscillator
    _group = [_audioController createChannelGroup];
    [_audioController addChannels:@[_loop1, _loop2, _oscillator] toChannelGroup:_group];
    
    // Finally, add the audio unit player
    [_audioController addChannels:@[_audioUnitPlayer]];
    
    [_audioController addObserver:self forKeyPath:@"numberOfInputChannels" options:0 context:(void*)&kInputChannelsChangedContext];
    
    return self;
}

-(void)dealloc {
    [_audioController removeObserver:self forKeyPath:@"numberOfInputChannels"];
    
    if ( _levelsTimer ) [_levelsTimer invalidate];
    
    NSMutableArray *channelsToRemove = [NSMutableArray arrayWithObjects:_loop1, _loop2, nil];
    
    if ( _player ) {
        [channelsToRemove addObject:_player];
    }
    
    if ( _oneshot ) {
        [channelsToRemove addObject:_oneshot];
    }
    
    if ( _playthrough ) {
        [channelsToRemove addObject:_playthrough];
        [_audioController removeInputReceiver:_playthrough];
    }
    
    [_audioController removeChannels:channelsToRemove];
    
    if ( _limiter ) {
        [_audioController removeFilter:_limiter];
    }
    
    if ( _expander ) {
        [_audioController removeFilter:_expander];
    }
    
    if ( _reverb ) {
        [_audioController removeFilter:_reverb];
    }
    
    if ( _audioUnitFile ) {
        AudioFileClose(_audioUnitFile);
    }
}

- (void)record:(id)sender {
    if ( _recorder ) {
        [_recorder finishRecording];
        [_audioController removeOutputReceiver:_recorder];
        [_audioController removeInputReceiver:_recorder];
        self.recorder = nil;
        _recordButton.state = NSOffState;
    } else {
        self.recorder = [[AERecorder alloc] initWithAudioController:_audioController];
        NSArray *documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *path = [documentsFolders[0] stringByAppendingPathComponent:@"Recording.aiff"];
        NSError *error = nil;
        if ( ![_recorder beginRecordingToFileAtPath:path fileType:kAudioFileAIFFType error:&error] ) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.alertStyle = NSCriticalAlertStyle;
            alert.messageText = @"Couldn't start recording";
            alert.informativeText = [error localizedDescription];
            [alert runModal];
            self.recorder = nil;
            return;
        }
        
        _recordButton.state = NSOnState;
        
        [_audioController addOutputReceiver:_recorder];
        [_audioController addInputReceiver:_recorder];
    }
}

- (void)play:(id)sender {
    if ( _player ) {
        [_audioController removeChannels:@[_player]];
        self.player = nil;
        _playButton.state = NSOffState;
    } else {
        NSArray *documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *path = [documentsFolders[0] stringByAppendingPathComponent:@"Recording.aiff"];
        
        if ( ![[NSFileManager defaultManager] fileExistsAtPath:path] ) return;
        
        NSError *error = nil;
        self.player = [AEAudioFilePlayer audioFilePlayerWithURL:[NSURL fileURLWithPath:path] error:&error];
        
        if ( !_player ) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.alertStyle = NSCriticalAlertStyle;
            alert.messageText = @"Couldn't start playback";
            alert.informativeText = [error localizedDescription];
            [alert runModal];
            return;
        }
        
        _player.removeUponFinish = YES;
        __weak ViewController *weakSelf = self;
        _player.completionBlock = ^{
            ViewController *strongSelf = weakSelf;
            strongSelf->_playButton.state = NSOffState;
            weakSelf.player = nil;
        };
        [_audioController addChannels:@[_player]];
        
        _playButton.state = NSOnState;
    }
}

static inline float translate(float val, float min, float max) {
    if ( val < min ) val = min;
    if ( val > max ) val = max;
    return (val - min) / (max - min);
}

- (void)updateLevels:(id)sender {

	Float32 inputAvg = 0.0;
	Float32 inputPeak = 0.0;
	Float32 outputAvg = 0.0;
	Float32 outputPeak = 0.0;
	[_audioController inputAveragePowerLevel:&inputAvg peakHoldLevel:&inputPeak];
	[_audioController outputAveragePowerLevel:&outputAvg peakHoldLevel:&outputPeak];

	[CATransaction begin];
	[CATransaction setDisableActions:YES];

		_inputLevelLayer.frame = NSMakeRect(
			_headerView.bounds.size.width/2.0 - 5.0 -
			translate(inputAvg, -20, 0) * (_headerView.bounds.size.width/2.0 - 15.0),
			_inputLevelLayer.frame.origin.y,
			translate(inputAvg, -20, 0) * (_headerView.bounds.size.width/2.0 - 15.0),
			10);

		_outputLevelLayer.frame = NSMakeRect(
			_headerView.bounds.size.width/2.0,
			_outputLevelLayer.frame.origin.y,
			translate(outputAvg, -20, 0) * (_headerView.bounds.size.width/2.0 - 15.0),
			10);

	[CATransaction commit];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    self.levelsTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(updateLevels:) userInfo:nil repeats:YES];
}

-(void)viewWillDisappear {
    [super viewWillDisappear];
    [_levelsTimer invalidate];
    self.levelsTimer = nil;
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return 11;
}

#pragma mark - NSTableViewDelegate

- (BOOL)tableView:(NSTableView *)tableView shouldSelectTableColumn:(NSTableColumn *)tableColumn {
    return NO;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return NO;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return 22;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSView *view;
    
    if ( [tableColumn isEqualTo:_nameColumn] ) {
        static NSString *nameIdentifier = @"nameItem";
        view = [tableView makeViewWithIdentifier:nameIdentifier owner:self];
        
        if ( !view ) {
            view = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 400, 40)];
            view.identifier = nameIdentifier;
        }
        NSButton *button = (NSButton *)view;
        button.bezelStyle = NSRoundRectBezelStyle;
        [button setButtonType:NSPushOnPushOffButton];
        
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 400, 40)];
        label.alignment = NSCenterTextAlignment;
        label.bordered = NO;
        
        switch ( row ) {
            case 0:
                button.title = @"Drums";
                button.state = _loop1.channelIsMuted ? NSOffState : NSOnState;
                button.target = self;
                button.action = @selector(loop1SwitchChanged:);
                break;
            case 1:
                button.title = @"Organ";
                button.state = _loop2.channelIsMuted ? NSOffState : NSOnState;
                button.target = self;
                button.action = @selector(loop2SwitchChanged:);
                break;
            case 2:
                button.title = @"Oscillator";
                button.state = _oscillator.channelIsMuted ? NSOffState : NSOnState;
                button.target = self;
                button.action = @selector(oscillatorSwitchChanged:);
                break;
            case 3:
                button.title = @"Group";
                button.state = [_audioController channelGroupIsMuted:_group] ? NSOffState : NSOnState;
                button.target = self;
                button.action = @selector(channelGroupSwitchChanged:);
                break;
            case 4:
                button.title = @"One shot";
                button.target = self;
                button.action = @selector(oneshotPlayButtonPressed:);
                break;
            case 5:
                button.title = @"One shot (audio unit)";
                [button setButtonType:NSMomentaryLightButton];
                button.target = self;
                button.action = @selector(oneshotAudioUnitPlayButtonPressed:);
                break;
            case 6:
                button.title = @"Limiter";
                button.state = _limiter ? NSOnState : NSOffState;
                button.target = self;
                button.action = @selector(limiterSwitchChanged:);
                break;
            case 7:
                button.title = @"Expander";
                button.state = _expander ? NSOnState : NSOffState;
                button.target = self;
                button.action = @selector(expanderSwitchChanged:);
                break;
            case 8:
                button.title = @"Cathedral Reverb";
                button.state = _reverb ? NSOnState : NSOffState;
                button.target = self;
                button.action = @selector(reverbSwitchChanged:);
                break;
            case 9:
                button.title = @"Input Playthrough";
                button.state = _playthrough ? NSOnState : NSOffState;
                button.target = self;
                button.action = @selector(playthroughSwitchChanged:);
                break;
            case 10:
                label.stringValue = @"Channels";
                view = label;
                break;
            default:
                button.title = @"";
                break;
        }
    } else if ( [tableColumn isEqualTo:_sliderColumn] ) {
        static NSString *sliderIdentifier = @"sliderItem";
        view = [tableView makeViewWithIdentifier:sliderIdentifier owner:self];
        
        if ( !view ) {
            view = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 400, 20)];
            view.identifier = sliderIdentifier;
        }
        NSSlider *slider = (NSSlider *)view;

        switch ( row ) {
            case 0:
                slider.doubleValue = _loop1.volume;
                slider.target = self;
                slider.action = @selector(loop1VolumeChanged:);
                break;
            case 1:
                slider.doubleValue = _loop2.volume;
                slider.target = self;
                slider.action = @selector(loop2VolumeChanged:);
                break;
            case 2:
                slider.doubleValue = _oscillator.volume;
                slider.target = self;
                slider.action = @selector(oscillatorVolumeChanged:);
                break;
            case 3:
                slider.doubleValue = [_audioController volumeForChannelGroup:_group];
                slider.target = self;
                slider.action = @selector(channelGroupVolumeChanged:);
                break;
            default:
                view = nil;
        }
        if (row == 10) {
            NSView *channelStrip = [[NSView alloc] initWithFrame:view.frame];
            int channelCount = _audioController.numberOfInputChannels;
            for ( int i=0; i<channelCount; i++ ) {
                NSButton *button = [[NSButton alloc] init];
                button.bezelStyle = NSRoundRectBezelStyle;
                [button setButtonType:NSPushOnPushOffButton];
                button.frame = NSMakeRect(i * 30, 2, 25, 20);
                button.title = [NSString stringWithFormat:@"%d", i + 1];
                button.state = [_audioController.inputChannelSelection containsObject:@(i)] ? NSOnState : NSOffState;
                button.tag = i;
                button.target = self;
                button.action = @selector(channelButtonPressed:);
                [channelStrip addSubview:button];
            }
            view = channelStrip;
        }
    }
    return view;
}

#pragma mark - UI Control

- (void)loop1SwitchChanged:(NSButton *)sender {
    _loop1.channelIsMuted = (sender.state == NSOffState);
}

- (void)loop1VolumeChanged:(NSSlider *)sender {
    _loop1.volume = sender.doubleValue;
}

- (void)loop2SwitchChanged:(NSButton *)sender {
    _loop2.channelIsMuted = (sender.state == NSOffState);
}

- (void)loop2VolumeChanged:(NSSlider *)sender {
    _loop2.volume = sender.doubleValue;
}

- (void)oscillatorSwitchChanged:(NSButton *)sender {
    _oscillator.channelIsMuted = (sender.state == NSOffState);
}

- (void)oscillatorVolumeChanged:(NSButton *)sender {
    _oscillator.volume = sender.doubleValue;
}

- (void)channelGroupSwitchChanged:(NSButton *)sender {
    BOOL isOn = (sender.state == NSOnState);
    [_audioController setMuted:!isOn forChannelGroup:_group];
}

- (void)channelGroupVolumeChanged:(NSSlider *)sender {
    [_audioController setVolume:sender.doubleValue forChannelGroup:_group];
}

- (void)oneshotPlayButtonPressed:(NSButton *)sender {
    if ( _oneshot ) {
        [_audioController removeChannels:@[_oneshot]];
        self.oneshot = nil;
        sender.state = NSOffState;
    } else {
        self.oneshot = [AEAudioFilePlayer
                        audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"Organ Run" withExtension:@"m4a"]
                        error:NULL];
        _oneshot.removeUponFinish = YES;
        __weak ViewController *weakSelf = self;
        __weak NSButton *weakOneshotButton = sender;
        _oneshot.completionBlock = ^{
            ViewController *strongSelf = weakSelf;
            strongSelf.oneshot = nil;
            NSButton *oneshotButton = weakOneshotButton;
            oneshotButton.state = NSOffState;
        };
        [_audioController addChannels:@[_oneshot]];
        sender.state = NSOnState;
    }
}

- (void)oneshotAudioUnitPlayButtonPressed:(NSButton *)sender {
    if ( !_audioUnitFile ) {
        NSURL *playerFile = [[NSBundle mainBundle] URLForResource:@"Organ Run" withExtension:@"m4a"];
        checkResult(AudioFileOpenURL((__bridge CFURLRef)playerFile, kAudioFileReadPermission, 0, &_audioUnitFile), "AudioFileOpenURL");
    }
    
    // Set the file to play
    checkResult(AudioUnitSetProperty(_audioUnitPlayer.audioUnit, kAudioUnitProperty_ScheduledFileIDs, kAudioUnitScope_Global, 0, &_audioUnitFile, sizeof(_audioUnitFile)),
                "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileIDs)");
    
    // Determine file properties
    UInt64 packetCount;
    UInt32 size = sizeof(packetCount);
    checkResult(AudioFileGetProperty(_audioUnitFile, kAudioFilePropertyAudioDataPacketCount, &size, &packetCount),
                "AudioFileGetProperty(kAudioFilePropertyAudioDataPacketCount)");
    
    AudioStreamBasicDescription dataFormat;
    size = sizeof(dataFormat);
    checkResult(AudioFileGetProperty(_audioUnitFile, kAudioFilePropertyDataFormat, &size, &dataFormat),
                "AudioFileGetProperty(kAudioFilePropertyDataFormat)");
    
    // Assign the region to play
    ScheduledAudioFileRegion region;
    memset (&region.mTimeStamp, 0, sizeof(region.mTimeStamp));
    region.mTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
    region.mTimeStamp.mSampleTime = 0;
    region.mCompletionProc = NULL;
    region.mCompletionProcUserData = NULL;
    region.mAudioFile = _audioUnitFile;
    region.mLoopCount = 0;
    region.mStartFrame = 0;
    region.mFramesToPlay = (UInt32)packetCount * dataFormat.mFramesPerPacket;
    checkResult(AudioUnitSetProperty(_audioUnitPlayer.audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region)),
                "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)");
    
    // Prime the player by reading some frames from disk
    UInt32 defaultNumberOfFrames = 0;
    checkResult(AudioUnitSetProperty(_audioUnitPlayer.audioUnit, kAudioUnitProperty_ScheduledFilePrime, kAudioUnitScope_Global, 0, &defaultNumberOfFrames, sizeof(defaultNumberOfFrames)),
                "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFilePrime)");
    
    // Set the start time (now = -1)
    AudioTimeStamp startTime;
    memset (&startTime, 0, sizeof(startTime));
    startTime.mFlags = kAudioTimeStampSampleTimeValid;
    startTime.mSampleTime = -1;
    checkResult(AudioUnitSetProperty(_audioUnitPlayer.audioUnit, kAudioUnitProperty_ScheduleStartTimeStamp, kAudioUnitScope_Global, 0, &startTime, sizeof(startTime)),
                "AudioUnitSetProperty(kAudioUnitProperty_ScheduleStartTimeStamp)");
    
}

- (void)limiterSwitchChanged:(NSButton *)sender {
    BOOL isOn = (sender.state == NSOnState);
    if ( isOn ) {
        self.limiter = [[AELimiterFilter alloc] init];
        _limiter.level = 0.1;
        [_audioController addFilter:_limiter];
    } else {
        [_audioController removeFilter:_limiter];
        self.limiter = nil;
    }
}

- (void)expanderSwitchChanged:(NSButton *)sender {
    BOOL isOn = (sender.state == NSOnState);
    if ( isOn ) {
        self.expander = [[AEExpanderFilter alloc] init];
        [_audioController addFilter:_expander];
    } else {
        [_audioController removeFilter:_expander];
        self.expander = nil;
    }
}

- (void)playthroughSwitchChanged:(NSButton *)sender {
    BOOL isOn = (sender.state == NSOnState);
    if ( isOn ) {
        self.playthrough = [[AEPlaythroughChannel alloc] initWithAudioController:_audioController];
        [_audioController addInputReceiver:_playthrough];
        [_audioController addChannels:@[_playthrough]];
    } else {
        [_audioController removeChannels:@[_playthrough]];
        [_audioController removeInputReceiver:_playthrough];
        self.playthrough = nil;
    }
}

- (void)reverbSwitchChanged:(NSButton *)sender {
    BOOL isOn = (sender.state == NSOnState);
    if ( isOn ) {
        self.reverb = [[AEAudioUnitFilter alloc] initWithComponentDescription:AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Effect, kAudioUnitSubType_MatrixReverb) preInitializeBlock:^(AudioUnit audioUnit) {
            
            CFArrayRef presets;
            UInt32 arraySize = sizeof(presets);

            // Get all reverb presets
            AudioUnitGetProperty(audioUnit,
                                 kAudioUnitProperty_FactoryPresets,
                                 kAudioUnitScope_Global,
                                 0,
                                 &presets,
                                 &arraySize);
            
            // Find the cathedral preset
            long arrayCount = CFArrayGetCount(presets);
            long presetNumber = 0;
            for (int i = 0; i < arrayCount; i++) {
                AUPreset *preset = (AUPreset *)CFArrayGetValueAtIndex(presets, i);
                NSString *name = (__bridge NSString *)(preset->presetName);
                if ([name isEqualToString:@"Cathedral"]) {
                    presetNumber = preset->presetNumber;
                }
            }
            
            UInt32 presetNumberSize = sizeof(presetNumber);
            
            // Set the cathedral preset
            AudioUnitSetProperty(audioUnit,
                                 kAudioUnitProperty_PresentPreset,
                                 kAudioUnitScope_Global,
                                 0,
                                 &presetNumber,
                                 presetNumberSize);
            
            CFRelease(presets);
        }];
        
        [_audioController addFilter:_reverb];
    } else {
        [_audioController removeFilter:_reverb];
        self.reverb = nil;
    }
}

- (void)channelButtonPressed:(NSButton *)sender {
    BOOL selected = [_audioController.inputChannelSelection containsObject:@(sender.tag)];
    selected = !selected;
    if ( selected ) {
        _audioController.inputChannelSelection = [[_audioController.inputChannelSelection arrayByAddingObject:@(sender.tag)] sortedArrayUsingSelector:@selector(compare:)];
    } else {
        NSMutableArray *channels = [_audioController.inputChannelSelection mutableCopy];
        [channels removeObject:@(sender.tag)];
        _audioController.inputChannelSelection = channels;
        sender.state = NSOffState;
    }
}

@end
