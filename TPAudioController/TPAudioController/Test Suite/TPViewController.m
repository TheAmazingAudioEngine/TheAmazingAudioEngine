//
//  TPViewController.m
//  Audio Controller Test Suite
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "TPViewController.h"
#import <TPAudioController/TPAudioController.h>
#import "TPAudioFilePlayer.h"
#import "TPOscilloscopeLayer.h"
#import "TPConvolutionFilter.h"
#import <QuartzCore/QuartzCore.h>

#define kAuxiliaryViewTag 251

@interface TPViewController () {
    TPChannelGroup _loopsGroup;
}

@property (nonatomic, retain) TPAudioController *audioController;
@property (nonatomic, retain) TPAudioFilePlayer *loop1;
@property (nonatomic, retain) TPAudioFilePlayer *loop2;
@property (nonatomic, retain) TPAudioFilePlayer *loop3;
@property (nonatomic, retain) TPAudioFilePlayer *sample1;
@property (nonatomic, retain) TPConvolutionFilter *filter;
@property (nonatomic, retain) TPOscilloscopeLayer *outputOscilloscope;
@property (nonatomic, retain) TPOscilloscopeLayer *inputOscilloscope;
@end

@implementation TPViewController
@synthesize audioController=_audioController,
            loop1=_loop1,
            loop2=_loop2,
            loop3=_loop3,
            sample1=_sample1,
            filter=_filter,
            outputOscilloscope=_outputOscilloscope,
            inputOscilloscope=_inputOscilloscope;

- (id)initWithAudioController:(TPAudioController*)audioController {
    if ( !(self = [super initWithStyle:UITableViewStyleGrouped]) ) return nil;
    
    self.audioController = audioController;
    
    self.loop1 = [TPAudioFilePlayer audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"caitlin" withExtension:@"caf"]
                                           audioController:_audioController
                                                     error:NULL];
    _loop1.volume = 1.0;
    _loop1.muted = YES;
    _loop1.loop = YES;
    
    self.loop2 = [TPAudioFilePlayer audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"congaloop" withExtension:@"caf"]
                                           audioController:_audioController
                                                     error:NULL];
    _loop2.volume = 1.0;
    _loop2.muted = YES;
    _loop2.loop = YES;
    
    self.loop3 = [TPAudioFilePlayer audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"dmxbeat" withExtension:@"aiff"]
                                           audioController:_audioController
                                                     error:NULL];
    _loop3.volume = 1.0;
    _loop3.muted = YES;
    _loop3.loop = YES;
    
    _loopsGroup = [_audioController createChannelGroup];
    [_audioController addChannels:[NSArray arrayWithObjects:_loop1, _loop2, _loop3, nil] toChannelGroup:_loopsGroup];
    
    self.tableView.scrollEnabled = NO;
    
    return self;
}

-(void)dealloc {
    NSMutableArray *channelsToRemove = [NSMutableArray arrayWithObjects:_loop1, _loop2, _loop3, nil];

    self.loop1 = nil;
    self.loop2 = nil;
    self.loop3 = nil;
    
    if ( _sample1 ) {
        [channelsToRemove addObject:_sample1];
        [_sample1 removeObserver:self forKeyPath:@"playing"];
        self.sample1 = nil;
    }
    
    if ( [channelsToRemove count] > 0 ) {
        [_audioController removeChannels:channelsToRemove];
    }
    
    [_audioController removeChannelGroup:_loopsGroup];
    
    if ( _filter ) {
        [_audioController removeFilter:_filter.callback userInfo:_filter];
        self.filter = nil;
    }
    
    self.outputOscilloscope = nil;
    self.inputOscilloscope = nil;
    
    self.audioController = nil;

    [super dealloc];
}

-(void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    UIView *oscilloscopeHostView = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 100)] autorelease];
    oscilloscopeHostView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    
    self.outputOscilloscope = [[[TPOscilloscopeLayer alloc] init] autorelease];
    _outputOscilloscope.frame = oscilloscopeHostView.bounds;
    [oscilloscopeHostView.layer addSublayer:_outputOscilloscope];
    [_audioController addOutputCallback:_outputOscilloscope.callback userInfo:_outputOscilloscope];
    [_outputOscilloscope start];
    
    self.inputOscilloscope = [[[TPOscilloscopeLayer alloc] init] autorelease];
    _inputOscilloscope.frame = oscilloscopeHostView.bounds;
    _inputOscilloscope.lineColor = [UIColor colorWithWhite:0.0 alpha:0.3];
    [oscilloscopeHostView.layer addSublayer:_inputOscilloscope];
    [_audioController addInputCallback:_inputOscilloscope.callback userInfo:_inputOscilloscope];
    [_inputOscilloscope start];
    
    self.tableView.tableHeaderView = oscilloscopeHostView;
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ( section ) {
        case 0:
            return 3;
            break;
            
        case 1:
            return 1;
            
        case 2:
            return 1;
    }
    return 0;
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
                    cell.textLabel.text = @"Loop 1";
                    ((UISwitch*)cell.accessoryView).on = !_loop1.muted;
                    slider.value = _loop1.volume;
                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(loop1SwitchChanged:) forControlEvents:UIControlEventValueChanged];
                    [slider addTarget:self action:@selector(loop1VolumeChanged:) forControlEvents:UIControlEventValueChanged];
                    break;
                }
                case 1: {
                    cell.textLabel.text = @"Loop 2";
                    ((UISwitch*)cell.accessoryView).on = !_loop2.muted;
                    slider.value = _loop2.volume;
                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(loop2SwitchChanged:) forControlEvents:UIControlEventValueChanged];
                    [slider addTarget:self action:@selector(loop2VolumeChanged:) forControlEvents:UIControlEventValueChanged];
                    break;
                }
                case 2: {
                    cell.textLabel.text = @"Loop 3";
                    ((UISwitch*)cell.accessoryView).on = !_loop3.muted;
                    slider.value = _loop3.volume;
                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(loop3SwitchChanged:) forControlEvents:UIControlEventValueChanged];
                    [slider addTarget:self action:@selector(loop3VolumeChanged:) forControlEvents:UIControlEventValueChanged];
                    break;
                }
            }
            break;
        } 
        case 1: {
            cell.accessoryView = [UIButton buttonWithType:UIButtonTypeRoundedRect];
            [(UIButton*)cell.accessoryView setTitle:@"Play" forState:UIControlStateNormal];
            [(UIButton*)cell.accessoryView setTitle:@"Stop" forState:UIControlStateSelected];
            [(UIButton*)cell.accessoryView sizeToFit];
            
            switch ( indexPath.row ) {
                case 0: {
                    cell.textLabel.text = @"Sample 1";
                    [(UIButton*)cell.accessoryView setSelected:_sample1 != nil];
                    [(UIButton*)cell.accessoryView addTarget:self action:@selector(sample1PlayButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
                }
            }
            break;
        }
        case 2: {
            cell.accessoryView = [[[UISwitch alloc] initWithFrame:CGRectZero] autorelease];
            
            switch ( indexPath.row ) {
                case 0: {
                    cell.textLabel.text = @"Reverb";
                    ((UISwitch*)cell.accessoryView).on = _filter != nil;
                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(filterSwitchChanged:) forControlEvents:UIControlEventValueChanged];
                }
            }
            break;
        }
            
    }
    
    return cell;
}

-(void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    
}

- (void)loop1SwitchChanged:(UISwitch*)sender {
    _loop1.muted = !sender.isOn;
}

- (void)loop1VolumeChanged:(UISlider*)sender {
    _loop1.volume = sender.value;
}

- (void)loop2SwitchChanged:(UISwitch*)sender {
    _loop2.muted = !sender.isOn;
}

- (void)loop2VolumeChanged:(UISlider*)sender {
    _loop2.volume = sender.value;
}

- (void)loop3SwitchChanged:(UISwitch*)sender {
    _loop3.muted = !sender.isOn;
}

- (void)loop3VolumeChanged:(UISlider*)sender {
    _loop3.volume = sender.value;
}

- (void)sample1PlayButtonPressed:(UIButton*)sender {
    if ( _sample1 ) {
        [_audioController removeChannels:[NSArray arrayWithObject:_sample1]];
        [_sample1 removeObserver:self forKeyPath:@"playing"];
        self.sample1 = nil;
        [sender setSelected:NO];
    } else {
        self.sample1 = [TPAudioFilePlayer audioFilePlayerWithURL:[[NSBundle mainBundle] URLForResource:@"lead" withExtension:@"aif"]
                                                 audioController:_audioController
                                                           error:NULL];
        [_sample1 addObserver:self forKeyPath:@"playing" options:0 context:sender];
        [_audioController addChannels:[NSArray arrayWithObject:_sample1]];
        [sender setSelected:YES];
    }
}

- (void)filterSwitchChanged:(UISwitch*)sender {
    if ( sender.isOn ) {
        self.filter = [[[TPConvolutionFilter alloc] initWithAudioController:_audioController filter:[TPConvolutionFilter filterFromAudioFile:[[NSBundle mainBundle] URLForResource:@"Factory Hall" withExtension:@"wav"] scale:15.0 error:NULL]] autorelease];
        [_audioController addFilter:_filter.callback userInfo:_filter];
    } else {
        [_audioController removeFilter:_filter.callback userInfo:_filter];
        self.filter = nil;
    }
}

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ( object == _sample1 ) {
        [_audioController removeChannels:[NSArray arrayWithObject:_sample1]];
        [_sample1 removeObserver:self forKeyPath:@"playing"];
        self.sample1 = nil;
        [(UIButton*)context setSelected:NO];
    }
}

@end
