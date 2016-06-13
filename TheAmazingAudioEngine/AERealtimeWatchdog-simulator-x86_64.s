//
//  AERealtimeWatchdog-simulator-x86_64.s
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


#include <TargetConditionals.h>
#include "AERealtimeWatchdog.h"
#if __x86_64__ && TARGET_IPHONE_SIMULATOR && REALTIME_WATCHDOG_ENABLED


/********************************************************************
 * Names for parameter registers.
 ********************************************************************/

#define a1  rdi
#define a1d edi
#define a1b dil
#define a2  rsi
#define a2d esi
#define a2b sil
#define a3  rdx
#define a3d edx
#define a4  rcx
#define a4d ecx
#define a5  r8
#define a5d r8d
#define a6  r9
#define a6d r9d

/////////////////////////////////////////////////////////////////////
//
// SaveRegisters
//
// Pushes a stack frame and saves all registers that might contain
// parameter values.
//
// On entry:
//		stack = ret
//
// On exit: 
//		%rsp is 16-byte aligned
//	
/////////////////////////////////////////////////////////////////////

.macro SaveRegisters

	push	%rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	
	mov	%rsp, %rbp
	.cfi_def_cfa_register rbp
	
	sub	$$0x80+8, %rsp		// +8 for alignment

	movdqa	%xmm0, -0x80(%rbp)
	push	%rax			// might be xmm parameter count
	movdqa	%xmm1, -0x70(%rbp)
	push	%a1
	movdqa	%xmm2, -0x60(%rbp)
	push	%a2
	movdqa	%xmm3, -0x50(%rbp)
	push	%a3
	movdqa	%xmm4, -0x40(%rbp)
	push	%a4
	movdqa	%xmm5, -0x30(%rbp)
	push	%a5
	movdqa	%xmm6, -0x20(%rbp)
	push	%a6
	movdqa	%xmm7, -0x10(%rbp)
	
.endmacro

/////////////////////////////////////////////////////////////////////
//
// RestoreRegisters
//
// Pops a stack frame pushed by SaveRegisters
//
// On entry:
//		%rbp unchanged since SaveRegisters
//
// On exit: 
//		stack = ret
//	
/////////////////////////////////////////////////////////////////////

.macro RestoreRegisters

	movdqa	-0x80(%rbp), %xmm0
	pop	%a6
	movdqa	-0x70(%rbp), %xmm1
	pop	%a5
	movdqa	-0x60(%rbp), %xmm2
	pop	%a4
	movdqa	-0x50(%rbp), %xmm3
	pop	%a3
	movdqa	-0x40(%rbp), %xmm4
	pop	%a2
	movdqa	-0x30(%rbp), %xmm5
	pop	%a1
	movdqa	-0x20(%rbp), %xmm6
	pop	%rax
	movdqa	-0x10(%rbp), %xmm7
	
	leave
	.cfi_def_cfa rsp, 8

    // Following removed to suppress "could not create compact unwind for _objc_msgSend: dwarf uses DW_CFA_same_value".
    // Seems to make no difference. -- MT
    //.cfi_same_value rbp

.endmacro


/********************************************************************
 *
 * id objc_msgSend(id self, SEL	_cmd,...);
 *
 ********************************************************************/

    .text
    .globl _objc_msgSend
	.align	6, 0x90
_objc_msgSend:
	.cfi_startproc

    // Save the parameter registers
	SaveRegisters

    // Look up the real objc_msgSend
	call	_AERealtimeWatchdogLookupMsgSendAndWarn

	// imp is now in %rax
	movq	%rax, %r11

    // Restore registers
	RestoreRegisters

    // Call imp
    jmp	*%r11
    
	.cfi_endproc

#endif
