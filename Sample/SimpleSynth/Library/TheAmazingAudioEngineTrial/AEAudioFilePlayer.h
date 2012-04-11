//
//  AEAudioFilePlayer.h
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AEAudioController.h"

/*!
 * Audio file player
 *
 *  This class allows you to play audio files, either as one-off samples, or looped.
 *  It will play any audio file format supported by iOS.
 *
 *  To use, create an instance, then add it to the audio controller.
 */
@interface AEAudioFilePlayer : NSObject <AEAudioPlayable>

/*!
 * Create a new player instance
 *
 * @param url               URL to the file to load
 * @param audioController   The audio controller
 * @param error             If not NULL, the error on output
 * @return The audio player, ready to be @link AEAudioController::addChannels: added @endlink to the audio controller.
 */
+ (id)audioFilePlayerWithURL:(NSURL*)url audioController:(AEAudioController*)audioController error:(NSError**)error;

@property (nonatomic, readwrite) BOOL loop;                 //!< Whether to loop this track
@property (nonatomic, readwrite) float volume;              //!< Track volume
@property (nonatomic, readwrite) float pan;                 //!< Track pan
@property (nonatomic, readwrite) BOOL playing;              //!< Whether the track is playing (observable)
@property (nonatomic, readwrite) BOOL muted;                //!< Whether the track is muted
@property (nonatomic, readwrite) BOOL removeUponFinish;     //!< Whether the track automatically removes itself from the audio controller after playback completes
@end
