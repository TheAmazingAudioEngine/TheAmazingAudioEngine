//
//  ViewController(Refact).m
//  TheEngineSample
//
//  Created by jufan wang on 2019/4/28.
//  Copyright © 2019 A Tasty Pixel. All rights reserved.
//

#import "ViewController(Refact).h"


@implementation ViewController(Refact)

//
//-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
//    return 4;
//}
//
//-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
//    switch ( section ) {
//        case 0:
//            return 4;
//            
//        case 1:
//            return 2;
//            
//        case 2:
//            return 3;
//            
//        case 3:
//            return 4 + (self.audioController.numberOfInputChannels > 1 ? 1 : 0);
//            
//        default:
//            return 0;
//    }
//}
//
//
//
//-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
//    BOOL isiPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
//    
//    static NSString *cellIdentifier = @"cell";
//    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
//    
//    if ( !cell ) {
//        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellIdentifier];
//    }
//    
//    cell.accessoryView = nil;
//    cell.selectionStyle = UITableViewCellSelectionStyleNone;
//    
//    switch ( indexPath.section ) {
//        case 0: {
//            UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 40)];
//            
//            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
//            slider.translatesAutoresizingMaskIntoConstraints = NO;
//            slider.maximumValue = 1.0;
//            slider.minimumValue = 0.0;
//            
//            UISwitch * onSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
//            onSwitch.translatesAutoresizingMaskIntoConstraints = NO;
//            onSwitch.on = self.expander != nil;
//            [view addSubview:slider];
//            [view addSubview:onSwitch];
//            [view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[slider]-20-[onSwitch]|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(slider, onSwitch)]];
//            [view addConstraint:[NSLayoutConstraint constraintWithItem:slider attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
//            [view addConstraint:[NSLayoutConstraint constraintWithItem:onSwitch attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
//            
//            cell.accessoryView = view;
//            
//            switch ( indexPath.row ) {
//                case 0: {
//                    cell.textLabel.text = @"Drums";
//                    onSwitch.on = !self.loop1.channelIsMuted;
//                    slider.value = self.loop1.volume;
//                    [onSwitch addTarget:self action:@selector(loop1SwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    [slider addTarget:self action:@selector(loop1VolumeChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 1: {
//                    cell.textLabel.text = @"Organ";
//                    onSwitch.on = !self.loop2.channelIsMuted;
//                    slider.value = self.loop2.volume;
//                    [onSwitch addTarget:self action:@selector(loop2SwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    [slider addTarget:self action:@selector(loop2VolumeChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 2: {
//                    cell.textLabel.text = @"Oscillator";
//                    onSwitch.on = !self.oscillator.channelIsMuted;
//                    slider.value = self.oscillator.volume;
//                    [onSwitch addTarget:self action:@selector(oscillatorSwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    [slider addTarget:self action:@selector(oscillatorVolumeChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 3: {
//                    cell.textLabel.text = @"Group";
//                    onSwitch.on = ![self.audioController channelGroupIsMuted:_group];
//                    slider.value = [self.audioController volumeForChannelGroup:_group];
//                    [onSwitch addTarget:self action:@selector(channelGroupSwitchChanged:) forControlEvents:UIControlEventValueChanged];
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
//                    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 250, 40)];
//                    UIButton *calibrateButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
//                    calibrateButton.translatesAutoresizingMaskIntoConstraints = NO;
//                    [calibrateButton setTitle:@"Calibrate" forState:UIControlStateNormal];
//                    [calibrateButton addTarget:self action:@selector(calibrateExpander:) forControlEvents:UIControlEventTouchUpInside];
//                    UISwitch * onSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
//                    onSwitch.translatesAutoresizingMaskIntoConstraints = NO;
//                    onSwitch.on = _expander != nil;
//                    [onSwitch addTarget:self action:@selector(expanderSwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    [view addSubview:calibrateButton];
//                    [view addSubview:onSwitch];
//                    [view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[calibrateButton][onSwitch]|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(calibrateButton, onSwitch)]];
//                    [view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[calibrateButton]|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(calibrateButton)]];
//                    [view addConstraint:[NSLayoutConstraint constraintWithItem:onSwitch attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
//                    cell.accessoryView = view;
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
//                    cell.textLabel.text = @"Use 48K Audio";
//                    ((UISwitch*)cell.accessoryView).on = fabs(_audioController.audioDescription.mSampleRate - 48000) < 1.0;
//                    [((UISwitch*)cell.accessoryView) addTarget:self action:@selector(sampleRateSwitchChanged:) forControlEvents:UIControlEventValueChanged];
//                    break;
//                }
//                case 4: {
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
//}
//

@end
