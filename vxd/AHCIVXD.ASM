;--- AHCIVXD.ASM: Windows 3.1x enhanced mode "FastDisk" for hard disks on
;--- IDE and AHCI controllers (32-bit disk access).  Device descriptor
;--- block, system control dispatcher, the BlockDev entry points and C
;--- callable wrappers for VMM and BlockDev services.  The disk code is in
;--- AHCIVXD.C (cdecl, Open Watcom -ecc).
;---
;--- Copyright (C) 2026 GeosOne.  GNU General Public License version 3.

	.386p
	.model flat, c
	option casemap:none

	include VXD.INC

AHCIVXD_MAJOR equ 0
AHCIVXD_MINOR equ 1
;--- like WDCTRL (the disks are registered in Sys_Critical_Init)
AHCIVXD_INIT_ORDER equ 0A8000000h

ahci_sys_critical_init proto c :dword
ahci_device_init       proto c
ahci_command           proto c :dword, :dword
ahci_v86_int13         proto c :dword, :dword
ahci_system_exit       proto c
ahci_dos13             proto c :dword, :dword
ahci_v86_int4b         proto c :dword, :dword
ahci_unswap            proto c :dword, :dword

	.code

;--- Every entry from the VMM clears the direction flag: the C code assumes
;--- DF = 0, but VMM may call us while a VM runs with DF = 1.

;--- system control: EAX = message, EBX = VM handle, EDX = reference data
control_proc proc
	cld
	mov [client_ptr], ebp	;client registers of the system VM
	cmp eax, SYS_CRITICAL_INIT
	jz m_sci
	cmp eax, DEVICE_INIT
	jz m_di
	cmp eax, SYSTEM_EXIT
	jz m_sx
	clc
	ret
m_sci:
	pushad
	invoke ahci_sys_critical_init, edx	;EDX = reference data (AHCIRMI.ASM)
	jmp done
m_di:
	pushad
	call ahci_device_init
	jmp done
m_sx:
	pushad
	call ahci_system_exit
done:
	cmp eax, 1	;C returns 0 = ok -> CF=1 only if eax != 0
	cmc
	popad
	ret
control_proc endp

;--- BlockDev command procedure: EDI -> BDD, ESI -> command block.  Called
;--- with interrupts disabled; completes the command with
;--- BlockDev_Command_Complete (from the C side).
command_proc proc
	pushad
	cld
	invoke ahci_command, edi, esi
	popad
	ret
command_proc endp

;--- BlockDev hardware interrupt procedure (BlockDev virtualizes the disk
;--- IRQ and calls this first): EAX = IRQ handle, EDI -> BDD.  AHCIVXD
;--- works polled with interrupts off at the drive, so an interrupt is never
;--- ours: CF set, BlockDev passes it on (to the BIOS of the VM).
hw_int_proc proc
	stc
	ret
hw_int_proc endp

;--- BlockDev synchronous command: AX = command, only Get_Version (0)
sync_cmd_proc proc
	test ax, ax
	jnz @F
	mov ax, AHCIVXD_MAJOR * 100h + AHCIVXD_MINOR
	clc
	ret
@@:	mov ax, 1	;BD_SC_Err_Invalid_Cmd
	stc
	ret
sync_cmd_proc endp

;--- V86 INT 13h hook (extended functions of our drives): EBX = VM,
;--- EBP -> client registers.  CF clear = handled, CF set = pass on.
int13_hook proc
	pushad
	cld
	invoke ahci_v86_int13, ebx, ebp
	cmp eax, 1	;0 = handled -> CF = 0, else CF = 1
	cmc
	popad
	ret
int13_hook endp

;--- V86 callback: MS-DOS calls the BIOS INT 13h code directly through its
;--- pointer (INT 2Fh AH=13h), which points here: EBX = VM, EBP -> client
;--- registers (ahci_dos13 handles our disks or continues at the old code)
dos13_callback proc
	pushad
	cld
	invoke ahci_dos13, ebx, ebp
	popad
	ret
dos13_callback endp

;--- V86 INT 4Bh hook (BIOS VDS fix): passes everything on (CF set), after
;--- fixing the bad calls of Intel AHCI firmware (ahci_v86_int4b)
int4b_hook proc
	pushad
	cld
	invoke ahci_v86_int4b, ebx, ebp
	popad
	stc
	ret
int4b_hook endp

;--- V86 callback: the fixed VDS unlock returns here (ahci_unswap)
unswap_callback proc
	pushad
	cld
	invoke ahci_unswap, ebx, ebp
	popad
	ret
unswap_callback endp

;--- C callable services ------------------------------------------------

;--- int vxd_hook_int4b(void): V86 INT 4Bh hook, 0 = ok
vxd_hook_int4b proc uses esi
	mov eax, 4Bh
	mov esi, offset int4b_hook
	VMMcall Hook_V86_Int_Chain
	sbb eax, eax
	ret
vxd_hook_int4b endp

;--- unsigned vxd_unswap_callback(void): V86 callback, seg:off or 0
vxd_unswap_callback proc uses esi
	mov esi, offset unswap_callback
	xor edx, edx
	VMMcall Allocate_V86_Call_Back
	jnc @F
	xor eax, eax
@@:	ret
vxd_unswap_callback endp

;--- unsigned vxd_v86_callback(void): V86 callback to dos13_callback,
;--- segment:offset or 0
vxd_v86_callback proc uses esi
	mov esi, offset dos13_callback
	xor edx, edx
	VMMcall Allocate_V86_Call_Back
	jnc @F
	xor eax, eax
@@:	ret
vxd_v86_callback endp

CLIENT_SIZE equ 6Ch	;Client_Reg_Struc

;--- struct v86regs (AHCIVXD.C)
R_EAX equ 0
R_EBX equ 4
R_ECX equ 8
R_EDX equ 12
R_ESI equ 16
R_EDI equ 20
R_DS  equ 24
R_ES  equ 26
R_FL  equ 28

;--- void vxd_exec_int(int intno, struct v86regs *r): software interrupt in
;--- the system VM (V86 mode, nested execution; Device_Init and later)
vxd_exec_int proc uses ebx esi edi ebp intno:dword, regs:dword
	mov esi, regs
	mov ebx, intno		;(the parameters are addressed through EBP)
	mov ebp, [client_ptr]
	sub esp, CLIENT_SIZE	;save the client state
	mov edi, esp
	VMMcall Save_Client_State
	VMMcall Begin_Nest_V86_Exec
	mov eax, [esi+R_EAX]
	mov [ebp+Client_EAX], eax
	mov eax, [esi+R_EBX]
	mov [ebp+Client_EBX], eax
	mov eax, [esi+R_ECX]
	mov [ebp+Client_ECX], eax
	mov eax, [esi+R_EDX]
	mov [ebp+Client_EDX], eax
	mov eax, [esi+R_ESI]
	mov [ebp+Client_ESI], eax
	mov eax, [esi+R_EDI]
	mov [ebp+Client_EDI], eax
	mov ax, [esi+R_DS]
	mov [ebp+Client_DS], ax
	mov ax, [esi+R_ES]
	mov [ebp+Client_ES], ax
	mov eax, ebx
	VMMcall Exec_Int
	mov eax, [ebp+Client_EAX]
	mov [esi+R_EAX], eax
	mov eax, [ebp+Client_EBX]
	mov [esi+R_EBX], eax
	mov eax, [ebp+Client_ECX]
	mov [esi+R_ECX], eax
	mov eax, [ebp+Client_EDX]
	mov [esi+R_EDX], eax
	mov eax, [ebp+Client_ESI]
	mov [esi+R_ESI], eax
	mov eax, [ebp+Client_EDI]
	mov [esi+R_EDI], eax
	mov ax, [ebp+Client_DS]
	mov [esi+R_DS], ax
	mov ax, [ebp+Client_ES]
	mov [esi+R_ES], ax
	mov eax, [ebp+Client_EFlags]
	mov [esi+R_FL], eax
	VMMcall End_Nest_Exec
	mov esi, esp		;restore the client state
	VMMcall Restore_Client_State
	add esp, CLIENT_SIZE
	ret
vxd_exec_int endp

;--- unsigned vxd_temp_v86(unsigned bytes): temporary V86 data area during
;--- Device_Init, linear address (< 1 MB) or 0
vxd_temp_v86 proc bytes:dword
	push 200h		;GVDAZeroInit
	push bytes
	VMMcall _Allocate_Temp_V86_Data_Area
	add esp, 8
	ret
vxd_temp_v86 endp

vxd_free_temp_v86 proc
	VMMcall _Free_Temp_V86_Data_Area
	ret
vxd_free_temp_v86 endp

;--- int vxd_register(BDD *): BlockDev_Register_Device, 0 = ok
vxd_register proc uses edi bdd:dword
	mov edi, bdd
	VxDcall BlockDev_Register_Device
	sbb eax, eax
	ret
vxd_register endp

;--- void vxd_complete(BDD *, BCB *): BlockDev_Command_Complete
vxd_complete proc uses esi edi bdd:dword, cmd:dword
	mov edi, bdd
	mov esi, cmd
	VxDcall BlockDev_Command_Complete
	ret
vxd_complete endp

;--- unsigned vxd_time(void): system time in milliseconds
vxd_time proc
	VMMcall Get_Last_Updated_System_Time
	ret
vxd_time endp

;--- int vxd_profile_int(const char *key, int default): [AHCIVXD] in SYSTEM.INI
vxd_profile_int proc uses esi edi key:dword, def:dword
	mov eax, def
	mov esi, offset szSection
	mov edi, key
	VMMcall Get_Profile_Decimal_Int
	ret
vxd_profile_int endp

;--- int vxd_hook_int13(void): hook V86 INT 13h, 0 = ok
vxd_hook_int13 proc uses esi
	mov eax, 13h
	mov esi, offset int13_hook
	VMMcall Hook_V86_Int_Chain
	sbb eax, eax
	ret
vxd_hook_int13 endp

;--- void *vxd_page_alloc(unsigned pages): fixed, zero-initialized memory
vxd_page_alloc proc uses ebx pages:dword
	push 1 or 8		;PageZeroInit, PageFixed
	push 0			;PhysAddrPtr
	push 0			;max phys page
	push 0			;min phys page
	push 0			;align mask
	push 0			;VM (not used for PG_SYS)
	push 1			;PG_SYS
	push pages
	VMMcall _PageAllocate
	add esp, 8*4
	or eax, eax
	jz @F
	mov eax, edx		;linear address
@@:
	ret
vxd_page_alloc endp

;--- unsigned vxd_lin_to_phys(void *lin): physical address (from the PTE)
vxd_lin_to_phys proc lin:dword
	local pte:dword
	push 0
	lea eax, pte
	push eax
	push 1
	mov eax, lin
	shr eax, 12
	push eax
	VMMcall _CopyPageTable
	add esp, 4*4
	mov eax, pte
	and eax, 0FFFFF000h
	mov ecx, lin
	and ecx, 0FFFh
	or eax, ecx
	ret
vxd_lin_to_phys endp

;--- void *vxd_map_phys(unsigned phys, unsigned size): -1 on error
vxd_map_phys proc physaddr:dword, size_:dword
	push 0
	push size_
	push physaddr
	VMMcall _MapPhysToLinear
	add esp, 3*4
	ret
vxd_map_phys endp

;--- unsigned vxd_high_linear(unsigned vm): linear base of a VM's memory
vxd_high_linear proc vm:dword
	mov eax, vm
	mov eax, [eax+CB_High_Linear]
	ret
vxd_high_linear endp

	.data

szSection db "AHCIVXD", 0
client_ptr dd 0

;--- the device descriptor block (exported as AHCIVXD_DDB)
	public AHCIVXD_DDB
AHCIVXD_DDB VxD_Desc_Block <0, DDK_VERSION, UNDEFINED_DEVICE_ID, AHCIVXD_MAJOR, AHCIVXD_MINOR, 0, \
	"AHCIVXD ", AHCIVXD_INIT_ORDER, offset control_proc, 0, 0, 0, 0, 0, 0, 0>

	public command_proc, sync_cmd_proc, hw_int_proc

	end
