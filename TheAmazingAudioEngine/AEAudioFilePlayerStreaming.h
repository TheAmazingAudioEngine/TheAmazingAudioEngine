//
//  AEAudioFilePlayerStreaming.h
//  The Amazing Audio Engine
//
//  AmazingAudioEngine created by Michael Tyson.
//  AEAudioFilePlayerStreaming created by Joel Shapiro (RepublicOfApps) on 10/24/13.
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
#import "AEAudioController.h"

#ifdef __cplusplus
extern "C" {
#endif

/*!
 * Audio file player streaming
 *
 *  This class allows you to play audio files as one-off samples.
 *  It will play any audio file format supported by iOS.
 *  It is well-suited for large audio files like mp3 song files
 *  because it streams the file's contents a little a time
 *  to minimize memory usage.
 *
 *  To use, create an instance, then add it to the audio controller.
 *
 *  Files are streamed from the local storage indicated by the given url,
 *  which may be from an MPMediaItem in your device's iPod library or a
 *  local file in your App's bundle or data or documents directories.
 *
 *  This reader is extremely memory efficient at the cost of using slightly
 *  more cpu.  It is ideally suited for reading large files (e.g. song mp3s).
 *  If you need looping or are working with smaller files, consider also
 *  the excellent AudioFilePlayer.
 *
 *  On a typical 4-minute mp3 song, compare this player's resource usage to
 *  that of AEAudioFilePlayer:
 *
 *      Player                        RAM Usage    CPU Usage
 *      --------------------------    ---------    ---------
 *      AEAudioFilePlayer             54.6 MB      0%
 *      AEAudioFilePlayerStreaming     3.9 MB      4%
 *
 *  (These stats are for a single blank view app running on an iPhone 5, iOS 7.0.3,
 *   but you should see similar efficiency tradeoffs on other devices/iOS versions.  The
 *   file was being played as Linear PCM as specified by nonInterleaved16BitStereoAudioDescription).
 *
 *  Besides using this player to play local files through file URLs, you can
 *  also use it to play an MPMediaItem from your device's iPod Library.  You
 *  do this by using the item's asset url:
 *  @code
 *      // Get an iPod Library song
 *      MPMediaItem *mediaItem = ...;
 *      NSURL *url = [mediaItem valueForProperty:MPMediaItemPropertyAssetURL];
 *
 *      // Play it
 *      AEAudioController audioController = ...;
 *      AEAudioFilePlayerStreaming* player = [AEAudioFilePlayerStreaming playerWithURL:url audioController:audioController];
 @  @endcode
 */
@interface AEAudioFilePlayerStreaming : NSObject<AEAudioPlayable>

/*!
 * Create a new player instance.
 * The contents of the file at the given url are played via
 * on-demand reading of the file and are rendered as specified
 * by the audioDescription of the given audioController.
 * The file is played in its entirety from start to finish.
 *
 * Hence this player can play an mp3 file and render it as PCM,
 * if the audioDescription is PCM, which is suitable for analysis of the sound data.
 *
 * @param url               URL to the file to load
 * @param audioController   The audio controller
 * @return The audio player, ready to be @link AEAudioController::addChannels: added @endlink to the audio controller.
 */
+ (instancetype)playerWithURL:(NSURL*)url audioController:(AEAudioController*)audioController;

/*!
 * Create a new player instance.
 * The contents of the file at the given url are played via
 * on-demand reading of the file and are rendered as specified
 * by the audioDescription of the given audioController.
 * The file is played for the section defined by
 * playbackStartTime and playbackEndTime.
 *
 * Hence this player can play an mp3 file and render it as PCM,
 * if the audioDescription is PCM, which is suitable for analysis of the sound data.
 *
 * @param url               URL to the file to load
 * @param audioController   The audio controller
 * @param playbackStartTime if non-nil, playback only at and after this time (in seconds)
 * @param playbackEndTime   if non-nil, playback only before and up to this time (in seconds)
 * @return The audio player, ready to be @link AEAudioController::addChannels: added @endlink to the audio controller.
 */
+ (instancetype)playerWithURL:(NSURL*)url audioController:(AEAudioController*)audioController playbackStartTime:(NSNumber*)playbackStartTime playbackEndTime:(NSNumber*)playbackEndTime;

# pragma mark - Custom Properties

@property (nonatomic, readonly, retain) NSURL* url; //!< Original media URL; must be a local file or MPMediaItem asset url
@property (nonatomic, readonly) NSNumber* currentPlaybackProgress; //!< Current playback progress in [0.0, 1.0] if playing and playback has started, else nil; 0 means at playbackStartTime, 1 at playbackEndTime
@property (nonatomic, copy) void (^completionBlock)(AEAudioFilePlayerStreaming* callingPlayer); //!< Optional block to call when playback has finished

# pragma mark - AEAudioPlayable Properties: Mutable, may be altered

@property (nonatomic, readwrite) float volume;
@property (nonatomic, readwrite) float pan;
@property (nonatomic, readwrite) BOOL channelIsPlaying;
@property (nonatomic, readwrite) BOOL channelIsMuted;

# pragma mark - AEAudioPlayable Properties: Immutable, may not be altered after initialization

@property (nonatomic, readonly) AudioStreamBasicDescription audioDescription;
@property (nonatomic, readonly) AEAudioControllerRenderCallback renderCallback;

@end

#ifdef __cplusplus
}
#endif
