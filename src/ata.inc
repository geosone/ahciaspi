;=============================================================================
; ATA (non-packet) removable disks on IDE channels and AHCI ports
;
; Cartridge drives such as the SyQuest EZ135 and EZFlyer are plain ATA disks
; with the removable bit in IDENTIFY DEVICE word 0, not ATAPI devices.  They
; are offered as SCSI direct access devices; the SCSI commands of the block
; drivers are carried out with ATA commands here:
;   TEST UNIT READY, READ CAPACITY     VERIFY of sector 0 (media and change)
;   READ / WRITE / VERIFY (10)         READ / WRITE / VERIFY SECTORS, PIO
;   START STOP UNIT (eject)            MEDIA EJECT
;   PREVENT ALLOW MEDIUM REMOVAL       DOOR LOCK / DOOR UNLOCK
;   INQUIRY                            from IDENTIFY DEVICE (vendor "ATA")
;   REASSIGN BLOCKS                    SyQuest REASSIGN SECTOR (F8h) in
;                                      super-user mode (FBh / FCh)
;   MODE SENSE (10), REQUEST SENSE     built here; the WP bit from
;                                      GET MEDIA STATUS where the drive
;                                      has it
; Addressing is CHS with the geometry found at init: these drives have no
; LBA.  A failed command leaves its sense data per device, mapped from the
; ATA error register (NM, MC, WP, ...), for REQUEST SENSE and auto sense.
; Nothing is retried or replayed, and a hung IDE drive is not reset: a
; channel reset would also hit the BIOS disk next to it.  On an AHCI port
; (a SATA drive, or an IDE drive behind a SATA bridge) a command is one
; ahci_exec with the CHS task file in the FIS; data goes through the bounce
; buffer, ATA_AHCI_CHUNK sectors per command, copied by the CPU.
;=============================================================================

; byte order of EAX reversed (BSWAP is a 486 instruction)
%macro BSWAP_EAX 0
        xchg    al, ah
        rol     eax, 16
        xchg    al, ah
%endmacro

ATA_READ        equ     20h
ATA_WRITE       equ     30h
ATA_VERIFY      equ     40h
ATA_INIT_PARAMS equ     91h
ATA_MEDIA_STATUS equ    0DAh
ATA_DOOR_LOCK   equ     0DEh
ATA_DOOR_UNLOCK equ     0DFh
ATA_IDENTIFY    equ     0ECh
ATA_EJECT       equ     0EDh
; SyQuest vendor commands (SparQ Internal EIDE Technical Reference, 1997,
; page 6-45). F8h is READ NATIVE MAX ADDRESS on other drives: it is only
; sent after a drive has confirmed super-user mode.
ATA_SQ_REASSIGN equ     0F8h            ; reassign the sector at the address
ATA_SQ_SUPER    equ     0FBh            ; enter (cyl FFFFh) / confirm (F00Fh)
ATA_SQ_LEAVE    equ     0FCh            ; leave super-user mode

; ATA error register
ATAE_NM         equ     02h             ; no media
ATAE_ABRT       equ     04h
ATAE_MCR        equ     08h             ; media change requested
ATAE_IDNF       equ     10h
ATAE_MC         equ     20h             ; media changed
ATAE_UNC        equ     40h             ; uncorrectable / write protected

ATA_CHUNK       equ     128             ; sectors per ATA command (IDE)
ATA_AHCI_CHUNK  equ     BOUNCE_SIZE / 512 ; sectors per ATA command (AHCI)
ATA_ID_OFS      equ     1024            ; IDENTIFY data in the bounce buffer
ATA_BUILD_OFS   equ     512             ; answers built in the bounce buffer

; sense data: key | ASC << 8 | ASCQ << 16
SNS_NO_MEDIUM   equ     02h | (3Ah << 8)
SNS_CHANGED     equ     06h | (28h << 8)
SNS_REMOVAL_REQ equ     06h | (5Ah << 8) | (01h << 16)
SNS_WPROT       equ     07h | (27h << 8)
SNS_UNC         equ     03h | (11h << 8)
SNS_NOT_FOUND   equ     03h | (14h << 8) | (01h << 16)
SNS_RANGE       equ     05h | (21h << 8)
SNS_BAD_OPCODE  equ     05h | (20h << 8)
SNS_BAD_FIELD   equ     05h | (24h << 8)
SNS_PREVENTED   equ     05h | (53h << 8) | (02h << 16)
SNS_ABORTED     equ     0Bh
SNS_HARDWARE    equ     04h | (44h << 8)
SNS_NO_SPARE    equ     03h | (32h << 8) ; no defect spare location
SNS_PARAM_LIST  equ     05h | (26h << 8) ; invalid field in parameter list

dev_heads       times MAX_DEV db 0      ; ATA: CHS geometry in use
dev_spt         times MAX_DEV db 0
dev_cap         times MAX_DEV dd 0      ; ATA: sectors
dev_bios        times MAX_DEV db 0      ; ATA: INT 13h drive using it, 0 none
ata_sense       times MAX_DEV dd 0      ; ATA: sense of the last command

ata_res         db      0               ; XR_* of the request
ata_op          db      0               ; ATA command of the request
ata_lba         dd      0
ata_left        dd      0
ata_n           dw      0               ; sectors of the current ATA command
ata_k           dw      0               ; data blocks still to move
ata_cyl         dw      0
ata_head        db      0
ata_sec         db      0
ata_raw         db      0               ; ata_chs keeps the registers set
ata_defects     dw      0               ; REASSIGN BLOCKS: LBAs left

; Run the SCSI command in cdb_buf on ATA device BX.  Data goes to / comes
; from [x_bufp] (at most [x_rem] bytes).  Returns AL = XR_*; XR_CHECK has
; the sense data in ata_sense.
ata_scsi:
        pushad
        push    es
        call    ide_setdev
        mov     dword [x_tfd], 0
        mov     dword [x_xfer], 0
        mov     byte [x_over], 0
        mov     byte [ata_res], XR_OK
        mov     byte [ata_op], 0
        mov     ax, [x_bufp]            ; start from a normalized pointer
        mov     di, ax
        mov     es, [x_bufp+2]
        call    advance_bufp
        call    ata_irq_off
        mov     al, [cdb_buf]
        cmp     al, SCSI_REQUEST_SENSE
        je      .rsense
        mov     si, bx                  ; a new command clears the sense
        shl     si, 2
        mov     dword [ata_sense+si], 0
        cmp     al, SCSI_TEST_UNIT_READY
        je      .tur
        cmp     al, SCSI_INQUIRY
        je      .inquiry
        cmp     al, 25h                 ; READ CAPACITY
        je      .rcap
        cmp     al, SCSI_READ10
        je      .read
        cmp     al, SCSI_WRITE10
        je      .write
        cmp     al, 2Eh                 ; WRITE AND VERIFY (10)
        je      .write
        cmp     al, 2Fh                 ; VERIFY (10)
        je      .verify
        cmp     al, SCSI_SEEK10
        je      .seek
        cmp     al, 1Bh                 ; START STOP UNIT
        je      .startstop
        cmp     al, 1Eh                 ; PREVENT ALLOW MEDIUM REMOVAL
        je      .prevent
        cmp     al, 07h                 ; REASSIGN BLOCKS
        jne     .not_reassign
        call    ata_reassign
        jmp     .done
.not_reassign:
        cmp     al, SCSI_MODE_SENSE10
        je      .msense
        cmp     al, SCSI_MODE_SELECT10  ; nothing to select
        je      .done
        cmp     al, 35h                 ; SYNCHRONIZE CACHE: written through
        je      .done
        mov     eax, SNS_BAD_OPCODE
        call    ata_set_sense
        jmp     .done

.tur:   call    ata_media
        jmp     .done

.rsense:
        mov     si, bx
        shl     si, 2
        mov     eax, [ata_sense+si]
        mov     dword [ata_sense+si], 0
        call    ata_build_sense
        movzx   cx, byte [cdb_buf+4]
        cmp     cx, 18
        jbe     .rs_len
        mov     cx, 18
.rs_len:
        call    ata_give
        jmp     .done

.inquiry:
        test    byte [cdb_buf+1], 1     ; vital product data
        jnz     .badfield
        call    ata_identify
        call    ata_result
        cmp     byte [ata_res], XR_OK
        jne     .done
        push    cs
        pop     es
        mov     di, [bounce_ptr]
        add     di, ATA_BUILD_OFS
        mov     eax, 02028000h          ; disk, removable, SCSI-2, format 2
        stosd
        mov     eax, 31                 ; additional length
        stosd
        mov     eax, 'ATA '
        stosd
        mov     eax, '    '
        stosd
        mov     si, [bounce_ptr]        ; product: model, words 27..34
        add     si, ATA_ID_OFS + 27*2
        mov     cx, 8
.inq_model:
        lodsw
        xchg    al, ah
        stosw
        loop    .inq_model
        mov     si, [bounce_ptr]        ; revision: firmware, words 23..24
        add     si, ATA_ID_OFS + 23*2
        lodsw
        xchg    al, ah
        stosw
        lodsw
        xchg    al, ah
        stosw
        mov     si, [bounce_ptr]
        add     si, ATA_BUILD_OFS
        movzx   cx, byte [cdb_buf+4]
        cmp     cx, 36
        jbe     .inq_len
        mov     cx, 36
.inq_len:
        call    ata_give
        jmp     .done

.rcap:  call    ata_media
        cmp     byte [ata_res], XR_OK
        jne     .done
        mov     si, bx
        shl     si, 2
        mov     eax, [dev_cap+si]
        dec     eax
        BSWAP_EAX
        mov     di, [bounce_ptr]
        add     di, ATA_BUILD_OFS
        mov     [di], eax
        mov     dword [di+4], 00020000h ; 512 byte blocks
        mov     si, di
        mov     cx, 8
        call    ata_give
        jmp     .done

.read:  mov     byte [ata_op], ATA_READ
        jmp     .rw
.write: mov     byte [ata_op], ATA_WRITE
        jmp     .rw
.verify:
        test    byte [cdb_buf+1], 02h   ; BYTCHK: compare with host data
        jnz     .badfield
        mov     byte [ata_op], ATA_VERIFY
.rw:    call    ata_range
        jc      .done
        call    ata_rw
        call    ata_result
        jmp     .done

.seek:  mov     dword [cdb_buf+6], 0    ; the LBA only
        call    ata_range
        jmp     .done

.startstop:
        mov     al, [cdb_buf+4]
        and     al, 03h                 ; LoEj, Start
        cmp     al, 02h                 ; eject; loading is up to the user
        jne     .done
        mov     byte [ata_op], ATA_EJECT
        xor     eax, eax
        mov     cx, ATA_EJECT << 8
        call    ata_nodata
        call    ata_result
        jmp     .done

.prevent:
        mov     ch, ATA_DOOR_UNLOCK
        test    byte [cdb_buf+4], 1
        jz      .prevent_cmd
        mov     ch, ATA_DOOR_LOCK
.prevent_cmd:
        mov     [ata_op], ch
        xor     eax, eax
        xor     cl, cl
        call    ata_nodata
        cmp     al, XR_CHECK
        jne     .prevent_res
        test    ah, ATAE_NM             ; no cartridge: nothing to lock
        jnz     .done
.prevent_res:
        call    ata_result
        jmp     .done

.msense:
        ; WP from GET MEDIA STATUS.  A drive without it aborts: not
        ; protected.  It also reports (and clears) a media change, which
        ; must not get lost: UNIT ATTENTION, as a SCSI disk would.
        mov     byte [ata_op], ATA_MEDIA_STATUS
        xor     eax, eax
        mov     cx, ATA_MEDIA_STATUS << 8
        call    ata_nodata
        xor     dl, dl
        cmp     al, XR_OK
        je      .ms_build
        cmp     al, XR_CHECK
        je      .ms_check
        call    ata_result              ; timeout, transport error
        jmp     .done
.ms_check:
        test    ah, ATAE_MC
        jz      .ms_wp
        mov     eax, SNS_CHANGED
        call    ata_set_sense
        jmp     .done
.ms_wp: test    ah, ATAE_UNC            ; WP for this command
        jz      .ms_build
        mov     dl, 80h
.ms_build:
        ; header, and a block descriptor unless DBD; no mode pages
        push    cs
        pop     es
        mov     di, [bounce_ptr]
        add     di, ATA_BUILD_OFS
        mov     si, di
        mov     cx, 8
        test    byte [cdb_buf+1], 08h
        jz      .ms_desc
        mov     dword [di], 00000600h   ; mode data length 6
        mov     dword [di+4], 0
        jmp     .ms_give
.ms_desc:
        mov     dword [di], 00000E00h   ; mode data length 14
        mov     dword [di+4], 08000000h ; block descriptor length 8
        push    si
        mov     si, bx
        shl     si, 2
        mov     eax, [dev_cap+si]
        pop     si
        cmp     eax, 0FFFFFFh
        jbe     .ms_blocks
        mov     eax, 0FFFFFFh
.ms_blocks:
        BSWAP_EAX                     ; density 0, blocks
        mov     [di+8], eax
        mov     dword [di+12], 00020000h
        mov     cx, 16
.ms_give:
        mov     [di+3], dl              ; device-specific: WP
        mov     ax, [cdb_buf+7]         ; allocation length
        xchg    al, ah
        cmp     cx, ax
        jbe     .ms_len
        mov     cx, ax
.ms_len:
        call    ata_give
        jmp     .done

.badfield:
        mov     eax, SNS_BAD_FIELD
        call    ata_set_sense
.done:  call    ata_irq_on
        pop     es
        popad
        mov     al, [ata_res]
        ret

; IDE interrupts of device BX off / on; nothing to do on an AHCI port
ata_irq_off:
        cmp     byte [dev_trans+bx], TR_IDE
        jne     .out
        call    ide_irq_off
.out:   ret

ata_irq_on:
        cmp     byte [dev_trans+bx], TR_IDE
        jne     .out
        call    ide_irq_on
.out:   ret

; EAX = sense -> ata_sense of device BX, request result XR_CHECK
ata_set_sense:
        push    si
        mov     si, bx
        shl     si, 2
        mov     [ata_sense+si], eax
        pop     si
        mov     byte [ata_res], XR_CHECK
        ret

; 18 bytes of fixed format sense data for EAX at bounce+ATA_BUILD_OFS
; -> SI = the data
ata_build_sense:
        push    es
        push    cs
        pop     es
        mov     di, [bounce_ptr]
        add     di, ATA_BUILD_OFS
        push    di
        push    eax
        xor     eax, eax
        mov     cx, 18 / 2
        rep     stosw
        pop     eax
        pop     di
        mov     byte [di], 70h          ; current error, fixed format
        mov     [di+2], al              ; sense key
        mov     byte [di+7], 10         ; additional length
        shr     eax, 8
        mov     [di+12], ax             ; ASC, ASCQ
        mov     si, di
        pop     es
        ret

; copy CX bytes at CS:SI to the request buffer (at most [x_rem])
ata_give:
        movzx   ecx, cx
        cmp     ecx, [x_rem]
        jbe     .copy
        mov     ecx, [x_rem]
.copy:  sub     [x_rem], ecx
        add     [x_xfer], ecx
        les     di, [x_bufp]
        rep     movsb
        ret

; LBA and count of a 10 byte CDB to ata_lba / ata_left; CF (and the sense)
; when they leave the medium
ata_range:
        mov     eax, [cdb_buf+2]
        BSWAP_EAX
        mov     [ata_lba], eax
        movzx   ecx, word [cdb_buf+7]
        xchg    cl, ch
        mov     [ata_left], ecx
        mov     si, bx
        shl     si, 2
        mov     edx, [dev_cap+si]
        sub     edx, eax
        jb      .out
        cmp     edx, ecx
        jb      .out
        clc
        ret
.out:   mov     eax, SNS_RANGE
        call    ata_set_sense
        stc
        ret

; REASSIGN BLOCKS (short list, 4-byte LBAs) on ATA device BX: SyQuest's
; four-command sequence. Enter super-user mode (the drive aborts this, as
; documented), confirm it (a drive without the function aborts this too:
; invalid opcode, nothing else sent), REASSIGN SECTOR for each LBA, and
; leave super-user mode, also after a failure. Nothing is retried.
; -> ata_res / sense
ata_reassign:
        test    byte [cdb_buf+1], 03h   ; LONGLBA, LONGLIST
        jnz     .badfield
        ; the parameter list: header, then the LBAs (big-endian)
        mov     ecx, [x_rem]
        cmp     ecx, 4
        jb      .badfield
        cmp     ecx, ATA_BUILD_OFS
        jbe     .copy
        mov     ecx, ATA_BUILD_OFS
.copy:  push    ecx
        call    ata_mem_out
        pop     ecx
        mov     si, [bounce_ptr]
        movzx   eax, word [si+2]
        xchg    al, ah                  ; defect list length
        test    al, 3
        jnz     .badlist
        add     eax, 4
        cmp     eax, ecx
        ja      .badlist
        sub     eax, 4
        shr     ax, 2
        mov     [ata_defects], ax
        or      ax, ax
        jz      .out                    ; nothing to reassign
        ; every LBA on the cartridge before anything is sent
        mov     cx, ax
        add     si, 4
        mov     di, bx
        shl     di, 2
.range: mov     eax, [si]
        BSWAP_EAX
        cmp     eax, [dev_cap+di]
        jae     .badrange
        add     si, 4
        loop    .range
        ; enter: the drive aborts this; only a timeout counts
        mov     word [ata_cyl], 0FFFFh
        mov     ch, ATA_SQ_SUPER
        call    .raw
        cmp     al, XR_TIMEOUT
        je      .result
        ; confirm: an abort means the drive has no super-user mode
        mov     word [ata_cyl], 0F00Fh  ; cylinder low 0Fh, high F0h
        mov     ch, ATA_SQ_SUPER
        call    .raw
        cmp     al, XR_OK
        je      .super
        cmp     al, XR_CHECK
        jne     .result
        test    ah, ATAE_ABRT
        jz      .result
        mov     eax, SNS_BAD_OPCODE
        jmp     ata_set_sense
.super: mov     si, [bounce_ptr]
        add     si, 4
.next:  mov     eax, [si]
        BSWAP_EAX
        push    si
        mov     byte [ata_op], ATA_SQ_REASSIGN
        mov     cx, (ATA_SQ_REASSIGN << 8) | 1
        call    ata_nodata
        pop     si
        cmp     al, XR_OK
        jne     .failed
        add     si, 4
        dec     word [ata_defects]
        jnz     .next
.failed:
        push    ax                      ; leave super-user mode in any case
        mov     word [ata_cyl], 0
        mov     ch, ATA_SQ_LEAVE
        call    .raw
        mov     dx, ax
        pop     ax
        cmp     al, XR_OK
        jne     .reassign_failed
        mov     ax, dx                  ; the reassignments worked: leaving?
        jmp     .result
.reassign_failed:
        cmp     al, XR_CHECK
        jne     .result
        test    ah, ATAE_ABRT           ; refused: no spare left
        jz      .result
        mov     eax, SNS_NO_SPARE
        jmp     ata_set_sense
.result:
        mov     byte [ata_op], 0
        jmp     ata_result
.badrange:
        mov     eax, SNS_RANGE
        jmp     ata_set_sense
.badlist:
        mov     eax, SNS_PARAM_LIST
        jmp     ata_set_sense
.badfield:
        mov     eax, SNS_BAD_FIELD
        jmp     ata_set_sense
.out:   ret
; command CH, no data, with the registers in ata_cyl (head, sector 0)
.raw:   mov     byte [ata_op], ch
        mov     byte [ata_head], 0
        mov     byte [ata_sec], 0
        mov     byte [ata_raw], 1
        xor     eax, eax
        xor     cl, cl
        call    ata_nodata
        mov     byte [ata_raw], 0
        ret

; Is there a readable cartridge?  VERIFY of sector 0 reports no media and a
; media change.  -> ata_res / sense
ata_media:
        mov     byte [ata_op], ATA_VERIFY
        xor     eax, eax
        mov     cx, (ATA_VERIFY << 8) | 1
        call    ata_nodata
        ; fall through

; AL = XR_* of an ATA command, AH = its error register -> ata_res / sense
ata_result:
        cmp     al, XR_CHECK
        je      .check
        mov     [ata_res], al
        ret
.check: mov     eax, SNS_NO_MEDIUM
        test    ah, ATAE_NM
        jnz     .set
        mov     eax, SNS_CHANGED
        test    ah, ATAE_MC
        jnz     .set
        test    ah, ATAE_UNC
        jz      .not_unc
        mov     eax, SNS_WPROT          ; on a write the bit means protected
        cmp     byte [ata_op], ATA_WRITE
        je      .set
        mov     eax, SNS_UNC
        jmp     .set
.not_unc:
        mov     eax, SNS_NOT_FOUND
        test    ah, ATAE_IDNF
        jnz     .set
        mov     eax, SNS_REMOVAL_REQ
        test    ah, ATAE_MCR
        jnz     .set
        test    ah, ATAE_ABRT
        jz      .hardware
        mov     eax, SNS_PREVENTED      ; refused while locked
        cmp     byte [ata_op], ATA_EJECT
        je      .set
        mov     eax, SNS_BAD_OPCODE     ; lock commands not supported
        cmp     byte [ata_op], ATA_DOOR_LOCK
        je      .set
        cmp     byte [ata_op], ATA_DOOR_UNLOCK
        je      .set
        mov     eax, SNS_ABORTED
        jmp     .set
.hardware:
        mov     eax, SNS_HARDWARE
.set:   jmp     ata_set_sense

; Select device BX and issue ATA command CH with sector count CL at LBA
; EAX (as CHS).  CF if the device stays busy.
ata_issue:
        pushad
        push    eax
        push    ecx
        call    ide_select              ; changes AX
        pop     ecx
        pop     eax
        jc      .out
        call    ata_chs
        mov     dx, 2                   ; sector count
        call    ide_port
        mov     al, cl
        out     dx, al
        inc     dx
        mov     al, [ata_sec]
        out     dx, al
        inc     dx
        mov     al, [ata_cyl]
        out     dx, al
        inc     dx
        mov     al, [ata_cyl+1]
        out     dx, al
        inc     dx
        mov     al, [ide_sel]
        or      al, [ata_head]
        out     dx, al
        inc     dx
        mov     al, ch
        out     dx, al
        call    ide_delay
        clc
.out:   popad
        ret

; LBA EAX of device BX -> ata_sec, ata_head, ata_cyl (registers kept).
; With ata_raw set they are left as the caller set them.
ata_chs:
        cmp     byte [ata_raw], 0
        je      .lba
        ret
.lba:   pushad
        movzx   esi, byte [dev_spt+bx]
        xor     edx, edx
        div     esi
        inc     dl
        mov     [ata_sec], dl
        movzx   esi, byte [dev_heads+bx]
        xor     edx, edx
        div     esi
        mov     [ata_head], dl
        mov     [ata_cyl], ax
        popad
        ret

; Wait until device BX is not busy -> AL = status, AH = error register (0
; without ERR).  CF on timeout.
ata_wait:
        push    ecx
        mov     ax, TFD_BSY << 8
        mov     ecx, [tmo_ticks]
        call    ide_wait
        pop     ecx
        jc      .out
        xor     ah, ah
        test    al, TFD_ERR
        jz      .out
        push    dx
        mov     dx, IDE_ERROR
        call    ide_port
        mov     ah, al
        in      al, dx
        xchg    al, ah
        pop     dx
        clc
.out:   ret

; Command CH without data, sector count CL, LBA EAX -> AL = XR_*, AH = error
ata_nodata:
        cmp     byte [dev_trans+bx], TR_IDE
        je      .ide
        mov     dword [ata_bytes], 0
        xor     dl, dl
        jmp     ata_ahci
.ide:   call    ata_issue
        jc      .timeout
        call    ata_wait
        jc      .timeout
        test    al, TFD_ERR
        jnz     .check
        mov     al, XR_OK
        ret
.check: mov     al, XR_CHECK
        ret
.timeout:
        mov     al, XR_TIMEOUT
        ret

; [ata_op] (read, write, verify) of [ata_left] sectors at [ata_lba]
; -> AL = XR_*, AH = error register
ata_rw:
        cmp     byte [dev_trans+bx], TR_IDE
        je      .next
        jmp     ata_rw_ahci
.next:  mov     ecx, [ata_left]
        or      ecx, ecx
        jz      .good
        cmp     ecx, ATA_CHUNK
        jbe     .count
        mov     ecx, ATA_CHUNK
.count: mov     [ata_n], cx
        mov     [ata_k], cx
        mov     eax, [ata_lba]
        mov     ch, [ata_op]
        call    ata_issue
        jc      .timeout
        cmp     byte [ata_op], ATA_VERIFY
        jne     .block
        call    ata_wait
        jc      .timeout
        test    al, TFD_ERR
        jnz     .check
        jmp     .advance
.block: call    ata_wait                ; next block requested or ready
        jc      .timeout
        test    al, TFD_ERR
        jnz     .check
        test    al, TFD_DRQ
        jz      .protocol
        mov     dx, IDE_DATA
        call    ide_port
        mov     cx, 512
        cmp     byte [ata_op], ATA_WRITE
        je      .out
        call    ide_pio_in
        jmp     .moved
.out:   call    ide_pio_out
.moved: dec     word [ata_k]
        jnz     .block
        cmp     byte [ata_op], ATA_WRITE
        jne     .advance
        call    ata_wait                ; the last block is written
        jc      .timeout
        test    al, TFD_ERR
        jnz     .check
.advance:
        movzx   eax, word [ata_n]
        add     [ata_lba], eax
        sub     [ata_left], eax
        jmp     .next
.good:  mov     ax, XR_OK
        ret
.check: mov     al, XR_CHECK
        ret
.timeout:
        mov     al, XR_TIMEOUT
        ret
.protocol:
        mov     al, XR_HBA
        ret

; IDENTIFY DEVICE of device BX (ide_setdev done, interrupts off) to
; bounce+ATA_ID_OFS -> AL = XR_*, AH = error register
ata_identify:
        cmp     byte [dev_trans+bx], TR_IDE
        je      .ide
        push    ecx
        push    edx
        mov     byte [x_cmd], ATA_IDENTIFY
        mov     dword [x_tf], 0A0000000h
        mov     byte [x_cnt], 0
        mov     eax, [phys_bounce]
        add     eax, ATA_ID_OFS
        mov     [ata_phys], eax
        mov     ecx, 512
        xor     dl, dl
        call    ata_ahci_exec
        pop     edx
        pop     ecx
        ret
.ide:   call    ide_select
        jc      .timeout
        mov     dx, IDE_COMMAND
        call    ide_port
        mov     al, ATA_IDENTIFY
        out     dx, al
        call    ide_delay
        call    ata_wait
        jc      .timeout
        test    al, TFD_ERR
        jnz     .check
        test    al, TFD_DRQ
        jz      .protocol
        mov     dx, IDE_DATA
        call    ide_port
        push    es
        push    cs
        pop     es
        mov     di, [bounce_ptr]
        add     di, ATA_ID_OFS
        mov     cx, 256
        rep     insw
        pop     es
        mov     ax, XR_OK
        ret
.check: mov     al, XR_CHECK
        ret
.timeout:
        mov     al, XR_TIMEOUT
        ret
.protocol:
        mov     al, XR_HBA
        ret

;-----------------------------------------------------------------------------
; AHCI transport
;-----------------------------------------------------------------------------

ata_phys        dd      0               ; physical address of the data
ata_bytes       dd      0               ; data bytes of the command

; ATA command CH, sector count CL, LBA EAX (as CHS) on AHCI device BX, with
; [ata_bytes] of data in the bounce buffer, DL = 1 for a write -> AL = XR_*,
; AH = error register
ata_ahci:
        mov     [x_cmd], ch
        mov     [x_cnt], cl
        call    ata_chs
        push    eax
        mov     al, [ata_sec]           ; FIS: sector, cylinder low, high,
        mov     ah, [ata_cyl]           ; device / head
        mov     [x_tf], ax
        mov     al, [ata_cyl+1]
        mov     ah, [ata_head]
        or      ah, 0A0h
        mov     [x_tf+2], ax
        mov     eax, [phys_bounce]
        mov     [ata_phys], eax
        pop     eax
        push    ecx
        mov     ecx, [ata_bytes]
        call    ata_ahci_exec
        pop     ecx
        ret

; x_cmd / x_tf / x_cnt on AHCI device BX, ECX bytes of data at [ata_phys],
; DL = 1 for a write.  ahci_exec's x_xfer / x_over (of the PRD) are not the
; request's and are kept.  -> AL = XR_*, AH = error register
ata_ahci_exec:
        push    bp
        push    si
        push    dword [x_xfer]
        mov     al, [x_over]
        push    ax
        mov     si, bx
        add     si, si
        mov     bp, [dev_port+si]
        mov     [x_write], dl
        call    prd_clear
        jecxz   .nodata
        mov     eax, [ata_phys]
        call    prd_add
.nodata:
        mov     byte [x_atapi], 0
        mov     byte [x_feat], 0
        mov     word [x_bcl], 0
        mov     byte [x_ata], 1
        call    ahci_exec
        mov     byte [x_ata], 0
        mov     ah, [x_tfd+1]
        pop     si                      ; the request's x_over
        push    ax
        mov     ax, si
        mov     [x_over], al
        pop     ax
        pop     dword [x_xfer]
        pop     si
        pop     bp
        ret

; [ata_op] of [ata_left] sectors at [ata_lba] on AHCI device BX, through the
; bounce buffer -> AL = XR_*, AH = error register
ata_rw_ahci:
.next:  mov     ecx, [ata_left]
        or      ecx, ecx
        jz      .good
        cmp     ecx, ATA_AHCI_CHUNK
        jbe     .count
        mov     ecx, ATA_AHCI_CHUNK
.count: mov     [ata_n], cx
        xor     dl, dl
        mov     dword [ata_bytes], 0
        cmp     byte [ata_op], ATA_VERIFY
        je      .go
        shl     ecx, 9
        mov     [ata_bytes], ecx
        cmp     byte [ata_op], ATA_WRITE
        jne     .go
        mov     dl, 1
        call    ata_mem_out
.go:    mov     cx, [ata_n]
        mov     ch, [ata_op]
        mov     eax, [ata_lba]
        call    ata_ahci
        cmp     al, XR_OK
        jne     .out
        cmp     byte [ata_op], ATA_READ
        jne     .advance
        mov     ecx, [ata_bytes]
        call    ata_mem_in
.advance:
        movzx   eax, word [ata_n]
        add     [ata_lba], eax
        sub     [ata_left], eax
        jmp     .next
.good:  mov     ax, XR_OK
.out:   ret

; ECX bytes read into the bounce buffer -> request buffer (at most [x_rem];
; the rest is dropped and reported as overrun)
ata_mem_in:
        pushad
        push    es
        cmp     ecx, [x_rem]
        jbe     .take
        mov     ecx, [x_rem]
        mov     byte [x_over], 1
.take:  sub     [x_rem], ecx
        add     [x_xfer], ecx
        les     di, [x_bufp]
        mov     si, [bounce_ptr]
        rep     movsb
        call    advance_bufp
        pop     es
        popad
        ret

; request buffer -> ECX bytes to write in the bounce buffer (at most [x_rem];
; zeros for the rest, reported as overrun)
ata_mem_out:
        pushad
        push    es
        mov     edx, ecx
        cmp     ecx, [x_rem]
        jbe     .take
        mov     ecx, [x_rem]
        mov     byte [x_over], 1
.take:  sub     [x_rem], ecx
        add     [x_xfer], ecx
        sub     edx, ecx                ; bytes to pad
        push    cs
        pop     es
        mov     di, [bounce_ptr]
        push    ds
        lds     si, [x_bufp]
        rep     movsb
        pop     ds
        push    di
        mov     di, si                  ; advance_bufp takes the offset in DI
        call    advance_bufp
        pop     di
        mov     ecx, edx
        xor     al, al
        rep     stosb
        pop     es
        popad
        ret

; Auto sense of the failed request of ATA device BX into the SRB at ES:SI
ata_auto_sense:
        push    si
        mov     si, bx
        shl     si, 2
        mov     eax, [ata_sense+si]
        mov     dword [ata_sense+si], 0
        call    ata_build_sense         ; -> SI (CS)
        mov     dx, si
        pop     si
        movzx   cx, byte [es:si+SRB_SenseLen]
        movzx   di, byte [es:si+SRB_CDBLen]
        add     di, si
        add     di, SRB_CDB
        push    si
        mov     si, dx
        cmp     cx, 18
        jbe     .copy
        push    cx                      ; the rest is zero
        push    di
        add     di, 18
        sub     cx, 18
        xor     al, al
        rep     stosb
        pop     di
        pop     cx
        mov     cx, 18
.copy:  rep     movsb
        pop     si
        ret
