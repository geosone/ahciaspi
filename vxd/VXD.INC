;--- VXD.INC: definitions for the AHCIVXD Windows 3.1 virtual device,
;--- written from the documented interfaces of VMM, BlockDev and Int13
;--- (service numbers = positions in the Windows 3.1 service tables).
;--- Copyright (C) 2026 GeosOne.  GNU General Public License version 3.

DDK_VERSION          equ 030Ah
UNDEFINED_DEVICE_ID  equ 0
UNDEF_TOUCH_MEM_INIT_ORDER equ 0A8000000h

VMM_DEVICE_ID      equ 0001h
VPICD_DEVICE_ID    equ 0003h
BLOCKDEV_DEVICE_ID equ 0010h
SHELL_DEVICE_ID    equ 0017h
INT13_DEVICE_ID    equ 0020h

;--- device descriptor block (Windows 3.1 layout)
VxD_Desc_Block struct
DDB_Next               dd ?
DDB_SDK_Version        dw ?
DDB_Req_Device_Number  dw ?
DDB_Dev_Major_Version  db ?
DDB_Dev_Minor_Version  db ?
DDB_Flags              dw ?
DDB_Name               db 8 dup (?)
DDB_Init_Order         dd ?
DDB_Control_Proc       dd ?
DDB_V86_API_Proc       dd ?
DDB_PM_API_Proc        dd ?
DDB_V86_API_CSIP       dd ?
DDB_PM_API_CSIP        dd ?
DDB_Reference_Data     dd ?
DDB_Service_Table_Ptr  dd ?
DDB_Service_Table_Size dd ?
VxD_Desc_Block ends

;--- system control messages
SYS_CRITICAL_INIT  equ 00h
DEVICE_INIT        equ 01h
INIT_COMPLETE      equ 02h
SYSTEM_EXIT        equ 05h
SYS_CRITICAL_EXIT  equ 06h

;--- VM control block
CB_High_Linear     equ 4

;--- client registers (EBP in V86 hooks)
Client_EDI   equ 00h
Client_ESI   equ 04h
Client_EBP   equ 08h
Client_EBX   equ 10h
Client_EDX   equ 14h
Client_ECX   equ 18h
Client_EAX   equ 1Ch
Client_EIP   equ 24h
Client_CS    equ 28h
Client_EFlags equ 2Ch
Client_ESP   equ 30h
Client_SS    equ 34h
Client_ES    equ 38h
Client_DS    equ 3Ch

;--- service ids: device shl 16 + position in the service table
@VMM macro name, num
name equ (VMM_DEVICE_ID shl 16) + num
endm
@VMM Get_Cur_VM_Handle,        001h
@VMM Get_Sys_VM_Handle,        003h
@VMM Allocate_V86_Call_Back,   00Bh
@VMM Hook_V86_Int_Chain,       041h
@VMM _HeapAllocate,            04Fh
@VMM _PageAllocate,            053h
@VMM _CopyPageTable,           061h
@VMM _MapPhysToLinear,         06Ch
@VMM Get_Profile_Decimal_Int,  0ABh
@VMM Get_Profile_Boolean,      0B1h
@VMM Fatal_Error_Handler,      0BEh
@VMM Begin_Nest_V86_Exec,      082h
@VMM Exec_Int,                 084h
@VMM End_Nest_Exec,            086h
@VMM Save_Client_State,        08Dh
@VMM Restore_Client_State,     08Eh
@VMM _Allocate_Temp_V86_Data_Area, 0A9h
@VMM _Free_Temp_V86_Data_Area, 0AAh
@VMM Get_Last_Updated_System_Time, 0CFh

@BLOCKDEV macro name, num
name equ (BLOCKDEV_DEVICE_ID shl 16) + num
endm
@BLOCKDEV BlockDev_Get_Version,          0
@BLOCKDEV BlockDev_Register_Device,      1
@BLOCKDEV BlockDev_Find_Int13_Drive,     2
@BLOCKDEV BlockDev_Get_Device_List,      3
@BLOCKDEV BlockDev_Send_Command,         4
@BLOCKDEV BlockDev_Command_Complete,     5
@BLOCKDEV BlockDev_Synchronous_Command,  6

;--- dynamic link: INT 20h followed by the service id (patched by VMM)
VMMcall macro service
	int 20h
	dd service
endm
VxDcall equ <VMMcall>
