//
//  AEAudioController.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 25/11/2011.
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

#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>

@class AEAudioController;

#pragma mark - Notifications and constants

/*!
 * @var AEAudioControllerSessionInterruptionBeganNotification
 *  Notification that the audio session has been interrupted.
 *
 * @var AEAudioControllerSessionInterruptionEndedNotification
 *  Notification that the audio session interrupted has ended, and control
 *  has been passed back to the application.
 *
 * @var AEAudioControllerSessionRouteChangeNotification
 *  Notification that the system's audio route has changed.
 *
 * @var AEAudioControllerDidRecreateGraphNotification
 *  Notification that AEAudioController has shut down and re-initialized
 *  the audio graph. This can happen in response to some unexpected system 
 *  errors. Objects that use the graph directly (such as creating audio units)
 *  should re-initialise the audio units.
 *
 * @var AEAudioControllerErrorOccurredNotification
 *  Some asynchronous error occurred, such as when the user denies your app
 *  record access. The userInfo dictionary of the notification will contain
 *  the AVAudioControllerErrorKey, an NSError.
 */
extern NSString * const AEAudioControllerSessionInterruptionBeganNotification;
extern NSString * const AEAudioControllerSessionInterruptionEndedNotification;
extern NSString * const AEAudioControllerSessionRouteChangeNotification;
extern NSString * const AEAudioControllerDidRecreateGraphNotification;
extern NSString * const AEAudioControllerErrorOccurredNotification;
    
/*!
 * Keys to be used with notifications
 */
extern NSString * const AEAudioControllerErrorKey;

/*!
 * Errors
 */
extern NSString * const AEAudioControllerErrorDomain;
enum {
    AEAudioControllerErrorInputAccessDenied
};
    
/*!
 * @enum AEInputMode
 *  Input mode
 *
 *  How to handle incoming audio
 *
 * @var AEInputModeFixedAudioFormat
 *  Receive input in the exact, fixed audio format you specified when initializing the
 *  audio controller, regardless of the number of input channels. For example, if you
 *  specified a stereo audio stream description, and you have a mono input source, the mono source
 *  will be bridged to stereo.
 *
 *  This is the default.
 *
 * @var AEInputModeVariableAudioFormat
 *  Audio format will change, depending on the number of input channels available.
 *  Mono audio sources will produce mono audio; 8-channel audio sources will produce 8-channel
 *  audio. You can determine how many channels are being provided by examining the
 *  `mNumberBuffers` field of the AudioBufferList for non-interleaved audio, or the
 *  `mNumberOfChannels` field of the first buffer within the AudioBufferList for 
 *  interleaved audio. Note that this might change without warning, as the user plugs/unplugs
 *  hardware.
 */
typedef enum {
    AEInputModeFixedAudioFormat,
    AEInputModeVariableAudioFormat
} AEInputMode;

#pragma mark - Callbacks and protocols

/*!
 * Render callback
 *
 *  This is called when audio for the channel is required. As this is called from Core Audio's
 *  realtime thread, you should not wait on locks, allocate memory, or call any Objective-C or BSD
 *  code from this callback.
 *
 *  The channel object is passed through as a parameter.  You should not send it Objective-C
 *  messages, but if you implement the callback within your channel's \@implementation block, you 
 *  can gain direct access to the instance variables of the channel ("((MyChannel*)channel)->myInstanceVariable").
 *
 * @param channel           The channel object
 * @param audioController   The Audio Controller
 * @param time              The time the buffer will be played, automatically compensated for hardware latency.
 * @param frames            The number of frames required
 * @param audio             The audio buffer list - audio should be copied into the provided buffers
 * @return A status code
 */
typedef OSStatus (*AEAudioControllerRenderCallback) (__unsafe_unretained id    channel,
                                                     __unsafe_unretained AEAudioController *audioController,
                                                     const AudioTimeStamp     *time,
                                                     UInt32                    frames,
                                                     AudioBufferList          *audio);

/*!
 * AEAudioPlayable protocol
 *
 *  The interface that a channel object must implement - this includes 'renderCallback',
 *  which is a @link AEAudioControllerRenderCallback C callback @endlink to be called when 
 *  audio is required.  The callback will be passed a reference to this object, so you should
 *  implement it from within the \@implementation block to gain access to your
 *  instance variables.
 */
@protocol AEAudioPlayable <NSObject>

/*!
 * Reference to the render callback
 *
 *  This method must return a pointer to the render callback function that provides
 *  the channel audio.  Always return the same pointer - this must not change over time.
 *
 * @return Pointer to a render callback function
 */
@property (nonatomic, readonly) AEAudioControllerRenderCallback renderCallback;

@optional

/*!
 * Track volume
 *
 *  Changes are tracked by Key-Value Observing, so be sure to send KVO notifications
 *  when the value changes (or use a readwrite property).
 *
 *  Range: 0.0 to 1.0
 */
@property (nonatomic, readonly) float volume;

/*!
 * Track pan
 *
 *  Changes are tracked by Key-Value Observing, so be sure to send KVO notifications
 *  when the value changes (or use a readwrite property).
 *
 *  Range: -1.0 (left) to 1.0 (right)
 */
@property (nonatomic, readonly) float pan;

/*
 * Whether channel is currently playing
 *
 *  If this is NO, then the track will be silenced and no further render callbacks
 *  will be performed until set to YES again.
 *
 *  Changes are tracked by Key-Value Observing, so be sure to send KVO notifications
 *  when the value changes (or use a readwrite property).
 */
@property (nonatomic, readonly) BOOL channelIsPlaying;

/*
 * Whether channel is muted
 *
 *  If YES, track will be silenced, but render callbacks will continue to be performed.
 *  
 *  Changes are tracked by Key-Value Observing, so be sure to send KVO notifications
 *  when the value changes (or use a readwrite property).
 */
@property (nonatomic, readonly) BOOL channelIsMuted;

/*
 * The audio format for this channel
 */
@property (nonatomic, readonly) AudioStreamBasicDescription audioDescription;

@end

/*!
 * @var AEAudioSourceInput
 *  Main audio input
 *
 * @var AEAudioSourceMainOutput
 *  Main audio output
 */
#define AEAudioSourceInput           ((void*)0x01)
#define AEAudioSourceMainOutput      ((void*)0x02)

/*!
 * Audio callback
 *
 *  This callback is used for notifying you of incoming audio (either from 
 *  the built-in microphone, or another input device), and outgoing audio that
 *  is about to be played by the system.
 *
 *  The receiver object is passed through as a parameter.  You should not send it Objective-C
 *  messages, but if you implement the callback within your receiver's \@implementation block, you 
 *  can gain direct access to the instance variables of the receiver ("((MyReceiver*)receiver)->myInstanceVariable").
 *
 *  Do not wait on locks, allocate memory, or call any Objective-C or BSD code.
 *
 * @param receiver   The receiver object
 * @param audioController The Audio Controller
 * @param source     The source of the audio: @link AEAudioSourceInput @endlink, @link AEAudioSourceMainOutput @endlink, an AEChannelGroupRef or an id<AEAudioPlayable>.
 * @param time       The time the audio was received (for input), or the time it will be played (for output), automatically compensated for hardware latency.
 * @param frames     The length of the audio, in frames
 * @param audio      The audio buffer list
 */
typedef void (*AEAudioControllerAudioCallback) (__unsafe_unretained id    receiver,
                                                __unsafe_unretained AEAudioController *audioController,
                                                void                     *source,
                                                const AudioTimeStamp     *time,
                                                UInt32                    frames,
                                                AudioBufferList          *audio);


/*!
 * AEAudioReceiver protocol
 *
 *  The interface that a object must implement to receive incoming or outgoing output audio.
 *  This includes 'receiverCallback', which is a @link AEAudioControllerAudioCallback C callback @endlink 
 *  to be called when audio is available.  The callback will be passed a reference to this object, so you 
 *  should implement it from within the \@implementation block to gain access to your instance variables.
 */
@protocol AEAudioReceiver <NSObject>

/*!
 * Reference to the receiver callback
 *
 *  This method must return a pointer to the receiver callback function that accepts received
 *  audio.  Always return the same pointer - this must not change over time.
 *
 * @return Pointer to an audio callback
 */
@property (nonatomic, readonly) AEAudioControllerAudioCallback receiverCallback;

@end

/*!
 * Filter audio producer
 *
 *  This defines the function passed to a AEAudioControllerFilterCallback,
 *  which is used to produce input audio to be processed by the filter.
 *
 * @param producerToken    An opaque pointer to be passed to the function
 * @param audio            Audio buffer list to be written to
 * @param frames           Number of frames to produce on input, number of frames produced on output
 * @return A status code
 */
typedef OSStatus (*AEAudioControllerFilterProducer)(void            *producerToken, 
                                                    AudioBufferList *audio, 
                                                    UInt32          *frames);


/*!
 * Filter callback
 *
 *  This callback is used for audio filters.
 *
 *  A filter implementation must call the function pointed to by the *producer* argument,
 *  passing *producerToken*, *audio*, and *frames* as arguments, in order to produce as much
 *  audio is required to produce *frames* frames of output audio:
 *
 *          OSStatus status = producer(producerToken, audio, &frames);
 *          if ( status != noErr ) return status;
 *
 *  Then the audio can be processed as desired.
 *
 *  The filter object is passed through as a parameter.  You should not send it Objective-C
 *  messages, but if you implement the callback within your filter's \@implementation block, you 
 *  can gain direct access to the instance variables of the filter ("((MyFilter*)filter)->myInstanceVariable").
 *
 *  Do not wait on locks, allocate memory, or call any Objective-C or BSD code.
 *
 * @param filter    The filter object
 * @param audioController The Audio Controller
 * @param producer  A function pointer to be used to produce input audio
 * @param producerToken An opaque pointer to be passed to the producer as the first argument
 * @param time      The time the output audio will be played or the time input audio was received, automatically compensated for hardware latency.
 * @param frames    The length of the required audio, in frames
 * @param audio     The audio buffer list to write output audio to
 * @return A status code
 */
typedef OSStatus (*AEAudioControllerFilterCallback)(__unsafe_unretained id    filter,
                                                    __unsafe_unretained AEAudioController *audioController,
                                                    AEAudioControllerFilterProducer producer,
                                                    void                     *producerToken,
                                                    const AudioTimeStamp     *time,
                                                    UInt32                    frames,
                                                    AudioBufferList          *audio);

/*!
 * AEAudioFilter protocol
 *
 *  The interface that a filter must implement - this includes 'filterCallback', which is a 
 *  @link AEAudioControllerFilterCallback C callback @endlink to be called when
 *  audio is to be filtered.  The callback will be passed a reference to this object, so you should
 *  implement it from within the \@implementation block to gain access to your
 *  instance variables.
 *
 *  Note that it is your responsibility to make sure you are using the correct
 *  AudioStreamBasicDescription for the source you are filtering.
 */
@protocol AEAudioFilter <NSObject>

/*!
 * Reference to the filter callback
 *
 *  This method must return a pointer to the filter callback function that performs
 *  audio manipulation.  Always return the same pointer - this must not change over time.
 *
 * @return Pointer to a variable speed filter callback
 */
@property (nonatomic, readonly) AEAudioControllerFilterCallback filterCallback;

@end


/*!
 * @enum AEAudioTimingContext
 *  Timing contexts
 *
 *  Used to indicate which context the audio system is in when a timing receiver
 *  is called.
 *
 * @var AEAudioTimingContextInput
 *  Input context: Audio system is about to process some incoming audio (from microphone, etc).
 *
 * @var AEAudioTimingContextOutput
 *  Output context: Audio system is about to render the next buffer for playback.
 *
 */
typedef enum {
    AEAudioTimingContextInput,
    AEAudioTimingContextOutput
} AEAudioTimingContext;

/*!
 * Timing callback
 *
 *  This callback used to notify you when the system time advances.  When called
 *  from an input context, it occurs before any input receiver calls are performed.
 *  When called from an output context, it occurs before any output receivers are
 *  performed.
 *
 *  The receiver object is passed through as a parameter.  You should not send it Objective-C
 *  messages, but if you implement the callback within your receiver's \@implementation block, you 
 *  can gain direct access to the instance variables of the receiver ("((MyReceiver*)receiver)->myInstanceVariable").
 *
 *  Do not wait on locks, allocate memory, or call any Objective-C or BSD code.
 *
 * @param receiver  The receiver object
 * @param audioController The Audio Controller
 * @param time      The time the audio was received (for input), or the time it will be played (for output), automatically compensated for hardware latency.
 * @param frames    The number of frames for the current block
 * @param context   The timing context - either input, or output
 */
typedef void (*AEAudioControllerTimingCallback) (__unsafe_unretained id    receiver,
                                                 __unsafe_unretained AEAudioController *audioController,
                                                 const AudioTimeStamp     *time,
                                                 UInt32                    frames,
                                                 AEAudioTimingContext      context);

/*!
 * AEAudioTimingReceiver protocol
 *
 *  The interface that a object must implement to receive system time advance notices.
 *  This includes 'timingReceiver', which is a @link AEAudioControllerTimingCallback C callback @endlink 
 *  to be called when the system time advances.  The callback will be passed a reference to this object, so you 
 *  should implement it from within the \@implementation block to gain access to your instance variables.
 */
@protocol AEAudioTimingReceiver <NSObject>

/*!
 * Reference to the receiver callback
 *
 *  This method must return a pointer to the receiver callback function that accepts received
 *  audio.  Always return the same pointer - this must not change over time.
 *
 * @return Pointer to an audio callback
 */
@property (nonatomic, readonly) AEAudioControllerTimingCallback timingReceiverCallback;

@end


/*!
 * Channel group identifier
 *
 *  See @link AEAudioController::createChannelGroup @endlink for more info.
 */
typedef struct _channel_group_t* AEChannelGroupRef;

@class AEAudioController;

/*!
 * Message handler function
 *
 * @param audioController   The audio controller
 * @param userInfo          Pointer to your data
 * @param userInfoLength    Length of userInfo in bytes
 */
typedef void (*AEAudioControllerMainThreadMessageHandler)(__unsafe_unretained AEAudioController *audioController, void *userInfo, int userInfoLength);

#pragma mark -

/*!
 * Main controller class
 *
 *  Use:
 *
 *  1. [Initialise](initWithAudioDescription:), with the desired audio format.
 *  2. Set required parameters.
 *  3. Add channels, input receivers, output receivers, timing receivers and filters, as required.
 *     Note that all these can be added/removed during operation as well.
 *  4. Call @link start: @endlink to begin processing audio.
 */
@interface AEAudioController : NSObject

#pragma mark - Setup and start/stop
/** @name Setup and start/stop */
///@{

/*!
 * 16-bit stereo audio description, interleaved
 *
 *  This is a 16-bit signed PCM, stereo, interleaved format at 44.1kHz that can be used
 *  with @link initWithAudioDescription: @endlink.
 */
+ (AudioStreamBasicDescription)interleaved16BitStereoAudioDescription;

/*!
 * 16-bit stereo audio description, non-interleaved
 *
 *  This is a 16-bit signed PCM, stereo, non-interleaved format at 44.1kHz that can be used
 *  with @link initWithAudioDescription: @endlink.
 */
+ (AudioStreamBasicDescription)nonInterleaved16BitStereoAudioDescription;

/*!
 * Floating-point stereo audio description, non-interleaved
 *
 *  This is a floating-point PCM, stereo, non-interleaved format at 44.1kHz that can be used
 *  with @link initWithAudioDescription: @endlink.
 */
+ (AudioStreamBasicDescription)nonInterleavedFloatStereoAudioDescription;

/*!
 * Determine whether voice processing is available on this device
 *
 *  Older devices are not able to perform voice processing - this determines
 *  whether it's available.  See @link voiceProcessingEnabled @endlink for info.
 */
+ (BOOL)voiceProcessingAvailable;

/*!
 * Initialize the audio controller system, with the audio description you provide.
 *
 *  Creates and configures the audio unit and initial mixer audio unit.
 *
 *  This initialises the audio system without input (from microphone, etc) enabled. If
 *  you desire audio input, use @link initWithAudioDescription:inputEnabled:useVoiceProcessing: @endlink.
 *
 * @param audioDescription  Audio description to use for all audio
 */
- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription;

/*!
 * Initialize the audio controller system, with the audio description you provide.
 *
 *  Creates and configures the input/output audio unit and initial mixer audio unit.
 *
 * @param audioDescription    Audio description to use for all audio
 * @param enableInput         Whether to enable audio input from the microphone or another input device
 */
- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput;

/*!
 * Initialize the audio controller system, with the audio description you provide.
 *
 *  Creates and configures the input/output audio unit and initial mixer audio unit.
 *
 * @param audioDescription    Audio description to use for all audio
 * @param enableInput         Whether to enable audio input from the microphone or another input device
 * @param useVoiceProcessing  Whether to use the voice processing unit (see @link voiceProcessingEnabled @endlink and @link voiceProcessingAvailable @endlink).
 */
- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput useVoiceProcessing:(BOOL)useVoiceProcessing;

/*!
 * Initialize the audio controller system, with the audio description you provide.
 *
 *  Creates and configures the input/output audio unit and initial mixer audio unit.
 *
 * @param audioDescription    Audio description to use for all audio
 * @param enableInput         Whether to enable audio input from the microphone or another input device
 * @param useVoiceProcessing  Whether to use the voice processing unit (see @link voiceProcessingEnabled @endlink and @link voiceProcessingAvailable @endlink).
 * @param enableOutput        Whether to enable audio output.  Sometimes when recording from external input-only devices at high sample rates (96k) you may need to disable output for the sample rate to be actually used.
 */
- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput useVoiceProcessing:(BOOL)useVoiceProcessing outputEnabled:(BOOL)enableOutput;


- (BOOL)updateWithAudioDescription:(AudioStreamBasicDescription)audioDescription inputEnabled:(BOOL)enableInput useVoiceProcessing:(BOOL)useVoiceProcessing outputEnabled:(BOOL)enableOutput;

/*!
 * Start audio engine
 *
 * @param error On output, if not NULL, the error
 * @return YES on success, NO on failure
 */
- (BOOL)start:(NSError**)error;

/*!
 * Stop audio engine
 */
- (void)stop;

///@}
#pragma mark - Channel and channel group management
/** @name Channel and channel group management */
///@{

/*!
 * Add channels
 *
 *  Takes an array of one or more objects that implement the @link AEAudioPlayable @endlink protocol.
 *
 * @param channels An array of id<AEAudioPlayable> objects
 */
- (void)addChannels:(NSArray*)channels;

/*!
 * Add channels to a channel group
 *
 * @param channels Array of id<AEAudioPlayable> objects
 * @param group    Group identifier
 */
- (void)addChannels:(NSArray*)channels toChannelGroup:(AEChannelGroupRef)group;

/*!
 * Remove channels
 *
 *  Takes an array of one or more objects that implement the @link AEAudioPlayable @endlink protocol.
 *
 * @param channels An array of id<AEAudioPlayable> objects
 */
- (void)removeChannels:(NSArray*)channels;

/*!
 * Remove channels from a channel group
 *
 * @param channels Array of id<AEAudioPlayable> objects
 * @param group    Group identifier
 */
- (void)removeChannels:(NSArray*)channels fromChannelGroup:(AEChannelGroupRef)group;

/*!
 * Obtain a list of all channels, across all channel groups
 */
- (NSArray*)channels;

/*!
 * Get a list of channels within a channel group
 *
 * @param group Group identifier
 * @return Array of id<AEAudioPlayable> objects contained within the group
 */
- (NSArray*)channelsInChannelGroup:(AEChannelGroupRef)group;

/*!
 * Create a channel group
 *
 *  Channel groups cause the channels within the group to be pre-mixed together, so that one filter
 *  can be applied to several channels without the added performance impact.
 *
 *  You can create trees of channel groups using @link addChannels:toChannelGroup: @endlink, with
 *  filtering at each branch, for complex filter chaining.
 *
 * @return An identifier for the created group
 */
- (AEChannelGroupRef)createChannelGroup;

/*!
 * Create a channel sub-group within an existing channel group
 *
 *  With this method, you can create trees of channel groups, with filtering steps at
 *  each branch of the tree.
 *
 * @param group Group identifier
 * @return An identifier for the created group
 */
- (AEChannelGroupRef)createChannelGroupWithinChannelGroup:(AEChannelGroupRef)group;

/*!
 * Remove a channel group
 *
 *  Removes channels from the group and releases associated resources.
 *
 * @param group Group identifier
 */
- (void)removeChannelGroup:(AEChannelGroupRef)group;

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
- (NSArray*)channelGroupsInChannelGroup:(AEChannelGroupRef)group;

/*!
 * Set the volume level of a channel group
 *
 * @param volume    Group volume (0 - 1)
 * @param group     Group identifier
 */
- (void)setVolume:(float)volume forChannelGroup:(AEChannelGroupRef)group;

/*!
 * Get the volume level of a channel group
 *
 * @param group     Group identifier
 * @return Group volume (0 - 1)
 */
- (float)volumeForChannelGroup:(AEChannelGroupRef)group;

/*!
 * Set the pan of a channel group
 *
 * @param pan       Group pan (-1.0, left to 1.0, right)
 * @param group     Group identifier
 */
- (void)setPan:(float)pan forChannelGroup:(AEChannelGroupRef)group;

/*!
 * Get the pan of a channel group
 *
 * @param group     Group identifier
 * @return Group pan (-1.0, left to 1.0, right)
 */
- (float)panForChannelGroup:(AEChannelGroupRef)group;

/*!
 * Set the mute status of a channel group
 *
 * @param muted     Whether group is muted
 * @param group     Group identifier
 */
- (void)setMuted:(BOOL)muted forChannelGroup:(AEChannelGroupRef)group;

/*!
 * Get the mute status of a channel group
 *
 * @param group     Group identifier
 * @return Whether group is muted
 */
- (BOOL)channelGroupIsMuted:(AEChannelGroupRef)group;

///@}
#pragma mark - Filters
/** @name Filters */
///@{

/*!
 * Add an audio filter to the system output
 *
 *  Audio filters are used to process live audio before playback.
 *
 * @param filter An object that implements the AEAudioFilter protocol
 */
- (void)addFilter:(id<AEAudioFilter>)filter;

/*!
 * Add an audio filter to a channel
 *
 *  Audio filters are used to process live audio before playback.
 *
 *  You can apply audio filters to one or more channels - use channel groups to do so
 *  without the extra performance overhead by pre-mixing channels together first. See
 *  @link createChannelGroup @endlink.
 *
 *  You can also apply more than one audio filter to a channel - each audio filter will
 *  be performed on the audio in the order in which the filters were added using this
 *  method.
 *
 * @param filter  An object that implements the AEAudioFilter protocol
 * @param channel The channel on which to perform audio processing
 */
- (void)addFilter:(id<AEAudioFilter>)filter toChannel:(id<AEAudioPlayable>)channel;

/*!
 * Add an audio filter to a channel group
 *
 *  Audio filters are used to process live audio before playback.
 *
 *  Create and add filters to a channel group to process multiple channels with one filter,
 *  without the performance hit of processing each channel individually.
 *
 * @param filter An object that implements the AEAudioFilter protocol
 * @param group  The channel group on which to perform audio processing
 */
- (void)addFilter:(id<AEAudioFilter>)filter toChannelGroup:(AEChannelGroupRef)group;

/*!
 * Add an audio filter to the system input
 *
 *  Audio filters are used to process live audio.
 *
 * @param filter An object that implements the AEAudioFilter protocol
 */
- (void)addInputFilter:(id<AEAudioFilter>)filter;

/*!
 * Add an audio filter to the system input
 *
 *  Audio filters are used to process live audio.
 *
 * @param filter An object that implements the AEAudioFilter protocol
 * @param channels An array of NSNumbers identifying by index the input channels to filter, or nil for default (the same as addInputFilter:)
 */
- (void)addInputFilter:(id<AEAudioFilter>)filter forChannels:(NSArray*)channels;

/*!
 * Remove a filter from system output
 *
 * @param filter The filter to remove
 */
- (void)removeFilter:(id<AEAudioFilter>)filter;

/*!
 * Remove a filter from a channel
 *
 * @param filter  The filter to remove
 * @param channel The channel to stop filtering
 */
- (void)removeFilter:(id<AEAudioFilter>)filter fromChannel:(id<AEAudioPlayable>)channel;

/*!
 * Remove a filter from a channel group
 *
 * @param filter The filter to remove
 * @param group  The group to stop filtering
 */
- (void)removeFilter:(id<AEAudioFilter>)filter fromChannelGroup:(AEChannelGroupRef)group;

/*!
 * Remove a filter from system input
 *
 * @param filter The filter to remove
 */
- (void)removeInputFilter:(id<AEAudioFilter>)filter;

/*!
 * Get a list of all top-level output filters
 */
- (NSArray*)filters;

/*!
 * Get a list of all filters currently operating on the channel
 *
 * @param channel Channel to get filters for
 */
- (NSArray*)filtersForChannel:(id<AEAudioPlayable>)channel;

/*!
 * Get a list of all filters currently operating on the channel group
 *
 * @param group Channel group to get filters for
 */
- (NSArray*)filtersForChannelGroup:(AEChannelGroupRef)group;

/*!
 * Get a list of all input filters
 */
- (NSArray*)inputFilters;

///@}
#pragma mark - Output receivers
/** @name Output receivers */
///@{

/*!
 * Add an output receiver
 *
 *  Output receivers receive audio that is being played by the system.  Use this
 *  method to add a receiver to receive audio that consists of all the playing channels
 *  mixed together.
 *
 * @param receiver An object that implements the AEAudioReceiver protocol
 */
- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver;

/*!
 * Add an output receiver
 *
 *  Output receivers receive audio that is being played by the system.  Use this
 *  method to add a callback to receive audio from a particular channel.
 *
 * @param receiver An object that implements the AEAudioReceiver protocol
 * @param channel  A channel
 */
- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannel:(id<AEAudioPlayable>)channel;

/*!
 * Add an output receiver for a particular channel group
 *
 *  Output receivers receive audio that is being played by the system.  By registering
 *  a callback for a particular channel group, you can receive the mixed audio of only that
 *  group.
 *
 * @param receiver An object that implements the AEAudioReceiver protocol
 * @param group    A channel group identifier
 */
- (void)addOutputReceiver:(id<AEAudioReceiver>)receiver forChannelGroup:(AEChannelGroupRef)group;

/*!
 * Remove an output receiver
 *
 * @param receiver The receiver to remove
 */
- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver;

/*!
 * Remove an output receiver from a channel
 *
 * @param receiver The receiver to remove
 * @param channel  Channel to remove receiver from
 */
- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver fromChannel:(id<AEAudioPlayable>)channel;

/*!
 * Remove an output receiver from a particular channel group
 *
 * @param receiver The receiver to remove
 * @param group    A channel group identifier
 */
- (void)removeOutputReceiver:(id<AEAudioReceiver>)receiver fromChannelGroup:(AEChannelGroupRef)group;

/*!
 * Obtain a list of all top-level output receivers
 */
- (NSArray*)outputReceivers;

/*!
 * Obtain a list of all output receivers for the specified channel
 *
 * @param channel A channel
 */
- (NSArray*)outputReceiversForChannel:(id<AEAudioPlayable>)channel;

/*!
 * Obtain a list of all output receivers for the specified group
 *
 * @param group A channel group identifier
 */
- (NSArray*)outputReceiversForChannelGroup:(AEChannelGroupRef)group;

///@}
#pragma mark - Input receivers
/** @name Input receivers */
///@{

/*!
 * Add an input receiver
 *
 *  Input receivers receive audio that is being received by the microphone or another input device.
 *
 *  Note that the audio format provided to input receivers added via this method depends on the value
 *  of @link inputMode @endlink. 
 *
 *  Check the audio buffer list parameters to determine the kind of audio you are receiving (for example, 
 *  if you are using an interleaved format such as @link interleaved16BitStereoAudioDescription @endlink
 *  then the audio->mBuffers[0].mNumberOfChannels field will be 1 for mono, and 2 for stereo audio).  If you
 *  are using a non-interleaved format such as @link nonInterleaved16BitStereoAudioDescription @endlink, then
 *  audio->mNumberBuffers will be 1 for mono, and 2 for stereo.
 *
 * @param receiver An object that implements the AEAudioReceiver protocol
 */
- (void)addInputReceiver:(id<AEAudioReceiver>)receiver;

/*!
 * Add an input receiver, specifying a channel selection
 *
 *  Input receivers receive audio that is being received by the microphone or another input device.
 *
 *  This method allows you to specify which input channels to receive by providing an
 *  array of NSNumbers with indexes identifying the selected channels.
 *
 *  Note that the audio format provided to input receivers added via this method depends on the value
 *  of @link inputMode @endlink.
 *
 *  Check the audio buffer list parameters to determine the kind of audio you are receiving (for example,
 *  if you are using an interleaved format such as @link interleaved16BitStereoAudioDescription @endlink
 *  then the audio->mBuffers[0].mNumberOfChannels field will be 1 for mono, and 2 for stereo audio).  If you
 *  are using a non-interleaved format such as @link nonInterleaved16BitStereoAudioDescription @endlink, then
 *  audio->mNumberBuffers will be 1 for mono, and 2 for stereo.
 *
 * @param receiver An object that implements the AEAudioReceiver protocol
 * @param channels An array of NSNumbers identifying by index the input channels to receive, or nil for default (the same as addInputReceiver:)
 */
- (void)addInputReceiver:(id<AEAudioReceiver>)receiver forChannels:(NSArray*)channels;

/*!
 * Remove an input receiver
 *
 * @param receiver Receiver to remove
 */
- (void)removeInputReceiver:(id<AEAudioReceiver>)receiver;

/*!
 * Obtain a list of all input receivers
 */
- (NSArray*)inputReceivers;

///@}
#pragma mark - Timing receivers
/** @name Timing receivers */
///@{

/*!
 * Add a timing receiver
 *
 *  Timing receivers receive notifications for when time has advanced.  When called
 *  from an input context, the call occurs before any input receiver calls are performed.
 *  When called from an output context, it occurs before any output receivers are
 *  performed.
 *
 *  This mechanism can be used to trigger time-dependent events.
 *
 * @param receiver An object that implements the AEAudioTimingReceiver protocol
 */
- (void)addTimingReceiver:(id<AEAudioTimingReceiver>)receiver;

/*!
 * Remove a timing receiver
 *
 * @param receiver An object that implements the AEAudioTimingReceiver protocol
 */
- (void)removeTimingReceiver:(id<AEAudioTimingReceiver>)receiver;

/*!
 * Obtain a list of all timing receivers
 */
- (NSArray*)timingReceivers;

///@}
#pragma mark - Realtime/Main thread messaging system
/** @name Realtime/Main thread messaging system */
///@{

/*!
 * Send a message to the realtime thread asynchronously, optionally receiving a response via a block
 *
 *  This is a synchronization mechanism that allows you to schedule actions to be performed 
 *  on the realtime audio thread without any locking mechanism required.  Pass in a block, and
 *  the block will be performed on the realtime thread at the next polling interval.
 *
 *  Important: Do not interact with any Objective-C objects inside your block, or hold locks, allocate
 *  memory or interact with the BSD subsystem, as all of these may result in audio glitches due
 *  to priority inversion.
 *
 *  If provided, the response block will be called on the main thread after the message has
 *  been sent. You may exchange information from the realtime thread to the main thread via a
 *  shared data structure (such as a struct, allocated on the heap in advance).
 *
 * @param block         A block to be performed on the realtime thread.
 * @param responseBlock A block to be performed on the main thread after the handler has been run, or nil.
 */
- (void)performAsynchronousMessageExchangeWithBlock:(void (^)())block
                                      responseBlock:(void (^)())responseBlock;

/*!
 * Send a message to the realtime thread synchronously
 *
 *  This is a synchronization mechanism that allows you to schedule actions to be performed 
 *  on the realtime audio thread without any locking mechanism required. Pass in a block, and
 *  the block will be performed on the realtime thread at the next polling interval.
 *
 *  Important: Do not interact with any Objective-C objects inside your block, or hold locks, allocate
 *  memory or interact with the BSD subsystem, as all of these may result in audio glitches due
 *  to priority inversion.
 *
 *  This method will block the current thread until the block has been performed on the realtime thread.
 *  You may pass information from the realtime thread to the calling thread via the use of __block variables.
 *
 *  If all you need is a checkpoint to make sure the Core Audio thread is not mid-render, etc, then
 *  you may pass nil for the block.
 *
 * @param block         A block to be performed on the realtime thread.
 */
- (void)performSynchronousMessageExchangeWithBlock:(void (^)())block;

/*!
 * Send a message to the main thread asynchronously
 *
 *  This is a synchronization mechanism that allows you to schedule actions to be performed 
 *  on the main thread, without any locking or memory allocation.  Pass in a function pointer
 *  optionally a pointer to data to be copied and passed to the handler, and the function will 
 *  be called on the realtime thread at the next polling interval.
 *
 * @param audioController The audio controller.
 * @param handler         A pointer to a function to call on the main thread.
 * @param userInfo        Pointer to user info data to pass to handler - this will be copied.
 * @param userInfoLength  Length of userInfo in bytes.
 */
void AEAudioControllerSendAsynchronousMessageToMainThread(__unsafe_unretained AEAudioController *audioController,
                                                          AEAudioControllerMainThreadMessageHandler    handler, 
                                                          void                              *userInfo,
                                                          int                                userInfoLength);


///@}
#pragma mark - Metering
/** @name Metering */
///@{

/*!
 * Get output power level information since this method was last called
 *
 * @param averagePower If not NULL, on output will be set to the average power level of the most recent output audio, in decibels
 * @param peakLevel If not NULL, on output will be set to the peak level of the most recent output audio, in decibels
 */
- (void)outputAveragePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel;

/*!
 * Get output power level information for multiple channels since this method was last called
 *
 * @param averagePowers If not NULL, each element of the array on output will be set to the average power level of the most recent output audio for each channel up to count, in decibels
 * @param peakLevels If not NULL, each element of the array on output will be set to the peak level of the most recent output audio for each channel up to count, in decibels
 * @param channelCount specifies the number of channels to fill in the averagePowers and peakLevels array parameters
 */
- (void)outputAveragePowerLevels:(Float32*)averagePowers peakHoldLevels:(Float32*)peakLevels channelCount:(UInt32)count;

/*!
 * Get output power level information for a particular group, since this method was last called
 *
 * @param averagePower If not NULL, on output will be set to the average power level of the most recent audio, in decibels
 * @param peakLevel If not NULL, on output will be set to the peak level of the most recent audio, in decibels
 * @param group The channel group
 */
- (void)averagePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel forGroup:(AEChannelGroupRef)group;

/*!
 * Get output power level information for a particular group, since this method was last called
 *
 * @param averagePower If not NULL, each element of the array on output will be set to the average power level of the most recent audio for each channel, in decibels
 * @param peakLevel If not NULL, each element of the array on output will be set to the peak level of the most recent audio for each channel, in decibels
 * @param group The channel group
 * @param channelCount specifies the number of channels to fill in the averagePowers and peakLevels array parameters
 */

- (void)averagePowerLevels:(Float32*)averagePowers peakHoldLevels:(Float32*)peakLevels forGroup:(AEChannelGroupRef)group channelCount:(UInt32)count;

/*!
 * Get input power level information since this method was last called
 *
 * @param averagePower If not NULL, on output will be set to the average power level of the most recent input audio, in decibels
 * @param peakLevel If not NULL, on output will be set to the peak level of the most recent input audio, in decibels
 */
- (void)inputAveragePowerLevel:(Float32*)averagePower peakHoldLevel:(Float32*)peakLevel;

/*!
 * Get input power level information for multiple channels since this method was last called
 *
 * @param averagePowers If not NULL, each element of the array on output will be set to the average power level of the most recent input audio for each channel up to count, in decibels
 * @param peakLevels If not NULL, each element of the array on output will be set to the peak level of the most recent input audio for each channel up to count, in decibels
 * @param channelCount specifies the number of channels to fill in the averagePowers and peakLevels array parameters
 */
- (void)inputAveragePowerLevels:(Float32*)averagePowers peakHoldLevels:(Float32*)peakLevels channelCount:(UInt32)count;

///@}
#pragma mark - Utilities
/** @name Utilities */
///@{

/*!
 * Get access to the configured AudioStreamBasicDescription
 */
AudioStreamBasicDescription *AEAudioControllerAudioDescription(__unsafe_unretained AEAudioController *audioController);

/*!
 * Get access to the input AudioStreamBasicDescription
 */
AudioStreamBasicDescription *AEAudioControllerInputAudioDescription(__unsafe_unretained AEAudioController *audioController);

/*!
 * Convert a time span in seconds into a number of frames at the current sample rate
 */
long AEConvertSecondsToFrames(__unsafe_unretained AEAudioController *audioController, NSTimeInterval seconds);

/*!
 * Convert a number of frames into a time span in seconds
 */
NSTimeInterval AEConvertFramesToSeconds(__unsafe_unretained AEAudioController *audioController, long frames);

///@}
#pragma mark - Properties

/*!
 * Audio session category to use
 *
 *  See discussion in the [Audio Session Programming Guide](http://developer.apple.com/library/ios/#documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionCategories/AudioSessionCategories.html)
 *  The default value is AVAudioSessionCategoryPlayAndRecord if audio input is enabled, or
 *  AVAudioSessionCategoryPlayback otherwise, with mixing with other apps enabled.
 */
@property (nonatomic, assign) NSString * audioSessionCategory;

/*!
 * Whether to allow mixing audio with other apps
 *
 *  When this is YES, your app's audio will be mixed with the output of other applications.
 *  If NO, then any other apps playing audio will be stopped when the audio engine is started.
 *  
 *  Note: If you are using remote controls with `UIApplication`'s `beginReceivingRemoteControlEvents`,
 *  setting this to YES will stop the remote controls working. This is an iOS limitation.
 *
 *  Default: YES
 */
@property (nonatomic, assign) BOOL allowMixingWithOtherApps;

/*!
 * Whether to use the "Measurement" Audio Session Mode for improved audio quality and bass response.
 *
 *  Note also the @link avoidMeasurementModeForBuiltInMic @endlink property.
 *
 * Default: NO
 */
@property (nonatomic, assign) BOOL useMeasurementMode;

/*!
 * Whether to avoid using Measurement Mode with the built-in mic
 *
 *  When used with the built-in microphone, Measurement Mode results in quite low audio
 *  input levels. Setting this property to YES causes TAAE to avoid using Measurement Mode
 *  with the built-in mic, avoiding this problem.
 *
 *  Default is YES.
 */
@property (nonatomic, assign) BOOL avoidMeasurementModeForBuiltInMic;

/*! 
 * Mute output
 *
 *  Set to YES to mute all system output. Note that even if this is YES, playback
 *  callbacks will still receive audio, as the silencing happens after output receiver
 *  callbacks are called.
 */
@property (nonatomic, assign) BOOL muteOutput;

/*!
 * Access the master output volume
 *
 *  Note that this value affects the output of the audio engine; it doesn't modify
 *  the hardware volume setting.
 */
@property (nonatomic, assign) float masterOutputVolume;

/*!
 * Enable audio input from Bluetooth devices
 *
 *  Note that setting this property to YES may have implications for input latency.
 *
 *  Default is NO.
 */
@property (nonatomic, assign) BOOL enableBluetoothInput;

/*!
 * Determine whether input gain is available
 */
@property (nonatomic, readonly) BOOL inputGainAvailable;

/*!
 * Set audio input gain (if input gain is available)
 *
 *  Value must be in the range 0-1
 */
@property (nonatomic, assign) float inputGain;

/*!
 * Whether to use the built-in voice processing system
 *
 *  This can be useful for removing echo/feedback when playing through the speaker
 *  while simultaneously recording through the microphone.  Not suitable for music,
 *  but works adequately well for speech.
 *
 *  Note that changing this value will cause the entire audio system to be shut down 
 *  and restarted with the new setting, which will result in a break in audio playback.
 *
 *  Enabling voice processing in short buffer duration environments (< 0.01s) may cause
 *  stuttering.
 *
 *  Default is NO.
 */
@property (nonatomic, assign) BOOL voiceProcessingEnabled;

/*!
 * Whether to only perform voice processing for the SpeakerAndMicrophone route
 *
 *  This causes voice processing to only be enabled in the classic echo removal
 *  scenario, when audio is being played through the device speaker and recorded
 *  by the device microphone.
 *
 *  Default is YES.
 */
@property (nonatomic, assign) BOOL voiceProcessingOnlyForSpeakerAndMicrophone;

/*! 
 * Input mode: How to handle incoming audio
 *
 *  If you are using an audio format with more than one channel, this setting 
 *  defines how the system receives incoming audio.
 *
 *  See @link AEInputMode @endlink for a description of the available options.
 *
 *  Default is AEInputModeFixedAudioFormat.
 */
@property (nonatomic, assign) AEInputMode inputMode;

/*!
 * Input channel selection
 *
 *  When there are more than one input channel, you may specify which of the
 *  available channels are actually used as input. This is an array of NSNumbers,
 *  each referring to a channel (starting with the number 0 for the first channel).
 *  
 *  Specified input channels will be mapped to output chanels in the order they appear
 *  in this array, so the first channel specified will be mapped to the first output
 *  channel (the only output channel, if output is mono, or the left channel for stereo
 *  output), the second input to the second output (the right channel).
 *
 *  By default, the first two inputs will be used, for devices with more than 1 input
 *  channel.
 */
@property (nonatomic, strong) NSArray *inputChannelSelection;

/*!
 * Preferred buffer duration (in seconds)
 *
 *  Set this to low values for better latency, but more processing overhead, or higher
 *  values for greater latency with lower processing overhead.  This parameter affects
 *  the length of the audio buffers received by the various callbacks.
 *
 *  System default is ~23ms, or 1024 frames.
 */
@property (nonatomic, assign) NSTimeInterval preferredBufferDuration;

/*!
 * Current buffer duration (in seconds)
 *
 *  This is the current hardware buffer duration, which may or may not be the same as
 *  the @link preferredBufferDuration @endlink property, depending on the set of active
 *  apps on the device and the order in which they were launched.
 *
 *  Observable.
 */
@property (nonatomic, readonly) NSTimeInterval currentBufferDuration;

/*!
 * Input latency (in seconds)
 *
 *  The currently-reported hardware input latency.
 *  See AEAudioControllerInputLatency.
 */
@property (nonatomic, readonly) NSTimeInterval inputLatency;

/*!
 * Output latency (in seconds)
 *
 *  The currently-reported hardware output latency.
 *  See AEAudioControllerOutputLatency
 */
@property (nonatomic, readonly) NSTimeInterval outputLatency;

/*!
 * Whether to automatically account for input/output latency
 *
 *  If you set this property to YES, the timestamps you see in the various callbacks
 *  will automatically account for input and output latency. If this is NO
 *  (the default), and you wish to account for latency, you will need to use
 *  the @link inputLatency @endlink and @link outputLatency @endlink properties, 
 *  or their corresponding C functions @link AEAudioControllerInputLatency @endlink
 *  and @link AEAudioControllerOutputLatency @endlink yourself.
 *
 *  Default is NO.
 */
@property (nonatomic, assign) BOOL automaticLatencyManagement;

/*!
 * Determine whether the audio engine is running
 *
 *  This is affected by calling start and stop on the audio controller.
 */
@property (nonatomic, readonly) BOOL running;

/*!
 * Determine whether audio is currently being played through the device's speaker
 *
 *  This property is observable
 */
@property (nonatomic, readonly) BOOL playingThroughDeviceSpeaker;

/*!
 * Determine whether audio is currently being recorded through the device's mic
 *
 *  This property is observable
 */
@property (nonatomic, readonly) BOOL recordingThroughDeviceMicrophone;

/*!
 * Whether audio input is currently available
 *
 *  Note: This property is observable
 */
@property (nonatomic, readonly) BOOL audioInputAvailable;

/*!
 * The number of audio channels that the current audio input device provides
 *
 *  Note that this will not necessarily be the same as the number of audio channels
 *  your app will receive, depending on the @link inputMode @endlink and
 *  @link inputChannelSelection @endlink properties. Use @link inputAudioDescription @endlink
 *  to obtain an AudioStreamBasicDescription representing the actual incoming audio.
 *
 *  Note: This property is observable
 */
@property (nonatomic, readonly) int numberOfInputChannels;

/*!
 * The audio description defining the input audio format
 * 
 *  Note: This property is observable
 *
 *  See also @link inputMode @endlink and @link inputChannelSelection @endlink
 */
@property (nonatomic, readonly) AudioStreamBasicDescription inputAudioDescription;

/*!
 * The audio description that the audio controller was setup with
 */
@property (nonatomic, readonly) AudioStreamBasicDescription audioDescription;

/*!
 * The Remote IO audio unit used for input and output
 */
@property (nonatomic, readonly) AudioUnit audioUnit;

/*!
 * The audio graph handle
 */
@property (nonatomic, readonly) AUGraph audioGraph;

#pragma mark - Timing

/*!
 * Input latency (in seconds)
 *
 *  To account for hardware latency, you can use this function to offset audio timestamps.
 *
 *  For example:
 *
 *      timestamp.mHostTime -= AEHostTicksFromSeconds(AEAudioControllerInputLatency(audioController));
 *
 *  Note that when connected to Audiobus input, this function returns 0.
 *
 * @param controller The audio controller
 * @returns The currently-reported hardware input latency
 */
NSTimeInterval AEAudioControllerInputLatency(__unsafe_unretained AEAudioController *controller);

/*!
 * Output latency (in seconds)
 *
 *  To account for hardware latency, you can use this function to offset audio timestamps.
 *
 *  For example:
 *
 *      timestamp.mHostTime += AEHostTicksFromSeconds(AEAudioControllerOutputLatency(audioController));
 *
 *  Note that when connected to Audiobus, this value will automatically account for any Audiobus latency.
 *
 * @param controller The audio controller
 * @returns The currently-reported hardware output latency
 */
NSTimeInterval AEAudioControllerOutputLatency(__unsafe_unretained AEAudioController *controller);

/*!
 * Get the current audio system timestamp
 *
 *  For use on the audio thread; returns the latest audio timestamp, either for the input or the
 *  output bus, depending on when this method is called.
 *
 * @param controller The audio controller
 * @returns The last-seen audio timestamp for the most recently rendered bus
 */
AudioTimeStamp AEAudioControllerCurrentAudioTimestamp(__unsafe_unretained AEAudioController *controller);

@end

#ifdef __cplusplus
}
#endif
