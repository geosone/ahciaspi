; EXT13.COM - test the extended INT 13h functions of drive 80h (for
; AHCIVXD in a Windows DOS box): AH=41h, AH=42h against AH=02h (CHS) for
; the first 8 sectors, AH=43h + 42h on the last sector of the disk (its
; contents are written back afterwards).  Prints OK/FAIL lines.
        cpu     386
        org     100h

        mov     ah, 41h
        mov     bx, 55AAh
        mov     dl, 80h
        int     13h
        jc      .no41
        cmp     bx, 0AA55h
        jne     .no41
        mov     si, msg_41ok
        call    print
        jmp     .t42
.no41:  mov     si, msg_41fail
        call    print
        jmp     .exit

.t42:   mov     word [dap+2], 8         ; 8 sectors LBA 0 -> buf1
        mov     word [dap+4], buf1
        mov     [dap+6], cs
        mov     dword [dap+8], 0
        mov     dword [dap+12], 0
        mov     ah, 42h
        mov     dl, 80h
        mov     si, dap
        int     13h
        jc      .f42
        mov     ax, 0208h               ; the same through CHS -> buf2
        mov     cx, 0001h
        mov     dx, 0080h
        mov     bx, buf2
        push    cs
        pop     es
        int     13h
        jc      .f42
        mov     si, buf1
        mov     di, buf2
        mov     cx, 8 * 512
        repe    cmpsb
        jne     .f42
        mov     si, msg_42ok
        call    print
        jmp     .t43
.f42:   mov     si, msg_42fail
        call    print
        jmp     .exit

.t43:   mov     byte [step], 'S'
        mov     ah, 48h                 ; size of the disk
        mov     dl, 80h
        mov     si, params
        mov     word [params], 30
        int     13h
        jc      .f43
        mov     eax, [params+10h]       ; last sector
        sub     eax, 1
        mov     [last], eax
        mov     byte [step], 'R'
        mov     word [dap+2], 1         ; save it
        mov     word [dap+4], buf2
        mov     [dap+8], eax
        mov     dword [dap+12], 0
        mov     ah, 42h
        mov     dl, 80h
        mov     si, dap
        int     13h
        jc      .f43
        mov     di, buf1                ; pattern
        mov     cx, 512
        mov     al, 0A5h
.pat:   mov     [di], al
        inc     di
        add     al, 3
        loop    .pat
        mov     byte [step], 'W'
        mov     word [dap+2], 1
        mov     word [dap+4], buf1
        mov     ax, 4300h
        mov     dl, 80h
        mov     si, dap
        int     13h
        jc      .f43
        mov     byte [step], 'B'
        mov     word [dap+2], 1         ; read it back
        mov     word [dap+4], buf3
        mov     ah, 42h
        mov     dl, 80h
        mov     si, dap
        int     13h
        jc      .f43
        mov     si, buf1
        mov     di, buf3
        mov     cx, 512
        mov     byte [step], 'C'
        repe    cmpsb
        jne     .f43
        mov     byte [step], 'X'
        mov     word [dap+2], 1         ; the old contents back
        mov     word [dap+4], buf2
        mov     ax, 4300h
        mov     dl, 80h
        mov     si, dap
        int     13h
        jc      .f43
        mov     si, msg_43ok
        call    print
        jmp     .exit
.f43:   mov     [code], ah
        mov     si, msg_43fail
        call    print
        mov     al, [step]
        mov     [msg_step], al
        mov     al, [code]
        shr     al, 4
        add     al, '0'
        mov     [msg_step+2], al
        mov     al, [code]
        and     al, 15
        add     al, '0'
        mov     [msg_step+3], al
        mov     si, msg_step
        call    print
.exit:  mov     ax, 4C00h
        int     21h

print:  lodsb
        or      al, al
        jz      .r
        mov     dl, al
        mov     ah, 2
        int     21h
        jmp     print
.r:     ret

msg_41ok   db 'EXT13: 41h OK', 13, 10, 0
msg_41fail db 'EXT13: 41h FAIL', 13, 10, 0
msg_42ok   db 'EXT13: 42h = 02h OK', 13, 10, 0
msg_42fail db 'EXT13: 42h FAIL', 13, 10, 0
msg_43ok   db 'EXT13: 43h write + read back OK', 13, 10, 0
msg_43fail db 'EXT13: 43h FAIL', 13, 10, 0
step    db '?'
code    db 0
msg_step db '? xx', 13, 10, 0
dap     db 16, 0
        dw 0, 0, 0
        dd 0, 0
last    dd 0
params  times 30 db 0
buf1    times 8*512 db 0
buf2    times 8*512 db 0
buf3    times 512 db 0
