A simple, fast circular buffer implementation for audio processing
==================================================================

A simple C implementation for a circular (ring) buffer. Thread-safe with a single producer and a single consumer, using OSAtomic.h primitives, and avoids any need for buffer wrapping logic by using a virtual memory map technique to place a virtual copy of the buffer straight after the end of the real buffer.

Distributed under the [MIT license](http://opensource.org/licenses/mit-license.php)

Usage
-----

Initialisation and cleanup: `TPCircularBufferInit` and `TPCircularBufferCleanup` to allocate and free resources.

Producing: Use `TPCircularBufferHead` to get a pointer to write to the buffer, followed by `TPCircularBufferProduce` to submit the written data.  `TPCircularBufferProduceBytes` is a convenience routine for writing data straight to the buffer.

Consuming: Use `TPCircularBufferTail` to get a pointer to the next data to read, followed by `TPCircularBufferConsume` to free up the space once processed.

TPCircularBuffer+AudioBufferList.(c,h) contain helper functions to queue and dequeue AudioBufferList
structures. These will automatically adjust the mData fields of each buffer to point to 16-byte aligned
regions within the circular buffer.

Thread safety
-------------

As long as you restrict multithreaded access to just one producer, and just one consumer, this utility should be thread safe. 

Only one shared variable is used (the buffer fill count), and OSAtomic primitives are used to write to this value to ensure atomicity.

-----------------------------------------------------

Virtual memory technique originally proposed by [Philip Howard](http://vrb.slashusr.org/), and [adapted to Darwin](http://www.snoize.com/Code/PlayBufferedSoundFile.tar.gz) by [Kurt Revis](http://www.snoize.com)

See more info at [atastypixel.com](http://atastypixel.com/blog/a-simple-fast-circular-buffer-implementation-for-audio-processing/)

Michael Tyson  
A Tasty Pixel