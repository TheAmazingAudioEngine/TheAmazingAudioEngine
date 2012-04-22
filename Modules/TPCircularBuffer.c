//
//  TPCircularBuffer.c
//  Circular/Ring buffer implementation
//
//  Created by Michael Tyson on 10/12/2011.
//  Copyright 2011-2012 A Tasty Pixel. All rights reserved.


#include "TPCircularBuffer.h"
#include <mach/mach.h>
#include <stdio.h>

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/'),__LINE__))
static inline bool _checkResult(kern_return_t result, const char *operation, const char* file, int line) {
    if ( result != ERR_SUCCESS ) {
        printf("%s:%d: %s: %s\n", file, line, operation, mach_error_string(result)); 
        return false;
    }
    return true;
}

bool TPCircularBufferInit(TPCircularBuffer *buffer, int length) {

    // Keep trying until we get our buffer, needed to handle race conditions
    while( 1 ) {

        buffer->length = round_page(length);    // We need whole page sizes

        // Temporarily allocate twice the length, so we have the contiguous address space to
        // support a second instance of the buffer directly after
        vm_address_t bufferAddress;
        if ( !checkResult(vm_allocate(mach_task_self(),
                                      &bufferAddress,
                                      buffer->length * 2,
                                      VM_FLAGS_ANYWHERE), // allocate anywhere it'll fit
                          "Buffer allocation") ) {
            // Try again if we fail
            continue;
        }
        
        // Now replace the second half of the allocation with a virtual copy of the first half. Deallocate the second half...
        if ( !checkResult(vm_deallocate(mach_task_self(),
                                        bufferAddress + buffer->length,
                                        buffer->length),
                          "Buffer deallocation") ) {
            // If this fails somehow, deallocate the whole region and try again
            vm_deallocate(mach_task_self(), bufferAddress, buffer->length);
            continue;
        }
        
        // Re-map the buffer to the address space immediately after the buffer
        vm_address_t virtualAddress = bufferAddress + buffer->length;
        vm_prot_t cur_prot, max_prot;
        if ( !checkResult(vm_remap(mach_task_self(),
                                 &virtualAddress,   // mirror target
                                 buffer->length,    // size of mirror
                                 0,                 // auto alignment
                                 0,                 // force remapping to virtualAddress
                                 mach_task_self(),  // same task
                                 bufferAddress,     // mirror source
                                 0,                 // MAP READ-WRITE, NOT COPY
                                 &cur_prot,         // unused protection struct
                                 &max_prot,         // unused protection struct
                                 VM_INHERIT_DEFAULT), 
                         "Remap buffer memory") ) {
            // If this remap failed, we hit a race condition, so deallocate and try again
            vm_deallocate(mach_task_self(), bufferAddress, buffer->length);
            continue;
        }
        
        if ( virtualAddress != bufferAddress+buffer->length ) {
            // If the memory is not contiguous, clean up both allocated buffers and try again
            printf("Couldn't map buffer memory to end of buffer\n");
            vm_deallocate(mach_task_self(), virtualAddress, buffer->length);
            vm_deallocate(mach_task_self(), bufferAddress, buffer->length);
            continue;
        }
        
        buffer->buffer = (void*)bufferAddress;
        buffer->fillCount = 0;
        buffer->head = buffer->tail = 0;
        
        return true;
    }
}

void TPCircularBufferCleanup(TPCircularBuffer *buffer) {
    vm_deallocate(mach_task_self(), (vm_address_t)buffer->buffer, buffer->length * 2);
    memset(buffer, 0, sizeof(TPCircularBuffer));
}

void TPCircularBufferClear(TPCircularBuffer *buffer) {
    buffer->head = buffer->tail = 0;
    buffer->fillCount = 0;
}
