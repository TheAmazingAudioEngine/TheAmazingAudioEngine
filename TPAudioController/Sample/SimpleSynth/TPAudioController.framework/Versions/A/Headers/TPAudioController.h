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
@class TPAudioController;

/*!
 * Render callback
 *
 *      This is called when audio for the channel is required. As this is called from Core Audio's
 *      realtime thread, you should not wait on locks, allocate memory, or call any Objective-C or BSD
 *      code from this callback.
 *
 *      The channel object is passed through as a parameter.  You should not send it Objective-C
 *      messages, but if you implement the callback within your channel's \@implementation block, you 
 *      can gain direct access to the instance variables of the channel ("channel->myInstanceVariable").
 *
 * @param channel           The channel object
 * @param time              The time the buffer will be played
 * @param frames            The number of frames required
 * @param audio             The audio buffer list - audio should be copied into the provided buffers
 */
typedef OSStatus (*TPAudioControllerRenderCallback) (id<TPAudioPlayable>       channel,
                                                     const AudioTimeStamp     *time,
                                                     UInt32                    frames,
                                                     AudioBufferList          *audio);

/*!
 * TPAudioPlayable protocol
 *
 *      The interface that a channel object must implement - this includes 'renderCallback',
 *      which is a @link TPAudioControllerRenderCallback C callback @/link to be called when 
 *      audio is required.  The callback will be passed a reference to this object, so you should
 *      implement it from within the \@implementation block to gain access to your
 *      instance variables.
 */
@protocol TPAudioPlayable <NSObject>

/*!
 * Reference to the render callback
 *
 *      This method must return a pointer to the render callback function that provides
 *      the channel audio.  Always return the same pointer - this must not change over time.
 *
 * @return Pointer to a render callback function
 */
@property (nonatomic, readonly) TPAudioControllerRenderCallback renderCallback;

@optional

/*!
 * Track volume
 *
 *      Changes are tracked by Key-Value Observing, so be sure to send KVO notifications
 *      when the value changes (or use a readwrite property).
 *
 *      Range: 0.0 to 1.0
 */
@property (nonatomic, readonly) float volume;

/*!
 * Track pan
 *
 *      Changes are tracked by Key-Value Observing, so be sure to send KVO notifications
 *      when the value changes (or use a readwrite property).
 *
 *      Range: -1.0 (left) to 1.0 (right)
 */
@property (nonatomic, readonly) float pan;

/*
 * Whether track is currently playing
 *
 *      If this is NO, then the track will be silenced and no further render callbacks
 *      will be performed until set to YES again.
 *
 *      Changes are tracked by Key-Value Observing, so be sure to send KVO notifications
 *      when the value changes (or use a readwrite property).
 */
@property (nonatomic, readonly) BOOL playing;

/*
 * Whether track is muted
 *
 *      If YES, track will be silenced, but render callbacks will continue to be performed.
 *      
 *      Changes are tracked by Key-Value Observing, so be sure to send KVO notifications
 *      when the value changes (or use a readwrite property).
 */
@property (nonatomic, readonly) BOOL muted;

@end


/*!
 * Audio callback callback
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
typedef OSStatus (*TPAudioControllerAudioCallback) (void                     *userInfo,
                                                    const AudioTimeStamp     *time,
                                                    UInt32                    frames,
                                                    AudioBufferList          *audio);

/*!
 * Timing contexts
 *
 *      Used to indicate which context the audio system is in when a timing callback
 *      is called.
 *
 * @constant TPAudioTimingContextInput
 *      Input context: Audio system is about to process some incoming audio (from microphone, etc).
 *
 * @constant TPAudioTimingContextOutput
 *      Output context: Audios sytem is about to render the next buffer for playback.
 *
 */
typedef enum {
    TPAudioTimingContextInput,
    TPAudioTimingContextOutput
} TPAudioTimingContext;

/*!
 * Timing callback
 *
 *      This callback used to notify you when the system time advances.  When called
 *      from an input context, it occurs before any input callback calls are performed.
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
 * Callback key
 *
 *      Used when returning lists of callbacks (see for example @link recordCallbacks @/link). 
 *      This is an NSValue containing a pointer.
 */
extern const NSString *kTPAudioControllerCallbackKey;

/*! 
 * User info key
 *
 *      Used when returning lists of callbacks (see for example @link recordCallbacks @/link). 
 *      This is an NSValue containing a pointer.
 */
extern const NSString *kTPAudioControllerUserInfoKey;

/*!
 * Channel group identifier
 *
 *      See @link createChannelGroup @/link for more info.
 */
typedef struct _channel_group_t* TPChannelGroup;

/*!
 * Message handler function
 */
typedef long (*TPAudioControllerMessageHandler) (TPAudioController *audioController, long *ioParameter1, long *ioParameter2, long *ioParameter3, void *ioOpaquePtr);

#pragma mark -

/*!
 *  Main controller class
 *
 *      Use:
 *
 *      1. Initialise, with the desired audio format
 *      2. Set required parameters
 *      3. Add channels, record callbacks, playback callbacks, timing callbacks and filters, as required.
 *         Note that all these can be added/removed during operation as well.
 *      4. Call @link start @/link to begin processing audio.
 *      
 */
@interface TPAudioController : NSObject

#pragma mark - Setup and start/stop

/*! @methodgroup Setup and start/stop */

/*!
 * Default audio description
 *
 *      This is a 16-bit signed PCM, stereo, interleaved format at 44.1kHz that can be used
 *      with @link initWithAudioDescription: @/link.
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
 * Initialize the audio controller system, with the audio description you provide.
 *
 *      Creates and configures the audio unit and initial mixer audio unit.
 *
 *      This initialises the audio system without input (from microphone, etc) enabled. If
 *      you desire audio input, use @link initWithAudioDescription:inputEnabled:useVoiceProcessing: @/link.
 *
 * @param audioDescription  Audio description to use for all audio
 */
- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription;

/*!
 * Initialize the audio controller system, with the audio description you provide.
 *
 *      Creates and configures the input/output audio unit and initial mixer audio unit.
 *
 * @param audioDescription    Audio description to use for all audio
 * @param enableInput         Whether to enable audio input from the microphone or another input device
 * @param useVoiceProcessing  Whether to use the voice processing unit (see @link voiceProcessingEnabled @/link and @link voiceProcessingAvailable @/link).
 */
- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput useVoiceProcessing:(BOOL)useVoiceProcessing;

/*!
 * Start audio engine
 *
 *      Calling this method for the first time causes the audio session to be initialised
 *      (either in MediaPlayback mode, or PlayAndRecord mode if you have enabled
 *      @link enableInput input @/link).
 */
- (void)start;

/*!
 * Stop audio engine
 */
- (void)stop;


#pragma mark - Channel and channel group management

/*! @methodgroup Channel and channel group management */

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
 * Create a channel group
 *
 *      Channel groups cause the channels within the group to be pre-mixed together, so that one filter
 *      can be applied to several channels without the added performance impact.
 *
 *      You can create trees of channel groups using @link addChannels:toChannelGroup: @/link, with
 *      filtering at each branch, for complex filter chaining.
 *
 * @return An identifier for the created group
 */
- (TPChannelGroup)createChannelGroup;

/*!
 * Create a channel sub-group within an existing channel group
 *
 *      With this method, you can create trees of channel groups, with filtering steps at
 *      each branch of the tree.
 *
 * @param group Group identifier
 * @return An identifier for the created group
 */
- (TPChannelGroup)createChannelGroupWithinChannelGroup:(TPChannelGroup)group;

/*!
 * Remove a channel group
 *
 *      Removes channels from the group and releases associated resources.
 *      Ungrouped channels will be added to the top level of the processing tree.
 *
 * @param group Group identifier
 */
- (void)removeChannelGroup:(TPChannelGroup)group;

/*!
 * Get a list of top-level channel groups
 *
 * @return Array of NSValues containing pointers (group identifiers)
 */
- (NSArray*)topLevelChannelGroups;

/*!
 * Get a list of sub-groups contained within a group
 *
 * @param group Group identifier
 * @return Array of NSNumber containing sub-group identifiers
 */
- (NSArray*)channelGroupsInChannelGroup:(TPChannelGroup)group;

/*!
 * Add channels to a channel group
 *
 *      If any channels have already been added with @link addChannels: @/link, then
 *      these will be moved from the top level of the processing tree to within the
 *      channel group.
 *
 * @param channels Array of id<TPAudioPlayable> objects
 * @param group    Group identifier
 */
- (void)addChannels:(NSArray*)channels toChannelGroup:(TPChannelGroup)group;

/*!
 * Remove channels from a channel group
 *
 *      Ungrouped channels will be re-added to the top level of the processing tree.
 *
 * @param channels Array of id<TPAudioPlayable> objects
 * @param group    Group identifier
 */
- (void)removeChannels:(NSArray*)channels fromChannelGroup:(TPChannelGroup)group;

/*!
 * Get a list of channels within a channel group
 *
 * @param group Group identifier
 * @return Array of id<TPAudioPlayable> objects contained within the group
 */
- (NSArray*)channelsInChannelGroup:(TPChannelGroup)group;


#pragma mark - Filters

/*! @methodgroup Filters */


/*!
 * Add an audio filter to a channel
 *
 *      Audio filters are used to process live audio before playback.
 *
 *      You can apply audio filters to one or more channels - use channel groups to do so
 *      without the extra performance overhead by pre-mixing channels together first. See
 *      @link createChannelGroup @/link.
 *
 *      You can also apply more than one audio filter to a channel - each audio filter will
 *      be performed on the audio in the order in which the filters were added using this
 *      method.
 *
 * @param callback A @link TPAudioControllerFilterCallback @/link callback to process audio
 * @param userInfo An opaque pointer to be passed to the callback
 * @param channel  The channel on which to perform audio processing
 */
- (void)addFilter:(TPAudioControllerFilterCallback)filter userInfo:(void*)userInfo toChannel:(id<TPAudioPlayable>)channel;

/*!
 * Remove a filter from a channel
 *
 * @param callback The callback to remove
 * @param userInfo The opaque pointer that was passed when the callback was added
 * @param channel  The channel to stop filtering
 */
- (void)removeFilter:(TPAudioControllerFilterCallback)filter userInfo:(void*)userInfo fromChannel:(id<TPAudioPlayable>)channel;

/*!
 * Get a list of all filters currently operating on the channel
 *
 *      This method returns an NSArray of NSDictionary elements, each containing
 *      a filter callback (kTPAudioControllerCallbackKey) and the corresponding userinfo
 *      (kTPAudioControllerUserInfoKey).
 *
 * @param channel Channel to get filters for
 */
- (NSArray*)filtersForChannel:(id<TPAudioPlayable>)channel;

/*!
 * Add an audio filter to a channel group
 *
 *      Audio filters are used to process live audio before playback.
 *
 *      Create and add filters to a channel group to process multiple channels with one filter,
 *      without the performance hit of processing each channel individually.
 *
 * @param callback A @link TPAudioControllerFilterCallback @/link callback to process audio
 * @param userInfo An opaque pointer to be passed to the callback
 * @param group    The channel group on which to perform audio processing
 */
- (void)addFilter:(TPAudioControllerFilterCallback)filter userInfo:(void*)userInfo toChannelGroup:(TPChannelGroup)group;

/*!
 * Remove a filter from a channel group
 *
 * @param callback The callback to remove
 * @param userInfo The opaque pointer that was passed when the callback was added
 * @param group    The group to stop filtering
 */
- (void)removeFilter:(TPAudioControllerFilterCallback)filter userInfo:(void*)userInfo fromChannelGroup:(TPChannelGroup)group;

/*!
 * Get a list of all filters currently operating on the channel group
 *
 *      This method returns an NSArray of NSDictionary elements, each containing
 *      a filter callback (kTPAudioControllerCallbackKey) and the corresponding userinfo
 *      (kTPAudioControllerUserInfoKey).
 *
 * @param group Channel group to get filters for
 */
- (NSArray*)filtersForChannelGroup:(TPChannelGroup)group;

#pragma mark - Callbacks

/*! @methodgroup Callbacks */

/*!
 * Add a record callback
 *
 *      Record callbacks receive audio that is being received by the microphone or another input device.
 *
 *      Note that if the @link receiveMonoInputAsBridgedStereo @/link property is set to YES, then incoming
 *      audio may be mono. Check the audio buffer list parameters to determine the kind of audio you are
 *      receiving (for example, if you are using the @link defaultAudioDescription default audio description @/link
 *      then the audio->mBuffers[0].mNumberOfChannels field will be 1 for mono, and 2 for stereo audio).
 *
 * @param callback A @link TPAudioControllerAudioCallback @/link callback to receive audio
 * @param userInfo An opaque pointer to be passed to the callback
 */

- (void)addRecordCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo;

/*!
 * Remove a record callback
 *
 * @param callback The callback to remove
 * @param userInfo The opaque pointer that was passed when the callback was added
 */
- (void)removeRecordCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo;

/*!
 * Add a playback callback
 *
 *      Playback callbacks receive audio that is being played by the system.  This is the outgoing
 *      audio that consists of all the playing channels mixed together.
 *
 * @param callback A @link TPAudioControllerAudioCallback @/link callback to receive audio
 * @param userInfo An opaque pointer to be passed to the callback
 */
- (void)addPlaybackCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo;

/*!
 * Remove a playback callback
 *
 * @param callback The callback to remove
 * @param userInfo The opaque pointer that was passed when the callback was added
 */
- (void)removePlaybackCallback:(TPAudioControllerAudioCallback)callback userInfo:(void*)userInfo;

/*!
 * Add a timing callback
 *
 *      Timing callbacks receive notifications for when time has advanced.  When called
 *      from an input context, the call occurs before any input callback calls are performed.
 *      When called from an output context, it occurs before any playback callbacks are
 *      performed.
 *
 *      This mechanism can be used to trigger time-dependent events.
 *
 * @param callback A @link TPAudioControllerTimingCallback @/link callback to receive audio
 * @param userInfo An opaque pointer to be passed to the callback
 */
- (void)addTimingCallback:(TPAudioControllerTimingCallback)callback userInfo:(void*)userInfo;

/*!
 * Remove a timing callback
 *
 * @param callback The callback to remove
 * @param userInfo The opaque pointer that was passed when the callback was added
 */
- (void)removeTimingCallback:(TPAudioControllerTimingCallback)callback userInfo:(void*)userInfo;

#pragma mark - Realtime/Main thread messaging system

/*! @methodgroup Realtime/Main thread messaging system */

/*!
 * Send a message to the realtime thread asynchronously, optionally receiving a response via a block
 *
 *      This is a synchronization mechanism that allows you to schedule actions to be performed 
 *      on the realtime audio thread without any locking mechanism required.  Pass in a function pointer
 *      and a number of arguments, and the function will be called on the realtime thread at the next
 *      polling interval.
 *
 *      If provided, the response block will be called on the main thread after the message has
 *      been sent, and will be passed the parameters and result code from the handler.
 *
 * @param handler       A pointer to a function to call on the realtime thread
 * @param parameter1    First parameter, usage up to the developer
 * @param parameter2    Second parameter
 * @param parameter3    Third parameter
 * @param ioOpaquePtr   An opaque pointer
 * @param responseBlock A block to be performed on the main thread after the handler has been run
 */
- (void)performAsynchronousMessageExchangeWithHandler:(TPAudioControllerMessageHandler)handler 
                                           parameter1:(long)parameter1 
                                           parameter2:(long)parameter2
                                           parameter3:(long)parameter3
                                          ioOpaquePtr:(void*)ioOpaquePtr 
                                        responseBlock:(void (^)(long result, long parameter1, long parameter2, long parameter3, void *ioOpaquePtr))responseBlock;

/*!
 * Send a message to the realtime thread synchronously
 *
 *      This is a synchronization mechanism that allows you to schedule actions to be performed 
 *      on the realtime audio thread without any locking mechanism required.  Pass in a function pointer
 *      and a number of arguments, and the function will be called on the realtime thread at the next
 *      polling interval.
 *
 *      This method will block on the main thread until the handler has been called, and a response
 *      received.
 *
 * @param handler       A pointer to a function to call on the realtime thread
 * @param parameter1    First parameter, usage up to the developer
 * @param parameter2    Second parameter
 * @param parameter3    Third parameter
 * @param ioOpaquePtr   An opaque pointer
 * @return The result returned from the handler
 */
- (long)performSynchronousMessageExchangeWithHandler:(TPAudioControllerMessageHandler)handler 
                                          parameter1:(long)parameter1 
                                          parameter2:(long)parameter2 
                                          parameter3:(long)parameter3
                                         ioOpaquePtr:(void*)ioOpaquePtr;

/*!
 * Send a message to the main thread asynchronously
 *
 *      This is a synchronization mechanism that allows you to schedule actions to be performed 
 *      on the main thread, without any locking or memory allocation.  Pass in a function pointer
 *      and a number of arguments, and the function will be called on the main thread at the next
 *      polling interval.
 *
 * @param audioController The audio controller
 * @param handler       A pointer to a function to call on the main thread
 * @param parameter1    First parameter, usage up to the developer
 * @param parameter2    Second parameter
 * @param parameter3    Third parameter
 * @param ioOpaquePtr   An opaque pointer
 */
void TPAudioControllerSendAsynchronousMessageToMainThread(TPAudioController* audioController, 
                                                          TPAudioControllerMessageHandler handler, 
                                                          long parameter1, 
                                                          long parameter2,
                                                          long parameter3,
                                                          void *ioOpaquePtr);


#pragma mark - Properties

/*! @group Properties */

/*!
 * Enable audio input
 *
 *      Set to YES to enable recording from an input device.
 *
 *      Note that setting this parameter will cause the entire audio system to be shut down and 
 *      restarted with the new setting, which will result in a break in audio playback.
 *
 *      Default is NO.
 */
@property (nonatomic, assign) BOOL enableInput;

/*! 
 * Mute output
 *
 *      Set to YES to mute all system output. Note that even if this is YES, playback
 *      callbacks will still receive audio, as the silencing happens after playback callback
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
 *      Note that changing this value will cause the entire audio system to be shut down 
 *      and restarted with the new setting, which will result in a break in audio playback.
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
 *      from mono input devices to be received by record callbacks as bridged stereo audio.
 *      Otherwise, audio will be received as mono audio.
 *
 *      See also discussion of @link addRecordCallback:userInfo: @/link.
 *
 *      Default is YES.
 */
@property (nonatomic, assign) BOOL receiveMonoInputAsBridgedStereo;

/*!
 * Preferred buffer duration (in seconds)
 *
 *      Set this to low values for better latency, but more processing overhead, or higher
 *      values for greater latency with lower processing overhead.  This parameter affects
 *      the length of the audio buffers received by the various callbacks and callbacks.
 *
 *      Default is 0.005.
 */
@property (nonatomic, assign) float preferredBufferDuration;

/*!
 * Obtain a list of all current channels
 */
@property (retain, readonly) NSArray *channels;

/*!
 * Obtain a list of all record callbacks
 *
 *      This yields an NSArray of NSDictionary elements, each containing a filter callback
 *      (kTPAudioControllerCallbackKey) and the corresponding userinfo (kTPAudioControllerUserInfoKey).
 */
@property (retain, readonly) NSArray *recordCallbacks;

/*!
 * Obtain a list of all playback callbacks
 *
 *      This yields an NSArray of NSDictionary elements, each containing a filter callback
 *      (kTPAudioControllerCallbackKey) and the corresponding userinfo (kTPAudioControllerUserInfoKey).
 */
@property (retain, readonly) NSArray *renderCallbacks;

/*!
 * Obtain a list of all timing callbacks
 *
 *      This yields an NSArray of NSDictionary elements, each containing a filter callback
 *      (TPAudioControllerTimingCallback) and the corresponding userinfo (kTPAudioControllerUserInfoKey).
 */
@property (retain, readonly) NSArray *timingCallbacks;

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

