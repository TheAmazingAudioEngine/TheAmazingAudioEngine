//
//  AEAudioUnitFilePlayer.h
//  TheAmazingAudioEngine
//
//  Created by Ryan Holmes on 8/9/15.
//  Copyright (c) 2015 A Tasty Pixel. All rights reserved.
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

#import "AEAudioUnitChannel.h"
#import "AEAudioController.h"

/*!
 * Audio Unit file player
 *
 *  This class allows you to play audio files, either as one-off samples, or looped.
 *  It will play any audio file format supported by iOS. It uses an AUAudioFilePlayer 
 *  to stream audio files from disk, so it's a good choice for large files that you 
 *  don't want to load into memory all at once.
 *
 *  To use, create an instance, then add it to the audio controller.
 */

@interface AEAudioUnitFilePlayer : AEAudioUnitChannel

+ (instancetype)audioUnitFilePlayerWithURL:(NSURL *)url error:(NSError **)error;
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;

@property (nonatomic, strong, readonly) NSURL *url;         //!< Original media URL
@property (nonatomic, readonly) NSTimeInterval duration;    //!< Length of audio, in seconds
@property (nonatomic, assign) NSTimeInterval currentTime;   //!< Current playback position, in seconds
@property (nonatomic, readwrite) BOOL loop;                 //!< Whether to loop this track
@property (nonatomic, readwrite) BOOL removeUponFinish;     //!< Whether the track automatically removes itself from the audio controller after playback completes
@property (nonatomic, copy) void(^completionBlock)();       //!< A block to be called when playback finishes
@property (nonatomic, copy) void(^startLoopBlock)();        //!< A block to be called when the loop restarts in loop
@end
