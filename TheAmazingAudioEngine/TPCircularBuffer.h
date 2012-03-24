//
//  TPCircularBuffer.h
//  Circular/Ring buffer implementation
//
//  Created by Michael Tyson on 10/12/2011.
//  Copyright 2011-2012 A Tasty Pixel. All rights reserved.
//
//
//  This implementation makes use of a virtual memory mapping technique that inserts a virtual copy
//  of the buffer memory directly after the buffer's end, negating the need for any buffer wrap-around
//  logic. Clients can simply use the returned memory address as if it were contiguous space.
//  
//  The implementation is thread-safe in the case of a single producer and single consumer.
//
//  Virtual memory technique originally proposed by Philip Howard (http://vrb.slashusr.org/), and
//  adapted to Darwin by Kurt Revis (http://www.snoize.com,
//  http://www.snoize.com/Code/PlayBufferedSoundFile.tar.gz)
//

#ifndef TPCircularBuffer_h
#define TPCircularBuffer_h

#include <libkern/OSAtomic.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif
    
typedef struct {
    void             *buffer;
    int32_t           length;
    int32_t           tail;
    int32_t           head;
    volatile int32_t  fillCount;
} TPCircularBuffer;

bool  TPCircularBufferInit(TPCircularBuffer *buffer, int32_t length);
void  TPCircularBufferCleanup(TPCircularBuffer *buffer);
void  TPCircularBufferClear(TPCircularBuffer *buffer);

// Reading (consuming)

static __inline__ __attribute__((always_inline)) void* TPCircularBufferTail(TPCircularBuffer *buffer, int32_t* availableBytes) {
    *availableBytes = buffer->fillCount;
    if ( *availableBytes == 0 ) return NULL;
    return (void*)((char*)buffer->buffer + buffer->tail);
}

static __inline__ __attribute__((always_inline)) void TPCircularBufferConsume(TPCircularBuffer *buffer, int32_t amount) {
    buffer->tail = (buffer->tail + amount) % buffer->length;
    OSAtomicAdd32Barrier(-amount, &buffer->fillCount);
}

static __inline__ __attribute__((always_inline)) void* TPCircularBufferHead(TPCircularBuffer *buffer, int32_t* availableBytes) {
    *availableBytes = (buffer->length - buffer->fillCount);
    if ( *availableBytes == 0 ) return NULL;
    return (void*)((char*)buffer->buffer + buffer->head);
}
    
// Writing (producing)

static __inline__ __attribute__((always_inline)) void TPCircularBufferProduce(TPCircularBuffer *buffer, int amount) {
    buffer->head = (buffer->head + amount) % buffer->length;
    OSAtomicAdd32Barrier(amount, &buffer->fillCount);
}

static __inline__ __attribute__((always_inline)) int TPCircularBufferProduceBytes(TPCircularBuffer *buffer, const void* src, int32_t len) {
    int32_t space;
    void *ptr = TPCircularBufferHead(buffer, &space);
    int copied = len > space ? space : len;
    memcpy(ptr, src, copied);
    TPCircularBufferProduce(buffer, copied);
    return copied;
}

#ifdef __cplusplus
}
#endif

#endif
