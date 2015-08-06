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
}

@property (nonatomic, strong) AEAudioController *audioController;
@property (nonatomic, strong) AEAudioFilePlayer *loop1;
@property (nonatomic, strong) AEAudioFilePlayer *loop2;
@property (nonatomic, strong) AEBlockChannel *oscillator;
@property (nonatomic, strong) AEAudioUnitChannel *audioUnitPlayer;
@property (nonatomic, strong) AEAudioFilePlayer *oneshot;
//@property (nonatomic, strong) AEPlaythroughChannel *playthrough;
@property (nonatomic, strong) AELimiterFilter *limiter;
@property (nonatomic, strong) AEExpanderFilter *expander;
@property (nonatomic, strong) AEAudioUnitFilter *reverb;
@property (nonatomic, strong) TPOscilloscopeLayer *outputOscilloscope;
@property (nonatomic, strong) TPOscilloscopeLayer *inputOscilloscope;
@property (nonatomic, strong) CALayer *inputLevelLayer;
@property (nonatomic, strong) CALayer *outputLevelLayer;
@property (nonatomic, weak) NSTimer *levelsTimer;
//@property (nonatomic, strong) AERecorder *recorder;
@property (nonatomic, strong) AEAudioFilePlayer *player;
@property (nonatomic, strong) NSButton *recordButton;
@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) NSButton *oneshotButton;
@property (nonatomic, strong) NSButton *oneshotAudioUnitButton;

@end

@implementation ViewController

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:CGRectMake(0, 0, 400, 600)];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _headerView = [[NSView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 100)];

    self.outputOscilloscope = [[TPOscilloscopeLayer alloc] initWithAudioController:_audioController];
    _outputOscilloscope.frame = CGRectMake(0, 500, _headerView.bounds.size.width, 80);
    [_headerView.layer addSublayer:_outputOscilloscope];
    [_audioController addOutputReceiver:_outputOscilloscope];
    [_outputOscilloscope start];
    
    self.inputOscilloscope = [[TPOscilloscopeLayer alloc] initWithAudioController:_audioController];
    _inputOscilloscope.frame = CGRectMake(0, 500, _headerView.bounds.size.width, 80);
    _inputOscilloscope.lineColor = [NSColor colorWithWhite:0.0 alpha:0.3];
    [_headerView.layer addSublayer:_inputOscilloscope];
    [_audioController addInputReceiver:_inputOscilloscope];
    [_inputOscilloscope start];
    
    self.inputLevelLayer = [CALayer layer];
    _inputLevelLayer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.3] CGColor];
    _inputLevelLayer.frame = CGRectMake(_headerView.bounds.size.width/2.0 - 5.0 - (0.0), 90, 0, 10);
    [_headerView.layer addSublayer:_inputLevelLayer];
    
    self.outputLevelLayer = [CALayer layer];
    _outputLevelLayer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.3] CGColor];
    _outputLevelLayer.frame = CGRectMake(_headerView.bounds.size.width/2.0 + 5.0, 90, 0, 10);
    [_headerView.layer addSublayer:_outputLevelLayer];
    
    [self.view addSubview:_headerView];
    
    _tableView = [[NSTableView alloc] initWithFrame:CGRectMake(0, 100, self.view.bounds.size.width, 400)];
    [self.view addSubview:_tableView];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    
    _nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"nameColumn"];
    _nameColumn.width = 400 / 2.0;
    [_tableView addTableColumn:_nameColumn];

    _sliderColumn = [[NSTableColumn alloc] initWithIdentifier:@"sliderColumn"];
    _sliderColumn.width = 400 / 2.0;
    [_tableView addTableColumn:_sliderColumn];
    
    NSView *footerView = [[NSView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 80)];

    self.recordButton = [[NSButton alloc] init];
    [self.recordButton setButtonType:NSPushOnPushOffButton];
    self.recordButton.title = @"Record";
    self.recordButton.action = @selector(record:);
    self.recordButton.target = self;
    self.recordButton.frame = CGRectMake(20, 10, (footerView.bounds.size.width - 50) / 2, footerView.bounds.size.height - 20);
    //    _recordButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleRightMargin;
    
    self.playButton = [[NSButton alloc] init];
    [self.playButton setButtonType:NSPushOnPushOffButton];
    self.playButton.title = @"Play";
    self.playButton.action = @selector(play:);
    self.playButton.target = self;
    self.playButton.frame = CGRectMake(CGRectGetMaxX(_recordButton.frame) + 10, 10, ((footerView.bounds.size.width - 50) / 2), footerView.bounds.size.height - 20);
    //    _playButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
    
    [footerView addSubview:self.recordButton];
    [footerView addSubview:self.playButton];

    [self.view addSubview:footerView];

}

- (instancetype)initWithAudioController:(AEAudioController *)audioController {
    if ( !(self = [super init]) ) return nil;
    
    self.audioController = audioController;
    
    // Create the first loop player
    self.loop1 = [AEAudioFilePlayer audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"Southern Rock Drums" withExtension:@"m4a"]
                                           audioController:_audioController
                                                     error:NULL];
    _loop1.volume = 1.0;
    _loop1.channelIsMuted = YES;
    _loop1.loop = YES;
    
    // Create the second loop player
    self.loop2 = [AEAudioFilePlayer audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"Southern Rock Organ" withExtension:@"m4a"]
                                           audioController:_audioController
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
            x -= 0.5;
            oscillatorPosition += oscillatorRate;
            if ( oscillatorPosition > 1.0 ) oscillatorPosition -= 2.0;
            ((float *)audio->mBuffers[0].mData)[i] = x;
            ((float *)audio->mBuffers[1].mData)[i] = x;
        }
    }];
    _oscillator.audioDescription = audioController.audioDescription;
//    _oscillator.audioDescription = [AEAudioController nonInterleaved16BitStereoAudioDescription];
    
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
    
//    if ( _playthrough ) {
//        [channelsToRemove addObject:_playthrough];
//        [_audioController removeInputReceiver:_playthrough];
//    }
    
    [_audioController removeChannels:channelsToRemove];
    
//    if ( _limiter ) {
//        [_audioController removeFilter:_limiter];
//    }
//    
//    if ( _expander ) {
//        [_audioController removeFilter:_expander];
//    }
    
    if ( _reverb ) {
        [_audioController removeFilter:_reverb];
    }
    
    if ( _audioUnitFile ) {
        AudioFileClose(_audioUnitFile);
    }
}

- (void)record:(id)sender {
    
}

- (void)play:(id)sender {

}

static inline float translate(float val, float min, float max) {
    if ( val < min ) val = min;
    if ( val > max ) val = max;
    return (val - min) / (max - min);
}

- (void)updateLevels:(id)sender {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    
    Float32 inputAvg, inputPeak, outputAvg, outputPeak;
    [_audioController inputAveragePowerLevel:&inputAvg peakHoldLevel:&inputPeak];
    [_audioController outputAveragePowerLevel:&outputAvg peakHoldLevel:&outputPeak];
    
    _inputLevelLayer.frame = CGRectMake(_headerView.bounds.size.width/2.0 - 5.0 - (translate(inputAvg, -20, 0) * (_headerView.bounds.size.width/2.0 - 15.0)),
                                        90,
                                        translate(inputAvg, -20, 0) * (_headerView.bounds.size.width/2.0 - 15.0),
                                        10);
    
    _outputLevelLayer.frame = CGRectMake(_headerView.bounds.size.width/2.0,
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
    return 13;
}

#pragma mark - NSTableViewDelegate

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return NO;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return 22;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSView *view;
    
    if ([tableColumn isEqualTo:_nameColumn]) {
        static NSString *nameIdentifier = @"nameItem";
        view = [tableView makeViewWithIdentifier:nameIdentifier owner:self];
        
        if (!view) {
            view = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 400, 20)];
            view.identifier = nameIdentifier;
        }
        NSButton *button = (NSButton *)view;
        button.bezelStyle = NSRoundRectBezelStyle;
        [button setButtonType:NSPushOnPushOffButton];
        
        switch (row) {
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
                button.state = NSOnState;
                break;
            case 4:
                button.title = @"One shot";
                [button setButtonType:NSMomentaryLightButton];
                break;
            case 5:
                button.title = @"One shot (audio unit)";
                [button setButtonType:NSMomentaryLightButton];
                break;
            case 6:
                button.title = @"Limiter";
                break;
            case 7:
                button.title = @"Expander";
                break;
            case 8:
                button.title = @"Reverb";
                break;
            case 9:
                button.title = @"Input Playthrough";
                break;
            case 10:
                button.title = @"Measurement Mode";
                break;
            case 11:
                button.title = @"Input Gain";
                break;
            case 12:
                button.title = @"Channels";
                break;
            default:
                button.title = @"";
                break;
        }
    } else if ([tableColumn isEqualTo:_sliderColumn]) {
        static NSString *sliderIdentifier = @"sliderItem";
        view = [tableView makeViewWithIdentifier:sliderIdentifier owner:self];
        
        if (!view) {
            view = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 400, 20)];
            view.identifier = sliderIdentifier;
        }
        NSSlider *slider = (NSSlider *)view;
        switch (row) {
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
                slider.doubleValue = 1.0;
                break;
            case 11:
                slider.enabled = NO;
                break;
            default:
                view = nil;
        }
    }
    return view;
    


//    switch ( indexPath.section ) {
//        case 0: {
//            cell.accessoryView = [[UISwitch alloc] initWithFrame:CGRectZero];
//            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(cell.bounds.size.width - (isiPad ? 250 : 210), 0, 100, cell.bounds.size.height)];
//            slider.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
//            slider.tag = kAuxiliaryViewTag;
//            slider.maximumValue = 1.0;
//            slider.minimumValue = 0.0;
//            [cell addSubview:slider];
//            
//            switch ( indexPath.row ) {
//                case 0: {
//                    cell.textLabel.text = @"Drums";
//                    ((UISwitch*)cell.accessoryView).on = !_loop1.channelIsMuted;
//                    slider.value = _loop1.volume;
//                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(loop1SwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    [slider addTarget:self action:@selector(loop1VolumeChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 1: {
//                    cell.textLabel.text = @"Organ";
//                    ((UISwitch*)cell.accessoryView).on = !_loop2.channelIsMuted;
//                    slider.value = _loop2.volume;
//                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(loop2SwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    [slider addTarget:self action:@selector(loop2VolumeChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 2: {
//                    cell.textLabel.text = @"Oscillator";
//                    ((UISwitch*)cell.accessoryView).on = !_oscillator.channelIsMuted;
//                    slider.value = _oscillator.volume;
//                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(oscillatorSwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    [slider addTarget:self action:@selector(oscillatorVolumeChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 3: {
//                    cell.textLabel.text = @"Group";
//                    ((UISwitch*)cell.accessoryView).on = ![_audioController channelGroupIsMuted:_group];
//                    slider.value = [_audioController volumeForChannelGroup:_group];
//                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(channelGroupSwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    [slider addTarget:self action:@selector(channelGroupVolumeChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//            }
//            break;
//        }
//        case 1: {
//            switch ( indexPath.row ) {
//                case 0: {
//                    cell.accessoryView = self.oneshotButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
//                    [_oneshotButton setTitle:@"Play" forState:UIControlStateNormal];
//                    [_oneshotButton setTitle:@"Stop" forState:UIControlStateSelected];
//                    [_oneshotButton sizeToFit];
//                    [_oneshotButton setSelected:_oneshot != nil];
//                    [_oneshotButton addTarget:self action:@selector(oneshotPlayButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
//                    cell.textLabel.text = @"One Shot";
//                    break;
//                }
//                case 1: {
//                    cell.accessoryView = self.oneshotAudioUnitButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
//                    [_oneshotAudioUnitButton setTitle:@"Play" forState:UIControlStateNormal];
//                    [_oneshotAudioUnitButton setTitle:@"Stop" forState:UIControlStateSelected];
//                    [_oneshotAudioUnitButton sizeToFit];
//                    [_oneshotAudioUnitButton setSelected:_oneshot != nil];
//                    [_oneshotAudioUnitButton addTarget:self action:@selector(oneshotAudioUnitPlayButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
//                    cell.textLabel.text = @"One Shot (Audio Unit)";
//                    break;
//                }
//            }
//            break;
//        }
//        case 2: {
//            cell.accessoryView = [[UISwitch alloc] initWithFrame:CGRectZero];
//            
//            switch ( indexPath.row ) {
//                case 0: {
//                    cell.textLabel.text = @"Limiter";
//                    ((UISwitch*)cell.accessoryView).on = _limiter != nil;
//                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(limiterSwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 1: {
//                    cell.textLabel.text = @"Expander";
//                    ((UISwitch*)cell.accessoryView).on = _expander != nil;
//                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(expanderSwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 2: {
//                    cell.textLabel.text = @"Reverb";
//                    ((UISwitch*)cell.accessoryView).on = _reverb != nil;
//                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(reverbSwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//            }
//            break;
//        }
//        case 3: {
//            cell.accessoryView = [[UISwitch alloc] initWithFrame:CGRectZero];
//            
//            switch ( indexPath.row ) {
//                case 0: {
//                    cell.textLabel.text = @"Input Playthrough";
//                    ((UISwitch*)cell.accessoryView).on = _playthrough != nil;
//                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(playthroughSwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 1: {
//                    cell.textLabel.text = @"Measurement Mode";
//                    ((UISwitch*)cell.accessoryView).on = _audioController.useMeasurementMode;
//                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(measurementModeSwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 2: {
//                    cell.textLabel.text = @"Input Gain";
//                    UISlider *inputGainSlider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
//                    inputGainSlider.minimumValue = 0.0;
//                    inputGainSlider.maximumValue = 1.0;
//                    inputGainSlider.value = _audioController.inputGain;
//                    [inputGainSlider addTarget:self action:@selector(inputGainSliderChanged:) forControlEvents:UIControlEventValueChanged];
//                    cell.accessoryView = inputGainSlider;
//                    break;
//                }
//                case 3: {
//                    cell.textLabel.text = @"Channels";
//                    
//                    int channelCount = _audioController.numberOfInputChannels;
//                    CGSize buttonSize = CGSizeMake(30, 30);
//                    
//                    UIScrollView *channelStrip = [[UIScrollView alloc] initWithFrame:CGRectMake(0,
//                                                                                                0,
//                                                                                                MIN(channelCount * (buttonSize.width+5) + 5,
//                                                                                                    isiPad ? 400 : 200),
//                                                                                                cell.bounds.size.height)];
//                    channelStrip.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
//                    channelStrip.backgroundColor = [UIColor clearColor];
//                    
//                    for ( int i=0; i<channelCount; i++ ) {
//                        UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
//                        button.frame = CGRectMake(i*(buttonSize.width+5), round((channelStrip.bounds.size.height-buttonSize.height)/2), buttonSize.width, buttonSize.height);
//                        [button setTitle:[NSString stringWithFormat:@"%d", i+1] forState:UIControlStateNormal];
//                        button.highlighted = [_audioController.inputChannelSelection containsObject:@(i)];
//                        button.tag = i;
//                        [button addTarget:self action:@selector(channelButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
//                        [channelStrip addSubview:button];
//                    }
//                    
//                    channelStrip.contentSize = CGSizeMake(channelCount * (buttonSize.width+5) + 5, channelStrip.bounds.size.height);
//                    
//                    cell.accessoryView = channelStrip;
//                    
//                    break;
//                }
//            }
//            break;
//        }
//            
//    }
//    
//    return cell;
}

- (void)loop1SwitchChanged:(NSButton *)sender {
    _loop1.channelIsMuted = (sender.state == NSOffState);
}

- (void)loop1VolumeChanged:(NSSlider *)sender {
    BOOL muted = _loop1.channelIsMuted;
    _loop1.volume = sender.doubleValue;
    _loop1.channelIsMuted = muted;
}

- (void)loop2SwitchChanged:(NSButton *)sender {
    _loop2.channelIsMuted = (sender.state == NSOffState);
}

- (void)loop2VolumeChanged:(NSSlider *)sender {
    BOOL muted = _loop2.channelIsMuted;
    _loop2.volume = sender.doubleValue;
    _loop2.channelIsMuted = muted;
}

- (void)oscillatorSwitchChanged:(NSButton *)sender {
    _oscillator.channelIsMuted = (sender.state == NSOffState);
}

- (void)oscillatorVolumeChanged:(NSButton *)sender {
    BOOL muted = _oscillator.channelIsMuted;
    _oscillator.volume = sender.doubleValue;
    _oscillator.channelIsMuted = muted;
}

- (void)channelGroupSwitchChanged:(NSButton *)sender {
    BOOL isOn = (sender.state == NSOnState);
    [_audioController setMuted:isOn forChannelGroup:_group];
}

- (void)channelGroupVolumeChanged:(NSSlider *)sender {
    [_audioController setVolume:sender.doubleValue forChannelGroup:_group];
}

//- (void)oneshotPlayButtonPressed:(NSButton *)sender {
//    if ( _oneshot ) {
//        [_audioController removeChannels:@[_oneshot]];
//        self.oneshot = nil;
//        _oneshotButton.selected = NO;
//    } else {
//        self.oneshot = [AEAudioFilePlayer audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"Organ Run" withExtension:@"m4a"]
//                                                 audioController:_audioController
//                                                           error:NULL];
//        _oneshot.removeUponFinish = YES;
//        __weak ViewController *weakSelf = self;
//        _oneshot.completionBlock = ^{
//            ViewController *strongSelf = weakSelf;
//            strongSelf.oneshot = nil;
//            strongSelf->_oneshotButton.selected = NO;
//        };
//        [_audioController addChannels:@[_oneshot]];
//        _oneshotButton.selected = YES;
//    }
//}
//
//- (void)oneshotAudioUnitPlayButtonPressed:(UIButton*)sender {
//    if ( !_audioUnitFile ) {
//        NSURL *playerFile = [[NSBundle mainBundle] URLForResource:@"Organ Run" withExtension:@"m4a"];
//        checkResult(AudioFileOpenURL((__bridge CFURLRef)playerFile, kAudioFileReadPermission, 0, &_audioUnitFile), "AudioFileOpenURL");
//    }
//    
//    // Set the file to play
//    checkResult(AudioUnitSetProperty(_audioUnitPlayer.audioUnit, kAudioUnitProperty_ScheduledFileIDs, kAudioUnitScope_Global, 0, &_audioUnitFile, sizeof(_audioUnitFile)),
//                "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileIDs)");
//    
//    // Determine file properties
//    UInt64 packetCount;
//    UInt32 size = sizeof(packetCount);
//    checkResult(AudioFileGetProperty(_audioUnitFile, kAudioFilePropertyAudioDataPacketCount, &size, &packetCount),
//                "AudioFileGetProperty(kAudioFilePropertyAudioDataPacketCount)");
//    
//    AudioStreamBasicDescription dataFormat;
//    size = sizeof(dataFormat);
//    checkResult(AudioFileGetProperty(_audioUnitFile, kAudioFilePropertyDataFormat, &size, &dataFormat),
//                "AudioFileGetProperty(kAudioFilePropertyDataFormat)");
//    
//    // Assign the region to play
//    ScheduledAudioFileRegion region;
//    memset (&region.mTimeStamp, 0, sizeof(region.mTimeStamp));
//    region.mTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
//    region.mTimeStamp.mSampleTime = 0;
//    region.mCompletionProc = NULL;
//    region.mCompletionProcUserData = NULL;
//    region.mAudioFile = _audioUnitFile;
//    region.mLoopCount = 0;
//    region.mStartFrame = 0;
//    region.mFramesToPlay = (UInt32)packetCount * dataFormat.mFramesPerPacket;
//    checkResult(AudioUnitSetProperty(_audioUnitPlayer.audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region)),
//                "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)");
//    
//    // Prime the player by reading some frames from disk
//    UInt32 defaultNumberOfFrames = 0;
//    checkResult(AudioUnitSetProperty(_audioUnitPlayer.audioUnit, kAudioUnitProperty_ScheduledFilePrime, kAudioUnitScope_Global, 0, &defaultNumberOfFrames, sizeof(defaultNumberOfFrames)),
//                "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFilePrime)");
//    
//    // Set the start time (now = -1)
//    AudioTimeStamp startTime;
//    memset (&startTime, 0, sizeof(startTime));
//    startTime.mFlags = kAudioTimeStampSampleTimeValid;
//    startTime.mSampleTime = -1;
//    checkResult(AudioUnitSetProperty(_audioUnitPlayer.audioUnit, kAudioUnitProperty_ScheduleStartTimeStamp, kAudioUnitScope_Global, 0, &startTime, sizeof(startTime)),
//                "AudioUnitSetProperty(kAudioUnitProperty_ScheduleStartTimeStamp)");
//    
//}
//
//- (void)playthroughSwitchChanged:(UISwitch*)sender {
//    if ( sender.isOn ) {
//        self.playthrough = [[AEPlaythroughChannel alloc] initWithAudioController:_audioController];
//        [_audioController addInputReceiver:_playthrough];
//        [_audioController addChannels:@[_playthrough]];
//    } else {
//        [_audioController removeChannels:@[_playthrough]];
//        [_audioController removeInputReceiver:_playthrough];
//        self.playthrough = nil;
//    }
//}
//
//- (void)measurementModeSwitchChanged:(UISwitch*)sender {
//    _audioController.useMeasurementMode = sender.on;
//}

//-(void)inputGainSliderChanged:(NSSlider *)slider {
//    _audioController.inputGain = slider.doubleValue;
//}

- (void)limiterSwitchChanged:(NSButton *)sender {
    BOOL isOn = (sender.state == NSOnState);
    if ( isOn ) {
        self.limiter = [[AELimiterFilter alloc] initWithAudioController:_audioController];
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
        self.expander = [[AEExpanderFilter alloc] initWithAudioController:_audioController];
        [_audioController addFilter:_expander];
    } else {
        [_audioController removeFilter:_expander];
        self.expander = nil;
    }
}

//- (void)reverbSwitchChanged:(NSButton *)sender {
//    BOOL isOn = (sender.state == NSOnState);
//    if ( isOn ) {
//        self.reverb = [[AEAudioUnitFilter alloc] initWithComponentDescription:AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Effect, kAudioUnitSubType_Reverb2) preInitializeBlock:^(AudioUnit audioUnit) {
//            AudioUnitSetParameter(audioUnit, kReverb2Param_DryWetMix, kAudioUnitScope_Global, 0, 100.f, 0);
//        }];
//        
//        [_audioController addFilter:_reverb];
//    } else {
//        [_audioController removeFilter:_reverb];
//        self.reverb = nil;
//    }
//}
//
//- (void)channelButtonPressed:(UIButton*)sender {
//    BOOL selected = [_audioController.inputChannelSelection containsObject:@(sender.tag)];
//    selected = !selected;
//    if ( selected ) {
//        _audioController.inputChannelSelection = [[_audioController.inputChannelSelection arrayByAddingObject:@(sender.tag)] sortedArrayUsingSelector:@selector(compare:)];
//        [self performSelector:@selector(highlightButtonDelayed:) withObject:sender afterDelay:0.01];
//    } else {
//        NSMutableArray *channels = [_audioController.inputChannelSelection mutableCopy];
//        [channels removeObject:@(sender.tag)];
//        _audioController.inputChannelSelection = channels;
//        sender.highlighted = NO;
//    }
//}



@end
