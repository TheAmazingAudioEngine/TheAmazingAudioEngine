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

#define kAuxiliaryViewTag 251

@interface TPViewController ()
@property (nonatomic, retain) TPAudioFilePlayer *loop1;
@property (nonatomic, retain) TPAudioFilePlayer *loop2;
@property (nonatomic, retain) TPAudioFilePlayer *loop3;
@property (nonatomic, retain) TPAudioFilePlayer *sample1;
@end

@implementation TPViewController
@synthesize audioController=_audioController,
            loop1=_loop1,
            loop2=_loop2,
            loop3=_loop3,
            sample1=_sample1;

- (id)init {
    if ( !(self = [super initWithStyle:UITableViewStyleGrouped]) ) return nil;
    
    return self;
}

-(void)dealloc {
    NSMutableArray *channelsToRemove = [NSMutableArray array];
    if ( _loop1 ) {
        [channelsToRemove addObject:_loop1];
        self.loop1 = nil;
    }
    if ( _loop2 ) {
        [channelsToRemove addObject:_loop2];
        self.loop2 = nil;
    }
    if ( _loop3 ) {
        [channelsToRemove addObject:_loop3];
        self.loop3 = nil;
    }
    if ( _sample1 ) {
        [channelsToRemove addObject:_sample1];
        [_sample1 removeObserver:self forKeyPath:@"playing"];
        self.sample1 = nil;
    }
    
    if ( [channelsToRemove count] > 0 ) {
        [_audioController removeChannels:channelsToRemove];
    }
    
    self.audioController = nil;

    [super dealloc];
}

-(void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
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
    
    [_audioController addChannels:[NSArray arrayWithObjects:_loop1, _loop2, _loop3, nil]];
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ( section ) {
        case 0:
            return 3;
            break;
            
        case 1:
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

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ( object == _sample1 ) {
        [_audioController removeChannels:[NSArray arrayWithObject:_sample1]];
        [_sample1 removeObserver:self forKeyPath:@"playing"];
        self.sample1 = nil;
        [(UIButton*)context setSelected:NO];
    }
}

@end
