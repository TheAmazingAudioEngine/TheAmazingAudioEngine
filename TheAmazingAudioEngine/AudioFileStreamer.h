//
//  AudioFileStreamer.h
//
//  Created by Ryan King and Jeremy Huff of Hello World Engineering, Inc on 7/15/15.
//  Copyright (c) 2015 Hello World Engineering, Inc. All rights reserved.
//
//  AudioFileStreamer is based on code written by Michael Tyson from The Amazing Audio Engine.
//  It also uses code written by Rob Rampley for The Amazing Audio Engine.
//  This source file is released under The Amazing Audio Engine license, pasted below.
//
//
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

#import <Foundation/Foundation.h>
#import "TheAmazingAudioEngine.h"

/*  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *
 *                                                                          *
 *  These are defined here so that subclasses have access to these macros   *
 *                                                                          *
 *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  *  */

#ifndef FS_CHECK_RESULT
#define FS_CHECK_RESULT
#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        int fourCC = CFSwapInt32HostToBig(result);
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&fourCC);
        return NO;
    }
    return YES;
}
#define checkResultForError(resultop,operation,errormsg,errorval,resultvar,errorvar) if(!(_checkResult((resultvar)=(resultop),(operation),strrchr(__FILE__, '/')+1,__LINE__))) \
    { \
        if ( (errorvar) ) \
            *(errorvar) = [NSError errorWithDomain:NSOSStatusErrorDomain code:(resultvar) userInfo:[NSDictionary dictionaryWithObject:@(errormsg) forKey:NSLocalizedDescriptionKey]]; \
        return (errorval); \
    }
#endif

/*!
 * Audio file Streamer
 *
 *  This class allows you to play audio files through audio units without having to load the entire file into memory.
 *
 *  To use, create an instance, then add it to the audio controller.
 */
@interface AudioFileStreamer : NSObject <AEAudioPlayable>
{
    @protected
    UInt32 _lengthInFrames;                         //!< Audio file length in frames
    AudioStreamBasicDescription _audioDescription;  //!< Audio description
    volatile int32_t _playhead;                     //!< The location of the playhead in frames
    
    // When moving the audio playhead from inside the class, this should be set EXCEPT
    //      -   During initialization
    //      -   During the playhead's update due to song play, during the render callback
    BOOL _reloadAudioRegionOnPlay;                  //!< If set, the streamer will reschedule the region of the audio unit when channelIsPlaying is set to YES
    
    // Audio unit related variables
    AEAudioController* _audioController;            //!< The audio controller this belongs to
    AUNode _node;                                   //!< The main audio unit node
    AudioUnit _audioUnit;                           //!< The main audio unit for playing the file
    AUNode _converterNode;                          //!< An optional node that converts file formats
    AudioUnit _converterUnit;                       //!< An optional unit that converts file formats
    AUGraph _audioGraph;                            //!< The audio controller's audio graph
    AudioFileID _audioUnitFile;                     //!< The file to be played as an audio file ID
}

/*!
 * Initializes an audio streamer
 *
 * @param url               URL to the file to load
 * @param audioController   The audio controller
 * @param error             If not NULL, the error on output
 * @return The audio streamer, ready to be @link AEAudioController::addChannels: added @endlink to the audio controller.
 */
- (id) initWithURL: (NSURL*) url audioController: (AEAudioController*)audioController error:(NSError**) error;

/*!
 * Plays the audio streamer from it's current playhead position
 */
- (void) play;

/*!
 * Pauses the audio streamer at it's current playhead position
 */
- (void) pause;

/*!
 * Stops the audio streamer, resetting the playhead to the start of the file
 */
- (void) stop;

/*!
 * Mutes the streamer
 */
- (void) mute;

/*!
 * Unmutes the streamer
 */
- (void) unmute;

+ (OSStatus) renderCallback: (__unsafe_unretained AudioFileStreamer*) THIS audioController: (__unsafe_unretained AEAudioController*) audioController time: (const AudioTimeStamp*) time numberOfFrames: (UInt32) frames audioBufferList: (AudioBufferList*) audio;

@property (nonatomic, strong, readonly) NSURL *url;         //<! The URL of the audio file
@property (nonatomic, readonly) NSTimeInterval duration;    //<! The length of the audio file in time
@property (nonatomic, assign) NSTimeInterval currentTime;   //<! The current location of the playhead in time

// AEAudioPlayable Properties
@property (nonatomic, assign) BOOL channelIsPlaying;        //<! Whether the channel is playing or not
@property (nonatomic, assign) BOOL channelIsMuted;          //<! Whether the channel is muted or not
@property (nonatomic, assign) float volume;                 //<! The volume, from 0.0 to 1.0
@property (nonatomic, assign) float pan;                    //<! The pan, from -1.0 to 1.0

@property (nonatomic, assign) int playbackDelay;            //<! The number of frames to wait before starting playback. Can be used to synchronize with effects audio units that introduce delay of their own.
@property (nonatomic, assign) Float64 playbackDelayInSeconds;  //<! The number of seconds to wait before starting playback.
@property (nonatomic, assign) BOOL looping;                 //<! If true, the audio file loops.

@property (nonatomic, readonly) AudioUnit audioUnit;       //<! The audio unit.
@property (nonatomic, readonly) AUNode node;          //<! The audio node;

@property (nonatomic, copy) void(^completionBlock)();       //<! The block to be called when playback ends

// MARK: Debug Properties
@property (nonatomic, readonly) int32_t currentFrame;       //<! The current frame of playback
@property (nonatomic, readonly) UInt32 totalFrames;         //<! The total number of frames in the audio file

@end
