//
//  TPAudioController.h
//
//  Created by Michael Tyson on 25/11/2011.
//  Copyright (c) 2011 A Tasty Pixel. All rights reserved.
//
//  http://atastypixel.com/code/TPAudioController

#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>


#pragma mark - Callbacks and protocols

@protocol TPAudioPlayable;

/*!
 * Playback callback
 *
 *      This is called when audio for the channel is required. As this is called from Core Audio's
 *      realtime thread, you should not wait on locks, allocate memory, or call any Objective-C or BSD
 *      code from this callback.
 *      The channel object is passed through as a parameter.  You should not send it Objective-C
 *      messages, but if you implement the callback within your channel's \@implementation block, you 
 *      can gain direct access to the instance variables of the channel ("channel->myInstanceVariable").
 *
 * @param channel   The channel object
 * @param time      The time the buffer will be played
 * @param frames    The number of frames required
 * @param audio     The audio buffer list - audio should be copied into the provided buffers
 */
typedef OSStatus (*TPAudioControllerPlaybackCallback) (id<TPAudioPlayable>       channel,
                                                       const AudioTimeStamp     *time,
                                                       UInt32                    frames,
                                                       AudioBufferList          *audio);

/*!
 * TPAudioPlayable protocol
 *
 *      The interface that a channel object must implement - this includes 'playbackCallback',
 *      which is a @link TPAudioControllerPlaybackCallback C callback @/link to be called when 
 *      audio is required.  The callback will be passed a reference to this object, so you should
 *      implement it from within the \@implementation block to gain access to your
 *      instance variables.
 */
@protocol TPAudioPlayable <NSObject>
@property (nonatomic, readonly) TPAudioControllerPlaybackCallback playbackCallback;

@optional
@property (nonatomic, readonly) float volume;
@property (nonatomic, readonly) float pan;
@property (nonatomic, readonly) BOOL playing;
@end


/*!
 * Audio delegate callback
 *
 *      This callback is used both for notifying you of incoming audio (either from 
 *      the built-in microphone, or another input device), and outgoing audio that
 *      is about to be played by the system.  
 *      Do not wait on locks, allocate memory, or call any Objective-C or BSD code.
 *
 * @param userInfo  The opaque pointer you provided when you registered this callback
 * @param time      The time the audio was received (for input), or the time it will be played (for output)
 * @param frames    The length of the audio, in frames
 * @param audio     The audio buffer list
 */
typedef OSStatus (*TPAudioControllerAudioDelegateCallback) (void                     *userInfo,
                                                            const AudioTimeStamp     *time,
                                                            UInt32                    frames,
                                                            AudioBufferList          *audio);

typedef enum {
    TPAudioTimingContextInput,
    TPAudioTimingContextOutput
} TPAudioTimingContext;

/*!
 * Timing callback
 *
 *      This callback used to notify you when the system time advances.  When called
 *      from an input context, it occurs before any input delegate calls are performed.
 *      When called from an output context, it occurs before any playback callbacks are
 *      performed.
 *      Do not wait on locks, allocate memory, or call any Objective-C or BSD code.
 *
 * @param userInfo  The opaque pointer you provided when you registered this callback
 * @param time      The time the audio was received (for input), or the time it will be played (for output)
 * @param context   The timing context - either input, or output
 */
typedef OSStatus (*TPAudioControllerTimingCallback) (void                     *userInfo,
                                                     const AudioTimeStamp     *time,
                                                     TPAudioTimingContext      context);



/*!
 * Audio filter callback
 *
 *      This is called when audio is ready to be filtered. You should modify the audio data
 *      with the buffers provided.
 *      Do not wait on locks, allocate memory, or call any Objective-C or BSD code.
 *
 * @param userInfo  The opaque pointer you provided when you registered this callback
 * @param time      The time the buffer will be played
 * @param frames    The number of frames of audio provided
 * @param audio     The audio buffer list - audio should be altered in place
 */
typedef OSStatus (*TPAudioControllerFilterCallback) (void                     *userInfo,
                                                     const AudioTimeStamp     *time,
                                                     UInt32                    frames,
                                                     AudioBufferList          *audio);

/*! 
 *  Callback key
 *
 *      Used when returning lists of callbacks (see for example @link recordDelegates @/link). 
 *      This is an NSValue containing a pointer.
 */
extern const NSString *kTPAudioControllerCallbackKey;

/*! 
 *  User info key
 *
 *      Used when returning lists of callbacks (see for example @link recordDelegates @/link). 
 *      This is an NSValue containing a pointer.
 */
extern const NSString *kTPAudioControllerUserInfoKey;

#pragma mark -

/*!
 *  Main controller class
 *
 *      Use:
 *
 *      1. Init
 *      2. Set required parameters
 *      3. Add channels, record delegates, playback delegates, timing delegates and filters, as required.
 *         Note that all these can be added/removed during operation as well.
 *      4. Call @link setupWithAudioDescription: @/link and pass in your audio description describing the
 *         format you want your audio in.
 *      5. Then call @link start @/link to begin processing audio.
 *      
 */
@interface TPAudioController : NSObject

/*!
 * Default audio description
 *
 *      This is a 16-bit signed PCM, stereo, interleaved format at 44.1kHz that can be used
 *      with @link setupWithAudioDescription: @/link.
 */
+ (AudioStreamBasicDescription)defaultAudioDescription;

/*!
 * Determine whether voice processing is available on this device
 *
 *      Older devices are not able to perform voice processing - this determines
 *      whether it's available.  See @link voiceProcessingEnabled @/link for info.
 */
+ (BOOL)voiceProcessingAvailable;

/*!
 * Setup
 *
 *      Setup the audio controller system, with the audio description you provide.
 *
 *      Internally, calling this method causes the audio session to be initialised
 *      (either in MediaPlayback mode, or PlayAndRecord mode if you have enabled
 *      @link enableInput input @/link), then creates and configures the input/output
 *      and mixer audio units.
 *
 * @param audioDescription Audio description to use for all audio
 */
- (void)setupWithAudioDescription:(AudioStreamBasicDescription)audioDescription;

/*!
 * Start audio engine
 */
- (void)start;

/*!
 * Stop audio engine
 */
- (void)stop;

#pragma mark - Channels and delegates

/*!
 * Add channels
 *
 *      Takes an array of one or more objects that implement the @link TPAudioPlayable @/link protocol.
 *
 * @param channels An array of id<TPAudioPlayable> objects
 */
- (void)addChannels:(NSArray*)channels;

/*!
 * Remove channels
 *
 *      Takes an array of one or more objects that implement the @link TPAudioPlayable @/link protocol.
 *
 * @param channels An array of id<TPAudioPlayable> objects
 */
- (void)removeChannels:(NSArray*)channels;

/*!
 * Add a record delegate
 *
 *      Record delegates receive audio that is being received by the microphone or another input device.
 *
 *      Note that if the @link receiveMonoInputAsBridgedStereo @/link property is set to YES, then incoming
 *      audio may be mono. Check the audio buffer list parameters to determine the kind of audio you are
 *      receiving (for example, if you are using the @link defaultAudioDescription default audio description @/link
 *      then the audio->mBuffers[0].mNumberOfChannels field will be 1 for mono, and 2 for stereo audio).
 *
 * @param callback A @link TPAudioControllerAudioDelegateCallback @/link callback to receive audio
 * @param userInfo An opaque pointer to be passed to the callback
 */
 
- (void)addRecordDelegate:(TPAudioControllerAudioDelegateCallback)callback userInfo:(void*)userInfo;

/*!
 * Remove a record delegate
 *
 * @param callback The callback to remove
 * @param userInfo The opaque pointer that was passed when the callback was added
 */
- (void)removeRecordDelegate:(TPAudioControllerAudioDelegateCallback)callback userInfo:(void*)userInfo;

/*!
 * Add a playback delegate
 *
 *      Playback delegates receive audio that is being played by the system.  This is the outgoing
 *      audio that consists of all the playing channels mixed together.
 *
 * @param callback A @link TPAudioControllerAudioDelegateCallback @/link callback to receive audio
 * @param userInfo An opaque pointer to be passed to the callback
 */
- (void)addPlaybackDelegate:(TPAudioControllerAudioDelegateCallback)callback userInfo:(void*)userInfo;

/*!
 * Remove a playback delegate
 *
 * @param callback The callback to remove
 * @param userInfo The opaque pointer that was passed when the callback was added
 */
- (void)removePlaybackDelegate:(TPAudioControllerAudioDelegateCallback)callback userInfo:(void*)userInfo;

/*!
 * Add a timing delegate
 *
 *      Timing delegates receive notifications for when time has advanced.  When called
 *      from an input context, the call occurs before any input delegate calls are performed.
 *      When called from an output context, it occurs before any playback callbacks are
 *      performed.
 *
 *      This mechanism can be used to trigger time-dependent events.
 *
 * @param callback A @link TPAudioControllerTimingCallback @/link callback to receive audio
 * @param userInfo An opaque pointer to be passed to the callback
 */
- (void)addTimingDelegate:(TPAudioControllerTimingCallback)callback userInfo:(void*)userInfo;

/*!
 * Remove a timing delegate
 *
 * @param callback The callback to remove
 * @param userInfo The opaque pointer that was passed when the callback was added
 */
- (void)removeTimingDelegate:(TPAudioControllerTimingCallback)callback userInfo:(void*)userInfo;

#pragma mark - Properties

/*!
 * Enable audio input
 *
 *      Set to YES to enable recording from an input device.
 *
 *      Setting this parameter after calling setupWithAudioDescription: will cause
 *      the entire audio system to be shut down and restarted with the new setting,
 *      which will result in a break in audio playback.
 *
 *      Default is NO.
 */
@property (nonatomic, assign) BOOL enableInput;

/*! 
 * Mute output
 *
 *      Set to YES to mute all system output. Note that even if this is YES, playback
 *      delegates will still receive audio, as the silencing happens after playback delegate
 *      callbacks are called.
 */
@property (nonatomic, assign) BOOL muteOutput;

/*!
 * Whether to use the built-in voice processing system
 *
 *      This can be useful for removing echo/feedback when playing through the speaker
 *      while simultaneously recording through the microphone.  Not suitable for music,
 *      but works adequately well for speech.
 *
 *      Note that changing this value after calling setupWithAudioDescription: will cause
 *      the entire audio system to be shut down and restarted with the new setting, which
 *      will result in a break in audio playback.
 *
 *      Enabling voice processing in short buffer duration environments (< 0.01s) may cause
 *      stuttering.
 *
 *      Default is NO.
 */
@property (nonatomic, assign) BOOL voiceProcessingEnabled;

/*!
 * Whether to only perform voice processing for the SpeakerAndMicrophone route
 *
 *      This causes voice processing to only be enabled in the classic echo removal
 *      scenario, when audio is being played through the device speaker and recorded
 *      by the device microphone.
 *
 *      Default is YES.
 */
@property (nonatomic, assign) BOOL voiceProcessingOnlyForSpeakerAndMicrophone;

/*! 
 * Whether to receive audio input from mono devices as bridged stereo
 *
 *      If you are using a stereo audio format, setting this to YES causes audio input
 *      from mono input devices to be received by record delegates as bridged stereo audio.
 *      Otherwise, audio will be received as mono audio.
 *
 *      See also discussion of @link addRecordDelegate:userInfo: @/link.
 *
 *      Default is YES.
 */
@property (nonatomic, assign) BOOL receiveMonoInputAsBridgedStereo;

/*!
 * Preferred buffer duration (in seconds)
 *
 *      Set this to low values for better latency, but more processing overhead, or higher
 *      values for greater latency with lower processing overhead.  This parameter affects
 *      the length of the audio buffers received by the various callbacks and delegates.
 *
 *      Default is 0.005.
 */
@property (nonatomic, assign) float preferredBufferDuration;

/*!
 * Obtain a list of all current channels
 */
@property (retain, readonly) NSArray *channels;

/*!
 * Obtain a list of all record delegates
 *
 *      This yields an NSArray of NSDictionary elements, each containing a filter callback
 *      (kTPAudioControllerCallbackKey) and the corresponding userinfo (kTPAudioControllerUserInfoKey).
 */
@property (retain, readonly) NSArray *recordDelegates;

/*!
 * Obtain a list of all playback delegates
 *
 *      This yields an NSArray of NSDictionary elements, each containing a filter callback
 *      (kTPAudioControllerCallbackKey) and the corresponding userinfo (kTPAudioControllerUserInfoKey).
 */
@property (retain, readonly) NSArray *playbackDelegates;

/*!
 * Obtain a list of all timing delegates
 *
 *      This yields an NSArray of NSDictionary elements, each containing a filter callback
 *      (TPAudioControllerTimingCallback) and the corresponding userinfo (kTPAudioControllerUserInfoKey).
 */
@property (retain, readonly) NSArray *timingDelegates;

/*!
 * Determine whether the audio engine is running
 *
 *      This is affected by calling start and stop on the audio controller.
 */
@property (nonatomic, readonly) BOOL running;

/*!
 * Determine whether audio is currently being played through the device's speaker
 *
 *      This property is observable
 */
@property (nonatomic, readonly) BOOL playingThroughDeviceSpeaker;

/*!
 * Whether audio input is currently available
 *
 *      Note: This property is observable
 */
@property (nonatomic, readonly) BOOL audioInputAvailable;

/*!
 * The number of audio channels than the current audio input device provides
 *
 *      Note: This property is observable
 */
@property (nonatomic, readonly) NSUInteger numberOfInputChannels;

/*!
 * The audio description that the audio controller was setup with
 */
@property (nonatomic, readonly) AudioStreamBasicDescription audioDescription;

/*!
 * The Remote IO audio unit used for input and output
 */
@property (nonatomic, readonly) AudioUnit audioUnit;

@end

