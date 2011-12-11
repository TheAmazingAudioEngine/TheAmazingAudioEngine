//
//  TPAudioController.h
//
//  Created by Michael Tyson on 25/11/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//
//  http://atastypixel.com/code/TPAudioController

#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>

@protocol TPAudioPlayable;
@protocol TPAudioRecordDelegate;
@protocol TPAudioPlaybackDelegate;

@interface TPAudioController : NSObject

+ (AudioStreamBasicDescription)audioDescription;

- (void)setup;

- (void)start;
- (void)stop;

- (void)addChannels:(NSArray*)channels;
- (void)removeChannels:(NSArray*)channels;

- (void)addRecordDelegate:(id<TPAudioRecordDelegate>)delegate;
- (void)removeRecordDelegate:(id<TPAudioRecordDelegate>)delegate;

- (void)addPlaybackDelegate:(id<TPAudioPlaybackDelegate>)delegate;
- (void)removePlaybackDelegate:(id<TPAudioPlaybackDelegate>)delegate;

@property (nonatomic, assign) BOOL enableInput;
@property (nonatomic, assign) BOOL muteOutput;
@property (retain, readonly) NSArray *channels;
@property (retain, readonly) NSArray *recordDelegates;
@property (retain, readonly) NSArray *playbackDelegates;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) BOOL audioInputAvailable;
@property (nonatomic, readonly) NSUInteger numberOfInputChannels;
@end

@protocol TPAudioPlayable <NSObject>
- (void)audioController:(TPAudioController*)controller needsBuffer:(SInt16*)buffer ofLength:(NSUInteger)frames time:(const AudioTimeStamp*)time;
@optional
@property (nonatomic, readonly) float volume;
@property (nonatomic, readonly) float pan;
@end

@protocol TPAudioRecordDelegate <NSObject>
- (void)audioController:(TPAudioController*)controller incomingAudio:(SInt16*)audio ofLength:(NSUInteger)frames numberOfChannels:(NSUInteger)numberOfChannels time:(const AudioTimeStamp*)time;
@end

@protocol TPAudioPlaybackDelegate <NSObject>
- (void)audioController:(TPAudioController*)controller outgoingAudio:(SInt16*)audio ofLength:(NSUInteger)frames time:(const AudioTimeStamp*)time;
@end
