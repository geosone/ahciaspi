;=============================================================================
; TESTDRV.SYS - minimal one-unit RAM disk block driver for tests
;
; Behaves like MKELS120.SYS / GUEST: an installable block driver with a
; single unit 0.  Requests for any other unit are rejected with "unknown
; unit", so tools that rewrite drive letters (DLMANIP) can be checked for
; keeping the unit number intact.  The disk holds a 32 KB FAT12 volume
; "TESTDRV<x>" with the file UNIT0.TXT, where <x> is the first character of
; the command line after the file name (DEVICE=TESTDRV.SYS L), default 0.
;=============================================================================
        cpu     386
        bits    16
        org     0

SECTORS         equ     64

hdr_next        dd      -1
hdr_attr        dw      0000h           ; block device
                dw      strategy
                dw      interrupt
                db      1, 'TESTDRV'

req_ptr         dd      0
bpb_ptr         dw      bpb

bpb:            dw      512             ; bytes per sector
                db      1               ; sectors per cluster
                dw      1               ; reserved sectors
                db      1               ; FATs
                dw      16              ; root entries
                dw      SECTORS         ; total sectors
                db      0F8h            ; media
                dw      1               ; sectors per FAT

strategy:
        mov     [cs:req_ptr], bx
        mov     [cs:req_ptr+2], es
        retf

interrupt:
        pushad
        push    ds
        push    es
        cld
        lds     bx, [cs:req_ptr]
        mov     al, [bx+2]
        cmp     al, 0
        je      .init
        cmp     byte [bx+1], 0          ; only unit 0 exists
        jne     .badunit
        cmp     al, 1
        je      .media
        cmp     al, 2
        je      .buildbpb
        cmp     al, 4
        je      .read
        cmp     al, 8
        je      .write
        cmp     al, 9
        je      .write
        jmp     .done
.badunit:
        mov     word [bx+3], 8101h
        jmp     .exit
.media: mov     byte [bx+0Eh], 1        ; not changed
        jmp     .done
.buildbpb:
        mov     word [bx+12h], bpb
        mov     [bx+14h], cs
        jmp     .done
.read:  call    xfer_setup
        jc      .badsec
        push    ds
        mov     ds, dx                  ; DS:SI = disk, ES:DI = buffer
        rep     movsw
        pop     ds
        jmp     .done
.write: call    xfer_setup
        jc      .badsec
        push    ds
        push    es                      ; swap direction
        mov     es, dx
        pop     ds
        xchg    si, di
        rep     movsw
        pop     ds
        jmp     .done
.badsec:
        mov     word [bx+12h], 0
        mov     word [bx+3], 8108h      ; sector not found
        jmp     .exit
.init:  call    init
.done:  mov     word [bx+3], 0100h
.exit:  pop     es
        pop     ds
        popad
        retf

; DS:BX = read/write request -> ES:DI buffer, DX:SI disk data, CX words
xfer_setup:
        mov     ax, [bx+14h]            ; start sector
        mov     cx, [bx+12h]            ; count
        mov     dx, ax
        add     dx, cx
        cmp     dx, SECTORS
        ja      .bad
        les     di, [bx+0Eh]
        shl     cx, 8                   ; words
        mov     dx, cs
        add     dx, disk_seg
        shl     ax, 5                   ; sectors -> paragraphs
        add     dx, ax
        xor     si, si
        clc
        ret
.bad:   stc
        ret

                align   16
disk:
disk_seg        equ     (disk - $$) / 16
                times SECTORS * 512 db 0
resident_end:

init:
        push    ds                      ; ID character from the command line
        lds     si, [bx+12h]
.skipname:
        lodsb
        cmp     al, ' '
        ja      .skipname
.skipblank:
        cmp     al, ' '
        jne     .gotid
        lodsb
        jmp     .skipblank
.gotid: pop     ds
        cmp     al, ' '
        ja      .setid
        mov     al, '0'
.setid: mov     [cs:root_dir+7], al
        mov     [cs:file_text+8], al
        mov     [cs:msg+8], al
        push    cs
        pop     es
        ; boot sector BPB copy
        mov     di, disk + 0Bh
        mov     si, bpb
        push    ds
        push    cs
        pop     ds
        mov     cx, 13
        rep     movsb
        mov     word [disk + 510], 0AA55h
        ; FAT: media, cluster 2 = EOF
        mov     dword [disk + 512], 0FFFFFFF8h
        mov     byte [disk + 516], 0Fh
        ; root directory: volume label and UNIT0.TXT
        mov     si, root_dir
        mov     di, disk + 1024
        mov     cx, 64
        rep     movsb
        mov     si, file_text
        mov     di, disk + 1536
        mov     cx, file_len
        rep     movsb
        mov     dx, msg
        mov     ah, 9
        int     21h
        pop     ds
        mov     byte [bx+0Dh], 1        ; one unit
        mov     word [bx+0Eh], resident_end
        mov     [bx+10h], cs
        mov     word [bx+12h], bpb_ptr
        mov     [bx+14h], cs
        ret

root_dir:       db      'TESTDRV0   ', 08h
                times 20 db 0
                db      'UNIT0   TXT', 20h
                times 14 db 0
                dw      2
                dd      file_len
file_text:      db      'TESTDRV 0 unit 0 read OK', 13, 10
file_len        equ     $ - file_text
msg:            db      'TESTDRV 0: 32 KB RAM disk, unit 0', 13, 10, '$'
