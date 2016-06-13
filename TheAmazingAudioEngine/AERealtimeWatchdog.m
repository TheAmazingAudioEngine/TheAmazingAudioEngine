//
//  AERealtimeWatchdog.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 12/06/2016.
//  Idea by Taylor Holliday
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
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

#import "AERealtimeWatchdog.h"
#ifdef REALTIME_WATCHDOG_ENABLED

#import <dlfcn.h>
#import <stdio.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <string.h>
#include <sys/socket.h>

// Uncomment the following to report every time we spot something bad, not just the first time
// #define REPORT_EVERY_INFRACTION




static void AERealtimeWatchdogUnsafeActivityWarning(const char * activity) {
#ifndef REPORT_EVERY_INFRACTION
    static BOOL once = NO;
    if ( !once ) {
        once = YES;
#endif
        
        printf("AERealtimeWatchdog: Caught unsafe %s on realtime thread. Put a breakpoint on %s to debug\n",
               activity, __FUNCTION__);
        
#ifndef REPORT_EVERY_INFRACTION
    }
#endif
}

BOOL AERealtimeWatchdogIsOnRealtimeThread(void);
BOOL AERealtimeWatchdogIsOnRealtimeThread(void) {
    pthread_t thread = pthread_self();
    
    static pthread_t __audioThread = NULL;
    
    if ( __audioThread ) {
        return thread == __audioThread;
    }
    
    char name[21] = {0};
    if ( pthread_getname_np(thread, name, sizeof(name)) == 0 && !strcmp(name, "AURemoteIO::IOThread") ) {
        __audioThread = thread;
        return YES;
    }
    
    return NO;
}





#pragma mark - Overrides

// Signatures for the functions we'll override
typedef void * (*malloc_t)(size_t);
typedef void * (*calloc_t)(size_t, size_t);
typedef void * (*realloc_t)(void *, size_t);
typedef void (*free_t)(void*);
typedef int (*pthread_mutex_lock_t)(pthread_mutex_t *);
typedef int (*objc_sync_enter_t)(id obj);
typedef id (*objc_storeStrong_t)(id *object, id value);
typedef id (*objc_msgSend_t)(void);
typedef ssize_t (*send_t)(int socket, const void *buffer, size_t length, int flags);
typedef ssize_t (*sendto_t)(int socket, const void *buffer, size_t length, int flags,
                            const struct sockaddr *dest_addr, socklen_t dest_len);
typedef ssize_t (*recv_t)(int socket, void *buffer, size_t length, int flags);
typedef ssize_t (*recvfrom_t)(int socket, void *restrict buffer, size_t length, int flags,
                              struct sockaddr *restrict address, socklen_t *restrict address_len);
typedef FILE * (*fopen_t)(const char *restrict filename, const char *restrict mode);
typedef size_t (*fread_t)(void *restrict ptr, size_t size, size_t nitems, FILE *restrict stream);
typedef size_t (*fwrite_t)(const void *restrict ptr, size_t size, size_t nitems, FILE *restrict stream);
typedef char * (*fgets_t)(char * restrict str, int size, FILE * restrict stream);
typedef ssize_t (*read_t)(int fildes, void *buf, size_t nbyte);
typedef ssize_t (*pread_t)(int d, void *buf, size_t nbyte, off_t offset);
typedef ssize_t (*write_t)(int fildes, const void *buf, size_t nbyte);
typedef ssize_t (*pwrite_t)(int fildes, const void *buf, size_t nbyte, off_t offset);


// Overrides

void * malloc(size_t sz) {
    static malloc_t funcptr = NULL;
    if ( !funcptr ) funcptr = (malloc_t) dlsym(RTLD_NEXT, "malloc");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("malloc");
    return funcptr(sz);
}

void * calloc(size_t count, size_t size) {
    static calloc_t funcptr = NULL;
    if ( !funcptr ) funcptr = (calloc_t) dlsym(RTLD_NEXT, "calloc");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("calloc");
    return funcptr(count, size);
}

void * realloc(void * ptr, size_t size) {
    static realloc_t funcptr = NULL;
    if ( !funcptr ) funcptr = (realloc_t) dlsym(RTLD_NEXT, "realloc");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("realloc");
    return funcptr(ptr, size);
}

void free(void *p) {
    static free_t funcptr = NULL;
    if ( !funcptr ) funcptr = (free_t) dlsym(RTLD_NEXT, "free");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("free");
    funcptr(p);
}

int pthread_mutex_lock(pthread_mutex_t * mutex) {
    static pthread_mutex_lock_t funcptr = NULL;
    if ( !funcptr ) funcptr = (pthread_mutex_lock_t) dlsym(RTLD_NEXT, "pthread_mutex_lock");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("pthread_mutex_lock");
    return funcptr(mutex);
}

int objc_sync_enter(id obj) {
    static objc_sync_enter_t funcptr = NULL;
    if ( !funcptr ) funcptr = (objc_sync_enter_t) dlsym(RTLD_NEXT, "objc_sync_enter");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("@synchronized block");
    return funcptr(obj);
}

id objc_storeStrong(id * object, id value);
id objc_storeStrong(id * object, id value) {
    static objc_storeStrong_t funcptr = NULL;
    if ( !funcptr ) funcptr = (objc_storeStrong_t) dlsym(RTLD_NEXT, "objc_storeStrong");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("object retain");
    return funcptr(object,value);
}

objc_msgSend_t AERealtimeWatchdogLookupMsgSendAndWarn(void);
objc_msgSend_t AERealtimeWatchdogLookupMsgSendAndWarn(void) {
    // This method is called by our objc_msgSend implementation
    static objc_msgSend_t funcptr = NULL;
    if ( !funcptr ) funcptr = (objc_msgSend_t) dlsym(RTLD_NEXT, "objc_msgSend");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("message send");
    return funcptr;
}

ssize_t send(int socket, const void *buffer, size_t length, int flags) {
    static send_t funcptr = NULL;
    if ( !funcptr ) funcptr = (send_t) dlsym(RTLD_NEXT, "send");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("send");
    return funcptr(socket, buffer, length, flags);
}

ssize_t sendto(int socket, const void *buffer, size_t length, int flags,
               const struct sockaddr *dest_addr, socklen_t dest_len) {
    static sendto_t funcptr = NULL;
    if ( !funcptr ) funcptr = (sendto_t) dlsym(RTLD_NEXT, "sendto");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("sendto");
    return funcptr(socket, buffer, length, flags, dest_addr, dest_len);
}

ssize_t recv(int socket, void *buffer, size_t length, int flags) {
    static recv_t funcptr = NULL;
    if ( !funcptr ) funcptr = (recv_t) dlsym(RTLD_NEXT, "recv");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("recv");
    return funcptr(socket, buffer, length, flags);
}

ssize_t recvfrom(int socket, void *restrict buffer, size_t length, int flags,
                 struct sockaddr *restrict address, socklen_t *restrict address_len) {
    static recvfrom_t funcptr = NULL;
    if ( !funcptr ) funcptr = (recvfrom_t) dlsym(RTLD_NEXT, "recvfrom");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("recvfrom");
    return funcptr(socket, buffer, length, flags, address, address_len);
}

FILE * fopen(const char *restrict filename, const char *restrict mode) {
    static fopen_t funcptr = NULL;
    if ( !funcptr ) funcptr = (fopen_t) dlsym(RTLD_NEXT, "fopen");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("fopen");
    return funcptr(filename, mode);
}

size_t fread(void *restrict ptr, size_t size, size_t nitems, FILE *restrict stream) {
    static fread_t funcptr = NULL;
    if ( !funcptr ) funcptr = (fread_t) dlsym(RTLD_NEXT, "fread");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("fread");
    return funcptr(ptr, size, nitems, stream);
}

size_t fwrite(const void *restrict ptr, size_t size, size_t nitems, FILE *restrict stream) {
    static fwrite_t funcptr = NULL;
    if ( !funcptr ) funcptr = (fwrite_t) dlsym(RTLD_NEXT, "fwrite");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("fwrite");
    return funcptr(ptr, size, nitems, stream);
}

char * fgets(char * restrict str, int size, FILE * restrict stream) {
    static fgets_t funcptr = NULL;
    if ( !funcptr ) funcptr = (fgets_t) dlsym(RTLD_NEXT, "fgets");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("fgets");
    return funcptr(str, size, stream);
}

ssize_t read(int fildes, void *buf, size_t nbyte) {
    static read_t funcptr = NULL;
    if ( !funcptr ) funcptr = (read_t) dlsym(RTLD_NEXT, "read");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("read");
    return funcptr(fildes, buf, nbyte);
}

ssize_t pread(int d, void *buf, size_t nbyte, off_t offset) {
    static pread_t funcptr = NULL;
    if ( !funcptr ) funcptr = (pread_t) dlsym(RTLD_NEXT, "pread");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("pread");
    return funcptr(d, buf, nbyte, offset);
}

ssize_t write(int fildes, const void *buf, size_t nbyte) {
    static write_t funcptr = NULL;
    if ( !funcptr ) funcptr = (write_t) dlsym(RTLD_NEXT, "write");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("write");
    return funcptr(fildes, buf, nbyte);
}

ssize_t pwrite(int fildes, const void *buf, size_t nbyte, off_t offset) {
    static pwrite_t funcptr = NULL;
    if ( !funcptr ) funcptr = (pwrite_t) dlsym(RTLD_NEXT, "pwrite");
    if ( AERealtimeWatchdogIsOnRealtimeThread() ) AERealtimeWatchdogUnsafeActivityWarning("pwrite");
    return funcptr(fildes, buf, nbyte, offset);
}

#endif
