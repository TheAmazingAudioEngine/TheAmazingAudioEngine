//
//  TheAmazingAudioEngine.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 18/03/2012.
//
//  Copyright (C) 2012-2013 A Tasty Pixel
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

#ifdef __cplusplus
extern "C" {
#endif

#import "AEAudioController.h"
#import "AEAudioController+Audiobus.h"
#import "AEAudioFileLoaderOperation.h"
#import "AEAudioFilePlayer.h"
#import "AEAudioFileWriter.h"
#import "AEBlockChannel.h"
#import "AEBlockFilter.h"
#import "AEBlockAudioReceiver.h"
#import "AEAudioUnitChannel.h"
#import "AEAudioUnitFilter.h"
#import "AEFloatConverter.h"
#import "AEBlockScheduler.h"
#import "AEUtilities.h"

/*!
@mainpage
 
@section Introduction
 
 The Amazing Audio Engine is a framework you can use to build iOS audio apps.
 It's built to be very easy to use, but also offers an abundance of sophisticated functionality.
 
 The basic building-blocks of The Engine are:
 
  - [Channels](@ref Creating-Audio), which is how audio content is generated. These can be audio files, blocks, Objective-C objects, or Audio Units.
  - [Channel Groups](@ref Grouping-Channels), which let you group channels together in order to filter or record collections of channels.
  - [Filters](@ref Filtering), which process audio. These can be blocks, Objective-C objects, or Audio Units.
  - [Audio Receivers](@ref Receiving-Audio), which give you access to audio from various sources.
 
 <img src="blockdiagram.png" alt="Sample block diagram" />
 
 In addition to these basic components, The Amazing Audio Engine includes a number of other features and utilities:
 
  - Deep integration of [Audiobus](@ref Audiobus), the inter-app audio system for iOS.
  - A channel class for [playing and looping audio files](@ref Audio-Files).
  - An NSOperation class for [loading audio files into memory](@ref Reading-Audio).
  - A class for [writing audio to an audio file](@ref Writing-Audio).
  - Sophisticated [multi-channel input](@ref Multichannel-Input) hardware support.
  - Utilities for [managing AudioBufferLists](@ref Audio-Buffers), the basic unit of audio.
  - [Timing Receivers](@ref Timing-Receivers), which are used for sequencing and synchronization.
  - A class for managing easy conversion to and from [floating-point format](@ref Vector-Processing) for use with the Accelerate vector processing framework.
  - A [lock-free synchronization](@ref Synchronization) system that lets you send messages between your app's main thread, and the
    Core Audio thread, without having to worry about managing access to shared variables in a way that doesn't
    cause performance problems.
  - A suite of auxiliary components, including:
    - A [recorder](@ref Recording) class, for recording and mixing one or more sources of audio
    - A [playthrough](@ref Playthrough) channel, for providing easy audio monitoring
    - Limiter and expander filters
 
 Next: [Get Started](@ref Getting-Started).
 
@page Getting-Started Getting Started
 
 @section Setup
 
 First, you need to set up your project with The Amazing Audio Engine.
 
 The easiest way to do so is using [CocoaPods](http://cocoapods.org):
 
 1. Add `pod 'TheAmazingAudioEngine'` to your Podfile, or, if you don't have one: at the top level of your project 
    folder, create a file called "Podfile" with the following content:
    @code
    pod 'TheAmazingAudioEngine'
    @endcode
 2. Then, in the terminal and in the same folder, type:
    @code
    pod install
    @endcode
 
 Alternatively, if you aren't using CocoaPods, or want to use the very latest code:
 
 1. Clone The Amazing Audio Engine's [git repository](https://github.com/TheAmazingAudioEngine/TheAmazingAudioEngine)
    (or just download it) into a folder within your project, such as `Library/The Amazing Audio Engine`.  
      
    *Note: If you are cloning the repository, you may wish to grab only the latest version, with the following command:*
 
    @code
    git clone --depth=1 https://github.com/TheAmazingAudioEngine/TheAmazingAudioEngine.git
    @endcode
 2. Drag `TheAmazingAudioEngine.xcodeproj` from that folder into your project's navigation tree in Xcode. It'll
    be added as a sub-project.
 3. In the "Build Phases" tab of your main target, open up the "Target Dependencies" section, press the "+" button,
    and select "TheAmazingAudioEngine".
 4. In the "Link Binary with Libraries" section, press the "+" button, and select "libTheAmazingAudioEngine.a".
 5. If "AudioToolbox.framework", "AVFoundation.framework" and "Accelerate.framework" aren't already in the "Link Binary with Libraries" section,
    press the "+" button again, and add them all.
 6. In the "Build Settings" tab, find the "Header Search Paths" item and add the path to the "TheAmazingAudioEngine"
    folder. For example, if you put the distribution into "Library/The Amazing Audio Engine", you might enter
    `"Library/The Amazing Audio Engine/TheAmazingAudioEngine"`.
 
 Finally, if you intend to use some of the modules provided with The Amazing Audio Engine, drag the source files of
 the modules you want to use from the "Modules" folder straight into your project.
 
 Take a look at "TheEngineSample.xcodeproj" for an example configuration.
 
 Note that TAAE now uses ARC, so if you're including source files directly within your non-ARC project, you'll
 need to add the `-fobjc-arc` flag to the build parameters for each source file, which you can do by opening the
 "Build Phases" tab of your app target, opening the "Compile Sources" section, and double-clicking in the
 "Compiler Flags" column of the relevant source files.
 
 @section Meet-AEAudioController Meet AEAudioController
 
 The main hub of The Amazing Audio Engine is AEAudioController. This class contains the main audio engine, and manages
 your audio session for you.
 
 To begin, create a new instance of AEAudioController in an appropriate location, such as within your app delegate:
 
 @code
 @property (nonatomic, strong) AEAudioController *audioController;
 
 ...
 
 self.audioController = [[AEAudioController alloc]
                            initWithAudioDescription:[AEAudioController nonInterleaved16BitStereoAudioDescription]
                                inputEnabled:YES]; // don't forget to autorelease if you don't use ARC!
 @endcode
 
 Here, you pass in the audio format you wish to use within your app. AEAudioController offers some easy-to-use predefined
 formats, but you can use anything that the underlying Core Audio system supports.
 
 You can also enable audio input, if you choose.
 
 Now start the audio engine running. You can pass in an NSError pointer if you like, which will be filled in
 if an error occurs:
 
 @code
 NSError *error = NULL;
 BOOL result = [_audioController start:&error];
 
 if ( !result ) {
    // Report error
 }
 @endcode
 
 Take a look at the documentation for AEAudioController to see the available properties that can be set to modify
 behaviour, such as preferred buffer duration, audio input mode, audio category session to use. You can set these at any time.
 
 Now that you've got a running audio engine, it's time to [create some audio](@ref Creating-Audio).
 
@page Creating-Audio Creating Audio Content
 
 There are a number of ways you can create audio with The Amazing Audio Engine:

 - You can play an audio file, with AEAudioFilePlayer.
 - You can create a block to generate audio programmatically, using AEBlockChannel.
 - You can create an Objective-C class that implements the AEAudioPlayable protocol.
 - You can even use an Audio Unit, using the AEAudioUnitChannel class.

 @section Audio-Files Playing Audio Files
 
 AEAudioFilePlayer supports any audio format supported by the underlying system, and has a number of handy features:
 
 - Looping
 - Position seeking/scrubbing
 - One-shot playback with a block to call upon completion
 - Pan, volume, mute
 
 To use it, call @link AEAudioFilePlayer::audioFilePlayerWithURL:audioController:error: audioFilePlayerWithURL:audioController:error: @endlink,
 like so:
 
 @code
 NSURL *file = [[NSBundle mainBundle] URLForResource:@"Loop" withExtension:@"m4a"];
 self.loop = [AEAudioFilePlayer audioFilePlayerWithURL:file
                                       audioController:_audioController
                                                 error:NULL];
 @endcode
 
 If you'd like the audio to loop, you can set [loop](@ref AEAudioFilePlayer::loop) to `YES`. Take a look at the class
 documentation for more things you can do.
 
 @section Block-Channels Block Channels
 
 AEBlockChannel is a class that allows you to create a block to generate audio programmatically. Call
 [channelWithBlock:](@ref AEBlockChannel::channelWithBlock:), passing in your block implementation in the form
 defined by @link AEBlockChannelBlock @endlink:
 
 @code
 self.channel = [AEBlockChannel channelWithBlock:^(const AudioTimeStamp  *time,
                                                   UInt32           frames,
                                                   AudioBufferList *audio) {
     // TODO: Generate audio in 'audio'
 }];
 @endcode
 
 The block will be called with a timestamp which, when adjusted by the value returned from
 @link AEAudioControllerOutputLatency AEAudioController::AEAudioControllerOutputLatency @endlink,
 corresponds to the time the audio will reach the device audio output; the number of audio frames 
 you are expected to produce, and an AudioBufferList in which to store the generated audio.
 
 @section Object-Channels Objective-C Object Channels
 
 The AEAudioPlayable protocol defines an interface that you can conform to in order to create Objective-C
 classes that can act as channels.
 
 The protocol requires that you define a method that returns a pointer to a C function that takes the form
 defined by AEAudioControllerRenderCallback. This C function will be called when audio is required.
 
 <blockquote class="tip">
 If you put this C function within the \@implementation block, you will be able to access instance
 variables via the C struct dereference operator, "->". Note that you should never make any Objective-C calls
 from within a Core Audio realtime thread, as this will cause performance problems and audio glitches. This
 includes accessing properties via the "." operator.
 </blockquote>
 
 @code
 @interface MyChannelClass <AEAudioPlayable>
 @end

 @implementation MyChannelClass

 ...
 
 static OSStatus renderCallback(__unsafe_unretained MyChannelClass *THIS,
                                __unsafe_unretained AEAudioController *audioController,
                                const AudioTimeStamp *time,
                                UInt32 frames,
                                AudioBufferList *audio) {
     // TODO: Generate audio in 'audio'
     return noErr;
 }
 
 -(AEAudioControllerRenderCallback)renderCallback {
     return &renderCallback;
 }
 
 @end

 ...
 
 self.channel = [[MyChannelClass alloc] init];
 @endcode
 
 @section Audio-Unit-Channels Audio Unit Channels
 
 The AEAudioUnitChannel class acts as a host for audio units, allowing you to use any generator audio unit as an
 audio source.
 
 To use it, call @link AEAudioUnitChannel::initWithComponentDescription:audioController:error: initWithComponentDescription:audioController:error: @endlink,
 passing in an `AudioComponentDescription` structure (you can use the utility function @link AEAudioComponentDescriptionMake @endlink for this),
 along with a reference to the AEAudioController instance, and optionally, a pointer to an NSError to be filled if the audio unit
 creation failed.
 
 @code
 AudioComponentDescription component
    = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple,
                                      kAudioUnitType_MusicDevice,
                                      kAudioUnitSubType_Sampler)
 
 NSError *error = NULL;
 self.sampler = [[AEAudioUnitChannel alloc]
                       initWithComponentDescription:component
                                    audioController:_audioController
                                              error:&error];
 
 if ( !_sampler ) {
    // Report error
 }
 @endcode
 
 You can then access the audio unit directly via the [audioUnit](@ref AEAudioUnitFilter::audioUnit) property.
 
 @section Adding-Channels Adding Channels
 
 Once you've created a channel, you add it to the audio engine with [addChannels:](@ref AEAudioController::addChannels:).
 
 @code
 [_audioController addChannels:[NSArray arrayWithObject:_channel]];
 @endcode
 
 Note that you can use as many channels as the device can handle, and you can add/remove channels whenever you like, by
 calling [addChannels:](@ref AEAudioController::addChannels:) or [removeChannels:](@ref AEAudioController::removeChannels:).
 
 @section Grouping-Channels Grouping Channels
 
 The Amazing Audio Engine provides *channel groups*, which let you construct trees of channels so you can do things with them
 together.
 
 <img src="groups.png" alt="Channel groups">
 
 Create channel groups by calling [createChannelGroup](@ref AEAudioController::createChannelGroup) or create subgroups with
 [createChannelGroupWithinChannelGroup:](@ref AEAudioController::createChannelGroupWithinChannelGroup:), then add channels
 to these groups by calling [addChannels:toChannelGroup:](@ref AEAudioController::addChannels:toChannelGroup:).
 
 You can then perform a variety of operations on the channel groups, such as @link AEAudioController::setVolume:forChannelGroup: setting volume @endlink
 and @link AEAudioController::setPan:forChannelGroup: pan @endlink, and adding filters and audio receivers, which we shall cover next.
 
 -----------
 
 So, you're creating audio - now it's time to do something with it: [Filtering](@ref Filtering).
 
@page Filtering Filtering
 
 The Amazing Audio Engine includes a sophisticated and flexible audio processing architecture, allowing you to
 apply effects to audio throughout your application.
 
 The Engine gives you three ways to apply effects to audio:
 
 - You can process audio with blocks, via the AEBlockFilter class.
 - You can implement Objective-C classes that implement the AEAudioFilter protocol.
 - You can use Audio Units.
 
 @section Block-Filters Block Filters
 
 To filter audio using a block, create an instance of AEBlockFilter using [filterWithBlock:](@ref AEBlockFilter::filterWithBlock:),
 passing in a block implementation that takes the form defined by @link AEBlockFilterBlock @endlink.
 
 The block will be passed a function pointer, `producer`, which is used to pull audio from the system. Your
 implementation block must invoke this function when audio is needed, passing as the first argument the
 opaque `producerToken` pointer also passed to the block.
 
@code
self.filter = [AEBlockFilter filterWithBlock:^(AEAudioControllerFilterProducer producer,
                                               void                     *producerToken,
                                               const AudioTimeStamp     *time,
                                               UInt32                    frames,
                                               AudioBufferList          *audio) {
     // Pull audio
     OSStatus status = producer(producerToken, audio, &frames);
     if ( status != noErr ) return;
     
     // Now filter audio in 'audio'
}];
 @endcode
 
 @section Filter-Channels Objective-C Object Filters
 
 The AEAudioFilter protocol defines an interface that you can conform to in order to create Objective-C
 classes that can filter audio.
 
 The protocol requires that you define a method that returns a pointer to a C function that takes the form
 defined by AEAudioControllerFilterCallback. This C function will be called when audio is to be filtered.
 
 <blockquote class="tip">
 If you put this C function within the \@implementation block, you will be able to access instance
 variables via the C struct dereference operator, "->". Note that you should never make any Objective-C calls
 from within a Core Audio realtime thread, as this will cause performance problems and audio glitches. This
 includes accessing properties via the "." operator.
 </blockquote>
 
 As with block filters, above, the callback you provide will be passed a function pointer, `producer`, 
 which is used to pull audio from the system. Your implementation block must invoke this function when audio
 is needed, passing as the first argument the opaque `producerToken` pointer also passed to the block.
 
 @code
 @interface MyFilterClass <AEAudioFilter>
 @end

 @implementation MyFilterClass

 ...
 
 static OSStatus filterCallback(__unsafe_unretained MyFilterClass *THIS,
                                __unsafe_unretained AEAudioController *audioController,
                                AEAudioControllerFilterProducer producer,
                                void                     *producerToken,
                                const AudioTimeStamp     *time,
                                UInt32                    frames,
                                AudioBufferList          *audio) {
 
     // Pull audio
     OSStatus status = producer(producerToken, audio, &frames);
     if ( status != noErr ) status;
 
     // Now filter audio in 'audio'
 
     return noErr;
 }

 -(AEAudioControllerFilterCallback)filterCallback {
     return filterCallback;
 }
 
 @end

 ...
 
 self.filter = [[MyFilterClass alloc] init];
 @endcode
 
 @section Audio-Unit-Filters Audio Unit Filters
 
 The AEAudioUnitFilter class allows you to use audio units to apply effects to audio.
 
 To use it, call @link AEAudioUnitFilter::initWithComponentDescription:audioController:error: initWithComponentDescription:audioController:error: @endlink,
 passing in an `AudioComponentDescription` structure (you can use the utility function @link AEAudioComponentDescriptionMake @endlink for this),
 along with a reference to the AEAudioController instance, and optionally, a pointer to an NSError to be filled if the audio unit
 creation failed.
 
 @code
 AudioComponentDescription component
    = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple,
                                      kAudioUnitType_Effect,
                                      kAudioUnitSubType_Reverb2)
 
 NSError *error = NULL;
 self.reverb = [[AEAudioUnitFilter alloc]
                       initWithComponentDescription:component
                                    audioController:_audioController
                                              error:&error];
 
 if ( !_reverb ) {
    // Report error
 }
 @endcode
 
 You can then access the audio unit directly via the [audioUnit](@ref AEAudioUnitFilter::audioUnit) property:
 
 @code
 AudioUnitSetParameter(_reverb.audioUnit,
                       kReverb2Param_DryWetMix,
                       kAudioUnitScope_Global,
                       0,
                       100.f,
                       0);
 @endcode
 
 @section Adding-Filters Adding Filters
 
 Once you've got a filter, you can apply it to a variety of different audio sources:
 
 - Apply it to your entire app's output using @link AEAudioController::addFilter: addFilter: @endlink.
 - Apply it to an individual channel using @link AEAudioController::addFilter:toChannel: addFilter:toChannel: @endlink.
 - Apply it to a [channel group](@ref Grouping-Channels) using @link AEAudioController::addFilter:toChannelGroup: addFilter:toChannelGroup: @endlink.
 - Apply it to your app's audio input using @link AEAudioController::addInputFilter: addInputFilter: @endlink.
 
 You can add and remove filters at any time, using @link AEAudioController::addFilter: addFilter: @endlink and 
 @link AEAudioController::removeFilter: removeFilter: @endlink, and the other channel, group and input equivalents.

 ------------
 
 Now you're producing audio and applying effects to it. But what if you want to record, process audio input, or do something else with the audio?
 Read on: [Receiving Audio](@ref Receiving-Audio).
 
@page Receiving-Audio Receiving Audio
 
 So far we've covered creating and processing audio, but what if you want to do something with the microphone/device audio input, or
 take the audio coming from your app and do something with it?
 
 The Amazing Audio Engine supports receiving audio from a number of sources:
 
 - The device's audio input (the microphone, or an attached compatible audio device).
 - Your app's audio output.
 - One particular channel.
 - A channel group.
 
 To begin receiving audio, you can either create an Objective-C class that implements the @link AEAudioReceiver @endlink protocol:
 
 @code
 @interface MyAudioReceiver : NSObject <AEAudioReceiver>
 @end
 @implementation MyAudioReceiver
 static void receiverCallback(__unsafe_unretained MyAudioReceiver *THIS,
                              __unsafe_unretained AEAudioController *audioController,
                              void                     *source,
                              const AudioTimeStamp     *time,
                              UInt32                    frames,
                              AudioBufferList          *audio) {
     
     // Do something with 'audio'
 }
 
 -(AEAudioControllerAudioCallback)receiverCallback {
     return receiverCallback;
 }
 @end
 
 ...

 id<AEAudioReceiver> receiver = [[MyAudioReceiver alloc] init];
 @endcode
 
 ...or you can use the AEBlockAudioReceiver class to specify a block to receive audio:
 
 @code
 id<AEAudioReceiver> receiver = [AEBlockAudioReceiver audioReceiverWithBlock:
                                    ^(void                     *source,
                                      const AudioTimeStamp     *time,
                                      UInt32                    frames,
                                      AudioBufferList          *audio) {
    // Do something with 'audio'
 }];
 @endcode
 
 Then, add the receiver to the source of your choice:
 
 - To receive audio input, use @link AEAudioController::addInputReceiver: addInputReceiver: @endlink.
 - To receive audio output, use @link AEAudioController::addOutputReceiver: addOutputReceiver: @endlink.
 - To receive audio from a channel, use @link AEAudioController::addOutputReceiver:forChannel: addOutputReceiver:forChannel: @endlink.
 - To receive audio from a channel group, use @link AEAudioController::addOutputReceiver:forChannelGroup: addOutputReceiver:forChannelGroup: @endlink.
 
 @section Playthrough Playthrough/Audio Monitoring
 
 For some applications it might be necessary to provide audio monitoring, where the audio coming in through the
 microphone or other device audio input is played out of the speaker.
 
 The AEPlaythroughChannel located within the "Modules" directory takes care of this. This class implements both the
 @link AEAudioPlayable @endlink *and* the @link AEAudioReceiver @endlink protocols, so that it acts as both an
 audio receiver and an audio source.
 
 To use it, initialize it using @link AEPlaythroughChannel::initWithAudioController: initWithAudioController: @endlink,
 then add it as an input receiver using AEAudioController's @link AEAudioController::addInputReceiver: addInputReceiver: @endlink
 and add it as a channel using @link AEAudioController::addChannels: addChannels: @endlink.
 
 @section Recording Recording
 
 Included within the "Modules" directory is the AERecorder class, which implements the @link AEAudioReceiver @endlink
 protocol and provides simple but sophisticated audio recording.
 
 To use AERecorder, initialize it using @link AERecorder::initWithAudioController: initWithAudioController: @endlink.
 
 Then, when you're ready to begin recording, use
 @link AERecorder::beginRecordingToFileAtPath:fileType:error: beginRecordingToFileAtPath:fileType:error: @endlink,
 passing in the path to the file you'd like to record to, and the file type to use. Common file types include
 `kAudioFileAIFFType`, `kAudioFileWAVEType`, `kAudioFileM4AType` (using AAC audio encoding), and `kAudioFileCAFType`.
 
 Finally, add the AERecorder instance as a receiver using the methods listed above.
 
 Note that you can add the instance as a receiver of *more than one source*, and these will be mixed together automatically.

 For example, you might have a karaoke app with a record function, and you want to record both the backing music and the microphone
 audio at the same time:
 
 @code
 - (void)beginRecording {
    // Init recorder
    self.recorder = [[AERecorder alloc] initWithAudioController:_audioController];
 
    NSString *documentsFolder = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) 
                                    objectAtIndex:0];
    NSString *filePath = [documentsFolder stringByAppendingPathComponent:@"Recording.aiff"];
 
    // Start the recording process
    NSError *error = NULL;
    if ( ![_recorder beginRecordingToFileAtPath:filePath 
                                       fileType:kAudioFileAIFFType 
                                          error:&error] ) {
        // Report error
        return;
    }
 
    // Receive both audio input and audio output. Note that if you're using
    // AEPlaythroughChannel, mentioned above, you may not need to receive the input again.
    [_audioController addInputReceiver:_recorder];
    [_audioController addOutputReceiver:_recorder];
 }
 @endcode
  
 To complete the recording, call [finishRecording](@ref AERecorder::finishRecording).
 
 @code
 - (void)endRecording {
    [_audioController removeInputReceiver:_recorder];
    [_audioController removeOutputReceiver:_recorder];
 
    [_recorder finishRecording];
 
    self.recorder = nil;
 }
 @endcode
 
 @section Multichannel-Input Multi-Channel Input Support
 
 The Amazing Audio Engine provides the ability to select a set of input channels when a multi-channel input
 device is connected.
 
 You can assign an array of NSIntegers to the [inputChannelSelection](@ref AEAudioController::inputChannelSelection) property
 of AEAudioController in order to select which channels of the input device should be used.
 
 For example, for a four-channel input device, the following will select the last two channels as a stereo stream:
 
 @code
 _audioController.inputChannelSelection = [NSArray arrayWithObjects:
                                            [NSNumber numberWithInt:2],
                                            [NSNumber numberWithInt:3,
                                            nil];
 @endcode
 
 You can also assign audio input receivers or filters for different selections of channels. For example, you can
 have one AEAudioReceiver object receiving from the first channel of a stereo input device, and a different
 object receiving from the second channel.
 
 Use the @link AEAudioController::addInputReceiver:forChannels: addInputReceiver:forChannels: @endlink and
 @link AEAudioController::addInputFilter:forChannels: addInputFilter:forChannels: @endlink methods to do this:
 
 @code
 [_audioController addInputReceiver:
    [ABBlockAudioReceiver audioReceiverWithBlock:^(void                     *source,
                                                   const AudioTimeStamp     *time,
                                                   UInt32                    frames,
                                                   AudioBufferList          *audio) {
        // Receiving left channel
    }]
                        forChannels:[NSArray arrayWithObject:[NSNumber numberWithInt:0]]];
 
 [_audioController addInputReceiver:
    [ABBlockAudioReceiver audioReceiverWithBlock:^(void                     *source,
                                                   const AudioTimeStamp     *time,
                                                   UInt32                    frames,
                                                   AudioBufferList          *audio) {
        // Receiving right channel
    }]
                        forChannels:[NSArray arrayWithObject:[NSNumber numberWithInt:1]]];
 @endcode
 
 Note that the [numberOfInputChannels](@ref AEAudioController::numberOfInputChannels) property is key-value observable,
 so you can use this to be notified when to display appopriate UI, etc.
 
 ----------
 
 Next, read on to find out how to interact with other audio apps, sending, receiving or filtering audio
 with [Audiobus](@ref Audiobus).
 
@page Audiobus Audiobus
 
 [Audiobus](http://audiob.us) is a widely-used iOS library that lets users combine iOS apps into an integrated,
 modular virtual studio - a bit like virtual audio cables.
 
 Compatible apps build in support for the Audiobus SDK, which allows them to create 'ports' which can either send,
 receive or process audio.
 
 The Amazing Audio Engine, developed by Michael Tyson, the same developer who created Audiobus, contains a
 @link AEAudioController(AudiobusAdditions) deep integration @endlink of Audiobus, with support for:
 
 - Receiving Audiobus audio that seamlessly replaces microphone/device audio input.
 - Sending Audiobus audio from any point in your app: The primary app output, or any channel or channel group.
 
 To integrate Audiobus into your The Amazing Audio Engine-based app, you need to register an account with 
 the [Audiobus Developer Center](http://developer.audiob.us), download the latest Audiobus SDK and
 follow the instructions in the [Audiobus Documentation](http://developer.audiob.us/doc)'s
 [integration guide](http://developer.audiob.us/doc/_integration-_guide.html) to set up
 your project with the Audiobus SDK.

 Then you can:
 
 - Receive Audiobus audio by creating an ABReceiverPort and passing it to The Amazing Audio Engine
   via AEAudioController's [audiobusReceiverPort](@ref AEAudioController::audiobusReceiverPort) property.
 - Send your app's audio output via Audiobus by creating an ABSenderPort and assigning it to
   [audiobusSenderPort](@ref AEAudioController::audiobusSenderPort).
 - Send one individual channel via Audiobus by assigning a new ABSenderPort via
   @link AEAudioController::setAudiobusSenderPort:forChannel: setAudiobusSenderPort:forChannel: @endlink
 - Send a channel group via Audiobus by assigning a new ABSenderPort via
   @link AEAudioController::setAudiobusSenderPort:forChannelGroup: setAudiobusSenderPort:forChannelGroup: @endlink
 - Filter Audiobus audio by creating an ABFilterPort with AEAudioController's [audioUnit](@ref AEAudioController::audioUnit),
   and passing it to The Amazing Audio Engine via AEAudioController's [audiobusFilterPort](@ref AEAudioController::audiobusFilterPort)
   property.
 
 
 Take a look at the header documentation for the @link AEAudioController(AudiobusAdditions) Audiobus functions @endlink
 for details.
 
 -------------
 
 We've now covered the basic building blocks of apps using The Amazing Audio Engine, but there's plenty more to know.
 
 [Read on](@ref Other-Facilities) to find out about:
 
  - [Reading](@ref Reading-Audio) from audio files.
  - [Writing](@ref Writing-Audio) to audio files.
  - [Managing audio buffers](@ref Audio-Buffers).
  - Making your app dramatically more efficient by using [vector processing operations](@ref Vector-Processing).
  - Efficient, safe and simple [inter-thread synchronization](@ref Synchronization) using The Amazing Audio Engine's messaging system.
  - How to [schedule events](@ref Timing-Receivers) with absolute accuracy.
 
@page Other-Facilities Other Facilities
 
 The Amazing Audio Engine provides quite a number of utilities and other bits and pieces designed to make writing
 audio apps easier.
 
 @section Reading-Audio Reading from Audio Files
 
 The AEAudioFileLoaderOperation class provides an easy way to load audio files into memory. All audio formats that
 are supported by the Core Audio subsystem are supported, and audio is converted automatically into the audio
 format of your choice.
 
 The class is an `NSOperation` subclass, which means that it can be run asynchronously using an `NSOperationQueue`.
 Alternatively, you can use it in a synchronous fashion by calling `start` directly:
 
 @code
 AEAudioFileLoaderOperation *operation = [[AEAudioFileLoaderOperation alloc] initWithFileURL:url 
                                                                      targetAudioDescription:audioDescription];
 [operation start];
 
 if ( operation.error ) {
    // Load failed! Clean up, report error, etc.
    return;
 }

 _audio = operation.bufferList;
 _lengthInFrames = operation.lengthInFrames;
 @endcode
 
 Note that this class loads the entire audio file into memory, and doesn't support streaming of very large
 audio files. For that, you will need to use the `ExtAudioFile` services directly.
 
 @section Writing-Audio Writing to Audio Files
 
 The AEAudioFileWriter class allows you to easily write to any audio file format supported by the system.
 
 To use it, instantiate it using @link AEAudioFileWriter::initWithAudioDescription: initWithAudioDescription: @endlink,
 passing in the audio format you wish to use. Then, begin the operation by calling  
 @link AEAudioFileWriter::beginWritingToFileAtPath:fileType:error: beginWritingToFileAtPath:fileType:error: @endlink,
 passing in the path to the file you'd like to record to, and the file type to use. Common file types include
 `kAudioFileAIFFType`, `kAudioFileWAVEType`, `kAudioFileM4AType` (using AAC audio encoding), and `kAudioFileCAFType`.
 
 Once the write operation has started, you use the C functions [AEAudioFileWriterAddAudio](@ref AEAudioFileWriter::AEAudioFileWriterAddAudio)
 and [AEAudioFileWriterAddAudioSynchronously](@ref AEAudioFileWriter::AEAudioFileWriterAddAudioSynchronously) to write audio
 to the file. Note that you should only use [AEAudioFileWriterAddAudio](@ref AEAudioFileWriter::AEAudioFileWriterAddAudio)
 when writing audio from the Core Audio thread, as this is done asynchronously in a way that does not hold up the thread.
 
 When you are finished, call [finishWriting](@ref AEAudioFileWriter::finishWriting) to close the file.
 
 @section Audio-Buffers Managing Audio Buffers
 
 `AudioBufferList` is the basic unit of audio for Core Audio, representing a small time interval of audio. This
 structure contains one or more pointers to an area of memory holding the audio samples: For interleaved audio, there will
 be one buffer holding the interleaved samples for all channels, while for non-interleaved audio there will be one buffer
 per channel.
 
 The Amazing Audio Engine provides a number of utility functions for dealing with audio buffer lists:
 
 - @link AEAllocateAndInitAudioBufferList @endlink will take an `AudioStreamBasicDescription` and a number of frames to
   allocate, and will allocate and initialise an audio buffer list and the corresponding memory buffers appropriately.
 - @link AECopyAudioBufferList @endlink will copy an existing audio buffer list into a new one, allocating memory as needed.
 - @link AEFreeAudioBufferList @endlink will free the memory pointed to by an audio buffer list.
 - @link AEInitAudioBufferList @endlink will initialize the values of an already-existing audio buffer list.
 - @link AEGetNumberOfFramesInAudioBufferList @endlink will take an `AudioStreamBasicDescription` and return the number
   of frames contained within the audio buffer list given the `mDataByteSize` values within.
 
 Note: Do not use those functions above that perform memory allocation or deallocation from within the Core Audio thread,
 as this may cause performance problems.
 
 @section Vector-Processing Improving Efficiency using Vector Operations
 
 Vector operations offer orders of magnitude improvements in processing efficiency over performing the same operation
 as a large number of scalar operations.
 
 For example, take the following code which calculates the absolute maximum value within an audio buffer:
 
 @code
 float max = 0;
 for ( int i=0; i<frames; i++ ) {
    float value = fabs(((float*)audio->mBuffers[0].mData)[i]);
    if ( value > max ) max = value;
 }
 @endcode
 
 This consists of *frames* address calculations, followed by *frames* calls to `fabs`, *frames* floating-point comparisons, and at worst case,
 *frames* assignments, followed by *frames* integer increments.
 
 This can be replaced by a single vector operation, using the Accelerate framework:
 
 @code
 float max = 0;
 vDSP_maxmgv((float*)audio->mBuffers[0].mData, 1, &max, frames);
 @endcode
 
 For those working with floating-point audio, this already works, but for those working in other audio formats, an extra
 conversion to floating-point is required.
 
 If you are using *only* non-interleaved 16-bit signed integers, then this can be performed easily, using `vDSP_vflt16`.
 Otherwise, The Amazing Audio Engine provides the AEFloatConverter class to perform this operation easily with any audio format:
 
 @code
 static const int kScratchBufferSize[4096];
 
 AudioBufferList *scratchBufferList
    = AEAllocateAndInitAudioBufferList([AEAudioController nonInterleavedFloatStereoAudioDescription], 
                                       kScratchBufferSize);

 
 ...
 
 self.floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:_audioController.audioDescription];
 
 ...
 
 AEFloatConverterToFloatBufferList(THIS->_floatConverter, audio, THIS->_scratchBufferList, frames);
 // Now process the floating-point audio in 'scratchBufferList'.
 @endcode
 
 
 @section Synchronization Thread Synchronization
 
 Thread synchronization is notoriously difficult at the best of times, but when the timing constraints introduced by
 the Core Audio realtime thread are taken into account, this becomes a very tricky problem indeed.
 
 A common solution is the use of mutexes with try-locks, so that rather than blocking on a lock, the Core Audio thread will 
 simply fail to acquire the lock, and will abort the operation. This can work, but always runs the risk of creating
 audio artefacts when it stops generating audio for a time interval, which is precisely the problem that we are trying
 to avoid by not blocking.
 
 All this can be avoided with The Amazing Audio Engine's messaging feature.
 
 This utility allows the main thread to send messages to the Core Audio thread, and vice versa, without any locking
 required.
 
 To send a message to the Core Audio thread, use either
 @link AEAudioController::performAsynchronousMessageExchangeWithBlock:responseBlock: performAsynchronousMessageExchangeWithBlock:responseBlock: @endlink,
 or @link AEAudioController::performSynchronousMessageExchangeWithBlock: performSynchronousMessageExchangeWithBlock: @endlink:
 
 @code
 [_audioController performAsynchronousMessageExchangeWithBlock:^{
    // Do something on the Core Audio thread
 } responseBlock:^{
    // The thing above has been done, and now we're back on the main thread
 }];
 @endcode
 
 @code 
 [_audioController performSynchronousMessageExchangeWithBlock:^{
    // Do something on the Core Audio thread.
    // We will block on the main thread until this has been completed
 }];
 
 // Now the Core Audio thread finished doing whatever we asked it do, and we're back.
 @endcode
 
 To send messages from the Core Audio thread back to the main thread, you need to
 define a C callback, which takes the form defined by @link AEAudioControllerMainThreadMessageHandler @endlink,
 then call @link AEAudioController::AEAudioControllerSendAsynchronousMessageToMainThread AEAudioControllerSendAsynchronousMessageToMainThread @endlink, passing a reference to
 any parameters, with the length of the parameters in bytes.
 
 @code
 struct _myHandler_arg_t { int arg1; int arg2; };
 static void myHandler(AEAudioController *audioController, void *userInfo, int userInfoLength) {
    struct _myHandler_arg_t *arg = (struct _myHandler_arg_t*)userInfo;
    NSLog(@"On main thread; args are %d and %d", arg->arg1, arg->arg2);
 }
 
 ...
 
 // From Core Audio thread
 AEAudioControllerSendAsynchronousMessageToMainThread(THIS->_audioController,
                                                      myHandler,
                                                      &(struct _myHandler_arg_t) {
                                                        .arg1 = 1,
                                                        .arg2 = 2 },
                                                      sizeof(struct _myHandler_arg_t));
 @endcode
 
 Whatever is passed via the 'userInfo' parameter of
 @link AEAudioController::AEAudioControllerSendAsynchronousMessageToMainThread AEAudioControllerSendAsynchronousMessageToMainThread @endlink will be copied
 onto an internal buffer. A pointer to the copied item on the internal buffer will be passed to the
 callback you provide.
 
 **Note: This is an important distinction.** The bytes pointed to by the 'userInfo' parameter value are passed by *value*, not by reference.
 To pass a pointer to an instance of an Objective-C class, you need to pass a reference to the pointer.
 
 This:
 
 @code
 AEAudioControllerSendAsynchronousMessageToMainThread(THIS->_audioController,
                                                      myHandler,
                                                      &THIS,
                                                      sizeof(id) },
 @endcode
 
 Not this:

 @code
 AEAudioControllerSendAsynchronousMessageToMainThread(THIS->_audioController,
                                                      myHandler,
                                                      THIS,
                                                      sizeof(id) },
 @endcode
  
 @section Timing-Receivers Receiving Time Cues
 
 For certain applications, it's important that events take place at a precise time. `NSTimer` and the `NSRunLoop` scheduling
 methods simply can't do the job when it comes to millisecond-accurate timing, which is why The Amazing Audio Engine
 provides support for receiving time cues.
 
 [Audio receivers](@ref Receiving-Audio), [channels](@ref Creating-Audio) and [filters](@ref Filtering) all receive and
 can act on audio timestamps, but there are some cases where it makes more sense to have a separate class handle the
 timing and synchronization.
 
 In that case, you can implement the @link AEAudioTimingReceiver @endlink protocol and add your class as a timing receiver
 via [addTimingReceiver:](@ref AEAudioController::addTimingReceiver:).  The callback you provide will be called from
 two contexts: When input is received (@link AEAudioTimingContextInput @endlink), and when output is about to be
 generated (@link AEAudioTimingContextOutput @endlink). In both cases, the timing receivers will be notified before
 any of the audio receivers or channels are invoked, so that you can set app state that will affect the current time interval.
 
 @subsection Scheduling Scheduling Events
 
 AEBlockScheduler is a class you can use to schedule blocks for execution at a particular time. This implements the
 @link AEAudioTimingReceiver @endlink protocol, and provides an interface for scheduling blocks with sample-level
 accuracy.
 
 To use it, instantiate AEBlockScheduler, add it as a timing receiver with [addTimingReceiver:](@ref AEAudioController::addTimingReceiver:),
 then begin scheduling events using
 @link AEBlockScheduler::scheduleBlock:atTime:timingContext:identifier: scheduleBlock:atTime:timingContext:identifier: @endlink:
 
 @code
 self.scheduler = [[AEBlockScheduler alloc] initWithAudioController:_audioController];
 [_audioController addTimingReceiver:_scheduler];
 
 ...
 
 [_scheduler scheduleBlock:^(const AudioTimeStamp *time, UInt32 offset) {
    // We are now on the Core Audio thread at *time*, which is *offset* frames
    // before the time we scheduled, *timestamp*.
                           }
                  atTime:timestamp
            timingContext:AEAudioTimingContextOutput
               identifier:@"my event"];
 @endcode
 
 The block will be passed the current time, and the number of frames offset between the current time
 and the scheduled time.
 
 The alternate scheduling method, @link AEBlockScheduler::scheduleBlock:atTime:timingContext:identifier:mainThreadResponseBlock: scheduleBlock:atTime:timingContext:identifier:mainThreadResponseBlock: @endlink,
 allows you to provide a block that will be called on the main thread after the schedule has completed.
 
 There are a number of utilities you can use to construct and calculate timestamps, including
 [now](@ref AEBlockScheduler::now), [timestampWithSecondsFromNow:](@ref AEBlockScheduler::timestampWithSecondsFromNow:), 
 [hostTicksFromSeconds:](@ref AEBlockScheduler::hostTicksFromSeconds:) and
 [secondsFromHostTicks:](@ref AEBlockScheduler::secondsFromHostTicks:).
 
@page Contributing Contributing
 
 Want to help develop The Amazing Audio Engine, or some new modules?
 
 Fantastic!
 
 You can fork the [GitHub repository](https://github.com/TheAmazingAudioEngine/TheAmazingAudioEngine), and submit pull requests to
 suggest changes.
 
 Alternatively, if you've got a module you'd like to make available, but you'd like to self-host it, let us know on the
 [forum](http://forum.theamazingaudioengine.com).
 
 
 */

#ifdef __cplusplus
}
#endif
