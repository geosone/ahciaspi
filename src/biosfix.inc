;=============================================================================
; biosfix.inc - work around two bugs in the VDS use of Intel AHCI firmware
; (resident part of AHCIASPI.SYS)
;
; The INT 13h code of Intel AHCI option ROMs uses the Virtual DMA Services
; (INT 4Bh) of a memory manager (EMM386, ...) wrongly:
; 1. it locks a region with ES:DI -> DMA descriptor, but unlocks with the
;    descriptor's segment in DS instead of ES (the memory manager reads a
;    wrong descriptor: physical address 0);
; 2. it puts the descriptor at the start of the EBDA (offset from the ROM is
;    0) and so overwrites BIOS data there (e.g. the PS/2 mouse data).
; The fix filters DOS's pointers to the INT 13h code (INT 2Fh AH=13h): while
; a BIOS disk call runs, INT 4Bh is hooked; a lock of a region at the start
; of the EBDA saves its first 6Ch bytes, the unlock restores them, and an
; unlock with the descriptor in the wrong segment register gets ES and DS
; swapped (and swapped back when the VDS call returns).
; In Windows 3.x enhanced mode the filter is off (INT 2Fh AX=1605h ..
; 1606h): VDS is Windows' own there, AHCIVXD.386 takes the disks over.
;
; Based on ahcifixd.sys by PluMGMK (MIT license,
; https://github.com/PluMGMK/ahcifixd.sys), rewritten for NASM.
;=============================================================================

BF_SCRATCH      equ     6Ch

bf_flags        db      0               ; bit 0 = filter on, bit 1 = ROM pointer
bf_dos13        dd      0               ; DOS's INT 13h code before us
bf_rom13        dd      0               ; the ROM's
bf_old4b        dd      0
bf_old2f        dd      0
bf_ret          dd      0               ; return address of the INT 13h call
bf_retfl        dw      0               ; its flags
bf_vdsret       dd      0               ; return address of the VDS call
bf_scratch      times BF_SCRATCH db 0   ; saved start of the EBDA

; DMA descriptor (VDS)
DD_OFFSET       equ     4
DD_SEGMENT      equ     8
DD_PHYS         equ     12

; DOS's INT 13h pointer (DOS calls it with PUSHF + CALL FAR)
bf_int13_rom:
        or      byte [cs:bf_flags], 2
bf_int13:
        test    byte [cs:bf_flags], 1
        jz      .pass
        push    ax
        push    es
        mov     ax, 40h
        mov     es, ax
        test    byte [es:7Bh], 20h      ; VDS present?
        pop     es
        pop     ax
        jnz     .filter
.pass:  btr     word [cs:bf_flags], 1
        jc      .rom
        jmp     far [cs:bf_dos13]
.rom:   jmp     far [cs:bf_rom13]

.filter:
        call    bf_hook4b
        pop     word [cs:bf_ret]        ; IP, CS, flags of the caller
        pop     word [cs:bf_ret+2]
        pop     word [cs:bf_retfl]      ; (no POPF: interrupts stay as they are)
        push    word [cs:bf_ret+2]      ; RETF frame for us
        push    word [cs:bf_ret]
        push    word [cs:bf_retfl]      ; IRET frame for the BIOS
        btr     word [cs:bf_flags], 1
        jc      .crom
        call    far [cs:bf_dos13]
        jmp     .done
.crom:  call    far [cs:bf_rom13]
.done:  call    bf_unhook4b
        retf                            ; flags (CF) as the BIOS returned them

bf_hook4b:
        push    es
        push    eax
        xor     ax, ax
        mov     es, ax
        mov     ax, cs
        cmp     ax, [es:4Bh*4+2]        ; already ours (nested call)
        je      .done
        mov     eax, [es:4Bh*4]
        mov     [cs:bf_old4b], eax
        mov     word [es:4Bh*4], bf_int4b
        mov     [es:4Bh*4+2], cs
.done:  pop     eax
        pop     es
        ret

bf_unhook4b:
        push    es
        push    eax
        xor     ax, ax
        mov     es, ax
        mov     eax, [cs:bf_old4b]
        mov     [es:4Bh*4], eax
        pop     eax
        pop     es
        ret

; segment of the EBDA -> AX
bf_ebda:
        push    es
        mov     ax, 40h
        mov     es, ax
        mov     ax, [es:0Eh]
        pop     es
        ret

; INT 4Bh while a BIOS disk call runs
bf_int4b:
        cmp     ah, 81h
        jne     .pass
        cmp     al, 03h                 ; lock DMA region
        jne     .notlock
        push    ax
        call    bf_ebda
        cmp     [es:di+DD_SEGMENT], ax
        pop     ax
        jne     .pass
        cmp     dword [es:di+DD_OFFSET], BF_SCRATCH
        jae     .pass
        push    ds                      ; save the start of the EBDA
        push    es
        push    si
        push    di
        push    cx
        mov     ds, [es:di+DD_SEGMENT]
        push    cs
        pop     es
        xor     si, si
        mov     di, bf_scratch
        mov     cx, BF_SCRATCH / 4
        cld
        rep     movsd
        pop     cx
        pop     di
        pop     si
        pop     es
        pop     ds
        jmp     .pass

.notlock:
        cmp     al, 06h                 ; scatter/gather unlock
        je      .unlock
        cmp     al, 04h                 ; unlock DMA region
        jne     .pass
.unlock:
        cmp     dword [es:di+DD_PHYS], 0
        jne     .ebda
        push    es                      ; descriptor in the wrong register
        push    ds
        pop     es
        pop     ds
        pop     dword [cs:bf_vdsret]    ; the VDS IRET returns to bf_unswap
        push    cs                      ; (the flags of the INT frame stay)
        push    word bf_unswap
.ebda:  push    ax
        call    bf_ebda
        cmp     [es:di+DD_SEGMENT], ax
        pop     ax
        jne     .pass
        cmp     dword [es:di+DD_OFFSET], BF_SCRATCH
        jae     .pass
        push    ds                      ; restore the start of the EBDA
        push    es
        push    si
        push    di
        push    cx
        mov     es, [es:di+DD_SEGMENT]
        push    cs
        pop     ds
        mov     si, bf_scratch
        xor     di, di
        mov     cx, BF_SCRATCH / 4
        cld
        rep     movsd
        pop     cx
        pop     di
        pop     si
        pop     es
        pop     ds
.pass:  jmp     far [cs:bf_old4b]

; the VDS call returns here (IRET popped the flags): swap back
bf_unswap:
        push    es
        push    ds
        pop     es
        pop     ds
        jmp     far [cs:bf_vdsret]

; INT 2Fh: no filter while Windows runs in enhanced mode
bf_int2f:
        cmp     ax, 1605h               ; Windows starts
        jne     .exit
        test    dx, 1                   ; standard mode: keep the filter
        jnz     .chain
        and     byte [cs:bf_flags], ~1
        jmp     .chain
.exit:  cmp     ax, 1606h               ; Windows exits
        jne     .chain
        test    dx, 1
        jnz     .chain
        or      byte [cs:bf_flags], 1
.chain: jmp     far [cs:bf_old2f]
