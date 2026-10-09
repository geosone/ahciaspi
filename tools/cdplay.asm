;=============================================================================
; CDPLAY.COM - play CD audio through MSCDEX like a DOS game does
;
; Reads the disc's track list (IOCTL audio disk / track info), plays the
; first audio track for a few seconds (Red Book addressing), reads the
; current position from the Q channel while playing and stops again.
; Prints every step and the device driver status words.
;=============================================================================
        cpu     386
        bits    16
        org     100h

PLAY_SECONDS    equ     3

start:
        mov     ax, 1500h               ; MSCDEX installed?
        xor     bx, bx
        int     2Fh
        or      bx, bx
        jnz     .found
        mov     dx, msg_nomscdex
        jmp     exit
.found: mov     [drive], cx

        ; audio disk info: lowest / highest track
        mov     byte [cb], 0Ah
        mov     cx, 7
        call    ioctl_in
        mov     dx, msg_disk
        call    status
        jc      done
        mov     dx, msg_tracks
        call    puts
        mov     al, [cb+1]
        call    dec8
        mov     dl, '-'
        call    putc
        mov     al, [cb+2]
        call    dec8
        call    crlf
        mov     al, [cb+1]
        mov     [track], al
        mov     al, [cb+2]
        mov     [last], al

.find:  ; first track without the data bit (control bit 6)
        mov     byte [cb], 0Bh
        mov     al, [track]
        mov     [cb+1], al
        mov     cx, 7
        call    ioctl_in
        jc      done
        test    byte [cb+6], 40h
        jz      .audio
        mov     al, [track]
        cmp     al, [last]
        jae     .noaudio
        inc     byte [track]
        jmp     .find
.noaudio:
        mov     dx, msg_noaudio
        jmp     exit
.audio: mov     dx, msg_track
        call    puts
        mov     al, [track]
        call    dec8
        mov     dx, msg_at
        call    puts
        mov     al, [cb+4]              ; minute
        call    dec8
        mov     dl, ':'
        call    putc
        mov     al, [cb+3]              ; second
        call    dec8
        mov     dl, '.'
        call    putc
        mov     al, [cb+2]              ; frame
        call    dec8
        call    crlf

        ; PLAY AUDIO, Red Book start address, PLAY_SECONDS seconds
        mov     eax, [cb+2]             ; frame, second, minute, 0
        mov     byte [req], 22
        mov     byte [req+2], 132
        mov     byte [req+0Dh], 1       ; Red Book addressing
        mov     [req+0Eh], eax
        mov     dword [req+12h], PLAY_SECONDS * 75
        call    send
        mov     dx, msg_play
        call    status
        jc      done

        mov     cx, 18                  ; ~1 second
.wait:  call    wait_tick
        loop    .wait

        ; Q channel: current position while playing
        mov     byte [cb], 0Ch
        mov     cx, 11
        call    ioctl_in
        mov     dx, msg_qchan
        call    status
        jc      .stop
        mov     dx, msg_pos
        call    puts
        mov     al, [cb+2]              ; track (BCD as on the disc)
        call    hex8
        mov     dx, msg_in
        call    puts
        mov     al, [cb+4]
        call    dec8
        mov     dl, ':'
        call    putc
        mov     al, [cb+5]
        call    dec8
        mov     dl, '.'
        call    putc
        mov     al, [cb+6]
        call    dec8
        call    crlf

.stop:  mov     byte [req], 13          ; STOP AUDIO
        mov     byte [req+2], 133
        call    send
        mov     dx, msg_stop
        call    status
done:   mov     dx, msg_done
exit:   mov     ah, 9
        int     21h
        mov     ax, 4C00h
        int     21h

; IOCTL input with control block cb, CX = length
ioctl_in:
        mov     byte [req], 26
        mov     byte [req+2], 3
        mov     byte [req+0Dh], 0
        mov     word [req+0Eh], cb
        mov     [req+10h], cs
        mov     [req+12h], cx
        mov     word [req+14h], 0
        mov     dword [req+16h], 0
send:   mov     word [req+3], 0
        push    cs
        pop     es
        mov     bx, req
        mov     cx, [drive]
        mov     ax, 1510h
        int     2Fh
        ret

; print label DX and the status word.  CF if the error bit is set.
status: call    puts
        mov     ax, [req+3]
        push    ax
        mov     al, ah
        call    hex8
        pop     ax
        call    hex8
        call    crlf
        test    byte [req+4], 80h
        jz      .ok
        stc
        ret
.ok:    clc
        ret

wait_tick:
        push    ax
        push    es
        push    word 40h
        pop     es
        mov     ax, [es:6Ch]
.w:     sti
        cmp     ax, [es:6Ch]
        je      .w
        pop     es
        pop     ax
        ret

puts:   push    ax
        mov     ah, 9
        int     21h
        pop     ax
        ret

putc:   push    ax
        mov     ah, 2
        int     21h
        pop     ax
        ret

crlf:   push    dx
        mov     dx, msg_crlf
        call    puts
        pop     dx
        ret

dec8:   push    ax                      ; AL, two digits
        push    dx
        aam
        add     ax, 3030h
        push    ax
        mov     dl, ah
        call    putc
        pop     ax
        mov     dl, al
        call    putc
        pop     dx
        pop     ax
        ret

hex8:   push    ax
        push    dx
        mov     ah, al
        shr     al, 4
        call    .nib
        mov     al, ah
        and     al, 0Fh
        call    .nib
        pop     dx
        pop     ax
        ret
.nib:   add     al, '0'
        cmp     al, '9'
        jbe     .p
        add     al, 7
.p:     mov     dl, al
        jmp     putc

msg_nomscdex    db      'MSCDEX not installed', 13, 10, '$'
msg_disk        db      'AUDIO DISK INFO status $'
msg_tracks      db      'tracks $'
msg_noaudio     db      'no audio track', 13, 10, '$'
msg_track       db      'first audio track $'
msg_at          db      ' at $'
msg_play        db      'PLAY AUDIO status $'
msg_qchan       db      'Q CHANNEL status $'
msg_pos         db      'playing track $'
msg_in          db      ' at $'
msg_stop        db      'STOP AUDIO status $'
msg_done        db      'CDPLAY done', 13, 10, '$'
msg_crlf        db      13, 10, '$'
drive           dw      0
track           db      0
last            db      0
cb              times 16 db 0
req             times 32 db 0
