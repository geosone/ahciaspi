;--- RTVXD.ASM: the 64-bit shift helpers Open Watcom calls (the C library
;--- is not linked into the VxD).  EDX:EAX = value, ECX:EBX = count,
;--- result in EDX:EAX; other registers preserved.
;--- Copyright (C) 2026 GeosOne.  GNU General Public License version 3.

	.386
	.model flat
	option casemap:none

	.code

	public __U8RS, __U8LS, __I8RS

__U8RS proc
	push ecx
	mov ecx, ebx
	and ecx, 63
	cmp cl, 32
	jb @F
	mov eax, edx
	xor edx, edx
	sub cl, 32
	shr eax, cl
	pop ecx
	ret
@@:	shrd eax, edx, cl
	shr edx, cl
	pop ecx
	ret
__U8RS endp

__I8RS proc
	push ecx
	mov ecx, ebx
	and ecx, 63
	cmp cl, 32
	jb @F
	mov eax, edx
	sar edx, 31
	sub cl, 32
	sar eax, cl
	pop ecx
	ret
@@:	shrd eax, edx, cl
	sar edx, cl
	pop ecx
	ret
__I8RS endp

__U8LS proc
	push ecx
	mov ecx, ebx
	and ecx, 63
	cmp cl, 32
	jb @F
	mov edx, eax
	xor eax, eax
	sub cl, 32
	shl edx, cl
	pop ecx
	ret
@@:	shld edx, eax, cl
	shl eax, cl
	pop ecx
	ret
__U8LS endp

	end
