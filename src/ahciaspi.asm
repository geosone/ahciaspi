;=============================================================================
; AHCIASPI.SYS - ASPI manager (SCSIMGR$) for ATAPI devices on AHCI controllers
;
; Makes ATAPI devices (CD/DVD, ZIP, LS-120, tape, ...) attached to an AHCI
; SATA controller - directly or through SATA/IDE adapters - or to a classic
; IDE channel available to DOS ASPI clients such as ASPICD.SYS, ASPIDISK.SYS,
; MKELS120.SYS or GUEST.EXE.
;
; Build:  nasm -f bin -o AHCIASPI.SYS ahciaspi.asm
;         (-DE9LOG mirrors all init output to the QEMU debug console)
;
; CONFIG.SYS:
;   DEVICE=AHCIASPI.SYS [/C:n] [/ID:name] [/M:x] [/PIO] [/RAWINQ] [/T:s] [/Q] [/V]
;                       [/NOAHCI] [/NOIDE] [/NOPCI] [/P:port[,ctl]]
;                       [/BIOSFIX] [/NOBIOSFIX]
;
; /BIOSFIX: work around the VDS bugs of Intel AHCI firmware under EMM386
; (biosfix.inc; on by default with an Intel AHCI controller)
;
; Design notes
; - Register access to the HBA goes through one of four methods: the AHCI
;   index/data pair in an I/O BAR or in PCI config space (works in V86 mode),
;   flat real mode ("unreal", needs real mode) or INT 15h AH=87h (slow but
;   works everywhere).
; - The driver owns one command list / command table / FIS area.  For every
;   command the port state set up by the BIOS is saved, our structures are
;   installed, the command runs (polled, no interrupts) and the BIOS state is
;   restored.  This keeps BIOS INT 13h disk access on the same controller
;   working.
; - Classic IDE channels (1F0h, 170h, native channels of PCI IDE / RAID
;   cards such as SiI0680, Promise, HighPoint, ITE8212 found in their I/O
;   BARs, and /P: ports) are driven with ATAPI
;   PACKET commands in PIO mode, polled, data moved by the CPU straight into
;   the client buffer.  Only DEVICE RESET is used, never a channel reset, so
;   a BIOS disk on the same channel is not disturbed.
; - Several ASPI managers: DOS only finds the SCSIMGR$ loaded last.  If one
;   is already loaded (e.g. USBASPI.SYS, ASPI8DOS.SYS), AHCIASPI chains to
;   it: its host adapters keep their numbers, ours follows, and requests
;   for the other adapters are passed on.
; - Data is transferred by DMA straight into the client buffer (physical
;   address via VDS when present) or through a bounce buffer.
;=============================================================================

        cpu     386
        bits    16
        org     0

%include "ahci.inc"
%include "aspi.inc"

%define VERSION_STR '0.3'

NPRD            equ     8               ; PRDT entries per command
BOUNCE_SIZE     equ     800h            ; bounce buffer (2 KB, 2 KB aligned)
STACK_SIZE      equ     0C00h           ; BIOS IRQ handlers run on it too
MAX_DEV         equ     7               ; targets 0..6, adapter is ID 7
HA_TARGET_ID    equ     7

; DMA area layout (offsets from a 2 KB aligned base)
DMA_BOUNCE      equ     000h            ; 800h bytes bounce buffer
DMA_CL          equ     800h            ; command list (1 KB aligned, slot 0)
DMA_CT          equ     880h            ; command table (128 byte aligned)
DMA_SCRATCH     equ     980h            ; dword scratch for INT 15h access
DMA_FIS         equ     0A00h           ; received FIS area (256 byte aligned)
DMA_USED        equ     0B00h
DMA_RESERVE     equ     DMA_USED + 800h ; including alignment slack

; result codes of ahci_exec
XR_OK           equ     0
XR_CHECK        equ     1               ; device reported an error
XR_TIMEOUT      equ     2
XR_HBA          equ     3               ; HBA / interface error
XR_PORT         equ     4               ; port could not be started

; register access methods
AM_IDP_IO       equ     0
AM_IDP_CFG      equ     1
AM_FLAT         equ     2
AM_BIOS         equ     3
AM_NONE         equ     0FFh

; device transports
TR_AHCI         equ     0
TR_IDE          equ     1

; IDE task file register offsets
IDE_DATA        equ     0
IDE_ERROR       equ     1
IDE_FEATURE     equ     1
IDE_IREASON     equ     2
IDE_BCL_LO      equ     4
IDE_BCL_HI      equ     5
IDE_SELECT      equ     6
IDE_STATUS      equ     7
IDE_COMMAND     equ     7
IDE_CTL_OFS     equ     206h            ; device control / alt status
IDE_NIEN        equ     0Ah             ; device control: interrupts off
IDE_IEN         equ     08h             ; device control: interrupts on
IDE_BCL         equ     0F000h          ; byte count limit per DRQ block
ATA_DEVICE_RESET equ    08h
MAX_IDE_CH      equ     10

; device flags
DF_DMA          equ     01h
DF_DMADIR       equ     02h
DF_CDB16        equ     04h

; data mapping modes
MAP_NONE        equ     0
MAP_DIRECT      equ     1
MAP_VDS_SG      equ     2
MAP_VDS_LOCK    equ     3
MAP_BOUNCE      equ     4

; translation modes
XL_NONE         equ     0
XL_MODESENSE    equ     1
XL_MODESELECT   equ     2

; DOS request header
RQ_CMD          equ     02h
RQ_STATUS       equ     03h
RQ_XFER         equ     0Eh
RQ_COUNT        equ     12h
RQ_END          equ     0Eh             ; init: end of resident part
RQ_CMDLINE      equ     12h             ; init: command line

; VDS
VDS_FLAG_SEG    equ     40h
VDS_FLAG_OFS    equ     7Bh
VDS_FLAG_BIT    equ     20h

;=============================================================================
; Resident part
;=============================================================================

hdr_next        dd      -1
hdr_attr        dw      0C000h          ; character device, IOCTL supported
hdr_strat       dw      strategy
hdr_intr        dw      interrupt
hdr_name        db      'SCSIMGR$'

req_ptr         dd      0

;-----------------------------------------------------------------------------
; DOS device driver entry points
;-----------------------------------------------------------------------------
strategy:
        mov     [cs:req_ptr], bx
        mov     [cs:req_ptr+2], es
        retf

interrupt:
        pushf
        push    ax
        push    bx
        push    di
        push    ds
        push    es
        lds     bx, [cs:req_ptr]
        mov     al, [bx+RQ_CMD]
        or      al, al
        jnz     .not_init
        call    word [cs:init_vec]
        jmp     .exit
.not_init:
        cmp     al, 3                   ; IOCTL input: return entry point
        je      .ioctl_in
        cmp     al, 0Dh                 ; open
        je      .done
        cmp     al, 0Eh                 ; close
        je      .done
        mov     word [bx+RQ_STATUS], 8103h ; unknown command
        jmp     .exit
.ioctl_in:
        les     di, [bx+RQ_XFER]
        mov     word [es:di], aspi_entry
        mov     [es:di+2], cs
        mov     word [bx+RQ_COUNT], 4
.done:
        mov     word [bx+RQ_STATUS], 0100h
.exit:
        pop     es
        pop     ds
        pop     di
        pop     bx
        pop     ax
        popf
        retf

init_vec        dw      init
init_fail_vec   dw      0

;-----------------------------------------------------------------------------
; Resident data
;-----------------------------------------------------------------------------
mgr_id          db      'AHCIASPI        '      ; 16 bytes, /ID: overrides
ha_ident        db      'AHCI SATA       '      ; 16 bytes
ha_unique       dw      0001h           ; buffer alignment mask (word)
                db      0               ; reserved
                db      MAX_DEV + 1     ; max targets
                dd      10000h          ; max transfer length
                times 8 db 0

acc_method      db      AM_NONE
rd_vec          dw      0               ; register read routine
wr_vec          dw      0               ; register write routine
idp_port        dw      0               ; index/data pair in I/O space
idp_cfg         dd      0               ; index/data pair in config space
abar            dd      0               ; physical address of the HBA regs
hba_cap         dd      0

vds_ok          db      0               ; VDS present
a20_fixed       db      0               ; flat mode: A20 enabled by us
xms_entry       dd      0

tmo_ticks       dd      15 * 182 / 10   ; command timeout in BIOS ticks
inq_scsi2       db      1               ; report CD/DVD drives as SCSI-2 (/RAWINQ)

; DMA area pointers (offsets in our segment) and physical addresses
bounce_ptr      dw      0
cl_ptr          dw      0
ct_ptr          dw      0
scratch_ptr     dw      0
phys_bounce     dd      0
phys_cl         dd      0
phys_ct         dd      0
phys_fis        dd      0
phys_scratch    dd      0

; device table
dev_count       db      0
dev_port        times MAX_DEV dw 0      ; port register base (100h + n*80h)
dev_flags       times MAX_DEV db 0
dev_type        times MAX_DEV db 0
dev_pnum        times MAX_DEV db 0
dev_trans       times MAX_DEV db 0      ; TR_AHCI / TR_IDE
dev_ctl         times MAX_DEV dw 0      ; IDE: device control port
dev_sel         times MAX_DEV db 0      ; IDE: A0h master, B0h slave

; IDE transfer state
ide_base        dw      0
ide_ctl         dw      0
ide_sel         db      0
x_bufp          dd      0               ; PIO data pointer
x_rem           dd      0               ; PIO bytes left in the buffer

; previously loaded ASPI manager (chaining)
prev_entry      dd      0
prev_count      db      0               ; its host adapters = our HA number

; ASPI call state
in_aspi         db      0
old_ss          dw      0
old_sp          dw      0
srb_ptr         dd      0
post_ptr        dd      0

; port state saved while we own a port
sv_cmd          dd      0
sv_clb          dd      0
sv_clbu         dd      0
sv_fb           dd      0
sv_fbu          dd      0
sv_ie           dd      0

; command context for ahci_exec
x_atapi         db      0
x_cmd           db      0
x_feat          db      0
x_write         db      0
x_nprd          dw      0
x_bcl           dw      0               ; ATAPI byte count limit
x_tfd           dd      0               ; PxTFD after the command
x_res           db      0
x_xfer          dd      0               ; bytes actually transferred
x_over          db      0               ; device wanted to move more data
cdb_buf         times 16 db 0

; SCSI request state
s_dev           dw      0               ; device index
s_len           dd      0               ; data length from the SRB
s_buf           dd      0               ; data buffer (far pointer)
s_dir           db      0               ; 0 none, 1 in, 2 out
s_xlate         db      0
s_map           db      0
s_blen          dw      0               ; bytes used in the bounce buffer
s_alloc6        dw      0               ; MODE SENSE(6) allocation length
s_msel_bdonly   db      0               ; MODE SELECT(6) without mode pages
s_xfer          dd      0               ; x_xfer / x_over of the request
s_over          db      0

; VDS descriptors (DDS for lock, EDDS for scatter/gather lock)
dds:
dds_size        dd      0
dds_off         dd      0
dds_seg         dw      0
dds_bufid       dw      0
dds_phys        dd      0

edds:
edds_size       dd      0
edds_off        dd      0
edds_seg        dw      0
                dw      0
edds_avail      dw      NPRD
edds_used       dw      0
edds_regions    times NPRD * 8 db 0

; GDT for INT 15h AH=87h
gdt15           times 16 db 0
gdt15_src       dw      0FFFFh, 0
                db      0, 93h, 0, 0
gdt15_dst       dw      0FFFFh, 0
                db      0, 93h, 0, 0
                times 16 db 0

; GDT for flat real mode
flat_gdtr       dw      15
                dd      0               ; linear address of flat_gdt
flat_gdt        dq      0
                dq      008F92000000FFFFh ; 4 GB data segment
old_gdtr        dw      0
                dd      0

;-----------------------------------------------------------------------------
; HBA register access
;   reg_rd: AX = register offset          -> EAX = value
;   reg_wr: AX = register offset, ECX = value (EAX destroyed)
;-----------------------------------------------------------------------------
reg_rd:
        jmp     word [cs:rd_vec]

reg_wr:
        jmp     word [cs:wr_vec]

rd_idp_io:
        push    dx
        pushf
        cli
        movzx   eax, ax
        mov     dx, [cs:idp_port]
        out     dx, eax
        add     dx, 4
        in      eax, dx
        popf
        pop     dx
        ret

wr_idp_io:
        push    dx
        pushf
        cli
        movzx   eax, ax
        mov     dx, [cs:idp_port]
        out     dx, eax
        add     dx, 4
        mov     eax, ecx
        out     dx, eax
        popf
        pop     dx
        ret

rd_idp_cfg:
        push    dx
        push    ebx
        pushf
        cli
        movzx   ebx, ax
        mov     dx, 0CF8h
        in      eax, dx
        push    eax
        mov     eax, [cs:idp_cfg]
        out     dx, eax
        mov     dl, 0FCh
        mov     eax, ebx
        out     dx, eax
        mov     dl, 0F8h
        mov     eax, [cs:idp_cfg]
        add     eax, 4
        out     dx, eax
        mov     dl, 0FCh
        in      eax, dx
        mov     ebx, eax
        mov     dl, 0F8h
        pop     eax
        out     dx, eax
        mov     eax, ebx
        popf
        pop     ebx
        pop     dx
        ret

wr_idp_cfg:
        push    dx
        push    ebx
        pushf
        cli
        movzx   ebx, ax
        mov     dx, 0CF8h
        in      eax, dx
        push    eax
        mov     eax, [cs:idp_cfg]
        out     dx, eax
        mov     dl, 0FCh
        mov     eax, ebx
        out     dx, eax
        mov     dl, 0F8h
        mov     eax, [cs:idp_cfg]
        add     eax, 4
        out     dx, eax
        mov     dl, 0FCh
        mov     eax, ecx
        out     dx, eax
        mov     dl, 0F8h
        pop     eax
        out     dx, eax
        popf
        pop     ebx
        pop     dx
        ret

; The 4 GB limit of FS is set again for every access, with interrupts off
; until the access is done: BIOS interrupt handlers that switch to protected
; mode (SeaBIOS does) leave 64 KB limits behind, and the next access would
; fault forever.
rd_flat:
        push    esi
        push    fs
        pushf
        cli
        call    flat_enable
        movzx   esi, ax
        add     esi, [cs:abar]
        xor     ax, ax
        mov     fs, ax
        mov     eax, [fs:esi]
        popf
        pop     fs
        pop     esi
        ret

wr_flat:
        push    esi
        push    fs
        pushf
        cli
        call    flat_enable
        movzx   esi, ax
        add     esi, [cs:abar]
        xor     ax, ax
        mov     fs, ax
        mov     [fs:esi], ecx
        popf
        pop     fs
        pop     esi
        ret

; INT 15h AH=87h: copy one dword between the HBA and our scratch dword
rd_bios:
        push    di
        movzx   eax, ax
        add     eax, [cs:abar]
        mov     di, gdt15_src
        call    set_desc
        mov     eax, [cs:phys_scratch]
        mov     di, gdt15_dst
        call    set_desc
        call    bios_move
        mov     di, [cs:scratch_ptr]
        mov     eax, [cs:di]
        pop     di
        ret

wr_bios:
        push    di
        movzx   eax, ax
        add     eax, [cs:abar]
        mov     di, gdt15_dst
        call    set_desc
        mov     eax, [cs:phys_scratch]
        mov     di, gdt15_src
        call    set_desc
        mov     di, [cs:scratch_ptr]
        mov     [cs:di], ecx
        call    bios_move
        pop     di
        ret

; DI = descriptor, EAX = 32 bit base
set_desc:
        mov     [cs:di+2], ax
        shr     eax, 16
        mov     [cs:di+4], al
        mov     [cs:di+7], ah
        ret

bios_move:
        pushad
        push    es
        push    cs
        pop     es
        mov     si, gdt15
        mov     cx, 2                   ; two words
        mov     ah, 87h
        int     15h
        pop     es
        popad
        ret

;-----------------------------------------------------------------------------
; Flat real mode: (re)load FS with a 4 GB limit.  Called on every ASPI entry
; because other software (BIOS block moves, XMS) may reset segment limits.
;-----------------------------------------------------------------------------
flat_enable:
        push    eax
        push    bx
        push    fs
        pushf
        cli
        sgdt    [cs:old_gdtr]
        lgdt    [cs:flat_gdtr]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     short .pm
.pm:    mov     bx, 8
        mov     fs, bx
        and     al, 0FEh
        mov     cr0, eax
        jmp     short .rm
.rm:    lgdt    [cs:old_gdtr]
        popf
        pop     fs
        pop     bx
        pop     eax
        ret

; ZF set if A20 is disabled (memory wraps at 1 MB)
a20_test:
        push    ax
        push    si
        push    di
        push    ds
        push    es
        xor     ax, ax
        mov     ds, ax
        dec     ax
        mov     es, ax
        mov     si, 0500h
        mov     di, 0510h
        mov     al, [si]
        mov     ah, [es:di]
        push    ax
        mov     byte [si], 0
        mov     byte [es:di], 0FFh
        cmp     byte [si], 0FFh
        pop     ax
        mov     [es:di], ah
        mov     [si], al
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     ax
        ret

; enable A20 (XMS local enable if available, else BIOS)
a20_enable:
        pushad
        cmp     dword [cs:xms_entry], 0
        je      .bios
        mov     ah, 05h
        call    far [cs:xms_entry]
        jmp     .done
.bios:  mov     ax, 2401h
        int     15h
.done:  popad
        ret

a20_disable:
        pushad
        cmp     dword [cs:xms_entry], 0
        je      .bios
        mov     ah, 06h
        call    far [cs:xms_entry]
        jmp     .done
.bios:  mov     ax, 2400h
        int     15h
.done:  popad
        ret

;-----------------------------------------------------------------------------
; Timing helpers
;-----------------------------------------------------------------------------
get_ticks:                              ; -> EAX = BIOS tick counter
        push    ds
        push    word 40h
        pop     ds
        mov     eax, [6Ch]
        pop     ds
        ret

; wait for at least BX timer ticks (interrupts are enabled meanwhile)
delay_ticks:
        push    eax
        push    esi
        pushf
        sti
        call    get_ticks
        mov     esi, eax
.wait:  call    get_ticks
        sub     eax, esi
        js      .reset                  ; midnight wrap
        cmp     ax, bx
        jbe     .wait
        popf
        pop     esi
        pop     eax
        ret
.reset: call    get_ticks
        mov     esi, eax
        jmp     .wait

; Wait until (reg AX & ECX) == EDX.  BX = timeout in ticks.  CF on timeout.
wait_reg:
        push    eax
        push    esi
        push    di
        mov     di, ax
        pushf
        sti
        call    get_ticks
        mov     esi, eax
.poll:  mov     ax, di
        call    reg_rd
        and     eax, ecx
        cmp     eax, edx
        je      .ok
        call    get_ticks
        sub     eax, esi
        jns     .chk
        call    get_ticks               ; midnight wrap: restart
        mov     esi, eax
        jmp     .poll
.chk:   cmp     ax, bx
        jbe     .poll
        popf
        stc
        jmp     .out
.ok:    popf
        clc
.out:   pop     di
        pop     esi
        pop     eax
        ret

;-----------------------------------------------------------------------------
; Port handling (BP = port register base)
;-----------------------------------------------------------------------------

; clear PxCMD.ST and wait for CR to drop.  CF on timeout.
port_stop:
        push    ecx
        push    edx
        push    bx
        lea     ax, [bp+PxCMD]
        call    reg_rd
        test    al, PxCMD_ST
        jz      .wait
        mov     ecx, eax
        and     cl, ~PxCMD_ST
        lea     ax, [bp+PxCMD]
        call    reg_wr
.wait:  lea     ax, [bp+PxCMD]
        mov     ecx, PxCMD_CR
        xor     edx, edx
        mov     bx, 10
        call    wait_reg
        pop     bx
        pop     edx
        pop     ecx
        ret

; clear PxCMD.FRE and wait for FR to drop.  CF on timeout.
port_fre_off:
        push    ecx
        push    edx
        push    bx
        lea     ax, [bp+PxCMD]
        call    reg_rd
        test    al, PxCMD_FRE
        jz      .wait
        mov     ecx, eax
        and     cl, ~PxCMD_FRE
        lea     ax, [bp+PxCMD]
        call    reg_wr
.wait:  lea     ax, [bp+PxCMD]
        mov     ecx, PxCMD_FR
        xor     edx, edx
        mov     bx, 10
        call    wait_reg
        pop     bx
        pop     edx
        pop     ecx
        ret

; COMRESET the port and wait for the link.  CF if no device comes back.
port_comreset:
        push    ecx
        push    edx
        push    bx
        call    port_stop
        lea     ax, [bp+PxSCTL]
        call    reg_rd
        mov     ecx, eax
        and     cx, 0F000h              ; keep SPM/PMP, clear IPM/SPD/DET
        or      cx, 0301h               ; no partial/slumber, DET=1
        lea     ax, [bp+PxSCTL]
        call    reg_wr
        mov     bx, 1
        call    delay_ticks             ; >= 1 ms
        and     cl, 0F0h                ; DET=0
        lea     ax, [bp+PxSCTL]
        call    reg_wr
        lea     ax, [bp+PxSSTS]
        mov     ecx, SSTS_DET
        mov     edx, SSTS_DET_PRESENT
        mov     bx, 19                  ; ~1 s
        call    wait_reg
        pushf
        mov     ecx, -1
        lea     ax, [bp+PxSERR]
        call    reg_wr
        popf
        pop     bx
        pop     edx
        pop     ecx
        ret

; Take over the port: save BIOS state, install our structures, start it.
; CF on failure.
port_acquire:
        push    ecx
        push    edx
        push    bx
        lea     ax, [bp+PxCMD]
        call    reg_rd
        mov     [sv_cmd], eax
        lea     ax, [bp+PxCLB]
        call    reg_rd
        mov     [sv_clb], eax
        lea     ax, [bp+PxCLBU]
        call    reg_rd
        mov     [sv_clbu], eax
        lea     ax, [bp+PxFB]
        call    reg_rd
        mov     [sv_fb], eax
        lea     ax, [bp+PxFBU]
        call    reg_rd
        mov     [sv_fbu], eax
        lea     ax, [bp+PxIE]
        call    reg_rd
        mov     [sv_ie], eax

        call    port_stop
        jc      .reset
        call    port_fre_off
        jnc     .program
.reset: call    port_comreset
        call    port_stop
        jc      .fail
        call    port_fre_off
        jc      .fail

.program:
        xor     ecx, ecx
        lea     ax, [bp+PxIE]
        call    reg_wr
        lea     ax, [bp+PxCLBU]
        call    reg_wr
        lea     ax, [bp+PxFBU]
        call    reg_wr
        mov     ecx, [phys_cl]
        lea     ax, [bp+PxCLB]
        call    reg_wr
        mov     ecx, [phys_fis]
        lea     ax, [bp+PxFB]
        call    reg_wr
        mov     ecx, -1
        lea     ax, [bp+PxSERR]
        call    reg_wr
        lea     ax, [bp+PxIS]
        call    reg_wr

        lea     ax, [bp+PxCMD]          ; FIS receive on
        call    reg_rd
        mov     ecx, eax
        or      cl, PxCMD_FRE
        lea     ax, [bp+PxCMD]
        call    reg_wr

        lea     ax, [bp+PxTFD]          ; device must not be busy
        mov     ecx, TFD_BSY | TFD_DRQ
        xor     edx, edx
        mov     bx, 19
        call    wait_reg
        jnc     .start
        test    byte [hba_cap+3], CAP_SCLO >> 24
        jz      .start
        lea     ax, [bp+PxCMD]          ; command list override
        call    reg_rd
        mov     ecx, eax
        or      cl, PxCMD_CLO
        lea     ax, [bp+PxCMD]
        call    reg_wr
        lea     ax, [bp+PxCMD]
        mov     ecx, PxCMD_CLO
        xor     edx, edx
        mov     bx, 10
        call    wait_reg

.start: lea     ax, [bp+PxCMD]
        call    reg_rd
        mov     ecx, eax
        or      cl, PxCMD_ST
        lea     ax, [bp+PxCMD]
        call    reg_wr
        clc
        jmp     .out
.fail:  stc
.out:   pop     bx
        pop     edx
        pop     ecx
        ret

; Stop the port and restore the state saved by port_acquire.
port_release:
        push    ecx
        push    edx
        push    bx
        call    port_stop
        jnc     .stopped
        call    port_comreset
.stopped:
        call    port_fre_off
        mov     ecx, -1
        lea     ax, [bp+PxSERR]
        call    reg_wr
        lea     ax, [bp+PxIS]
        call    reg_wr
        movzx   ecx, bp                 ; clear our bit in the global IS
        sub     cx, PORT_BASE
        shr     cx, 7
        xor     edx, edx
        bts     edx, ecx
        mov     ecx, edx
        mov     ax, HBA_IS
        call    reg_wr

        mov     ecx, [sv_clb]
        lea     ax, [bp+PxCLB]
        call    reg_wr
        mov     ecx, [sv_clbu]
        lea     ax, [bp+PxCLBU]
        call    reg_wr
        mov     ecx, [sv_fb]
        lea     ax, [bp+PxFB]
        call    reg_wr
        mov     ecx, [sv_fbu]
        lea     ax, [bp+PxFBU]
        call    reg_wr
        mov     ecx, [sv_ie]
        lea     ax, [bp+PxIE]
        call    reg_wr

        test    byte [sv_cmd], PxCMD_FRE
        jz      .out
        lea     ax, [bp+PxCMD]
        call    reg_rd
        mov     ecx, eax
        or      cl, PxCMD_FRE
        lea     ax, [bp+PxCMD]
        call    reg_wr
        test    byte [sv_cmd], PxCMD_ST
        jz      .out
        lea     ax, [bp+PxTFD]          ; ST needs BSY/DRQ clear
        mov     ecx, TFD_BSY | TFD_DRQ
        xor     edx, edx
        mov     bx, 19
        call    wait_reg
        lea     ax, [bp+PxCMD]
        call    reg_rd
        mov     ecx, eax
        or      cl, PxCMD_ST
        lea     ax, [bp+PxCMD]
        call    reg_wr
.out:   pop     bx
        pop     edx
        pop     ecx
        ret

;-----------------------------------------------------------------------------
; PRDT handling
;-----------------------------------------------------------------------------
prd_clear:
        mov     word [x_nprd], 0
        ret

; add EAX = physical address, ECX = byte count (even, > 0).  CF if full.
prd_add:
        push    eax
        push    ecx
        push    edx
        push    di
.next:  cmp     word [x_nprd], NPRD
        jae     .full
        mov     di, [x_nprd]
        shl     di, 4
        add     di, [ct_ptr]
        add     di, CT_PRDT
        mov     edx, ecx
        cmp     edx, PRD_MAX_BYTES
        jbe     .fits
        mov     edx, PRD_MAX_BYTES
.fits:  mov     [di], eax
        mov     dword [di+4], 0
        mov     dword [di+8], 0
        dec     edx
        mov     [di+12], edx
        inc     edx
        inc     word [x_nprd]
        add     eax, edx
        sub     ecx, edx
        jnz     .next
        clc
        jmp     .out
.full:  stc
.out:   pop     di
        pop     edx
        pop     ecx
        pop     eax
        ret

;-----------------------------------------------------------------------------
; Execute one command on port BP using the x_* context and the prepared PRDT.
; Returns AL = XR_* result, x_tfd = task file data.
;-----------------------------------------------------------------------------
ahci_exec:
        push    ecx
        push    edx
        push    esi
        push    di
        mov     dword [x_tfd], 0
        mov     dword [x_xfer], 0
        mov     byte [x_over], 0
        call    port_acquire
        jnc     .acquired
        mov     byte [x_res], XR_PORT
        jmp     .reset_release

.acquired:
        ; command header (slot 0)
        mov     di, [cl_ptr]
        mov     ax, CH_CFL5
        cmp     byte [x_atapi], 0
        je      .noatapi
        or      al, CH_ATAPI
.noatapi:
        cmp     byte [x_write], 0
        je      .nowrite
        or      al, CH_WRITE
.nowrite:
        mov     [di], ax
        mov     ax, [x_nprd]
        mov     [di+2], ax
        mov     dword [di+4], 0
        mov     eax, [phys_ct]
        mov     [di+8], eax
        mov     dword [di+12], 0

        ; command FIS
        mov     di, [ct_ptr]
        mov     byte [di], FIS_TYPE_H2D
        mov     byte [di+1], FIS_H2D_CMD
        mov     al, [x_cmd]
        mov     [di+2], al
        mov     al, [x_feat]
        mov     [di+3], al
        movzx   eax, word [x_bcl]       ; LBA mid/high = byte count limit
        shl     eax, 8
        mov     [di+4], eax
        xor     eax, eax
        mov     [di+8], eax
        mov     [di+12], eax
        mov     [di+16], eax

        ; ATAPI command packet
        mov     si, cdb_buf
        add     di, CT_ACMD
        mov     cx, 4
.cdb:   mov     eax, [si]
        mov     [di], eax
        add     si, 4
        add     di, 4
        loop    .cdb

        mov     ecx, -1
        lea     ax, [bp+PxIS]
        call    reg_wr
        mov     ecx, 1
        lea     ax, [bp+PxCI]
        call    reg_wr

        ; poll for completion
        pushf
        sti
        call    get_ticks
        mov     esi, eax
.poll:  lea     ax, [bp+PxIS]
        call    reg_rd
        test    eax, PxIS_FATAL
        jnz     .error
        lea     ax, [bp+PxCI]
        call    reg_rd
        test    al, 1
        jz      .complete
        call    get_ticks
        sub     eax, esi
        jns     .chk
        call    get_ticks
        mov     esi, eax
        jmp     .poll
.chk:   cmp     eax, [tmo_ticks]
        jbe     .poll
        popf
        mov     byte [x_res], XR_TIMEOUT
        jmp     .reset_release

.error: popf
        mov     edx, eax
        lea     ax, [bp+PxTFD]
        call    reg_rd
        mov     [x_tfd], eax
        mov     byte [x_res], XR_CHECK
        test    edx, PxIS_TFES
        jnz     .release
        mov     byte [x_res], XR_HBA
        jmp     .reset_release

.complete:
        popf
        lea     ax, [bp+PxIS]
        call    reg_rd
        test    eax, PxIS_OFS
        jz      .no_ovf
        mov     byte [x_over], 1
.no_ovf:
        mov     di, [cl_ptr]            ; PRD byte count of slot 0
        mov     eax, [di+4]
        mov     [x_xfer], eax
        lea     ax, [bp+PxTFD]
        call    reg_rd
        mov     [x_tfd], eax
        mov     byte [x_res], XR_OK
        test    al, TFD_ERR
        jz      .release
        mov     byte [x_res], XR_CHECK
.release:
        call    port_release
        jmp     .out
.reset_release:
        call    port_comreset
        call    port_release
.out:   mov     al, [x_res]
        pop     di
        pop     esi
        pop     edx
        pop     ecx
        ret

;-----------------------------------------------------------------------------
; Run the ATAPI packet in cdb_buf on device BX (index) with data through the
; bounce buffer.  ECX = transfer length (<= BOUNCE_SIZE), DL = 1 for write.
; Returns AL = XR_*.  Used for internal commands (INQUIRY, REQUEST SENSE).
;-----------------------------------------------------------------------------
packet_bounce:
        cmp     byte [dev_trans+bx], TR_IDE
        jne     .ahci
        mov     [x_rem], ecx
        mov     ax, [bounce_ptr]
        mov     [x_bufp], ax
        mov     [x_bufp+2], cs
        mov     [x_write], dl
        jmp     ide_packet
.ahci:  push    bp
        push    ecx
        push    si
        mov     si, bx
        add     si, si
        mov     bp, [dev_port+si]
        call    prd_clear
        mov     [x_write], dl
        jecxz   .nodata
        inc     ecx
        and     cl, 0FEh
        mov     eax, [phys_bounce]
        call    prd_add
.nodata:
        mov     byte [x_atapi], 1
        mov     byte [x_cmd], ATA_PACKET
        call    set_packet_feat
        mov     word [x_bcl], 0FFFEh
        call    ahci_exec
        pop     si
        pop     ecx
        pop     bp
        ret

; x_feat for a packet command on device BX with x_nprd / x_write set
set_packet_feat:
        mov     byte [x_feat], 0
        cmp     word [x_nprd], 0
        je      .out
        test    byte [dev_flags+bx], DF_DMA
        jz      .out
        mov     byte [x_feat], ATA_FEAT_DMA
        cmp     byte [x_write], 0
        jne     .out
        test    byte [dev_flags+bx], DF_DMADIR
        jz      .out
        or      byte [x_feat], ATA_FEAT_DMADIR
.out:   ret

;=============================================================================
; Classic IDE transport: ATAPI PACKET commands, PIO, polled
;=============================================================================

; BX = device index -> ide_base, ide_ctl, ide_sel
ide_setdev:
        push    ax
        push    si
        mov     si, bx
        add     si, si
        mov     ax, [dev_port+si]
        mov     [ide_base], ax
        mov     ax, [dev_ctl+si]
        mov     [ide_ctl], ax
        mov     al, [dev_sel+bx]
        mov     [ide_sel], al
        pop     si
        pop     ax
        ret

; ~400 ns: read the alternate status register four times
ide_delay:
        push    ax
        push    dx
        mov     dx, [ide_ctl]
        in      al, dx
        in      al, dx
        in      al, dx
        in      al, dx
        pop     dx
        pop     ax
        ret

; DX = register offset -> DX = port
ide_port:
        add     dx, [ide_base]
        ret

; Wait until (status & AH) == AL.  CX = timeout in ticks.
; -> AL = status, CF on timeout or floating bus (status FFh)
ide_wait:
        push    bx
        push    dx
        push    esi
        mov     bx, ax
        pushf
        sti
        call    get_ticks
        mov     esi, eax
.poll:  mov     dx, IDE_STATUS
        call    ide_port
        in      al, dx
        cmp     al, 0FFh
        je      .fail
        mov     ah, al
        and     ah, bh
        cmp     ah, bl
        je      .ok
        push    ax
        call    get_ticks
        sub     eax, esi
        js      .wrap
        cmp     eax, ecx
        pop     ax
        jbe     .poll
        jmp     .fail
.wrap:  call    get_ticks               ; midnight: restart
        mov     esi, eax
        pop     ax
        jmp     .poll
.fail:  popf
        stc
        jmp     .out
.ok:    popf
        clc
.out:   pop     esi
        pop     dx
        pop     bx
        ret

; select the device and wait until it is idle.  CF on failure.
ide_select:
        push    ecx
        mov     dx, IDE_SELECT
        call    ide_port
        mov     al, [ide_sel]
        out     dx, al
        call    ide_delay
        mov     ax, (TFD_BSY | TFD_DRQ) << 8
        mov     ecx, 19
        call    ide_wait
        pop     ecx
        ret

; DEVICE RESET for the selected device (ATAPI only, not the whole channel)
ide_devreset:
        push    ecx
        mov     dx, IDE_SELECT
        call    ide_port
        mov     al, [ide_sel]
        out     dx, al
        call    ide_delay
        mov     dx, IDE_COMMAND
        call    ide_port
        mov     al, ATA_DEVICE_RESET
        out     dx, al
        call    ide_delay
        mov     ax, TFD_BSY << 8
        mov     ecx, [tmo_ticks]
        call    ide_wait
        pop     ecx
        ret

; enable / disable device interrupts on the channel (preserves flags)
ide_irq_off:
        push    ax
        push    dx
        mov     dx, [ide_ctl]
        mov     al, IDE_NIEN
        out     dx, al
        pop     dx
        pop     ax
        ret

ide_irq_on:
        pushf
        push    ax
        push    dx
        mov     dx, [ide_ctl]
        mov     al, IDE_IEN
        out     dx, al
        pop     dx
        pop     ax
        popf
        ret

; DATA phase, device to host: CX bytes offered (DX = data port)
ide_pio_in:
        push    es
        push    di
        push    bx
        mov     bx, cx
        inc     bx
        shr     bx, 1                   ; words offered
        movzx   ecx, cx
        cmp     ecx, [x_rem]
        jbe     .take
        mov     ecx, [x_rem]
.take:  sub     [x_rem], ecx            ; ECX = bytes stored
        add     [x_xfer], ecx
        les     di, [x_bufp]
        push    cx
        shr     cx, 1
        sub     bx, cx
        rep     insw
        pop     cx
        test    cl, 1
        jz      .rest
        in      ax, dx                  ; odd byte: store the low half
        stosb
        dec     bx
.rest:  mov     cx, bx                  ; discard what does not fit
        jcxz    .done
        mov     byte [x_over], 1
.drop:  in      ax, dx
        loop    .drop
.done:  call    advance_bufp
        pop     bx
        pop     di
        pop     es
        ret

; DATA phase, host to device: CX bytes requested (DX = data port)
ide_pio_out:
        push    ds
        push    si
        push    bx
        mov     bx, cx
        inc     bx
        shr     bx, 1                   ; words requested
        movzx   ecx, cx
        cmp     ecx, [x_rem]
        jbe     .take
        mov     ecx, [x_rem]
.take:  sub     [x_rem], ecx
        add     [x_xfer], ecx
        inc     cx
        shr     cx, 1                   ; words from the buffer
        sub     bx, cx
        push    word [x_bufp+2]
        push    word [x_bufp]
        pop     si
        pop     ds
        rep     outsw
        push    cs
        pop     ds
        mov     di, si                  ; advance_bufp takes the offset in DI
        push    es
        mov     es, [x_bufp+2]
        call    advance_bufp
        pop     es
        mov     cx, bx                  ; pad with zeros
        jcxz    .done
        mov     byte [x_over], 1
        xor     ax, ax
.pad:   out     dx, ax
        loop    .pad
.done:  pop     bx
        pop     si
        pop     ds
        ret

; x_bufp = normalized ES:DI
advance_bufp:
        push    ax
        mov     ax, di
        shr     ax, 4
        add     ax, [x_bufp+2]
        mov     [x_bufp+2], ax
        and     di, 0Fh
        mov     [x_bufp], di
        pop     ax
        ret

; Run the ATAPI packet in cdb_buf on IDE device BX.  Data goes to / comes
; from [x_bufp] (at most [x_rem] bytes), x_write = direction.
; Returns AL = XR_*, x_tfd = status | error << 8.
ide_packet:
        pushad
        push    es
        call    ide_setdev
        mov     dword [x_tfd], 0
        mov     dword [x_xfer], 0
        mov     byte [x_over], 0
        mov     byte [x_res], XR_OK
        mov     ax, [x_bufp]            ; start from a normalized pointer
        mov     di, ax
        mov     es, [x_bufp+2]
        call    advance_bufp
        call    ide_irq_off
        call    ide_select
        jc      .timeout
        mov     dx, IDE_FEATURE
        call    ide_port
        xor     al, al                  ; PIO, no overlap
        out     dx, al
        inc     dx                      ; interrupt reason / sector count
        out     dx, al
        mov     dx, IDE_BCL_LO
        call    ide_port
        mov     ax, IDE_BCL
        out     dx, al
        inc     dx
        mov     al, ah
        out     dx, al
        mov     dx, IDE_COMMAND
        call    ide_port
        mov     al, ATA_PACKET
        out     dx, al
        call    ide_delay
        mov     ax, TFD_BSY << 8        ; wait for the packet request
        mov     ecx, 19
        call    ide_wait
        jc      .timeout
        test    al, TFD_ERR
        jnz     .finish
        test    al, TFD_DRQ
        jz      .protocol
        mov     dx, IDE_DATA
        call    ide_port
        mov     si, cdb_buf
        mov     cx, 6                   ; 12 byte packet
        test    byte [dev_flags+bx], DF_CDB16
        jz      .send
        mov     cx, 8
.send:  rep     outsw
        call    ide_delay
.phase: mov     ax, TFD_BSY << 8
        mov     ecx, [tmo_ticks]
        call    ide_wait
        jc      .timeout
        test    al, TFD_DRQ
        jz      .finish
        test    al, TFD_ERR
        jnz     .finish
        mov     dx, IDE_BCL_LO          ; bytes in this DRQ block
        call    ide_port
        in      al, dx
        mov     cl, al
        inc     dx
        in      al, dx
        mov     ch, al
        mov     dx, IDE_IREASON
        call    ide_port
        in      al, dx
        mov     dx, IDE_DATA
        call    ide_port
        test    al, 2                   ; I/O: 1 = to host
        jz      .write
        call    ide_pio_in
        jmp     .phase
.write: call    ide_pio_out
        jmp     .phase
.finish:
        mov     [x_tfd], al
        test    al, TFD_ERR
        jz      .irq
        mov     byte [x_res], XR_CHECK
        mov     dx, IDE_ERROR
        call    ide_port
        in      al, dx
        mov     [x_tfd+1], al
        jmp     .irq
.protocol:
        mov     [x_tfd], al
        mov     byte [x_res], XR_HBA
        call    ide_devreset
        jmp     .irq
.timeout:
        mov     byte [x_res], XR_TIMEOUT
        call    ide_devreset
.irq:   call    ide_irq_on
        pop     es
        popad
        mov     al, [x_res]
        ret

;=============================================================================
; ASPI entry point
;=============================================================================
aspi_entry:
        push    bp
        mov     bp, sp
        pushf
        pushad
        push    ds
        push    es
        push    fs
        push    gs
        ; Windows 3.x enhanced mode: no switch to another VM while we are
        ; in here (one driver state, one internal stack for all DOS boxes)
        xor     di, di
        smsw    ax
        test    al, 1
        jz      .nocs
        mov     ax, 1681h               ; begin critical section
        int     2Fh
        inc     di
.nocs:  push    di                      ; (kept on the caller's stack)
        mov     ax, cs
        mov     ds, ax
        les     si, [ss:bp+6]
        mov     [srb_ptr], si
        mov     [srb_ptr+2], es

        ; adapters of the previous manager: pass the request on, on the
        ; caller's stack (other managers may need more than our stack)
        mov     al, [es:si+SRB_HaId]
        cmp     al, [prev_count]
        jae     .ours
%ifdef E9LOG
        call    trace_in
%endif
        push    es
        push    si
        call    far [cs:prev_entry]
        add     sp, 4
        mov     ax, cs
        mov     ds, ax
        les     si, [ss:bp+6]
        cmp     byte [es:si+SRB_Cmd], SC_HA_INQUIRY
        jne     .fwd_done
        inc     byte [es:si+HA_Count]   ; count our adapter as well
.fwd_done:
%ifdef E9LOG
        mov     [srb_ptr], si
        mov     [srb_ptr+2], es
        call    trace_out
%endif
        jmp     .restore

.ours:  cmp     byte [in_aspi], 0
        jne     .nested
        pushf
        pop     dx
        cli
        mov     [old_ss], ss
        mov     [old_sp], sp
        mov     ax, cs                  ; (AL was overwritten with the HA id)
        mov     ss, ax
        mov     sp, stack_top
        push    dx
        popf
.nested:
        inc     byte [in_aspi]
        cld

        cmp     byte [acc_method], AM_FLAT
        jne     .go
        call    flat_enable
        call    a20_test
        jnz     .go
        call    a20_enable
        mov     byte [a20_fixed], 1

.go:
%ifdef E9LOG
        call    trace_in
%endif
        call    aspi_dispatch
%ifdef E9LOG
        call    trace_out
%endif

        cmp     byte [a20_fixed], 0
        je      .leave
        mov     byte [a20_fixed], 0
        call    a20_disable
.leave: dec     byte [in_aspi]
        jnz     .restore
        cli
        mov     ss, [old_ss]
        mov     sp, [old_sp]
.restore:
        pop     cx                      ; critical section to end?
        jcxz    .nocs2
        mov     ax, 1682h               ; end critical section
        int     2Fh
.nocs2: pop     gs
        pop     fs
        pop     es
        pop     ds
        popad
        popf
        pop     bp
        retf

;-----------------------------------------------------------------------------
; ASPI trace to the QEMU debug console (test builds only)
;   > c=<cmd> h=<ha> t=<target> [op=<cdb0> n=<cdblen> f=<flags> l=<buflen>]
;   < s=<status> [ha=<hastat> ts=<targstat> sk=<sense key>]
;-----------------------------------------------------------------------------
%ifdef E9LOG
trace_in:
        push    ax
        push    si
        push    es
        les     si, [srb_ptr]
        mov     al, '>'
        call    e9_putc
        mov     al, 'c'
        mov     ah, [es:si+SRB_Cmd]
        call    e9_field
        mov     al, 'h'
        mov     ah, [es:si+SRB_HaId]
        call    e9_field
        cmp     byte [es:si+SRB_Cmd], SC_HA_INQUIRY
        je      .end
        mov     al, 't'
        mov     ah, [es:si+SRB_Target]
        call    e9_field
        cmp     byte [es:si+SRB_Cmd], SC_EXEC_SCSI_CMD
        jne     .end
        push    si
        mov     si, e9_op
        call    e9_str
        pop     si
        mov     al, [es:si+SRB_CDB]
        call    e9_hex8
        mov     al, 'n'
        mov     ah, [es:si+SRB_CDBLen]
        call    e9_field
        mov     al, 'f'
        mov     ah, [es:si+SRB_Flags]
        call    e9_field
        mov     al, 'l'
        mov     ah, [es:si+SRB_BufLen+1]
        call    e9_field
        mov     al, [es:si+SRB_BufLen]
        call    e9_hex8
.end:   pop     es
        pop     si
        pop     ax
        ret

trace_out:
        push    ax
        push    bx
        push    si
        push    es
        les     si, [srb_ptr]
        mov     al, ' '
        call    e9_putc
        mov     al, '<'
        call    e9_putc
        mov     al, 's'
        mov     ah, [es:si+SRB_Status]
        call    e9_field
        cmp     byte [es:si+SRB_Cmd], SC_EXEC_SCSI_CMD
        jne     .end
        cmp     byte [es:si+SRB_Status], SS_COMP
        je      .end
        push    si
        mov     si, e9_ha
        call    e9_str
        pop     si
        mov     al, [es:si+SRB_HaStat]
        call    e9_hex8
        mov     al, 't'
        mov     ah, [es:si+SRB_TargStat]
        call    e9_field
        cmp     byte [es:si+SRB_TargStat], STATUS_CHKCOND
        jne     .end
        movzx   bx, byte [es:si+SRB_CDBLen]
        add     bx, si
        push    si
        mov     si, e9_sk
        call    e9_str
        pop     si
        mov     al, [es:bx+SRB_CDB+2]
        and     al, 0Fh
        call    e9_hex8
        mov     al, '/'
        call    e9_putc
        mov     al, [es:bx+SRB_CDB+12]
        call    e9_hex8
        mov     al, '/'
        call    e9_putc
        mov     al, [es:bx+SRB_CDB+13]
        call    e9_hex8
.end:   mov     al, 13
        call    e9_putc
        mov     al, 10
        call    e9_putc
        pop     es
        pop     si
        pop     bx
        pop     ax
        ret

; " <AL>=<AH as hex>"
e9_field:
        push    ax
        mov     al, ' '
        call    e9_putc
        pop     ax
        call    e9_putc
        mov     al, '='
        call    e9_putc
        mov     al, ah
e9_hex8:
        push    ax
        shr     al, 4
        call    .nib
        pop     ax
        push    ax
        and     al, 0Fh
        call    .nib
        pop     ax
        ret
.nib:   add     al, '0'
        cmp     al, '9'
        jbe     e9_putc
        add     al, 7
e9_putc:
        out     0E9h, al
        ret

e9_str: push    ax
.l:     mov     al, [cs:si]
        or      al, al
        jz      .e
        call    e9_putc
        inc     si
        jmp     .l
.e:     pop     ax
        ret

e9_op           db      ' op=', 0
e9_ha           db      ' ha=', 0
e9_sk           db      ' sk=', 0
%endif

aspi_dispatch:
        les     si, [srb_ptr]
        mov     al, [es:si+SRB_Cmd]
        mov     ah, [es:si+SRB_HaId]
        cmp     al, SC_HA_INQUIRY
        je      srb_ha_inquiry
        cmp     ah, [prev_count]
        jne     .bad_ha
        cmp     al, SC_GET_DEV_TYPE
        je      srb_get_dev_type
        cmp     al, SC_EXEC_SCSI_CMD
        je      srb_exec
        cmp     al, SC_ABORT_SRB
        je      srb_abort
        cmp     al, SC_RESET_DEV
        je      srb_reset
        cmp     al, SC_GET_DISK_INFO
        je      srb_disk_info
        mov     byte [es:si+SRB_Status], SS_INVALID_CMD
        ret
.bad_ha:
        mov     byte [es:si+SRB_Status], SS_INVALID_HA
        ret

;--- SC_HA_INQUIRY -----------------------------------------------------------
srb_ha_inquiry:
        mov     al, [prev_count]
        inc     al
        mov     [es:si+HA_Count], al
        dec     al
        cmp     [es:si+SRB_HaId], al
        je      .ok
        mov     byte [es:si+SRB_Status], SS_INVALID_HA
        ret
.ok:    mov     byte [es:si+HA_SCSI_ID], HA_TARGET_ID
        lea     di, [si+HA_ManagerId]
        push    si
        mov     si, mgr_id
        mov     cx, 48                  ; manager id, adapter id, unique
        rep     movsb
        pop     si
        cmp     word [es:si+SRB_Hdr_Rsvd], 0AA55h ; extended inquiry?
        jne     .done
        mov     word [es:si+SRB_Hdr_Rsvd], 55AAh
        mov     al, [es:si+SRB_Hdr_Rsvd+2]      ; bytes requested
        cmp     al, 2
        jb      .none
        mov     word [es:si+HA_ExtFlags], HA_EXT_RESIDUAL
        mov     al, 2
        jmp     .ext
.none:  xor     al, al
.ext:   mov     [es:si+SRB_Hdr_Rsvd+2], al
.done:  mov     byte [es:si+SRB_Status], SS_COMP
        ret

; ES:SI = SRB -> BX = device index.  CF (and status set) if no device.
find_dev:
        movzx   bx, byte [es:si+SRB_Target]
        cmp     bl, [dev_count]
        jae     .none
        cmp     byte [es:si+SRB_Lun], 0
        jne     .none
        clc
        ret
.none:  mov     byte [es:si+SRB_Status], SS_NO_DEVICE
        stc
        ret

;--- SC_GET_DEV_TYPE ---------------------------------------------------------
srb_get_dev_type:
        call    find_dev
        jc      .out
        mov     al, [dev_type+bx]
        mov     [es:si+SRB_DeviceType], al
        mov     byte [es:si+SRB_Status], SS_COMP
.out:   ret

;--- SC_ABORT_SRB: all requests complete synchronously -----------------------
srb_abort:
        mov     byte [es:si+SRB_Status], SS_ABORT_FAIL
        ret

;--- SC_GET_DISK_INFO --------------------------------------------------------
srb_disk_info:
        call    find_dev
        jc      .out
        xor     ax, ax
        mov     [es:si+SRB_DriveFlags], ax      ; not an INT 13h drive
        mov     [es:si+SRB_Heads], ax
        mov     byte [es:si+SRB_Status], SS_COMP
.out:   ret

;--- SC_RESET_DEV ------------------------------------------------------------
srb_reset:
        call    find_dev
        jc      .out
        cmp     byte [dev_trans+bx], TR_IDE
        jne     .ahci
        call    ide_setdev
        call    ide_irq_off
        call    ide_devreset
        call    ide_irq_on
        jmp     .result
.ahci:  push    bp
        mov     di, bx
        add     di, di
        mov     bp, [dev_port+di]
        call    port_acquire
        call    port_comreset
        pushf
        call    port_release
        popf
        pop     bp
.result:
        mov     word [es:si+SRB_HaStat], 0      ; HaStat, TargStat
        jnc     .ok
        mov     byte [es:si+SRB_HaStat], HASTAT_SEL_TO
        mov     byte [es:si+SRB_Status], SS_ERR
        jmp     call_post
.ok:    mov     byte [es:si+SRB_Status], SS_COMP
        jmp     call_post
.out:   ret

; call the post routine of the SRB at ES:SI if requested
call_post:
        test    byte [es:si+SRB_Flags], SRB_POSTING
        jz      .out
        mov     eax, [es:si+SRB_PostProc]
        or      eax, eax
        jz      .out
        mov     [post_ptr], eax
        sti
        push    es
        push    si
        call    far [post_ptr]
        add     sp, 4
.out:   ret

;--- SC_EXEC_SCSI_CMD --------------------------------------------------------
srb_exec:
        call    find_dev
        jnc     .dev
        jmp     call_post
.dev:   mov     [s_dev], bx
        mov     word [es:si+SRB_HaStat], 0      ; HaStat, TargStat
        mov     dword [s_xfer], 0
        mov     byte [s_over], 0
        test    byte [es:si+SRB_Flags], SRB_LINKING
        jz      .nolink
        jmp     .invalid                ; ATAPI has no linked commands
.nolink:
        mov     eax, [es:si+SRB_BufLen]
        mov     [s_len], eax
        mov     eax, [es:si+SRB_BufPointer]
        mov     [s_buf], eax

        ; copy the CDB
        movzx   cx, byte [es:si+SRB_CDBLen]
        test    cx, cx
        jz      .invalid
        cmp     cx, 16
        ja      .invalid
        cmp     cx, 12
        jbe     .cdblen_ok
        test    byte [dev_flags+bx], DF_CDB16
        jz      .invalid
.cdblen_ok:
        xor     eax, eax
        mov     [cdb_buf], eax
        mov     [cdb_buf+4], eax
        mov     [cdb_buf+8], eax
        mov     [cdb_buf+12], eax
        push    si
        add     si, SRB_CDB
        mov     di, cdb_buf
.copy:  mov     al, [es:si]
        mov     [di], al
        inc     si
        inc     di
        loop    .copy
        pop     si

        ; transfer direction
        mov     byte [s_dir], 0
        cmp     dword [s_len], 0
        je      .dir_done
        mov     al, [es:si+SRB_Flags]
        and     al, SRB_DIR_MASK
        cmp     al, SRB_DIR_NONE
        je      .dir_done
        mov     byte [s_dir], 1
        cmp     al, SRB_DIR_IN
        je      .dir_done
        mov     byte [s_dir], 2
        cmp     al, SRB_DIR_OUT
        je      .dir_done
        mov     al, [cdb_buf]           ; SRB_DIR_AUTO: look at the opcode
        call    opcode_is_write
        jc      .dir_done
        mov     byte [s_dir], 1
.dir_done:

        call    translate_cdb
        jc      .invalid
        cmp     byte [dev_trans+bx], TR_IDE
        je      .ide
        call    map_data
        jc      .invalid

        jmp     .ahci

.ide:   ; PIO straight into the client buffer, or the bounce buffer for
        ; translated MODE SENSE / MODE SELECT
        xor     eax, eax
        mov     [x_rem], eax
        cmp     byte [s_xlate], XL_NONE
        je      .ide_client
        movzx   eax, word [s_blen]
        mov     [x_rem], eax
        mov     ax, [bounce_ptr]
        mov     [x_bufp], ax
        mov     [x_bufp+2], cs
        jmp     .ide_go
.ide_client:
        cmp     byte [s_dir], 0
        je      .ide_nodata
        mov     eax, [s_len]
        mov     [x_rem], eax
.ide_nodata:
        mov     eax, [s_buf]
        mov     [x_bufp], eax
.ide_go:
        xor     al, al
        cmp     byte [s_dir], 2
        jne     .ide_rd
        inc     al
.ide_rd:
        mov     [x_write], al
        call    ide_packet
.xdone: mov     byte [s_map], MAP_NONE
        jmp     .done_exec

.ahci:  ; execute
        push    bp
        mov     di, bx
        add     di, di
        mov     bp, [dev_port+di]
        mov     byte [x_atapi], 1
        mov     byte [x_cmd], ATA_PACKET
        xor     al, al
        cmp     byte [s_dir], 2
        jne     .rd
        inc     al
.rd:    mov     [x_write], al
        call    set_packet_feat
        mov     word [x_bcl], 0FFFEh
        call    ahci_exec
        pop     bp
        push    ax
        call    unmap_data
        pop     ax

.done_exec:
        les     si, [srb_ptr]
        push    eax
        mov     eax, [x_xfer]
        mov     [s_xfer], eax
        mov     ah, [x_over]
        mov     [s_over], ah
        pop     eax
        cmp     al, XR_OK
        jne     .failed
        cmp     byte [s_xlate], XL_MODESENSE
        jne     .nomsb
        call    modesense_back
.nomsb: call    inquiry_fixup
.good:  mov     byte [es:si+SRB_Status], SS_COMP
        call    exec_extras
        jmp     call_post

.failed:
        cmp     al, XR_CHECK
        jne     .hba_err
        ; ATAPI devices cannot change their block size and reject a MODE
        ; SELECT that only carries a block descriptor (ASPICD.SYS sends one
        ; to set 2048 byte blocks).  Report success, as ATAPI ASPI managers do.
        cmp     byte [s_xlate], XL_MODESELECT
        jne     .check
        cmp     byte [s_msel_bdonly], 0
        je      .check
        mov     al, [x_tfd+1]           ; ATA error register: sense key
        shr     al, 4
        cmp     al, SENSE_ILLEGAL_REQUEST
        je      .good
.check:
        mov     byte [es:si+SRB_TargStat], STATUS_CHKCOND
        call    auto_sense
        les     si, [srb_ptr]
        jmp     .err
.hba_err:
        mov     byte [es:si+SRB_HaStat], HASTAT_SEL_TO
        cmp     al, XR_HBA
        jne     .err
        mov     byte [es:si+SRB_HaStat], HASTAT_PHASE_ERR
.err:   mov     byte [es:si+SRB_Status], SS_ERR
        call    exec_extras
        jmp     call_post

.invalid:
        les     si, [srb_ptr]
        mov     byte [es:si+SRB_Status], SS_INVALID_CMD
        jmp     call_post

; Data overrun reporting and residual byte count for the SRB at ES:SI
;  - overrun (device wanted to move more data than the buffer holds) is
;    reported as HaStat 12h when the SRB gives an explicit direction
;  - with SRB_RESIDUAL, SRB_BufLen returns the bytes not transferred
exec_extras:
        cmp     byte [s_over], 0
        je      .resid
        mov     al, [es:si+SRB_Flags]
        and     al, SRB_DIR_MASK
        cmp     al, SRB_DIR_IN
        je      .over
        cmp     al, SRB_DIR_OUT
        jne     .resid
.over:  cmp     byte [es:si+SRB_HaStat], HASTAT_OK
        jne     .resid
        mov     byte [es:si+SRB_HaStat], HASTAT_DO_DU
        mov     byte [es:si+SRB_Status], SS_ERR
.resid: test    byte [es:si+SRB_Flags], SRB_RESIDUAL
        jz      .out
        xor     eax, eax
        cmp     byte [s_xlate], XL_NONE ; translated: buffer sizes differ
        jne     .set
        cmp     byte [s_dir], 0
        je      .set
        mov     eax, [s_len]
        sub     eax, [s_xfer]
        jae     .set
        xor     eax, eax
.set:   mov     [es:si+SRB_BufLen], eax
.out:   ret

; ATAPI CD/DVD drives report ANSI version 0 (or 5) in their INQUIRY data.
; ASPICD.SYS only uses the standard SCSI-2 audio commands for drives of
; unknown vendors that claim SCSI-2 and otherwise installs them "for
; Data-Mode only" (no CD audio).  Report version 2 for CD/DVD drives.
inquiry_fixup:
        cmp     byte [inq_scsi2], 0
        je      .out
        cmp     byte [cdb_buf], SCSI_INQUIRY
        jne     .out
        test    byte [cdb_buf+1], 1     ; vital product data page
        jnz     .out
        cmp     dword [s_len], 3
        jb      .out
        push    es
        push    di
        les     di, [s_buf]
        mov     al, [es:di]
        and     al, 1Fh
        cmp     al, 5                   ; CD/DVD device
        jne     .pop
        mov     al, [es:di+2]
        and     al, 7
        cmp     al, 2
        je      .pop
        mov     byte [es:di+2], 2
.pop:   pop     di
        pop     es
.out:   ret

; CF set if opcode AL transfers data from host to device
opcode_is_write:
        push    cx
        push    di
        push    es
        push    cs
        pop     es
        mov     di, write_opcodes
        mov     cx, write_opcodes_len
        repne   scasb
        pop     es
        pop     di
        pop     cx
        clc
        jne     .out
        stc
.out:   ret

write_opcodes   db      04h, 07h, 0Ah, 15h, 18h, 1Dh, 2Ah, 2Eh, 39h, 3Ah
                db      3Bh, 3Fh, 41h, 4Ch, 54h, 55h, 5Dh, 0A3h, 0AAh
                db      0AEh, 0BFh
write_opcodes_len equ   $ - write_opcodes

;-----------------------------------------------------------------------------
; Rewrite 6 byte commands that ATAPI devices commonly reject into their
; 10 byte equivalents.  CF if the request cannot be handled.
;   READ(6), WRITE(6)   -> READ(10), WRITE(10)
;   SEEK(6), REZERO     -> SEEK(10)
;   MODE SENSE(6)       -> MODE SENSE(10), answer converted back
;   MODE SELECT(6)      -> MODE SELECT(10), parameter list converted
;-----------------------------------------------------------------------------
translate_cdb:
        mov     byte [s_xlate], XL_NONE
        mov     al, [cdb_buf]
        cmp     al, SCSI_READ6
        je      .rw6
        cmp     al, SCSI_WRITE6
        je      .rw6
        cmp     al, SCSI_MODE_SENSE6
        je      .msense
        cmp     al, SCSI_MODE_SELECT6
        je      .mselect
        cmp     al, SCSI_SEEK6
        je      .seek6
        cmp     al, SCSI_REZERO_UNIT
        je      .rezero
        clc
        ret

.rezero:
        ; REZERO UNIT -> SEEK(10) to LBA 0
        mov     bl, [cdb_buf+5]
        xor     eax, eax
        mov     [cdb_buf], eax
        mov     [cdb_buf+4], eax
        mov     byte [cdb_buf], SCSI_SEEK10
        mov     [cdb_buf+9], bl
        mov     bx, [s_dev]
        clc
        ret

.seek6: ; SEEK(6) -> SEEK(10)
        mov     ah, [cdb_buf+1]
        and     ah, 1Fh                 ; LBA bits 20..16
        mov     dx, [cdb_buf+2]         ; LBA bits 15..0 (big endian)
        mov     bl, [cdb_buf+5]
        mov     byte [cdb_buf], SCSI_SEEK10
        mov     byte [cdb_buf+1], 0
        mov     byte [cdb_buf+2], 0
        mov     [cdb_buf+3], ah
        mov     [cdb_buf+4], dx
        mov     word [cdb_buf+6], 0
        mov     byte [cdb_buf+8], 0
        mov     [cdb_buf+9], bl
        mov     bx, [s_dev]
        clc
        ret

.rw6:   ; READ(6)/WRITE(6) -> READ(10)/WRITE(10)
        add     al, 20h                 ; 08h->28h, 0Ah->2Ah
        mov     ah, [cdb_buf+1]
        and     ah, 1Fh                 ; LBA bits 20..16
        mov     dx, [cdb_buf+2]         ; LBA bits 15..0 (big endian)
        movzx   cx, byte [cdb_buf+4]    ; length, 0 means 256
        or      cx, cx
        jnz     .len_ok
        mov     cx, 256
.len_ok:
        mov     bl, [cdb_buf+5]
        mov     [cdb_buf], al
        mov     byte [cdb_buf+1], 0
        mov     byte [cdb_buf+2], 0
        mov     [cdb_buf+3], ah
        mov     [cdb_buf+4], dx
        mov     byte [cdb_buf+6], 0
        xchg    cl, ch
        mov     [cdb_buf+7], cx
        mov     [cdb_buf+9], bl
        mov     bx, [s_dev]
        clc
        ret

.msense:
        ; MODE SENSE(6) -> MODE SENSE(10), answer converted afterwards
        movzx   cx, byte [cdb_buf+4]
        mov     [s_alloc6], cx
        jcxz    .ms_build               ; nothing requested, nothing to fix
        cmp     byte [s_dir], 2
        je      .fail
        mov     byte [s_dir], 1
        mov     byte [s_xlate], XL_MODESENSE
        add     cx, 4
        mov     [s_blen], cx
.ms_build:
        mov     bl, [cdb_buf+5]
        mov     al, [cdb_buf+1]
        and     al, 08h                 ; DBD
        mov     byte [cdb_buf], SCSI_MODE_SENSE10
        mov     [cdb_buf+1], al
        mov     byte [cdb_buf+4], 0
        mov     byte [cdb_buf+5], 0
        mov     byte [cdb_buf+6], 0
        xchg    cl, ch
        mov     [cdb_buf+7], cx
        mov     [cdb_buf+9], bl
        mov     bx, [s_dev]
        clc
        ret

.mselect:
        ; MODE SELECT(6) -> MODE SELECT(10), parameter list converted now
        movzx   cx, byte [cdb_buf+4]
        jcxz    .sel_build
        cmp     cx, 4
        jb      .fail
        cmp     byte [s_dir], 1
        je      .fail
        mov     byte [s_dir], 2
        mov     byte [s_xlate], XL_MODESELECT
        call    modeselect_prepare
        mov     cx, [s_blen]
.sel_build:
        mov     bl, [cdb_buf+5]
        mov     al, [cdb_buf+1]
        and     al, 11h                 ; PF, SP
        mov     byte [cdb_buf], SCSI_MODE_SELECT10
        mov     [cdb_buf+1], al
        mov     byte [cdb_buf+4], 0
        mov     byte [cdb_buf+5], 0
        mov     byte [cdb_buf+6], 0
        xchg    cl, ch
        mov     [cdb_buf+7], cx
        mov     [cdb_buf+9], bl
        mov     bx, [s_dev]
        clc
        ret
.fail:  mov     bx, [s_dev]
        stc
        ret

; build the MODE SELECT(10) parameter list in the bounce buffer
; CX = MODE SELECT(6) parameter list length (>= 4)
modeselect_prepare:
        push    ds
        push    es
        mov     di, [bounce_ptr]
        push    cs
        pop     es
        lds     si, [cs:s_buf]
        movzx   ax, byte [si+3]         ; only a block descriptor, no pages?
        add     ax, 4
        cmp     cx, ax
        setbe   byte [cs:s_msel_bdonly]
        xor     ax, ax
        stosw                           ; mode data length (reserved)
        mov     ax, [si+1]              ; medium type, device specific
        stosw
        xor     ax, ax
        stosw
        stosb
        mov     al, [si+3]              ; block descriptor length
        stosb
        add     si, 4
        sub     cx, 4
        push    cx
        rep     movsb
        pop     cx
        pop     es
        pop     ds
        add     cx, 8
        mov     [s_blen], cx
        ret

; convert a MODE SENSE(10) answer in the bounce buffer to MODE SENSE(6)
; format and copy it to the client buffer
modesense_back:
        push    es
        push    si
        mov     si, [bounce_ptr]
        mov     ax, [si]                ; mode data length (big endian)
        xchg    al, ah
        sub     ax, 3
        jae     .nonneg
        xor     ax, ax
.nonneg:
        cmp     ax, 255
        jbe     .lenok
        mov     ax, 255
.lenok: mov     [si], al
        mov     al, [si+2]              ; medium type
        mov     [si+1], al
        mov     al, [si+3]              ; device specific parameter
        mov     [si+2], al
        mov     al, [si+7]              ; block descriptor length
        mov     [si+3], al
        lea     di, [si+4]              ; move the rest down by 4
        add     si, 8
        mov     cx, [s_alloc6]
        push    es
        push    cs
        pop     es
        rep     movsb
        pop     es
        ; copy to the client
        movzx   ecx, word [s_alloc6]
        cmp     dword [s_len], ecx
        jae     .copy
        mov     cx, [s_len]
.copy:  les     di, [s_buf]
        mov     si, [bounce_ptr]
        rep     movsb
        pop     si
        pop     es
        ret

;-----------------------------------------------------------------------------
; Data buffer mapping.  Builds the PRDT for the current request.
; CF if the buffer cannot be used for DMA.
;-----------------------------------------------------------------------------
map_data:
        push    es
        call    prd_clear
        mov     byte [s_map], MAP_NONE
        cmp     byte [s_dir], 0
        je      .ok
        cmp     byte [s_xlate], XL_NONE
        jne     .bounce_ready

        mov     ecx, [s_len]
        movzx   eax, word [s_buf+2]     ; linear address of the buffer
        shl     eax, 4
        movzx   edx, word [s_buf]
        add     eax, edx
        test    al, 1                   ; AHCI needs word alignment
        jnz     .bounce
        test    cl, 1
        jnz     .bounce
        call    vds_present             ; checked per request: Windows 3.x
        jnz     .vds                    ; enhanced mode brings its own VDS

        call    prd_add                 ; physical == linear
        jc      .fail
        mov     byte [s_map], MAP_DIRECT
        jmp     .ok

.vds:   ; scatter/gather lock
        mov     [edds_size], ecx
        mov     [edds_off], edx
        mov     ax, [s_buf+2]
        mov     [edds_seg], ax
        mov     word [edds_avail], NPRD
        push    cs
        pop     es
        mov     di, edds
        mov     ax, 8105h
        xor     dx, dx
        int     4Bh
        jc      .vds_lock
        mov     cx, [edds_used]
        jcxz    .sg_undo
        cmp     cx, NPRD
        ja      .sg_undo
        mov     si, edds_regions
.sg:    push    ecx
        mov     eax, [si]
        mov     ecx, [si+4]
        call    prd_add
        pop     ecx
        jc      .sg_undo
        add     si, 8
        loop    .sg
        mov     byte [s_map], MAP_VDS_SG
        jmp     .ok
.sg_undo:
        mov     ax, 8106h
        xor     dx, dx
        mov     di, edds
        int     4Bh
        call    prd_clear

.vds_lock:
        ; plain lock, VDS may use its own buffer
        mov     ecx, [s_len]
        mov     [dds_size], ecx
        movzx   eax, word [s_buf]
        mov     [dds_off], eax
        mov     ax, [s_buf+2]
        mov     [dds_seg], ax
        mov     word [dds_bufid], 0
        push    cs
        pop     es
        mov     di, dds
        xor     dx, dx
        cmp     byte [s_dir], 2
        jne     .lock
        mov     dx, 02h                 ; copy data into the VDS buffer
.lock:  mov     ax, 8103h
        int     4Bh
        jc      .bounce
        mov     eax, [dds_phys]
        mov     ecx, [s_len]
        call    prd_add
        mov     byte [s_map], MAP_VDS_LOCK
        jmp     .ok

.bounce:
        mov     ecx, [s_len]
        cmp     ecx, BOUNCE_SIZE
        ja      .fail
        mov     [s_blen], cx
        cmp     byte [s_dir], 2
        jne     .bounce_ready
        push    ds                      ; copy the client data in
        mov     di, [bounce_ptr]
        push    cs
        pop     es
        lds     si, [s_buf]
        rep     movsb
        pop     ds
.bounce_ready:
        movzx   ecx, word [s_blen]
        jecxz   .ok
        inc     ecx
        and     cl, 0FEh
        mov     eax, [phys_bounce]
        call    prd_add
        mov     byte [s_map], MAP_BOUNCE
.ok:    clc
        pop     es
        mov     bx, [s_dev]
        ret
.fail:  stc
        pop     es
        mov     bx, [s_dev]
        ret

; ZF clear if a VDS provider is active (BIOS data area 40:7B bit 5)
vds_present:
        push    ds
        push    word VDS_FLAG_SEG
        pop     ds
        test    byte [VDS_FLAG_OFS], VDS_FLAG_BIT
        pop     ds
        ret

; undo map_data after the command; copies bounced read data to the client
unmap_data:
        push    es
        mov     al, [s_map]
        cmp     al, MAP_VDS_SG
        jne     .notsg
        push    cs
        pop     es
        mov     di, edds
        mov     ax, 8106h
        xor     dx, dx
        int     4Bh
        jmp     .out
.notsg: cmp     al, MAP_VDS_LOCK
        jne     .notlock
        push    cs
        pop     es
        mov     di, dds
        xor     dx, dx
        cmp     byte [s_dir], 1
        jne     .unlock
        mov     dx, 02h                 ; copy data out of the VDS buffer
.unlock:
        mov     ax, 8104h
        int     4Bh
        jmp     .out
.notlock:
        cmp     al, MAP_BOUNCE
        jne     .out
        cmp     byte [s_dir], 1
        jne     .out
        cmp     byte [s_xlate], XL_NONE
        jne     .out
        mov     cx, [s_blen]
        les     di, [s_buf]
        mov     si, [bounce_ptr]
        rep     movsb
.out:   pop     es
        mov     bx, [s_dev]
        ret

;-----------------------------------------------------------------------------
; Automatic REQUEST SENSE after CHECK CONDITION for the SRB at [srb_ptr]
;-----------------------------------------------------------------------------
auto_sense:
        les     si, [srb_ptr]
        movzx   cx, byte [es:si+SRB_SenseLen]
        test    cx, cx
        jz      .out
        mov     ax, [x_tfd]             ; keep the error register
        push    ax
        xor     eax, eax
        mov     [cdb_buf], eax
        mov     [cdb_buf+4], eax
        mov     [cdb_buf+8], eax
        mov     [cdb_buf+12], eax
        mov     byte [cdb_buf], SCSI_REQUEST_SENSE
        inc     cx                      ; even length: QEMU's IDE ATAPI never
        and     cl, 0FEh                ; ends a PIO transfer of an odd size
        cmp     cx, 252                 ; (the copy below takes SenseLen)
        jbe     .alloc
        mov     cx, 252
.alloc: mov     [cdb_buf+4], cl
        movzx   ecx, cx
        xor     dl, dl
        mov     bx, [s_dev]
        call    packet_bounce
        pop     dx                      ; DH = error register
        les     si, [srb_ptr]
        movzx   cx, byte [es:si+SRB_SenseLen]
        movzx   di, byte [es:si+SRB_CDBLen]
        add     di, si
        add     di, SRB_CDB
        cmp     al, XR_OK
        jne     .fake
        cmp     cx, 252
        jbe     .copy
        mov     cx, 252
.copy:  mov     si, [bounce_ptr]
        rep     movsb
        jmp     .out
.fake:  ; REQUEST SENSE failed: build sense data from the ATA error register
        push    di
        xor     al, al
        rep     stosb
        pop     di
        mov     al, [es:si+SRB_SenseLen]
        cmp     al, 3
        jb      .out
        mov     byte [es:di], 70h
        shr     dh, 4
        mov     [es:di+2], dh
        cmp     al, 8
        jb      .out
        mov     byte [es:di+7], 0Ah
.out:   ret


;-----------------------------------------------------------------------------
; Stack and DMA area
;-----------------------------------------------------------------------------
%include "biosfix.inc"

                align   16
stack_bottom:   times STACK_SIZE db 0
stack_top:

dma_area:       times DMA_RESERVE db 0

resident_end:

;=============================================================================
; Initialisation (discarded after init)
;=============================================================================

opt_ctl         db      0               ; /C: controller index
opt_method      db      AM_NONE         ; /M: forced access method
opt_pio         db      0               ; /PIO
opt_quiet       db      0               ; /Q
opt_verbose     db      0               ; /V
opt_noahci      db      0               ; /NOAHCI
opt_biosfix     db      0               ; 1 = /BIOSFIX, 2 = /NOBIOSFIX
intel_ahci      db      0               ; an Intel AHCI controller was found
opt_noide       db      0               ; /NOIDE
opt_nopci       db      0               ; /NOPCI
ide_count       db      2               ; IDE channels to scan
ide_bases       dw      1F0h, 170h
                times MAX_IDE_CH - 2 dw 0
ide_ctls        dw      3F6h, 376h
                times MAX_IDE_CH - 2 dw 0
pci_lastbus     db      0
is_v86          db      0
pci_bdf         dw      0
pci_vendev      dd      0
sata_cap        db      0
idp_cfg_ok      db      0
idp_io_ok       db      0
hba_vs          dd      0
hba_pi          dd      0
port_num        db      0
id_model        times 41 db 0

init:
        pushad
        push    ds
        push    es
        push    fs
        push    gs
        mov     ax, cs
        mov     ds, ax
        mov     es, ax
        cld

        call    parse_cmdline           ; may set /Q before the banner
        cmp     byte [opt_quiet], 0
        jne     .nobanner
        mov     si, msg_banner
        call    print
.nobanner:

        call    check_386
        jnc     .cpu_ok
        mov     si, msg_no386
        jmp     init_fail
.cpu_ok:
        smsw    ax
        and     al, 1
        mov     [is_v86], al

        push    es                      ; VDS present?
        mov     ax, VDS_FLAG_SEG
        mov     es, ax
        test    byte [es:VDS_FLAG_OFS], VDS_FLAG_BIT
        pop     es
        setnz   byte [vds_ok]

        mov     ax, 4300h               ; XMS driver (for A20 handling)
        int     2Fh
        cmp     al, 80h
        jne     .noxms
        push    es
        mov     ax, 4310h
        int     2Fh
        mov     [xms_entry], bx
        mov     [xms_entry+2], es
        pop     es
.noxms:
        call    setup_dma_area
        jnc     .dma_ok
        mov     si, msg_vds_fail
        jmp     init_fail
.dma_ok:
        call    find_prev_manager
        cmp     byte [opt_noahci], 0
        jne     .ide
        call    find_controller
        jnc     .ctl_ok
        cmp     byte [opt_verbose], 0   ; no AHCI controller: IDE only
        je      .ide
        call    print
        jmp     .ide
.ctl_ok:
        cmp     word [pci_vendev], 8086h  ; Intel firmware: BIOS VDS fix
        sete    byte [intel_ahci]
        call    choose_method
        jnc     .method_ok
        jmp     init_fail
.method_ok:
        call    init_hba
        jnc     .hba_ok
        jmp     init_fail
.hba_ok:
        call    scan_ports
.ide:   cmp     byte [opt_noide], 0
        jne     .scanned
        cmp     byte [opt_nopci], 0
        jne     .nopci
        call    scan_pci_ide
.nopci: call    scan_ide
.scanned:
        cmp     byte [dev_count], 0
        jne     .found
        ; no ATAPI device: stay resident only for the BIOS VDS fix (as
        ; AHCIFIX$, no ASPI manager), if it is wanted
        cmp     byte [opt_biosfix], 2
        je      .nodev
        cmp     byte [opt_biosfix], 1
        je      .fixonly
        cmp     byte [intel_ahci], 0
        je      .nodev
.fixonly:
        mov     dword [hdr_name], 'AHCI'
        mov     dword [hdr_name+4], 'FIX$'
        call    bf_install
        mov     si, msg_fix_only
        call    print
        jmp     .resident
.nodev: mov     si, msg_no_dev
        jmp     init_fail
.found:
        cmp     byte [opt_biosfix], 2
        je      .nofix
        cmp     byte [opt_biosfix], 1
        je      .fix
        cmp     byte [intel_ahci], 0
        je      .nofix
.fix:   call    bf_install
.nofix:
.resident:
        les     bx, [req_ptr]
        mov     word [es:bx+RQ_END], resident_end
        mov     [es:bx+RQ_END+2], cs
        mov     word [es:bx+RQ_STATUS], 0100h
        jmp     init_out

; SI = error message
init_fail:
        call    print
        mov     si, msg_not_inst
        call    print
        les     bx, [req_ptr]
        mov     word [es:bx+RQ_END], 0
        mov     [es:bx+RQ_END+2], cs
        mov     word [es:bx+RQ_STATUS], 810Ch
init_out:
        pop     gs
        pop     fs
        pop     es
        pop     ds
        popad
        ret

; install the BIOS VDS fix (biosfix.inc): filters on DOS's INT 13h pointers
; and the INT 2Fh hook
bf_install:
        push    ds
        push    es
        mov     ah, 13h                 ; DOS's pointers -> our filters
        mov     dx, bf_int13
        mov     bx, bf_int13_rom
        int     2Fh                     ; DS:DX, ES:BX = the previous ones
        mov     [cs:bf_dos13], dx
        mov     [cs:bf_dos13+2], ds
        mov     [cs:bf_rom13], bx
        mov     [cs:bf_rom13+2], es
        pop     es
        pop     ds
        push    es
        mov     ax, 352Fh
        int     21h
        mov     [bf_old2f], bx
        mov     [bf_old2f+2], es
        pop     es
        mov     ax, 252Fh
        mov     dx, bf_int2f
        int     21h
        or      byte [bf_flags], 1
        cmp     byte [opt_quiet], 0
        jne     .q
        mov     si, msg_biosfix
        call    print
.q:     ret

; CF if the CPU is older than a 386
check_386:
        pushf
        pushf
        pop     ax
        and     ax, 0FFFh
        push    ax
        popf
        pushf
        pop     ax
        and     ax, 0F000h
        cmp     ax, 0F000h              ; 8086/88: bits 12-15 always set
        je      .old
        pushf
        pop     ax
        or      ax, 7000h
        push    ax
        popf
        pushf
        pop     ax
        test    ax, 7000h               ; 286 real mode: bits 12-14 clear
        jz      .old
        popf
        clc
        ret
.old:   popf
        stc
        ret

;-----------------------------------------------------------------------------
; Command line parsing
;-----------------------------------------------------------------------------
parse_cmdline:
        push    es
        les     bx, [req_ptr]
        les     si, [es:bx+RQ_CMDLINE]
.skipname:                              ; skip the driver file name
        mov     al, [es:si]
        call    is_eol
        je      .done
        cmp     al, ' '
        jbe     .args
        cmp     al, '/'
        je      .args
        inc     si
        jmp     .skipname
.args:  mov     al, [es:si]
        call    is_eol
        je      .done
        inc     si
        cmp     al, '/'
        jne     .args
        mov     al, [es:si]
        call    upcase
        inc     si
        cmp     al, 'C'
        je      .opt_c
        cmp     al, 'M'
        je      .opt_m
        cmp     al, 'T'
        je      .opt_t
        cmp     al, 'Q'
        je      .opt_q
        cmp     al, 'V'
        je      .opt_v
        cmp     al, 'I'
        je      .opt_i
        cmp     al, 'P'
        je      .opt_p
        cmp     al, 'R'
        je      .opt_r
        cmp     al, 'N'
        je      .opt_n
        cmp     al, 'B'
        je      .opt_b
.bad:   push    si
        mov     si, msg_bad_opt
        call    print
        pop     si
        jmp     .args

.opt_c: call    get_colon
        jc      .bad
        call    get_number
        jc      .bad
        mov     [opt_ctl], al
        jmp     .args
.opt_t: call    get_colon
        jc      .bad
        call    get_number
        jc      .bad
        or      ax, ax
        jz      .bad
        mov     cx, 182
        mul     cx
        mov     cx, 10
        div     cx
        mov     [tmo_ticks], ax
        jmp     .args
.opt_q: mov     byte [opt_quiet], 1
        jmp     .args
.opt_v: mov     byte [opt_verbose], 1
        jmp     .args
.opt_m: call    get_colon
        jc      .bad
        mov     al, [es:si]
        inc     si
        call    upcase
        mov     ah, AM_IDP_IO
        cmp     al, 'I'
        je      .setm
        mov     ah, AM_IDP_CFG
        cmp     al, 'C'
        je      .setm
        mov     ah, AM_FLAT
        cmp     al, 'F'
        je      .setm
        mov     ah, AM_BIOS
        cmp     al, 'B'
        jne     .bad
.setm:  mov     [opt_method], ah
        jmp     .args
.opt_p: cmp     byte [es:si], ':'       ; /P:port[,ctl] (extra IDE channel)
        jne     .opt_pio
        inc     si
        call    get_hex
        jc      .bad
        mov     bx, ax
        lea     dx, [bx+IDE_CTL_OFS]    ; ISA default: control at base+206h
        cmp     byte [es:si], ','
        jne     .p_add
        inc     si
        push    bx
        call    get_hex
        pop     bx
        jc      .bad
        mov     dx, ax
.p_add: mov     ax, bx
        call    add_ide_ch
        jmp     .args
.opt_n: mov     di, kw_noahci           ; /NOAHCI, /NOIDE
        call    match_kw
        jc      .opt_n2
        mov     byte [opt_noahci], 1
        jmp     .args
.opt_n2:
        mov     di, kw_noide
        call    match_kw
        jc      .opt_n3
        mov     byte [opt_noide], 1
        jmp     .args
.opt_n3:
        mov     di, kw_nopci
        call    match_kw
        jc      .opt_n4
        mov     byte [opt_nopci], 1
        jmp     .args
.opt_n4:
        mov     di, kw_nobiosfix
        call    match_kw
        jc      .bad
        mov     byte [opt_biosfix], 2
        jmp     .args
.opt_b: mov     di, kw_biosfix          ; /BIOSFIX
        call    match_kw
        jc      .bad
        mov     byte [opt_biosfix], 1
        jmp     .args
.opt_pio:
        mov     al, [es:si]             ; /PIO
        call    upcase
        cmp     al, 'I'
        jne     .bad
        mov     al, [es:si+1]
        call    upcase
        cmp     al, 'O'
        jne     .bad
        add     si, 2
        mov     byte [opt_pio], 1
        jmp     .args
.opt_r: mov     di, kw_rawinq           ; /RAWINQ
        call    match_kw
        jc      .bad
        mov     byte [inq_scsi2], 0
        jmp     .args
.opt_i: mov     al, [es:si]             ; /ID:name
        call    upcase
        cmp     al, 'D'
        jne     .bad
        inc     si
        call    get_colon
        jc      .bad
        mov     di, mgr_id
        mov     cx, 16
.idfill:
        mov     al, [es:si]
        call    is_eol
        je      .idpad
        cmp     al, ' '
        jbe     .idpad
        cmp     al, '/'
        je      .idpad
        mov     [di], al
        inc     di
        inc     si
        loop    .idfill
        jmp     .args
.idpad: mov     byte [di], ' '
        inc     di
        loop    .idpad
        jmp     .args
.done:  pop     es
        ret

; compare the rest of an option at ES:SI with the keyword at DI (upper case,
; zero terminated).  Advances SI on a match, CF otherwise.
match_kw:
        push    si
.c:     mov     ah, [di]
        or      ah, ah
        jz      .ok
        mov     al, [es:si]
        call    upcase
        cmp     al, ah
        jne     .no
        inc     si
        inc     di
        jmp     .c
.ok:    add     sp, 2
        clc
        ret
.no:    pop     si
        stc
        ret

kw_rawinq       db      'AWINQ', 0
kw_noahci       db      'OAHCI', 0
kw_noide        db      'OIDE', 0
kw_nopci        db      'OPCI', 0
kw_nobiosfix    db      'OBIOSFIX', 0
kw_biosfix      db      'IOSFIX', 0

; hexadecimal number at ES:SI -> AX.  CF if none.
get_hex:
        xor     ax, ax
        xor     cx, cx
.dig:   mov     dl, [es:si]
        cmp     dl, '0'
        jb      .end
        cmp     dl, '9'
        jbe     .num
        and     dl, 0DFh
        cmp     dl, 'A'
        jb      .end
        cmp     dl, 'F'
        ja      .end
        sub     dl, 7
.num:   sub     dl, '0'
        shl     ax, 4
        or      al, dl
        inc     si
        inc     cx
        jmp     .dig
.end:   cmp     cx, 1
        ret

is_eol: cmp     al, 0
        je      .y
        cmp     al, 0Dh
        je      .y
        cmp     al, 0Ah
.y:     ret

upcase: cmp     al, 'a'
        jb      .n
        cmp     al, 'z'
        ja      .n
        sub     al, 20h
.n:     ret

get_colon:
        cmp     byte [es:si], ':'
        jne     .no
        inc     si
        clc
        ret
.no:    stc
        ret

; decimal number at ES:SI -> AX.  CF if none.
get_number:
        xor     ax, ax
        xor     cx, cx
.dig:   mov     dl, [es:si]
        sub     dl, '0'
        cmp     dl, 9
        ja      .end
        mov     dh, 0
        imul    ax, ax, 10
        add     ax, dx
        inc     si
        inc     cx
        jmp     .dig
.end:   cmp     cx, 1
        ret                             ; CF if cx == 0

;-----------------------------------------------------------------------------
; Look for an ASPI manager loaded before us and chain to it
;-----------------------------------------------------------------------------
find_prev_manager:
        mov     byte [hdr_name+7], '#'  ; DOS must not find our own header
        mov     ax, 3D00h
        mov     dx, prev_name
        int     21h
        mov     byte [hdr_name+7], '$'
        jc      .none
        mov     bx, ax
        mov     ax, 4402h               ; IOCTL read: entry point
        mov     dx, prev_entry
        mov     cx, 4
        int     21h
        pushf
        mov     ah, 3Eh
        int     21h
        popf
        jc      .none
        cmp     dword [prev_entry], 0
        je      .none
        mov     di, prev_srb            ; host adapter inquiry, adapter 0
        mov     cx, 64
        xor     al, al
        push    es
        push    cs
        pop     es
        rep     stosb
        pop     es
        push    cs
        push    word prev_srb
        call    far [prev_entry]
        add     sp, 4
        mov     cx, 0FFFFh              ; managers that complete later
.wait:  cmp     byte [prev_srb+SRB_Status], SS_PENDING
        jne     .done
        loop    .wait
.done:  cmp     byte [prev_srb+SRB_Status], SS_COMP
        jne     .bad
        mov     al, [prev_srb+HA_Count]
        or      al, al
        jz      .bad
        mov     [prev_count], al
        cmp     byte [opt_quiet], 0
        jne     .out
        mov     si, msg_chain1
        call    print
        mov     cx, 16
        mov     si, prev_srb+HA_ManagerId
.name:  lodsb
        call    putc
        loop    .name
        mov     si, msg_chain2
        call    print
        movzx   ax, byte [prev_count]
        call    print_dec
        mov     si, msg_chain3
        call    print
        movzx   ax, byte [prev_count]
        call    print_dec
        mov     si, msg_crlf
        call    print
.out:   ret
.bad:   mov     dword [prev_entry], 0
.none:  mov     byte [prev_count], 0
        ret

prev_name       db      'SCSIMGR$', 0
prev_srb        times 64 db 0

;-----------------------------------------------------------------------------
; Place the DMA structures in the reserved area and get physical addresses
;-----------------------------------------------------------------------------
setup_dma_area:
        mov     ax, cs                  ; linear address of dma_area
        movzx   eax, ax
        shl     eax, 4
        add     eax, dma_area
        mov     edx, eax
        add     eax, 7FFh               ; align to 2 KB
        and     ax, 0F800h
        sub     eax, edx
        add     ax, dma_area            ; offset of the aligned base
        mov     bx, ax

        lea     ax, [bx+DMA_BOUNCE]
        mov     [bounce_ptr], ax
        lea     ax, [bx+DMA_CL]
        mov     [cl_ptr], ax
        lea     ax, [bx+DMA_CT]
        mov     [ct_ptr], ax
        lea     ax, [bx+DMA_SCRATCH]
        mov     [scratch_ptr], ax

        ; bounce buffer and control block each sit within one 4 KB page
        lea     ax, [bx+DMA_BOUNCE]
        mov     ecx, BOUNCE_SIZE
        call    get_phys
        jc      .fail
        mov     [phys_bounce], eax
        lea     ax, [bx+DMA_CL]
        mov     ecx, DMA_USED - DMA_CL
        call    get_phys
        jc      .fail
        mov     [phys_cl], eax
        add     eax, DMA_CT - DMA_CL
        mov     [phys_ct], eax
        add     eax, DMA_SCRATCH - DMA_CT
        mov     [phys_scratch], eax
        add     eax, DMA_FIS - DMA_SCRATCH
        mov     [phys_fis], eax

        mov     ax, cs                  ; flat mode GDT
        movzx   eax, ax
        shl     eax, 4
        add     eax, flat_gdt
        mov     [flat_gdtr+2], eax
        clc
.fail:  ret

; AX = offset in our segment, ECX = size -> EAX = physical address.
; Uses a permanent VDS lock when VDS is present.  CF on failure.
get_phys:
        push    es
        push    di
        push    dx
        movzx   edx, ax
        cmp     byte [vds_ok], 0
        jne     .vds
        mov     ax, cs
        movzx   eax, ax
        shl     eax, 4
        add     eax, edx
        clc
        jmp     .out
.vds:   mov     [dds_size], ecx
        mov     [dds_off], edx
        mov     [dds_seg], cs
        mov     word [dds_bufid], 0
        push    cs
        pop     es
        mov     di, dds
        mov     dx, 000Ch               ; no buffer, no remap
        mov     ax, 8103h
        int     4Bh
        jc      .out
        mov     eax, [dds_phys]
.out:   pop     dx
        pop     di
        pop     es
        ret

;-----------------------------------------------------------------------------
; PCI: find the AHCI controller.  CF and SI = message on failure.
;-----------------------------------------------------------------------------
find_controller:
        mov     ax, 0B101h
        xor     edi, edi
        int     1Ah
        jc      .nopci
        cmp     edx, 'PCI '
        jne     .nopci
        mov     ax, 0B103h
        mov     ecx, PCI_CLASS_AHCI
        movzx   si, byte [opt_ctl]
        int     1Ah
        jc      .noctl
        or      ah, ah
        jnz     .noctl
        mov     [pci_bdf], bx

        xor     di, di
        call    pci_rd
        mov     [pci_vendev], ecx

        mov     di, PCI_CMD             ; memory decode + bus master on
        call    pci_rd
        mov     eax, ecx
        or      cl, PCI_CMD_MEM | PCI_CMD_MASTER
        cmp     eax, ecx
        je      .cmd_ok
        call    pci_wr
.cmd_ok:
        mov     di, PCI_ABAR
        call    pci_rd
        test    cl, 1
        jnz     .badbar
        and     cl, 0F0h
        test    ecx, ecx
        jz      .badbar
        mov     [abar], ecx

        ; look for the SATA capability (index/data pair)
        mov     di, PCI_CMD
        call    pci_rd
        test    ecx, PCI_STATUS_CAPLIST << 16
        jz      .done
        mov     di, PCI_CAP_PTR
        call    pci_rd
        mov     dx, 48                  ; loop limit
.cap:   and     cl, 0FCh
        jz      .done
        movzx   di, cl
        call    pci_rd
        cmp     cl, PCI_CAP_SATA
        je      .sata
        mov     cl, ch
        dec     dx
        jnz     .cap
        jmp     .done
.sata:  mov     ax, di
        mov     [sata_cap], al
        add     di, 4
        call    pci_rd                  ; SATACR1
        mov     al, cl
        and     al, SATACR1_BARLOC
        cmp     al, SATACR1_BARLOC_CFG
        jne     .iobar
        movzx   eax, word [pci_bdf]     ; index at cap+8, data at cap+0Ch
        shl     eax, 8
        or      eax, 80000000h
        movzx   edx, byte [sata_cap]
        add     dl, 8
        or      eax, edx
        mov     [idp_cfg], eax
        mov     byte [idp_cfg_ok], 1
        jmp     .done
.iobar: cmp     al, 4
        jb      .done
        cmp     al, 9
        ja      .done
        shr     ecx, 4                  ; BAROFST in dwords
        and     ecx, 0FFFFFh
        shl     ecx, 2
        mov     edx, ecx
        movzx   di, al
        shl     di, 2                   ; BARLOC 4..9 -> config 10h..24h
        call    pci_rd
        test    cl, 1
        jz      .done                   ; must be an I/O BAR
        and     cl, 0FCh
        add     ecx, edx
        mov     [idp_port], cx
        mov     di, PCI_CMD             ; I/O decode on
        call    pci_rd
        test    cl, PCI_CMD_IO
        jnz     .io_on
        or      cl, PCI_CMD_IO
        call    pci_wr
.io_on: mov     byte [idp_io_ok], 1
.done:  clc
        ret
.nopci: mov     si, msg_no_pci
        stc
        ret
.noctl: mov     si, msg_no_ctl
        stc
        ret
.badbar:
        mov     si, msg_bad_bar
        stc
        ret

; DI = register -> ECX
pci_rd: push    ax
        push    bx
        mov     bx, [pci_bdf]
        mov     ax, 0B10Ah
        int     1Ah
        pop     bx
        pop     ax
        ret

; DI = register, ECX = value
pci_wr: push    ax
        push    bx
        mov     bx, [pci_bdf]
        mov     ax, 0B10Dh
        int     1Ah
        pop     bx
        pop     ax
        ret

;-----------------------------------------------------------------------------
; Pick the register access method.  CF and SI = message on failure.
;-----------------------------------------------------------------------------
choose_method:
        mov     al, [opt_method]
        cmp     al, AM_NONE
        jne     .forced
        mov     al, AM_IDP_IO
        cmp     byte [idp_io_ok], 0
        jne     .set
        mov     al, AM_IDP_CFG
        cmp     byte [idp_cfg_ok], 0
        jne     .set
        mov     al, AM_FLAT
        cmp     byte [is_v86], 0
        je      .set
        mov     al, AM_BIOS
        jmp     .set
.forced:
        cmp     al, AM_IDP_IO
        jne     .f1
        cmp     byte [idp_io_ok], 0
        je      .unavail
.f1:    cmp     al, AM_IDP_CFG
        jne     .f2
        cmp     byte [idp_cfg_ok], 0
        je      .unavail
.f2:    cmp     al, AM_FLAT
        jne     .set
        cmp     byte [is_v86], 0
        jne     .unavail
.set:   mov     [acc_method], al
        movzx   bx, al
        add     bx, bx
        mov     ax, [rd_table+bx]
        mov     [rd_vec], ax
        mov     ax, [wr_table+bx]
        mov     [wr_vec], ax
        cmp     byte [acc_method], AM_FLAT
        jne     .ok
        call    a20_test
        jnz     .a20ok
        call    a20_enable
        call    a20_test
        jnz     .a20ok
        mov     si, msg_no_a20
        stc
        ret
.a20ok: call    flat_enable
.ok:    clc
        ret
.unavail:
        mov     si, msg_bad_method
        stc
        ret

rd_table        dw      rd_idp_io, rd_idp_cfg, rd_flat, rd_bios
wr_table        dw      wr_idp_io, wr_idp_cfg, wr_flat, wr_bios

;-----------------------------------------------------------------------------
; HBA setup and report.  CF and SI = message on failure.
;-----------------------------------------------------------------------------
init_hba:
        mov     ax, HBA_CAP
        call    reg_rd
        mov     [hba_cap], eax
        cmp     eax, -1
        je      .dead
        mov     ax, HBA_VS
        call    reg_rd
        mov     [hba_vs], eax
        mov     ax, HBA_PI
        call    reg_rd
        mov     [hba_pi], eax
        mov     ax, HBA_GHC
        call    reg_rd
        test    eax, GHC_AE
        jnz     .ae
        mov     ecx, eax
        or      ecx, GHC_AE
        mov     ax, HBA_GHC
        call    reg_wr
.ae:
        cmp     byte [opt_quiet], 0
        jne     .ok
        mov     si, msg_ctl1
        call    print
        mov     eax, [hba_vs]
        shr     eax, 16
        call    print_dec
        mov     al, '.'
        call    putc
        mov     ax, [hba_vs]
        shr     ax, 8
        call    print_dec
        mov     si, msg_ctl2
        call    print
        mov     ax, [pci_vendev]
        call    print_hex16
        mov     al, ':'
        call    putc
        mov     ax, [pci_vendev+2]
        call    print_hex16
        mov     si, msg_ctl3
        call    print
        mov     al, [pci_bdf+1]
        call    print_hex8
        mov     al, ':'
        call    putc
        mov     al, [pci_bdf]
        shr     al, 3
        call    print_hex8
        mov     al, '.'
        call    putc
        mov     al, [pci_bdf]
        and     al, 7
        add     al, '0'
        call    putc
        mov     si, msg_ctl4
        call    print
        mov     eax, [abar]
        call    print_hex32
        mov     si, msg_ctl5
        call    print
        movzx   bx, byte [acc_method]
        add     bx, bx
        mov     si, [method_names+bx]
        call    print
        cmp     byte [vds_ok], 0
        je      .novds
        mov     si, msg_vds
        call    print
.novds: mov     si, msg_crlf
        call    print
.ok:    clc
        ret
.dead:  mov     si, msg_dead
        stc
        ret

method_names    dw      msg_m_io, msg_m_cfg, msg_m_flat, msg_m_bios

;-----------------------------------------------------------------------------
; Scan the implemented ports for ATAPI devices
;-----------------------------------------------------------------------------
scan_ports:
        mov     byte [port_num], 0
.next:  movzx   ecx, byte [port_num]
        cmp     cx, 32
        jae     .done
        mov     eax, [hba_pi]
        bt      eax, ecx
        jnc     .skip
        mov     bp, cx
        shl     bp, 7
        add     bp, PORT_BASE
        call    probe_port
.skip:  inc     byte [port_num]
        jmp     .next
.done:  ret

; probe port BP
probe_port:
        lea     ax, [bp+PxSSTS]
        call    reg_rd
        and     al, SSTS_DET
        cmp     al, SSTS_DET_PRESENT
        je      .present
        test    byte [hba_cap+3], CAP_SSS >> 24
        jz      .nodev
        lea     ax, [bp+PxCMD]          ; staggered spin-up: spin it up
        call    reg_rd
        test    al, PxCMD_SUD
        jnz     .nodev
        mov     ecx, eax
        or      cl, PxCMD_SUD
        lea     ax, [bp+PxCMD]
        call    reg_wr
        lea     ax, [bp+PxSSTS]
        mov     ecx, SSTS_DET
        mov     edx, SSTS_DET_PRESENT
        mov     bx, 19
        call    wait_reg
        jc      .nodev
.present:
        lea     ax, [bp+PxSIG]
        call    reg_rd
        cmp     eax, SIG_ATAPI
        je      .atapi
        cmp     eax, SIG_ATA
        jne     .try                    ; no or odd signature: ask the device
        cmp     byte [opt_verbose], 0
        je      .out
        mov     si, msg_ata_disk
        call    print_port_msg
        jmp     .out
.try:
.atapi:
        movzx   bx, byte [dev_count]
        cmp     bx, MAX_DEV
        jae     .full
        mov     di, bx
        add     di, di
        mov     [dev_port+di], bp
        mov     al, [port_num]
        mov     [dev_pnum+bx], al
        mov     byte [dev_flags+bx], 0

        call    identify_packet
        jc      .noid
        call    inquiry_dev
        inc     byte [dev_count]
        cmp     byte [opt_quiet], 0
        jne     .out
        call    print_dev
        jmp     .out
.noid:  cmp     byte [opt_verbose], 0
        je      .out
        mov     si, msg_id_fail
        call    print_port_msg
        jmp     .out
.full:  mov     si, msg_too_many
        call    print_port_msg
        jmp     .out
.nodev: cmp     byte [opt_verbose], 0
        je      .out
        mov     si, msg_no_link
        call    print_port_msg
.out:   ret

;-----------------------------------------------------------------------------
; Add IDE channel AX (command block), DX (control block port: alternate
; status / device control).  Ignores duplicates and a full list.
;-----------------------------------------------------------------------------
add_ide_ch:
        push    bx
        push    cx
        or      ax, ax
        jz      .out
        xor     bx, bx
        movzx   cx, byte [ide_count]
        jcxz    .add
.dup:   cmp     [ide_bases+bx], ax
        je      .out
        add     bx, 2
        loop    .dup
.add:   cmp     byte [ide_count], MAX_IDE_CH
        jae     .out
        mov     [ide_bases+bx], ax
        mov     [ide_ctls+bx], dx
        inc     byte [ide_count]
.out:   pop     cx
        pop     bx
        ret

;-----------------------------------------------------------------------------
; Find the channels of PCI IDE / RAID controllers (SiI0680, CMD646, Promise,
; HighPoint, ITE8212, VIA, ...).  They are not in any BIOS table, but their
; task file registers are in I/O BARs: BAR0/BAR1 primary, BAR2/BAR3
; secondary (command block / control block, alternate status at +2).
;   class 0101 (IDE): only the channels in native mode (prog-if bits 0, 2);
;                     compatibility channels are 1F0h / 170h anyway
;   class 0104 (RAID), 0180 (other mass storage): every I/O BAR pair
; AHCI, SCSI, SAS and NVMe controllers are left alone.
;-----------------------------------------------------------------------------
scan_pci_ide:
        mov     ax, 0B101h
        xor     edi, edi
        int     1Ah
        jc      .out
        cmp     edx, 'PCI '
        jne     .out
        mov     [pci_lastbus], cl
        xor     bx, bx                  ; bus:devfn
.dev:   mov     [pci_bdf], bx
        xor     di, di
        call    pci_rd                  ; vendor / device
        cmp     cx, 0FFFFh
        jne     .present
        test    bl, 7                   ; no function 0: skip the device
        jnz     .next
        or      bl, 7
        jmp     .next
.present:
        mov     [pci_vendev], ecx
        mov     di, 08h
        call    pci_rd                  ; class / subclass / prog-if
        shr     ecx, 8
        mov     dl, cl                  ; prog-if
        shr     ecx, 8                  ; CX = class:subclass
        cmp     cx, 0101h
        je      .ide
        cmp     cx, 0104h
        je      .raid
        cmp     cx, 0180h
        je      .raid
        jmp     .func0
.ide:   test    dl, 01h                 ; primary in native mode?
        jz      .ide2
        mov     di, PCI_BAR0
        call    pci_channel
.ide2:  test    dl, 04h                 ; secondary in native mode?
        jz      .func0
        mov     di, PCI_BAR0 + 8
        call    pci_channel
        jmp     .func0
.raid:  mov     di, PCI_BAR0
        call    pci_channel
        mov     di, PCI_BAR0 + 8
        call    pci_channel
.func0: test    bl, 7                   ; single function device: skip 1..7
        jnz     .next
        mov     di, 0Ch
        call    pci_rd
        test    ecx, 00800000h          ; header type bit 7: multi-function
        jnz     .next
        or      bl, 7
.next:  inc     bl
        jnz     .dev
        cmp     bh, [pci_lastbus]
        jae     .out
        inc     bh
        jmp     .dev
.out:   ret

; channel from the I/O BAR pair at config register DI (command block) and
; DI+4 (control block) of device [pci_bdf]
pci_channel:
        push    bx
        push    dx
        call    pci_rd
        test    cl, 1                   ; must be an I/O BAR
        jz      .out
        and     cl, 0FCh
        mov     bx, cx
        add     di, 4
        call    pci_rd
        test    cl, 1
        jz      .out
        and     cl, 0FCh
        mov     dx, cx
        add     dx, 2                   ; alternate status / device control
        mov     ax, bx
        or      ax, ax
        jz      .out
        mov     di, PCI_CMD             ; I/O decoding must be on
        call    pci_rd
        test    cl, PCI_CMD_IO
        jnz     .add
        or      cl, PCI_CMD_IO
        call    pci_wr
.add:   call    add_ide_ch
        cmp     byte [opt_verbose], 0
        je      .out
        push    si
        mov     si, msg_pci_ide
        call    print
        mov     ax, [pci_vendev]
        call    print_hex16
        mov     al, ':'
        call    putc
        mov     ax, [pci_vendev+2]
        call    print_hex16
        mov     si, msg_pci_ch
        call    print
        mov     ax, bx
        call    print_hex16
        mov     al, '/'
        call    putc
        mov     ax, dx
        call    print_hex16
        mov     si, msg_crlf
        call    print
        pop     si
.out:   pop     dx
        pop     bx
        ret

;-----------------------------------------------------------------------------
; Scan the classic IDE channels for ATAPI devices
;-----------------------------------------------------------------------------
scan_ide:
        xor     si, si
.chan:  movzx   ax, byte [ide_count]
        add     ax, ax
        cmp     si, ax
        jae     .done
        mov     ax, [ide_bases+si]
        or      ax, ax
        jz      .next
        mov     [ide_base], ax
        mov     ax, [ide_ctls+si]
        mov     [ide_ctl], ax
        mov     dx, [ide_base]          ; nothing decoded at this port?
        add     dx, IDE_STATUS
        in      al, dx
        cmp     al, 0FFh
        je      .next
        mov     byte [ide_sel], 0A0h
        call    probe_ide
        mov     byte [ide_sel], 0B0h
        call    probe_ide
.next:  add     si, 2
        jmp     .chan
.done:  ret

; probe the device ide_base / ide_sel
probe_ide:
        push    si
        movzx   bx, byte [dev_count]
        cmp     bx, MAX_DEV
        jae     .out
        mov     di, bx
        add     di, di
        mov     ax, [ide_base]
        mov     [dev_port+di], ax
        mov     ax, [ide_ctl]
        mov     [dev_ctl+di], ax
        mov     al, [ide_sel]
        mov     [dev_sel+bx], al
        mov     byte [dev_trans+bx], TR_IDE
        mov     byte [dev_flags+bx], 0
        call    identify_packet
        jc      .out
        and     byte [dev_flags+bx], ~(DF_DMA | DF_DMADIR)  ; PIO only
        call    inquiry_dev
        inc     byte [dev_count]
        cmp     byte [opt_quiet], 0
        jne     .out
        call    print_dev
.out:   pop     si
        ret

; IDENTIFY PACKET DEVICE on IDE device BX into the bounce buffer.  CF if
; there is no ATAPI device.
ide_identify:
        pushad
        call    ide_setdev
        call    ide_irq_off
        mov     dx, IDE_SELECT
        call    ide_port
        mov     al, [ide_sel]
        out     dx, al
        call    ide_delay
        mov     ax, (TFD_BSY | TFD_DRQ) << 8
        mov     ecx, 19
        call    ide_wait
        jc      .fail
        mov     dx, IDE_COMMAND
        call    ide_port
        mov     al, ATA_IDENTIFY_PACKET
        out     dx, al
        call    ide_delay
        mov     ax, TFD_BSY << 8
        mov     ecx, 19
        call    ide_wait
        jc      .fail
        test    al, TFD_ERR
        jnz     .fail
        test    al, TFD_DRQ
        jz      .fail
        mov     dx, IDE_DATA
        call    ide_port
        push    es
        push    cs
        pop     es
        mov     di, [bounce_ptr]
        mov     cx, 256
        rep     insw
        pop     es
        call    ide_irq_on
        popad
        clc
        ret
.fail:  call    ide_irq_on
        popad
        stc
        ret

print_port_msg:
        push    si
        mov     si, msg_port
        call    print
        movzx   ax, byte [port_num]
        call    print_dec
        pop     si
        jmp     print

; IDENTIFY PACKET DEVICE for device BX.  Sets flags/type.  CF on failure.
identify_packet:
        cmp     byte [dev_trans+bx], TR_IDE
        jne     .ahci
        call    ide_identify
        jc      .fail
        jmp     .parse
.ahci:  call    prd_clear
        mov     eax, [phys_bounce]
        mov     ecx, 512
        call    prd_add
        mov     byte [x_atapi], 0
        mov     byte [x_cmd], ATA_IDENTIFY_PACKET
        mov     byte [x_feat], 0
        mov     byte [x_write], 0
        mov     word [x_bcl], 0
        mov     si, [bounce_ptr]
        mov     word [si], 0
        call    ahci_exec
        cmp     al, XR_OK
        jne     .fail
.parse: mov     si, [bounce_ptr]
        mov     ax, [si]                ; word 0
        and     ax, ID_W0_PKT_MASK
        cmp     ax, ID_W0_ATAPI
        jne     .fail
        mov     ax, [si]
        mov     al, ah
        and     al, 1Fh                 ; device type from word 0
        mov     [dev_type+bx], al
        xor     dl, dl
        test    byte [si], ID_W0_CDB16
        jz      .c12
        or      dl, DF_CDB16
.c12:   cmp     byte [opt_pio], 0
        jne     .nodma
        test    word [si+49*2], ID_W49_DMA
        jz      .nodma
        or      dl, DF_DMA
        test    word [si+62*2], ID_W62_DMADIR
        jz      .nodma
        or      dl, DF_DMADIR
.nodma: mov     [dev_flags+bx], dl
        ; model string, words 27..46, byte swapped
        push    di
        add     si, 27*2
        mov     di, id_model
        mov     cx, 20
.model: mov     ax, [si]
        xchg    al, ah
        mov     [di], ax
        add     si, 2
        add     di, 2
        loop    .model
        mov     byte [di], 0
        pop     di
        clc
        ret
.fail:  stc
        ret

; INQUIRY for device BX (retried for unit attention).  Updates the type.
inquiry_dev:
        mov     cx, 4
.retry: push    cx
        xor     eax, eax
        mov     [cdb_buf], eax
        mov     [cdb_buf+4], eax
        mov     [cdb_buf+8], eax
        mov     [cdb_buf+12], eax
        mov     byte [cdb_buf], SCSI_INQUIRY
        mov     byte [cdb_buf+4], 36
        mov     ecx, 36
        xor     dl, dl
        call    packet_bounce
        pop     cx
        cmp     al, XR_OK
        je      .ok
        loop    .retry
        ret
.ok:    mov     si, [bounce_ptr]
        mov     al, [si]
        and     al, 1Fh
        mov     [dev_type+bx], al
        ret

; print the line for device BX
print_dev:
        push    bx
        mov     si, msg_id
        call    print
        mov     ax, bx
        call    print_dec
        cmp     byte [dev_trans+bx], TR_IDE
        je      .ide
        mov     si, msg_port
        call    print
        mov     al, [dev_pnum+bx]
        xor     ah, ah
        call    print_dec
        jmp     .loc
.ide:   mov     si, msg_ide
        call    print
        mov     di, bx
        add     di, di
        mov     ax, [dev_port+di]
        call    print_hex16
        mov     si, msg_master
        cmp     byte [dev_sel+bx], 0A0h
        je      .ms
        mov     si, msg_slave
.ms:    call    print
.loc:   mov     si, msg_colon
        call    print
        mov     si, id_model            ; trimmed model string
        call    print_trim
        mov     si, msg_open
        call    print
        mov     al, [dev_type+bx]
        cmp     al, 0Fh
        jbe     .known
        mov     al, 0Fh
.known: movzx   di, al
        add     di, di
        mov     si, [type_names+di]
        call    print
        mov     si, msg_dma
        test    byte [dev_flags+bx], DF_DMA
        jnz     .mode
        mov     si, msg_pio
.mode:  call    print
        pop     bx
        ret

type_names      dw      t_disk, t_tape, t_other, t_other, t_worm, t_cdrom
                dw      t_other, t_optical, t_other, t_other, t_other
                dw      t_other, t_other, t_other, t_other, t_other

;-----------------------------------------------------------------------------
; Output helpers (init only)
;-----------------------------------------------------------------------------
putc:   push    ax
        push    dx
%ifdef E9LOG
        out     0E9h, al
%endif
        mov     dl, al
        mov     ah, 2
        int     21h
        pop     dx
        pop     ax
        ret

print:  push    ax
        push    si
.l:     mov     al, [si]
        or      al, al
        jz      .e
        call    putc
        inc     si
        jmp     .l
.e:     pop     si
        pop     ax
        ret

; print an ASCIZ string without trailing blanks and leading blanks
print_trim:
        push    ax
        push    si
        push    di
.lead:  cmp     byte [si], ' '
        jne     .end
        inc     si
        jmp     .lead
.end:   mov     di, si
.find:  cmp     byte [di], 0
        je      .back
        inc     di
        jmp     .find
.back:  cmp     di, si
        je      .out
        cmp     byte [di-1], ' '
        jne     .pr
        dec     di
        jmp     .back
.pr:    mov     al, [si]
        call    putc
        inc     si
        cmp     si, di
        jb      .pr
.out:   pop     di
        pop     si
        pop     ax
        ret

print_hex32:
        push    eax
        shr     eax, 16
        call    print_hex16
        pop     eax
print_hex16:
        push    ax
        mov     al, ah
        call    print_hex8
        pop     ax
print_hex8:
        push    ax
        shr     al, 4
        call    .nib
        pop     ax
        push    ax
        and     al, 0Fh
        call    .nib
        pop     ax
        ret
.nib:   add     al, '0'
        cmp     al, '9'
        jbe     .p
        add     al, 7
.p:     jmp     putc

print_dec:                              ; AX
        push    ax
        push    cx
        push    dx
        push    bx
        mov     bx, 10
        xor     cx, cx
.div:   xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .div
.out:   pop     ax
        add     al, '0'
        call    putc
        loop    .out
        pop     bx
        pop     dx
        pop     cx
        pop     ax
        ret


;-----------------------------------------------------------------------------
; Messages
;-----------------------------------------------------------------------------
msg_banner      db      'AHCIASPI ', VERSION_STR
                db      ' - ASPI manager for ATAPI devices on AHCI', 13, 10, 0
msg_no386       db      '386 or better required', 13, 10, 0
msg_no_pci      db      'No PCI BIOS', 13, 10, 0
msg_no_ctl      db      'No AHCI controller found', 13, 10, 0
msg_bad_bar     db      'AHCI controller has no memory BAR', 13, 10, 0
msg_dead        db      'AHCI registers not accessible', 13, 10, 0
msg_vds_fail    db      'VDS lock of DMA buffers failed', 13, 10, 0
msg_biosfix     db      '  BIOS VDS fix for the AHCI firmware active', 13, 10, 0
msg_fix_only    db      '  no ATAPI devices: only the BIOS VDS fix stays resident', 13, 10, 0
msg_bad_method  db      'Requested access method not available', 13, 10, 0
msg_no_a20      db      'Cannot enable A20 for flat mode', 13, 10, 0
msg_no_dev      db      'No ATAPI devices found', 13, 10, 0
msg_not_inst    db      'AHCIASPI not installed', 13, 10, 0
msg_bad_opt     db      'Unknown option ignored', 13, 10, 0
msg_ctl1        db      'AHCI ', 0
msg_ctl2        db      ' controller ', 0
msg_ctl3        db      ' at PCI ', 0
msg_ctl4        db      ', ABAR ', 0
msg_ctl5        db      ', access: ', 0
msg_m_io        db      'index/data I/O', 0
msg_m_cfg       db      'index/data config', 0
msg_m_flat      db      'flat mode', 0
msg_m_bios      db      'INT 15h', 0
msg_vds         db      ', VDS', 0
msg_crlf        db      13, 10, 0
msg_port        db      '  port ', 0
msg_id          db      '  ID ', 0
msg_colon       db      ': ', 0
msg_ide         db      '  IDE ', 0
msg_chain1      db      'Chained to ASPI manager "', 0
msg_chain2      db      '", ', 0
msg_chain3      db      ' adapter(s); this is host adapter ', 0
msg_pci_ide     db      '  PCI IDE ', 0
msg_pci_ch      db      ' channel ', 0
msg_master      db      ' master', 0
msg_slave       db      ' slave', 0
msg_open        db      ' (', 0
msg_dma         db      ', DMA)', 13, 10, 0
msg_pio         db      ', PIO)', 13, 10, 0
msg_ata_disk    db      ': ATA disk, ignored', 13, 10, 0
msg_id_fail     db      ': IDENTIFY PACKET failed', 13, 10, 0
msg_too_many    db      ': too many devices, ignored', 13, 10, 0
msg_no_link     db      ': no device', 13, 10, 0
t_disk          db      'direct access', 0
t_tape          db      'tape', 0
t_worm          db      'WORM', 0
t_cdrom         db      'CD/DVD', 0
t_optical       db      'optical', 0
t_other         db      'other', 0
