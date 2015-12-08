The Amazing Audio Engine
========================

The Amazing Audio Engine is a sophisticated framework for iOS audio applications, built so you don't have to.

It is designed to be very easy to work with, and handles all of the intricacies of iOS audio on your behalf.

Built upon the efficient and low-latency Core Audio Remote IO system, and written by developer of [Audiobus](http://audiob.us) and [Loopy](http://loopyapp.com) Michael Tyson, The Amazing Audio Engine lets you get to work on making your app great instead of reinventing the wheel.

See http://theamazingaudioengine.com for details and http://theamazingaudioengine.com/doc for documentation.

License
-------

Copyright (C) 2012-2015 A Tasty Pixel

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
   
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
   
3. This notice may not be removed or altered from any source distribution.


Changelog
---------

### 1.5.5

- Added AEAudioBufferManager class, to enable management of AudioBufferList structures using normal ARC/retain-release memory management techniques
- Addressed a problem introduced in 1.5.3 that could cause a 30s hang when restarting audio system
- Revised timestamp management with Audiobus/IAA: now, TAAE will pass uncompensated timestamps to ABReceiverPortReceive, and will assume incoming timestamps, when hosted via IAA or Audiobus, are uncompensated.

### 1.5.4

- Fixed an output latency compensation issue when hosted via Inter-App Audio
- Deprecated "audiobusSenderPort" facility (use ABSenderPort's audioUnit initializer instead, with AEAudioController's audioUnit property)
- Improved performance reports (made these less verbose, added percentage of render budget)
- Fixed a crash when using AEPlaythroughChannel and changing the sample rate

### 1.5.3

- Added AEAudioBufferListCreateOnStack utility
- Enable automaticLatencyManagement by default
- Fixed a race condition when using setAudiobusSenderPort*
- Added tvOS support (thanks to Florian Doyon)
- Added playAtTime: facility to AEMemoryBufferPlayer (thanks to Anton Holmberg)
- Added setup/teardown methods to AEInputReceiver
- Fixed missing setup/teardown calls to input filters
- Replaced AEPlaythroughChannel initializer

### 1.5.2

- Added composite setAudioDescription:inputEnabled:outputEnabled: update method
- Added new initializer with AEAudioControllerOptions bitmask (thanks to Jonatan Liljedahl)
- Added setting to always use the hardware sample rate (thanks to Jonatan Liljedahl)
- Added missing teardown procedure for channels and filters
- Fixed incorrect audio input conversion for interleaved formats
- Fixed conversion issue with AEAudioUnitFilter
- Fixed OS X build issue by removing AEReverbFilter for OS X (not supported on that platform)
- Added 'audioGraphNode' properties to ABAudioUnitFilter/Channel
- Updated TPCircularBuffer with added safety measures that will refuse to compile or crash early when a version mismatch is detected with other instances in your project
- Address Audiobus issues for apps with both receiver and filter ports

### 1.5.1

- Important fixes for the iPhone 6S
- Added some AudioStreamBasicDescription utilities
- Added extra AudioBufferList utilities and renamed existing ones for consistent naming
- Added wrapper classes for Apple's effect audio units (thanks to Dream Engine's Jeremy Flores!)
- Added Audio Unit parameter facilities (setParameterValue:forId: and getParameterValue:forId:)
- Added AEMemoryBufferPlayer (a reincarnation of the previous in-memory AEAudioFilePlayer class)
- Implemented 'playAtTime:' synchronisation method on AEAudioFilePlayer
- Refactored out cross-thread messaging system into AEMessageQueue (thanks Jonatan Liljedahl!)
- Replaced 'updateWithAudioDescription:...' mechanism with separate 'setAudioDescription', 'setInputEnabled' and 'setOutputEnabled' methods
- Bunch of other little improvements; see git log for details.

### 1.5

- OS X support! Many, many thanks to Steve Rubin!
- Replaced in-memory version of AEAudioFilePlayer with an audio unit version which streams from disk (thanks to Ryan King and Jeremy Huff of Hello World Engineering, and Ryan Holmes for their contributions to this great enhancement).
- Bunch of other little improvements; see git log for details.