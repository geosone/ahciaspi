;--- AHCIRMI.ASM: real mode initialization of AHCIVXD (the LE entry point,
;--- called by WIN386 before it switches to protected mode).
;---
;--- The disks have to be registered with BlockDev in Sys_Critical_Init,
;--- before the BIOS can be called from protected mode, and WIN386 reuses
;--- this code's memory: so this part reads the first sector of each BIOS
;--- hard disk (80h..83h) through the BIOS and passes its CRC-32 in the
;--- BIOS Intra-Application Communication Area (0040:00F0, 16 bytes) to
;--- the protected mode part, which finds the disks on the controllers by
;--- it.  The reference data (EDX) says which CRCs are valid:
;---   bits 0-3  CRC of drive 80h+n valid
;---   bit 8     a program has hooked DOS's Int 13h path and is not
;---             BlockDev aware (INT 2Fh AX=1607h BX=10h CX=3)
;---   bits 16-23 number of BIOS hard disks, bits 24-31 = 0A5h
;---
;--- Entry: AX = Windows version, BX = flags, SI = environment segment
;--- Exit:  AX = 0 (load) or 8001h (don't load, no message), BX = SI = 0
;---
;--- Copyright (C) 2026 GeosOne.  GNU General Public License version 3.

	.386
_RCODE segment dword use16 public 'RCODE'
	assume cs:_RCODE, ds:_RCODE

rmi_start:
	test bx, 1                     ; Duplicate_Device_ID
	jnz no_load
	push cs
	pop ds
	push cs
	pop es
	xor ebp, ebp                   ; result flags

	mov ax, 1607h                  ; disk caches: hardware detection starts
	mov bx, 10h
	mov cx, 1
	int 2Fh

	push ds
	mov ax, 40h
	mov ds, ax
	movzx cx, byte ptr ds:[75h]    ; number of hard disks
	pop ds
	mov al, cl
	movzx eax, al
	shl eax, 16
	or ebp, eax
	cmp cx, 4
	jbe @F
	mov cx, 4
@@:	jcxz detect_done
	xor di, di                     ; drive index
next_drive:
	push cx
	mov bx, offset mbr             ; first sector through the BIOS
	mov dx, di
	or dl, 80h
	mov dh, 0
	mov ax, 0201h
	mov cx, 0001h
	int 13h
	jc drive_done
	mov si, offset mbr             ; CRC-32 (as zlib)
	mov cx, 512
	mov edx, 0FFFFFFFFh
crc_byte:
	lodsb
	xor dl, al
	mov bx, 8
crc_bit:
	shr edx, 1
	jnc @F
	xor edx, 0EDB88320h
@@:	dec bx
	jnz crc_bit
	loop crc_byte
	not edx
	push es
	mov ax, 40h
	mov es, ax
	mov bx, di
	shl bx, 2
	mov es:[0F0h+bx], edx          ; Intra-Application Communication Area
	pop es
	bts ebp, edi                   ; CRC valid
drive_done:
	pop cx
	inc di
	loop next_drive
detect_done:
	mov ax, 1607h
	mov bx, 10h
	mov cx, 2                      ; hardware detection ends
	int 2Fh

	call check_chain
	jnc @F
	or ebp, 100h
@@:	or ebp, 0A5000000h
	mov edx, ebp
	xor ax, ax                     ; Device_Load_Ok
	xor bx, bx
	xor si, si
	ret

no_load:
	mov ax, 8001h                  ; Abort_Device_Load + No_Fail_Message
	xor bx, bx
	xor si, si
	xor edx, edx
	ret

;--- has a program hooked DOS's Int 13h path (INT 2Fh AH=13h) and is not
;--- BlockDev aware?  CF set if so.
check_chain:
	push ds
	push es
	mov ah, 13h                    ; get the handlers by setting dummies
	mov dx, offset dummy_int13
	mov bx, offset dummy_int13
	push cs
	pop ds
	push cs
	pop es
	cli
	int 2Fh                        ; DS:DX = DOS's handler, ES:BX = ROM's
	mov cs:[dos13_off], dx
	mov cs:[dos13_seg], ds
	mov cs:[rom13_off], bx
	mov cs:[rom13_seg], es
	int 2Fh                        ; and back
	sti
	pop es
	pop ds
	mov ax, [dos13_seg]
	cmp ax, [rom13_seg]
	jne hooked
	mov ax, [dos13_off]
	cmp ax, [rom13_off]
	je chain_ok
hooked:
	mov ax, 1607h
	mov bx, 10h
	mov cx, 3                      ; Int13_Chain_Check
	int 2Fh
	jcxz chain_ok
	stc
	ret
chain_ok:
	clc
	ret

dummy_int13:
	iret

dos13_off    dw 0
dos13_seg    dw 0
rom13_off    dw 0
rom13_seg    dw 0
mbr          db 512 dup (0)

_RCODE ends

	end rmi_start
