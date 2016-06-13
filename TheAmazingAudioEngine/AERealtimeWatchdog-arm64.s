//
//  AERealtimeWatchdog-arm64.c
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 12/06/2016.
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
//
/*
 * Portions Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 */

#include "AERealtimeWatchdog.h"
#if __arm64__ && REALTIME_WATCHDOG_ENABLED

#include <arm/arch.h>

.text
.align 5
    .globl _objc_msgSend
_objc_msgSend:
    // Push frame
    stp	fp, lr, [sp, #-16]!
    mov	fp, sp

    // Save the parameter registers: x0..x8, q0..q7
    sub	sp, sp, #(10*8 + 8*16)
    stp	q0, q1, [sp, #(0*16)]
    stp	q2, q3, [sp, #(2*16)]
    stp	q4, q5, [sp, #(4*16)]
    stp	q6, q7, [sp, #(6*16)]
    stp	x0, x1, [sp, #(8*16+0*8)]
    stp	x2, x3, [sp, #(8*16+2*8)]
    stp	x4, x5, [sp, #(8*16+4*8)]
    stp	x6, x7, [sp, #(8*16+6*8)]
    str	x8,     [sp, #(8*16+8*8)]

    // Look up the real objc_msgSend
    bl	_AERealtimeWatchdogLookupMsgSendAndWarn

    // imp in x0
    mov	x17, x0

    // Restore registers and stack frame
    ldp	q0, q1, [sp, #(0*16)]
    ldp	q2, q3, [sp, #(2*16)]
    ldp	q4, q5, [sp, #(4*16)]
    ldp	q6, q7, [sp, #(6*16)]
    ldp	x0, x1, [sp, #(8*16+0*8)]
    ldp	x2, x3, [sp, #(8*16+2*8)]
    ldp	x4, x5, [sp, #(8*16+4*8)]
    ldp	x6, x7, [sp, #(8*16+6*8)]
    ldr	x8,     [sp, #(8*16+8*8)]

    mov	sp, fp
    ldp	fp, lr, [sp], #16

    // Call imp
    br	x17

#endif
