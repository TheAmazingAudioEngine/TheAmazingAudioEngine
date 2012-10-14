//
//  ViewController.m
//  Audio Controller Test Suite
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "ViewController.h"
#import "TheAmazingAudioEngine.h"
#import "TPOscilloscopeLayer.h"
#import "AEPlaythroughChannel.h"
#import "AEExpanderFilter.h"
#import "AELimiterFilter.h"
#import "AERecorder.h"
#import <QuartzCore/QuartzCore.h>

#define kAuxiliaryViewTag 251


@interface ViewController ()
@property (nonatomic, retain) AEAudioController *audioController;
@property (nonatomic, retain) AEAudioFilePlayer *loop1;
@property (nonatomic, retain) AEAudioFilePlayer *loop2;
@property (nonatomic, retain) AEAudioFilePlayer *oneshot;
@property (nonatomic, retain) AEPlaythroughChannel *playthrough;
@property (nonatomic, retain) AELimiterFilter *limiter;
@property (nonatomic, retain) AEExpanderFilter *expander;
@property (nonatomic, retain) TPOscilloscopeLayer *outputOscilloscope;
@property (nonatomic, retain) TPOscilloscopeLayer *inputOscilloscope;
@property (nonatomic, retain) CALayer *inputLevelLayer;
@property (nonatomic, retain) CALayer *outputLevelLayer;
@property (nonatomic, assign) NSTimer *levelsTimer;
@property (nonatomic, retain) AERecorder *recorder;
@property (nonatomic, retain) AEAudioFilePlayer *player;
@property (nonatomic, retain) UIButton *recordButton;
@property (nonatomic, retain) UIButton *playButton;
@property (nonatomic, retain) UIButton *oneshotButton;
@end

@implementation ViewController

@synthesize audioController = _audioController;
@synthesize loop1 = _loop1;
@synthesize loop2 = _loop2;
@synthesize oneshot = _oneshot;
@synthesize playthrough = _playthrough;
@synthesize limiter = _limiter;
@synthesize expander = _expander;
@synthesize outputOscilloscope = _outputOscilloscope;
@synthesize inputOscilloscope = _inputOscilloscope;
@synthesize inputLevelLayer = _inputLevelLayer;
@synthesize outputLevelLayer = _outputLevelLayer;
@synthesize levelsTimer = _levelsTimer;
@synthesize recorder = _recorder;
@synthesize player = _player;
@synthesize recordButton = _recordButton;
@synthesize playButton = _playButton;
@synthesize oneshotButton = _oneshotButton;

- (id)initWithAudioController:(AEAudioController*)audioController {
    if ( !(self = [super initWithStyle:UITableViewStyleGrouped]) ) return nil;
    
    self.audioController = audioController;
    
    self.loop1 = [AEAudioFilePlayer audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"Southern Rock Drums" withExtension:@"m4a"]
                                           audioController:_audioController
                                                     error:NULL];
    _loop1.volume = 1.0;
    _loop1.channelIsMuted = YES;
    _loop1.loop = YES;
    
    self.loop2 = [AEAudioFilePlayer audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"Southern Rock Organ" withExtension:@"m4a"]
                                           audioController:_audioController
                                                     error:NULL];
    _loop2.volume = 1.0;
    _loop2.channelIsMuted = YES;
    _loop2.loop = YES;
        
    [_audioController addChannels:[NSArray arrayWithObjects:_loop1, _loop2, nil]];
    
    return self;
}

-(void)dealloc {
    if ( _levelsTimer ) [_levelsTimer invalidate];

    NSMutableArray *channelsToRemove = [NSMutableArray arrayWithObjects:_loop1, _loop2, nil];
    
    self.loop1 = nil;
    self.loop2 = nil;
    
    if ( _player ) {
        [channelsToRemove addObject:_player];
        self.player = nil;
    }
    
    if ( _oneshot ) {
        [channelsToRemove addObject:_oneshot];
        self.oneshot = nil;
    }
    
    if ( _playthrough ) {
        [channelsToRemove addObject:_playthrough];
        [_audioController removeInputReceiver:_playthrough];
        self.playthrough = nil;
    }
    
    [_audioController removeChannels:channelsToRemove];
    
    if ( _limiter ) {
        [_audioController removeFilter:_limiter];
        self.limiter = nil;
    }
    
    if ( _expander ) {
        [_audioController removeFilter:_expander];
        self.expander = nil;
    }
    
    self.recorder = nil;
    self.recordButton = nil;
    self.playButton = nil;
    self.oneshotButton = nil;
    self.outputOscilloscope = nil;
    self.inputOscilloscope = nil;
    self.inputLevelLayer = nil;
    self.outputLevelLayer = nil;
    self.audioController = nil;
    
    [super dealloc];
}

-(void)viewDidLoad {
    [super viewDidLoad];
    
    UIView *headerView = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 100)] autorelease];
    headerView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    
    self.outputOscilloscope = [[[TPOscilloscopeLayer alloc] init] autorelease];
    _outputOscilloscope.frame = CGRectMake(0, 0, headerView.bounds.size.width, 80);
    [headerView.layer addSublayer:_outputOscilloscope];
    [_audioController addOutputReceiver:_outputOscilloscope];
    [_outputOscilloscope start];
    
    self.inputOscilloscope = [[[TPOscilloscopeLayer alloc] init] autorelease];
    _inputOscilloscope.frame = CGRectMake(0, 0, headerView.bounds.size.width, 80);
    _inputOscilloscope.lineColor = [UIColor colorWithWhite:0.0 alpha:0.3];
    [headerView.layer addSublayer:_inputOscilloscope];
    [_audioController addInputReceiver:_inputOscilloscope];
    [_inputOscilloscope start];
    
    self.inputLevelLayer = [CALayer layer];
    _inputLevelLayer.backgroundColor = [[UIColor colorWithWhite:0.0 alpha:0.3] CGColor];
    _inputLevelLayer.frame = CGRectMake(headerView.bounds.size.width/2.0 - 5.0 - (0.0), 90, 0, 10);
    [headerView.layer addSublayer:_inputLevelLayer];
    
    self.outputLevelLayer = [CALayer layer];
    _outputLevelLayer.backgroundColor = [[UIColor colorWithWhite:0.0 alpha:0.3] CGColor];
    _outputLevelLayer.frame = CGRectMake(headerView.bounds.size.width/2.0 + 5.0, 90, 0, 10);
    [headerView.layer addSublayer:_outputLevelLayer];
    
    self.tableView.tableHeaderView = headerView;
    
    UIView *footerView = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 80)] autorelease];
    self.recordButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    [_recordButton setTitle:@"Record" forState:UIControlStateNormal];
    [_recordButton setTitle:@"Stop" forState:UIControlStateSelected];
    [_recordButton addTarget:self action:@selector(record:) forControlEvents:UIControlEventTouchUpInside];
    _recordButton.frame = CGRectMake(10, 10, ((footerView.bounds.size.width-30) / 2), footerView.bounds.size.height - 20);
    self.playButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    [_playButton setTitle:@"Play" forState:UIControlStateNormal];
    [_playButton setTitle:@"Stop" forState:UIControlStateSelected];
    [_playButton addTarget:self action:@selector(play:) forControlEvents:UIControlEventTouchUpInside];
    _playButton.frame = CGRectMake(_recordButton.frame.origin.x+_recordButton.frame.size.width+10, 10, ((footerView.bounds.size.width-30) / 2), footerView.bounds.size.height - 20);
    [footerView addSubview:_recordButton];
    [footerView addSubview:_playButton];
    self.tableView.tableFooterView = footerView;
}

-(void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.levelsTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(updateLevels:) userInfo:nil repeats:YES];
}

-(void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_levelsTimer invalidate];
    self.levelsTimer = nil;
}

-(BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation {
    return YES;
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ( section ) {
        case 0:
            return 2;
            
        case 1:
            return 1;
            
        case 2:
            return 2;
            
        case 3:
            return 1;
            
        default:
            return 0;
    }
}

-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    
    if ( !cell ) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellIdentifier] autorelease];
    }
    
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    [[cell viewWithTag:kAuxiliaryViewTag] removeFromSuperview];
    
    switch ( indexPath.section ) {
        case 0: {
            cell.accessoryView = [[[UISwitch alloc] initWithFrame:CGRectZero] autorelease];
            UISlider *slider = [[[UISlider alloc] initWithFrame:CGRectMake(cell.bounds.size.width - cell.accessoryView.frame.size.width - 20 - 100, 0, 100, cell.bounds.size.height)] autorelease];
            slider.tag = kAuxiliaryViewTag;
            slider.maximumValue = 1.0;
            slider.minimumValue = 0.0;
            [cell addSubview:slider];
            
            switch ( indexPath.row ) {
                case 0: {
                    cell.textLabel.text = @"Drums";
                    ((UISwitch*)cell.accessoryView).on = !_loop1.channelIsMuted;
                    slider.value = _loop1.volume;
                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(loop1SwitchChanged:) forControlEvents:UIControlEventValueChanged];
                    [slider addTarget:self action:@selector(loop1VolumeChanged:) forControlEvents:UIControlEventValueChanged];
                    break;
                }
                case 1: {
                    cell.textLabel.text = @"Organ";
                    ((UISwitch*)cell.accessoryView).on = !_loop2.channelIsMuted;
                    slider.value = _loop2.volume;
                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(loop2SwitchChanged:) forControlEvents:UIControlEventValueChanged];
                    [slider addTarget:self action:@selector(loop2VolumeChanged:) forControlEvents:UIControlEventValueChanged];
                    break;
                }
            }
            break;
        } 
        case 1: {
            cell.accessoryView = self.oneshotButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
            [_oneshotButton setTitle:@"Play" forState:UIControlStateNormal];
            [_oneshotButton setTitle:@"Stop" forState:UIControlStateSelected];
            [_oneshotButton sizeToFit];
            [_oneshotButton setSelected:_oneshot != nil];
            [_oneshotButton addTarget:self action:@selector(oneshotPlayButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
            cell.textLabel.text = @"One Shot";
            break;
        }
        case 2: {
            cell.accessoryView = [[[UISwitch alloc] initWithFrame:CGRectZero] autorelease];
            
            switch ( indexPath.row ) {
                case 0: {
                    cell.textLabel.text = @"Limiter";
                    ((UISwitch*)cell.accessoryView).on = _limiter != nil;
                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(limiterSwitchChanged:) forControlEvents:UIControlEventValueChanged];
                    break;
                }
                case 1: {
                    cell.textLabel.text = @"Expander";
                    ((UISwitch*)cell.accessoryView).on = _expander != nil;
                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(expanderSwitchChanged:) forControlEvents:UIControlEventValueChanged];
                    break;
                }
            }
            break;
        }
        case 3: {
            cell.accessoryView = [[[UISwitch alloc] initWithFrame:CGRectZero] autorelease];
            
            switch ( indexPath.row ) {
                case 0: {
                    cell.textLabel.text = @"Input Playthrough";
                    ((UISwitch*)cell.accessoryView).on = _playthrough != nil;
                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(playthroughSwitchChanged:) forControlEvents:UIControlEventValueChanged];
                    break;
                }
            }
            break;
        }
            
    }
    
    return cell;
}

- (void)loop1SwitchChanged:(UISwitch*)sender {
    _loop1.channelIsMuted = !sender.isOn;
}

- (void)loop1VolumeChanged:(UISlider*)sender {
    _loop1.volume = sender.value;
}

- (void)loop2SwitchChanged:(UISwitch*)sender {
    _loop2.channelIsMuted = !sender.isOn;
}

- (void)loop2VolumeChanged:(UISlider*)sender {
    _loop2.volume = sender.value;
}

- (void)oneshotPlayButtonPressed:(UIButton*)sender {
    if ( _oneshot ) {
        [_audioController removeChannels:[NSArray arrayWithObject:_oneshot]];
        self.oneshot = nil;
        _oneshotButton.selected = NO;
    } else {
        self.oneshot = [AEAudioFilePlayer audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"Organ Run" withExtension:@"m4a"]
                                                 audioController:_audioController
                                                           error:NULL];
        _oneshot.removeUponFinish = YES;
        _oneshot.completionBlock = ^{
            self.oneshot = nil;
            _oneshotButton.selected = NO;
        };
        [_audioController addChannels:[NSArray arrayWithObject:_oneshot]];
        _oneshotButton.selected = YES;
    }
}

- (void)playthroughSwitchChanged:(UISwitch*)sender {
    if ( sender.isOn ) {
        self.playthrough = [[[AEPlaythroughChannel alloc] initWithAudioController:_audioController] autorelease];
        [_audioController addInputReceiver:_playthrough];
        [_audioController addChannels:[NSArray arrayWithObject:_playthrough]];
    } else {
        [_audioController removeChannels:[NSArray arrayWithObject:_playthrough]];
        [_audioController removeInputReceiver:_playthrough];
        self.playthrough = nil;
    }
}

- (void)limiterSwitchChanged:(UISwitch*)sender {
    if ( sender.isOn ) {
        self.limiter = [[[AELimiterFilter alloc] init] autorelease];
        _limiter.level = INT16_MAX * 0.1;
        [_audioController addFilter:_limiter];
    } else {
        [_audioController removeFilter:_limiter];
        self.limiter = nil;
    }
}

- (void)expanderSwitchChanged:(UISwitch*)sender {
    if ( sender.isOn ) {
        self.expander = [[[AEExpanderFilter alloc] init] autorelease];
        [_audioController addFilter:_expander];
    } else {
        [_audioController removeFilter:_expander];
        self.expander = nil;
    }
}

- (void)record:(id)sender {
    if ( _recorder ) {
        [_recorder finishRecording];
        [_audioController removeOutputReceiver:_recorder];
        [_audioController removeInputReceiver:_recorder];
        self.recorder = nil;
        _recordButton.selected = NO;
    } else {
        self.recorder = [[[AERecorder alloc] initWithAudioController:_audioController] autorelease];
        NSArray *documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *path = [[documentsFolders objectAtIndex:0] stringByAppendingPathComponent:@"Recording.aiff"];
        NSError *error = nil;
        if ( ![_recorder beginRecordingToFileAtPath:path fileType:kAudioFileAIFFType error:&error] ) {
            [[[[UIAlertView alloc] initWithTitle:@"Error" 
                                         message:[NSString stringWithFormat:@"Couldn't start recording: %@", [error localizedDescription]]
                                        delegate:nil
                               cancelButtonTitle:nil
                               otherButtonTitles:@"OK", nil] autorelease] show];
            self.recorder = nil;
            return;
        }
        
        _recordButton.selected = YES;
        
        [_audioController addOutputReceiver:_recorder];
        [_audioController addInputReceiver:_recorder];
    }
}

- (void)play:(id)sender {
    if ( _player ) {
        [_audioController removeChannels:[NSArray arrayWithObject:_player]];
        self.player = nil;
        _playButton.selected = NO;
    } else {
        NSArray *documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *path = [[documentsFolders objectAtIndex:0] stringByAppendingPathComponent:@"Recording.aiff"];
        
        if ( ![[NSFileManager defaultManager] fileExistsAtPath:path] ) return;
        
        NSError *error = nil;
        self.player = [AEAudioFilePlayer audioFilePlayerWithURL:[NSURL fileURLWithPath:path] audioController:_audioController error:&error];
        
        if ( !_player ) {
            [[[[UIAlertView alloc] initWithTitle:@"Error" 
                                         message:[NSString stringWithFormat:@"Couldn't start playback: %@", [error localizedDescription]]
                                        delegate:nil
                               cancelButtonTitle:nil
                               otherButtonTitles:@"OK", nil] autorelease] show];
            return;
        }
        
        _player.removeUponFinish = YES;
        _player.completionBlock = ^{
            _playButton.selected = NO;
            self.player = nil;
        };
        [_audioController addChannels:[NSArray arrayWithObject:_player]];
        
        _playButton.selected = YES;
    }
}

static inline float translate(float val, float min, float max) {
    if ( val < min ) val = min;
    if ( val > max ) val = max;
    return (val - min) / (max - min);
}

- (void)updateLevels:(NSTimer*)timer {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    
    Float32 inputAvg, inputPeak, outputAvg, outputPeak;
    [_audioController inputAveragePowerLevel:&inputAvg peakHoldLevel:&inputPeak];
    [_audioController outputAveragePowerLevel:&outputAvg peakHoldLevel:&outputPeak];
    UIView *headerView = self.tableView.tableHeaderView;
    
    _inputLevelLayer.frame = CGRectMake(headerView.bounds.size.width/2.0 - 5.0 - (translate(inputAvg, -20, 0) * (headerView.bounds.size.width/2.0 - 15.0)),
                                        90,
                                        translate(inputAvg, -20, 0) * (headerView.bounds.size.width/2.0 - 15.0),
                                        10);
    
    _outputLevelLayer.frame = CGRectMake(headerView.bounds.size.width/2.0,
                                         _outputLevelLayer.frame.origin.y, 
                                         translate(outputAvg, -20, 0) * (headerView.bounds.size.width/2.0 - 15.0),
                                         10);
    
    [CATransaction commit];
}

@end
