;ÚÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ¿
;³                 Joe Forster/STA                 ³
;³                                                 ³
;³                   DLMANIP.ASM                   ³
;³                                                 ³
;³             Drive Letter Manipulator            ³
;ÀÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÙ

CSeg		segment
		assume	cs:CSeg, ds:CSeg, ss:CSeg
	ifdef DeviceDriver
		org	0000h			;Device drivers start at 0000h
	else
		org	0100h			;COM programs start at 0100h
	endif
		jumps				;Automatic jump sizing

;Boolean values
False		equ	0
True		equ	1

;Characters
chTab		equ	9			;Tab
chLF		equ	10			;Line feed
chCR		equ	13			;Carriage return
chDriveSep	equ	':'			;Colon, DOS drive separator
chDirSep	equ	'\'			;Backslash, DOS dir separator

;System constants
MinDOSVersion	equ	4			;Minimum DOS version number
WinDOSVersion	equ	7			;Windows DOS version number
MinDrives	equ	4			;Minimum number of drives
MaxDrives	equ	26			;Maximum number of drives
MaxPartitions	equ	32			;Maximum number of partitions
MaxHardDisks	equ	8			;Max number of phys hard disks
PartPerBootRec	equ	4			;Partitions per boot record
MaxNumStrLen	equ	10			;Maximum length for numbers
CmdParamSize	equ	80			;Max length of cmdline params
CmdLineSize	equ	128			;Max length of command line
VolLabLen	equ	11			;Max length of volume label
FSNameLen	equ	8			;Max len of file system name
OEMNameLen	equ	8			;Max len of OEM name/version
LastFloppyDisk	equ	03h			;Phys drive of last floppy
FirstHardDisk	equ	80h			;Phys drive of first hard disk
DefBytePerSec	equ	0200h			;Number of bytes per sector
BootSectorSign	equ	0AA55h			;Boot sector/record signature
DriveValidMask	equ	0C000h			;Attrib mask for valid drives

;DOS partition types
ptEmpty		equ	00h			;No partition defined
ptFAT12		equ	01h			;FAT12 partition
ptFAT16Max32MB	equ	04h			;Old FAT16 part, max. 32MB
ptExtended	equ	05h			;Extended partition
ptFAT16		equ	06h			;FAT16 partition
ptFAT32		equ	0Bh			;FAT32 partition
ptFAT32LBA	equ	0Ch			;FAT32 partition, LBA support
ptFAT16LBA	equ	0Eh			;FAT16 partition, LBA support
ptExtendedLBA	equ	0Fh			;Extended part, LBA support

;Special drive letters
dlAutoAssign	equ	0FFh			;Drive letter to auto assign
dlDelFlag	equ	80h			;Delete drive letter

;FreeDOS-specific drive flags
fdfDiskChange	equ	40h			;Disk change detected
fdfMultiLog	equ	10h			;Multiple logical drive (A:/B:)
fdfCurrentLog	equ	20h			;Drive is current of multiples

EntryPt		struc				;Routine entry point structure
epOffs		dw	?			;Entry offset
epPreExec	db	?			;Pre-exec flag
		ends

;Disk sector
Sector		struc
		db	(DefBytePerSec) dup (?)
		ends

;Partition table entry
PartitionEntry	struc
peActive	db	?			;Active/bootable flag
peStartHead	db	?			;Starting head
peStartCylSec	dw	?			;Starting cylinder and sector
peType		db	?			;Partition type
peEndHead	db	?			;Ending head
peEndCylSec	dw	?			;Ending cylinder and sector
peStartRelSec	dd	?			;Relative starting sector
peSize		dd	?			;Partition size in sectors
		ends
PartEntrySize	equ	type (PartitionEntry)

;Boot record
BootRecord	struc
brCode		db	(DefBytePerSec - 2 - PartPerBootRec * PartEntrySize) dup (?)
brPartTable	PartitionEntry (PartPerBootRec) dup (?)	;Partition table
brSignature	dw	?			;Boot record signature
		ends

;Data structure for extended disk functions
ExtDiskFuncPack	struc
xfSize		db	?			;Packet size
xfReserved	db	?
xfSectorNum	dw	?			;Number of sectors to process
xfDataBuffer	dd	?			;Pointer to data buffer
xfLBASectorLo	dd	?			;64-bit LBA sector number
xfLBASectorHi	dd	?
		ends
ExtDFPSize	equ	type (ExtDiskFuncPack)

;Device request header
DevReqHeader	struc
drSize		db	?			;Header size
drUnitNum	db	?			;Number of units in device
drCommand	db	?			;Command code
drStatus	dw	?			;Return status code
drReserved	db	8 dup (?)
drData		db	16 dup (?)		;Variable length data area
		ends

;Data for initializing devices
DevInitData	struc
diUnitNum	db	?			;Number of units in device
diResidentEnd	dd	?			;End of resident code
diCommandLine	dd	?			;Command line from CONFIG.SYS
diDriveNum	db	?			;Drive number for device
diErrorCode	dw	?			;If not zero, error is printed
		ends

;List of lists
ListList	struc
llDriveParBlock	dd	?			;First drive parameter block
llSysFileTable	dd	?			;First system file table
llCLOCKDevHdr	dd	?			;CLOCK$ device header
llCONDevHdr	dd	?			;CON device header
llBlkBytePerSec	dw	?			;Max bytes per sec in blkdevs
llDiskBufInfo	dd	?			;Disk buffer info record
llCurDirStruc	dd	?			;Current directory structures
llSysFCBTable	dd	?			;System FCB tables
llProtFCBNum	dw	?			;Number of protected FCB's
llBlockDevNum	db	?			;Number of block devices
llLastDrive	db	?			;Number of drive letters
;[...]						;...further entries omitted...
		ends

;File system information
FileSysInfo	struc
fiPhysDriveNum	db	?			;Physical drive number
fiReserved	db	?
fiSignature	db	?
fiSerialNum	dd	?			;Serial number
fiVolumeLabel	db	(VolLabLen + 1) dup (?)	;Volume label (space-padded)
fiFileSystem	db	(FSNameLen + 1) dup (?)	;File system name (spc-padded)
		ends

;Drive parameter block
DriveParBlock	struc
dpDriveNum	db	?			;Drive number
dpUnitNum	db	?			;Unit number into parent drive
dpBytePerSector	dw	?			;Number of bytes per sector
dpSectorPerClus	db	?			;Number of sectors per cluster
dpClusterShift	db	?			;Sectors per cluster shift
dpResSectorNum	dw	?			;Number of sectors before FAT
dpFATNum	db	?			;Number of FAT copies
dpRootDirLen	dw	?			;Number of root dir entries
dpFirstDataSec	dw	?			;First data sector
dpClusterNum	dw	?			;Number of clusters + 1
dpSectorPerFAT	dw	?			;Number of sectors per FAT
dpFirstDirSec	dw	?			;First root dir sector
dpDeviceHeader	dd	?			;Disk device header
dpMediaID	db	?			;Media descriptor byte
dpDiskAccessed	db	?			;Disk accessed flag
dpNextBlock	dd	?			;Next drive parameter block
dpFirstFreeClus	dw	?			;Start of free cluster search
dpFreeClusNum	dw	?			;Number of free clusters
		ends

;Current directory entry
CurDirEntry	struc
cdPath		db	67 dup (?)		;Path
cdAttrib	dw	?			;Attributes
cdDriveParBlock	dd	?			;Pointer to drive param block
cdCurDirCluster	dw	?			;Cluster of current directory
cdUnknown	dd	?
cdRootDirOffset	dw	?			;Offset of root dir into path
cdRemoteType	db	?			;Remote drive type
cdIFSDriver	dd	?			;Pointer to IFS driver
cdIFSDriverData	dw	?			;IFS driver work area
		ends
CurDirEntrySize	equ	type (CurDirEntry)

;BIOS parameter block
BIOSParBlock	struc
bbBytePerSector	dw	?			;Number of bytes per sector
bbSectorPerClus	db	?			;Number of sectors per cluster
bbResSectorNum	dw	?			;Number of sectors before FAT
bbFATNum	db	?			;Number of FAT copies
bbRootDirLen	dw	?			;Number of root dir entries
bbSectorNum	dw	?			;Total number of sectors
bbMediaID	db	?			;Media descriptor byte
bbSectorPerFAT	dw	?			;Number of sectors per FAT
bbSecPerTrack	dw	?			;Number of sectors per track
bbHeadNum	dw	?			;Number of heads
bbHiddenSecNum	dd	?			;Number of hidden sectors
bbExtSectorNum	dd	?			;Total number of sectors
		ends

;Boot sector
BootSector	struc
bsJumpToExec	db	3 dup (?)		;Jump to boot code
bsOEMNameVer	db	OEMNameLen dup (?)	;Format OS name and version
bsBIOSParBlock	BIOSParBlock <?>		;BIOS parameter block
bsFileSysInfo	FileSysInfo <?>			;File system information
		ends

;Windows-specific extended BIOS parameter block
ExtBIOSParBlock	struc
xbBIOSParBlock	BIOSParBlock <?>		;DOS-style BIOS param block
xbExtSecParFAT	dd	?			;Number of sectors per FAT
xbExtFlags	dw	?			;Extended flags
xbFileSysVer	dw	?			;File system version
xbRootDirClus	dd	?			;Root directory cluster
xbFSInfoSec	dw	?			;File system info sector
xbBakBootSec	dw	?			;Backup boot sector
xbReserved	db	6 dup (?)
		ends

;Windows-specific extended boot sector
ExtBootSector	struc
xsJumpToExec	db	3 dup (?)		;Jump to boot code
xsOEMNameVer	db	OEMNameLen dup (?)	;Format OS name and version
xsBIOSParBlock	ExtBIOSParBlock <?>		;BIOS parameter block
xsReserved	db	6 dup (?)
xsFileSysInfo	FileSysInfo <?>			;File system information
		ends

;Drive data entry
DrvDatEntry	struc
ddNextEntry	dd	?			;Next entry (offs=-1 for last)
ddPhysDriveNum	db	?			;Physical drive number
ddDriveNum	db	?			;Drive number
ddBIOSParBlock	BIOSParBlock <?>		;BIOS parameter block
ddFlags2	db	?			;Additional device flags
ddOpenCount	dw	?			;Counter of open connections
ddDeviceType	db	?			;Device type
ddFlags		dw	?			;Attributes
ddCylinderNum	dw	?			;Number of cylinders
ddBIOSParBlock2	BIOSParBlock <?>		;Secondary BIOS param block
ddBPB2Reserved	db	6 dup (?)
ddLastTrackAcc	db	?	  		;Last track number accessed
ddPartitionType	dw	?			;Partition type (unreliable)
ddStartingCyl	dw	?			;Starting cylinder into disk
ddVolumeLabel	db	(VolLabLen + 1) dup (?)	;Volume label (space-padded)
ddSerialNum	dd	?			;Serial number
ddFileSystem	db	(FSNameLen + 1) dup (?)	;File system name (spc-padded)
		ends

;FreeDOS-specific extended drive data entry
FDDrvDatEntry	struc
fdNextEntry	dd	?			;Next entry (offs=-1 for last)
fdPhysDriveNum	db	?			;Physical drive number
fdDriveNum	db	?			;Drive number
fdBIOSParBlock1	BIOSParBlock <?>		;BIOS param block (FAT16-style)
fdFlags2	db	?			;Additional device flags
fdReserved1	db	?
fdMediaID	db	?			;Media descriptor byte,
fdSerialNum1	dd	?			;  serial number and
fdVolumeLabel1	db	(VolLabLen + 1) dup (?)	;  volume label (only FAT12/16)
fdDeviceType	db	?			;Device type
fdFlags		dw	?			;Attributes
fdCylinderNum	dw	?			;Number of cylinders
fdBIOSParBlock	ExtBIOSParBlock <?>		;BIOS parameter block
fdLastTrackAcc	db	?	  		;Last track number accessed
fdDiskAccess	dd	?	  		;Union of various values
fdVolumeLabel	db	(VolLabLen + 1) dup (?)	;Volume label (space-padded)
fdSerialNum	dd	?			;Serial number
fdFileSystem	db	(FSNameLen + 1) dup (?)	;File system name (spc-padded)
fdStartingCyl	dw	?			;Starting cylinder into disk
		ends

;Windows-specific extended drive data entry
ExtDrvDatEntry	struc
xdNextEntry	dd	?			;Next entry (offs=-1 for last)
xdPhysDriveNum	db	?			;Physical drive number
xdDriveNum	db	?			;Drive number
xdBIOSParBlock	ExtBIOSParBlock <?>		;BIOS parameter block
xdFlags2	db	?			;Additional device flags
xdOpenCount	dw	?			;Counter of open connections
xdDeviceType	db	?			;Device type
xdFlags		dw	?			;Attributes
xdCylinderNum	dw	?			;Number of cylinders
xdBIOSParBlock2	ExtBIOSParBlock <?>		;Secondary BIOS param block
xdLastTrackAcc	db	?			;Last track number accessed
xdPartitionType	dw	?			;Partition type (unreliable)
xdStartingCyl	dw	?			;Starting cylinder into disk
xdVolumeLabel	db	(VolLabLen + 1) dup (?)	;Volume label (space-padded)
xdSerialNum	dd	?			;Serial number
xdFileSystem	db	(FSNameLen + 1) dup (?)	;File system name (spc-padded)
		ends

;Internal logical drive table entry
DriveEntry	struc
ldDriveParBlock	dd	?			;Pointer to drive param block
ldDrvDatEntry	dd	?			;Pointer to drive data entry
ldDriveNum	db	?			;Drive number
ldPhysDriveNum	db	?			;Physical drive number
ldPartNum	db	?			;Partition num in phys drive
ldAttrib	dw	?			;Drive attributes
ldVolumeLabel	db	(VolLabLen + 1) dup (?)	;Volume label
ldSerialNum	dd	?			;Serial number
ldFileSystem	db	(FSNameLen + 1) dup (?)	;File system name
ldCDS		CurDirEntry <?>
		ends
DrvEntrySize	equ	type (DriveEntry)

;Internal partition entry
PhysDrvEntry	struc
pdPhysDriveNum	db	?			;Physical drive number
pdPartNum	db	?			;Partition number
pdVolumeLabel	db	(VolLabLen + 1) dup (?)	;Volume label
pdSerialNum	dd	?			;Serial number
		ends
PhysDrvEntSize	equ	type (PhysDrvEntry)

Main:

;Device driver header
	ifdef DeviceDriver
NextDevice	dw	-1, -1			;No more devices in the chain
DeviceAttr	dw	8000h			;Character device
StratPtr	dw	Offset StratFunc	;Pointer to strategy routine
IntPtr		dw	Offset IntFunc		;Pointer to interrupt routine
DeviceName	db	'DLMANIP '		;Name of device (8 characters)

;Device driver strategy function
;  Input : ES:BX: device request header
StratFunc:	mov	word ptr cs:RequestHeader[0], bx	;Save header
		mov	word ptr cs:RequestHeader[2], es
		retf				;Return to caller

;Device driver interrupt function
IntFunc:	push	ds			;Save registeres
		push	es
		push	ax
		push	bx
		push	cx
		push	dx
		push	si
		push	di
		push	bp
		push	cs			;Setup own segments
		pop	ds
		push	cs
		pop	es
		push	es
		les	bx, RequestHeader	;Get device request header
		cmp	es:[bx].DevReqHeader.drCommand, 0	;If command is
		je	@01_IntFunc		; not "init", return "unknown
		mov	es:[bx].DevReqHeader.drStatus, 8103h	; command"
		jmp	@00_IntFunc		; error code
@01_IntFunc:	xor	ax, ax
		mov	es:[bx].DevReqHeader.drData.DevInitData.diUnitNum, al
						;No units in device
		mov	word ptr es:[bx].DevReqHeader.drData.DevInitData.diResidentEnd[0], ax
		mov	word ptr es:[bx].DevReqHeader.drData.DevInitData.diResidentEnd[2], cs
						;No code to keep resident
		mov	es:[bx].DevReqHeader.drData.DevInitData.diErrorCode, ax
						;No error message to print
		mov	es:[bx].DevReqHeader.drStatus, 0100h	;Success
		pop	es
		call	MainProg		;Call main program
@00_IntFunc:	pop	bp
		pop	di			;Restore registers
		pop	si
		pop	dx
		pop	cx
		pop	bx
		pop	ax
		pop	es
		pop	ds
		retf				;Return to caller
	endif

;Main program
MainProg:	mov	di, Offset DataStart	;Clear data area
		mov	cx, DataEnd - DataStart
		xor	al, al
		cld
		rep	stosb
		call	CmdLine			;Process command line
		pushf
		push	dx
		mov	dx, Offset Hello	;Display startup message
		stc
		call	PrintStr
		pop	dx
		popf
		jc	@01
		mov	ax, 3000h		;Get DOS version number
		mov	bh, 50h			;Preload OEM number
		int	21h
		cmp	al, WinDOSVersion	;For DOS 7.x versions, set
		jne	@34			; extended DOS structures flag
		mov	ExtendedStruct, True
@34:		cmp	al, MinDOSVersion	;Display error message if
		jb	@02			; major version number below 4
		cmp	bh, 0FDh		;Handle FreeDOS OEM number
		je	@39
		cmp	bh, 50h			;Display error message if OEM
		jb	@03			; number between 50h and FEh,
		cmp	bh, 0FEh		; a non-Microsoft DOS
		ja	@03
@02:		mov	dx, Offset WrongDOSVersion
		jmp	@01
@39:		mov	UnderFreeDOS, True
@03:		mov	ax, 160Ah		;Identify Windows
		int	2Fh
		or	ax, ax
		jne	@04
		mov	UnderWindows, True	;Set Windows running flag
@04:		mov	ax, 4A10h		;Identify SmartDrive or
		xor	bx, bx			; compatible disk cache
		mov	cx, 0EBABh
		int	2Fh
		cmp	ax, 0BABEh
		jne	@05
		mov	DiskCache, True		;Set disk cache detected flag
@05:		mov	ah, 52h			;Get pointer to list of lists
		int	21h
		mov	word ptr ListOfLists[0], bx
		mov	word ptr ListOfLists[2], es
		mov	al, es:[bx].ListList.llLastDrive	;Get maximum
		cmp	al, MinDrives		; number of drives
		jb	@06			;Display error message if the
		cmp	al, MaxDrives		; maximum number of drives is
		jbe	@07			; invalid
@06:		mov	dx, Offset DriveNumInvalid
		jmp	@01
@07:		mov	LastDrive, al
		les	bx, es:[bx].ListList.llCurDirStruc	;Get pointer
		mov	word ptr CurDirStructs[0], bx	;to current directory
		mov	word ptr CurDirStructs[2], es	;structures
		call	ReadPart		;Read disk partitions
		xor	cx, cx			;Initialize drive table with
		mov	di, Offset DriveTable	; default drive num and empty
@08:		mov	[di].DriveEntry.ldDriveNum, cl	; physical drive num
		mov	[di].DriveEntry.ldPhysDriveNum, -1
		add	di, DrvEntrySize
		inc	cl
		cmp	cl, MaxDrives
		jb	@08
		les	bx, ListOfLists		;Get first drive param block
		les	bx, es:[bx].ListList.llDriveParBlock
@12:		cmp	bx, -1			;End loop if pointer is NULL
		je	@10			; or offset is FFFFh
		mov	ax, es
		or	ax, bx
		je	@10
		mov	al, es:[bx].DriveParBlock.dpDriveNum	;Get drive num
		cmp	al, MaxDrives		;Display error message if the
		jb	@11			; drive number is invalid
		mov	dx, Offset DPBDriveNumInv
		jmp	@01
@11:		mov	dl, DrvEntrySize	;Store drive parameter block
		mul	dl			; pointer into drive table
		mov	di, ax
		mov	word ptr DriveTable[di].DriveEntry.ldDriveParBlock[0], bx
		mov	word ptr DriveTable[di].DriveEntry.ldDriveParBlock[2], es
		les	bx, es:[bx].DriveParBlock.dpNextBlock	;Continue with
		jmp	@12			; next drive parameter block
@10:		xor	cl, cl			;Process current directory
		les	si, CurDirStructs	; structures
@18:		cmp	byte ptr es:[si].CurDirEntry.cdPath[1], chDriveSep
		jne	@13			;Drive is not local if 2nd-3rd
		cmp	byte ptr es:[si].CurDirEntry.cdPath[2], chDirSep
		jne	@13			; characters are not ":\"
		mov	al, byte ptr es:[si].CurDirEntry.cdPath[0]
		sub	al, 'A'			;Display error message if the
		cmp	al, cl			; drive letter in path is not
		je	@15			; as expected (probably
		mov	dx, Offset BadDriveLetter	; SUBST'ed drive)
		jmp	@01
@15:		mov	dl, DrvEntrySize	;Display error message if the
		mul	dl			; DPB in the CDS mismatches
		mov	di, ax			; that in the drive table
		mov	ax, es:[si].CurDirEntry.cdAttrib
		mov	DriveTable[di].DriveEntry.ldAttrib, ax
		test	ax, DriveValidMask
		je	@14			;Skip check if empty drive
		mov	ax, word ptr DriveTable[di].DriveEntry.ldDriveParBlock[0]
		cmp	ax, word ptr es:[si].CurDirEntry.cdDriveParBlock[0]
		jne	@16
		mov	ax, word ptr DriveTable[di].DriveEntry.ldDriveParBlock[2]
		cmp	ax, word ptr es:[si].CurDirEntry.cdDriveParBlock[2]
		je	@14
@16:		mov	dx, Offset BadCDSOrDPB
		jmp	@01
@13:		cmp	byte ptr es:[si].CurDirEntry.cdPath[0], chDirSep
		jne	@17			;Display error message if
		cmp	byte ptr es:[si].CurDirEntry.cdPath[1], chDirSep
		je	@14			; non-local path does not
@17:		mov	dx, Offset WeirdCDSPath	; start with "\\"
		jmp	@01
@14:		push	cx			;Copy current directory entry
		push	si
		push	di
		mov	cx, CurDirEntrySize
@26:		mov	al, es:[si]
		mov	byte ptr DriveTable[di].DriveEntry.ldCDS, al
		inc	si
		inc	di
		loop	@26
		pop	di
		pop	si
		pop	cx
		add	si, CurDirEntrySize	;Continue with next current
		inc	cl			; directory entry
		cmp	cl, LastDrive
		jb	@18
		push	ds
		mov	ax, 0803h		;Get pointer to drive data
		int	2Fh			; table
		mov	bx, di
		push	ds
		pop	es
		pop	ds
		mov	word ptr DrvDatTable[0], bx
		mov	word ptr DrvDatTable[2], es
		xor	cl, cl			;Process drive data table
@25:		mov	dl, es:[bx].DrvDatEntry.ddDriveNum	;Get drive num
		xor	ch, ch			;Find drive in drive table
		mov	si, Offset DriveTable
@23:		push	es
		push	bx
		mov	al, -1			;Set drive number to invalid
		les	bx, [si].DriveEntry.ldDriveParBlock
		mov	di, es			;Get drive number from drive
		or	di, bx			; parameter block if the block
		je	@21			; is not NULL
		mov	al, es:[bx].DriveParBlock.dpDriveNum
		mov	ah, es:[bx].DriveParBlock.dpDiskAccessed
		;!!!
		int	3
@21:		pop	bx			;If DPB drive number is equal
		pop	es			; to current and has been
		cmp	al, dl			; accessed, copy physical
		jne	@22			; drive number, drive data
		test	ah, ah			; entry pointer and serial
		jne	@22			; number
		cmp	UnderFreeDOS, False	;Further drive valid checks
		je	@43
		mov	ax, es:[bx].FDDrvDatEntry.fdFlags
		test	al, fdfDiskChange	;Skip drive if not disk
		jne	@22			; has been changed
		test	al, fdfMultiLog		;If drive is not multiple
		je	@41			; logical drive or it is the
		test	al, fdfCurrentLog	; currently active instance
		je	@22			; then the drive is valid
		jmp	@41
@43:		push	es
		push	si
		push	di
		push	ds
		pop	es
		mov	al, ch			;Convert drive number to drive
		add	al, 'A'			; letter
		mov	byte ptr BootSec[0], al	;Write "X:" into buffer
		mov	word ptr BootSec[1], chDriveSep
		mov	si, Offset BootSec
		mov	di, Offset BootSec[18]	;Specify dummy area for FCB
		mov	ax, 2900h		;Parse "X:" into unopened FCB
		int	21h
		pop	di
		pop	si
		pop	es
		test	al, al			;Skip drive upon any error
		jne	@22			; (invalid drive)
		mov	ah, ch			;Convert 0-based drive number
		inc	ah			; to 1-based
		cmp	ah, 3			;Only check drives A: and B:
		jae	@41
		cmp	ah, 2			;When checking drive B:, get
		jne	@44			; the letter via which the
		push	bx			; other drive (A:) was last
		mov	bl, ah			; accessed
		dec	bl
		mov	ax, 440Eh
		int	21h
		jnc	@45
		xor	al, al
@45:		test	al, al			;Exit if an error occurred or
		pop	bx			; drive A: has only one letter
		jz	@41			; assigned
@44:		push	bx
		mov	bl, ch
		inc	bl
		mov	ax, 440Eh		;Get the letter via which the
		int	21h			; drive was last accessed
		pop	bx
		jc	@41
		dec	al
		cmp	al, ch			;Skip drive if it was last
		jne	@22			; accessed with other letter
@41:		mov	al, es:[bx].DrvDatEntry.ddPhysDriveNum	; number
		mov	[si].DriveEntry.ldPhysDriveNum, al
		mov	word ptr [si].DriveEntry.ldDrvDatEntry[0], bx
		mov	word ptr [si].DriveEntry.ldDrvDatEntry[2], es
		push	ax
		push	bx
		push	cx
		cmp	UnderFreeDOS, False	;Fetch volume label and serial
		jne	@40			; number
		cmp	ExtendedStruct, False
		jne	@32
		mov	ax, word ptr es:[bx].DrvDatEntry.ddSerialNum[0]
		mov	dx, word ptr es:[bx].DrvDatEntry.ddSerialNum[2]
		lea	bx, [bx].DrvDatEntry.ddVolumeLabel
		jmp	@33
@40:		mov	ax, word ptr es:[bx].FDDrvDatEntry.fdSerialNum[0]
		mov	dx, word ptr es:[bx].FDDrvDatEntry.fdSerialNum[2]
		lea	bx, [bx].FDDrvDatEntry.fdVolumeLabel
		jmp	@33
@32:		mov	ax, word ptr es:[bx].ExtDrvDatEntry.xdSerialNum[0]
		mov	dx, word ptr es:[bx].ExtDrvDatEntry.xdSerialNum[2]
		lea	bx, [bx].ExtDrvDatEntry.xdVolumeLabel
@33:		mov	word ptr [si].DriveEntry.ldSerialNum[0], ax
		mov	word ptr [si].DriveEntry.ldSerialNum[2], dx
		lea	di, [si].DriveEntry.ldVolumeLabel	;Copy serial
		call	ReadVolLab		; number and volume label from
		pop	cx			; drive table entry
		pop	bx
		pop	ax			;Find partition number for
		call	GetPartNum		; logical drive
		call	PrDrvInfo		;Display drive information
		jmp	@42
@22:		add	si, DrvEntrySize	;Continue with next drive in
		inc	ch			; drive table
		cmp	ch, MaxDrives
		jb	@23
@42:		les	bx, es:[bx]		;Get pointer to next entry in
		cmp	bx, -1			; the drive data table, exit
		je	@24			; if offset is FFFFh
		inc	cl			;Continue with next drive in
		cmp	cl, MaxDrives		; drive data table
		jb	@25
@24:		push	ds			;Restore ES to data segment
		pop	es
		call	CoreFunc		;Do the actual manipulation
		jc	@01
		call	AutoAssign		;Auto assign letters to drives
		jc	@01			; without letters
		xor	cl, cl			;Update drive letter changes
		mov	si, Offset DriveTable	; in DOS system tables
		mov	HighestDrvNum, cl	;Clear highest drive number
@20:		mov	ch, [si].DriveEntry.ldDriveNum
		cmp	ch, cl			;Skip drive if drive number
		je	@19			; has not changed
		push	si
		mov	LettersChanged, True	;Set letters changed flag
		call	PrDriveChg		;Display drive letter change
		push	cx
		and	ch, (not dlDelFlag)	;Remove "delete letter" flag
		mov	al, cl
		mov	dl, DrvEntrySize	;Go to drive table entry of
		mul	dl			; new drive
		mov	di, ax			;Put orig num into new drive
		les	bx, DriveTable[di].DriveEntry.ldDrvDatEntry
		mov	dx, es
		or	dx, bx
		je	@28
		mov	es:[bx].DrvDatEntry.ddDriveNum, ch
@28:		mov	al, ch
		mov	dl, CurDirEntrySize	;Go to current directory entry
		mul	dl			; of original drive
		les	bx, CurDirStructs
		add	bx, ax
		push	bx
		push	cx
		push	di
		mov	cx, CurDirEntrySize
@27:		mov	al, byte ptr DriveTable[di].DriveEntry.ldCDS
		mov	es:[bx], al		;Copy current directory entry
		inc	di			; of original drive to that
		inc	bx			; of new drive
		loop	@27
		pop	di
		pop	cx
		pop	bx
		cmp	byte ptr es:[bx].CurDirEntry.cdPath[0], chDirSep
		je	@30			;Skip network drives
		mov	al, ch			;Change original drive letter
		add	al, 'A'			; in path to new one
		mov	byte ptr es:[bx].CurDirEntry.cdPath[0], al
		mov	ax, -1			;Invalidate cached data
		mov	es:[bx].CurDirEntry.cdCurDirCluster, ax
		mov	word ptr es:[bx].CurDirEntry.cdUnknown[0], ax
		mov	word ptr es:[bx].CurDirEntry.cdUnknown[2], ax
@30:		pop	cx
		test	ch, dlDelFlag		;Delete drive letter
		je	@31
		mov	word ptr es:[bx].CurDirEntry.cdAttrib, 0
		jmp	@35
@31:		cmp	HighestDrvNum, ch	;If highest drive number is
		jae	@35			; lower than current then make
		mov	HighestDrvNum, ch	; the current the highest
@35:		les	bx, DriveTable[di].DriveEntry.ldDriveParBlock
		pop	si			;Put orig drive and unit num
		and	ch, (not dlDelFlag)	; into drive parameter block
		mov	es:[bx].DriveParBlock.dpDriveNum, ch
		mov	es:[bx].DriveParBlock.dpUnitNum, ch
@19:		add	si, DrvEntrySize	;Continue with next drive
		inc	cl
		cmp	cl, MaxDrives
		jb	@20
		cmp	LettersChanged, False	;Display message if no drive
		je	@29			; letter has been changed
		les	bx, ListOfLists		;If number of block devices is
		mov	al, HighestDrvNum	; less than highest drive num
		inc	al			; plus 1 then update
		cmp	byte ptr es:[bx].ListList.llBlockDevNum, al
		jae	@36
		mov	byte ptr es:[bx].ListList.llBlockDevNum, al
@36:		xor	cl, cl			;Process current directory
		les	bx, CurDirStructs	; structure
@09:		xor	ch, ch			;Search for drive in drive
		mov	si, Offset DriveTable	; table
@38:		cmp	cl, [si].DriveEntry.ldDriveNum
		je	@37
	       	add	si, DrvEntrySize	;Continue with next drive
		inc	ch
		cmp	ch, MaxDrives		;If drive not found then
		jb	@38			; delete it via empty attrib
		mov	word ptr es:[bx].CurDirEntry.cdAttrib, 0
@37:		add	bx, CurDirEntrySize	;Go to next current directory
		inc	cl			; entry
		cmp	cl, MaxDrives
		jb	@09
		jmp	@00
@29:		cmp	ListAssign, False	;Don't display "no changes" if
		jne	@00			; listing assignments
		mov	dx, Offset NoChanges
@01:		or	dx, dx			;Skip if string is NULL
		je	@00
		stc
		call	PrintStr
@00:
	ifdef DeviceDriver
		retn				;Return to device int function
	else
		mov	ax, 4C00h		;Terminate program
		int	21h
	endif

;Get volume label from boot sector contents or drive data entry
;  Input : ES:BX: original volume label; trailing spaces, "NO NAME" value
;                 means empty string
;          DS:DI: pointer to destination string
ReadVolLab:	push	di
		add	bx, VolLabLen - 1	;Go to end of volume label
		add	di, VolLabLen - 1
		mov	cx, VolLabLen		;Copy label, removing spaces
@01_ReadVolLab:	mov	al, es:[bx]		;Step backwards in volume
		cmp	al, ' '			; label, skipping spaces
		jne	@02_ReadVolLab
		dec	bx
		dec	di
		loop	@01_ReadVolLab
@02_ReadVolLab:	mov	byte ptr [di], 0	;Terminate volume label and
		jcxz	@03_ReadVolLab		; exit if no more characters
@04_ReadVolLab:	mov	al, es:[bx]		;Copy characters backwards
		mov	[di], al
		dec	bx
		dec	di
		loop	@04_ReadVolLab
@03_ReadVolLab:	pop	di
		push	es
		push	ds
		pop	es
		push	si
		mov	si, di
		mov	di, Offset EmptyVolLabel
		call	StrComp			;Compare volume label with
		jne	@05_ReadVolLab		; "NO NAME" value and, if
		mov	byte ptr [si], 0	; matches, clear volume label
@05_ReadVolLab:	pop	si
		pop	es
		retn

;Find logical drive in internal partition table and extract partition number
;  Input : DS:SI: pointer to current logical drive in internal drive table
GetPartNum:	push	es			;Save registers
		push	ax
		push	cx
		push	si
		push	ds
		pop	es
		mov	cl, PartNum		;Start with first partition
		mov	di, Offset PhysDriveTable
@02_GetPartNum:	mov	al, [di].PhysDrvEntry.pdPhysDriveNum
		cmp	al, [si].DriveEntry.ldPhysDriveNum
		jne	@01_GetPartNum		;Compare physical drive number
		mov	ax, word ptr [di].PhysDrvEntry.pdSerialNum[0]
		cmp	ax, word ptr [si].DriveEntry.ldSerialNum[0]
		jne	@01_GetPartNum		;Compare serial number
		mov	ax, word ptr [di].PhysDrvEntry.pdSerialNum[2]
		cmp	ax, word ptr [si].DriveEntry.ldSerialNum[2]
		jne	@01_GetPartNum
		push	si
		push	di
		lea	di, [di].PhysDrvEntry.pdVolumeLabel
		lea	si, [si].DriveEntry.ldVolumeLabel
		call	StrComp			;Compare volume label
		pop	di
		pop	si
		jne	@01_GetPartNum		;If all match, copy partition
		mov	al, [di].PhysDrvEntry.pdPartNum	; number and exit
		mov	[si].DriveEntry.ldPartNum, al
		jmp	@03_GetPartNum
@01_GetPartNum:	add	di, PhysDrvEntSize	;Continue with next partition
		loop	@02_GetPartNum
@03_GetPartNum:	pop	si			;Restore registers
		pop	cx
		pop	ax
		pop	es
		retn

;Read sector from disk
;  Input : AX:BX:CX: sector position; in CHS mode, cylinder, head and sector;
;                    in LBA mode, LBA sector number
;          ES:DI: buffer to read sector contents into
;  Output: CF: when set, an error occurred
;          AL: error code
ReadSector:	push	dx
		push	si
		cmp	ExtDiskFunc, False	;Determine CHS or LBA access
		jne	@01_ReadSector
		xchg	ax, cx			;Pack cylinder, head and
		xchg	cl, ch			; sector into BIOS format
		ror	cl, 2
		or	cl, al
		mov	dh, bl
		mov	bx, di
		mov	ax, 0201h
		jmp	@02_ReadSector
@01_ReadSector:	mov	DiskFuncPack.xfSize, ExtDFPSize	;Fill in extended disk
		mov	DiskFuncPack.xfReserved, 0	; function packet
		mov	DiskFuncPack.xfSectorNum, 1
		mov	word ptr DiskFuncPack.xfDataBuffer[0], di
		mov	word ptr DiskFuncPack.xfDataBuffer[2], es
		mov	word ptr DiskFuncPack.xfLBASectorLo[0], ax
		mov	word ptr DiskFuncPack.xfLBASectorLo[2], bx
		mov	word ptr DiskFuncPack.xfLBASectorHi[0], cx
		mov	word ptr DiskFuncPack.xfLBASectorHi[2], 0
		mov	si, Offset DiskFuncPack
		push	ds
		pop	es
		mov	ah, 42h
@02_ReadSector:	mov	dl, PhysDrvNum		;Get physical drive number
		int	13h
		mov	al, ah			;Move error code
		pop	si
		pop	dx
		retn

;Process boot record
;  Input : DH: when True, the Master Boot Record is to be processed; otherwise
;              a normal boot record
;          AX:BX:CX: sector position; in CHS mode, cylinder, head and sector;
;                    in LBA mode, LBA sector number
PrcBootRec:	mov	word ptr SecPos[0], ax	;Save start position of
		mov	word ptr SecPos[2], bx	; current partition
		mov	word ptr SecPos[4], cx
		mov	dl, PhysPartNum
		mov	di, Offset BootRec	;Read boot record from disk
		push	ds
		pop	es
		call	ReadSector		;Exit if an error occurred or
		jc	@00_PrcBootRec		; if signature is missing
		cmp	word ptr BootRec[DefBytePerSec - 2], BootSectorSign
		jne	@00_PrcBootRec
		mov	FollowExt, False	;Process normal part entries
@01_PrcBootRec:	mov	PartEntryCnt, PartPerBootRec	;Startt with first
		mov	si, Offset BootRec.brPartTable	; partition entry
@04_PrcBootRec:	cmp	ExtDiskFunc, False	;Determine CHS or LBA access
		jne	@02_PrcBootRec
		mov	ax, [si].PartitionEntry.peStartCylSec
		push	ax			;Unpack BIOS format to
		rol	al, 2			; cylinder, head and sector
		and	al, 03h
		xchg	al, ah
		pop	cx
		and	cx, 003Fh
		mov	bl, [si].PartitionEntry.peStartHead
		xor	bh, bh
		jmp	@03_PrcBootRec
@02_PrcBootRec:	mov	ax, word ptr [si].PartitionEntry.peStartRelSec[0]
		mov	bx, word ptr [si].PartitionEntry.peStartRelSec[2]
		xor	cx, cx			;Get LBA sector number
@03_PrcBootRec:	mov	dl, [si].PartitionEntry.peType	;Get partition type
		or	dl, dl			;Skip empty partitions
		je	@05_PrcBootRec
		cmp	dl, ptExtended		;Extended partition types
		je	@06_PrcBootRec
		cmp	dl, ptExtendedLBA
		jne	@07_PrcBootRec
@06_PrcBootRec:	cmp	FollowExt, False	;Skip ext part entries when
		je	@05_PrcBootRec		; processing norm part entries
		or	dh, dh			;When processing MBR, save
		je	@08_PrcBootRec		; start of ext partition...
		mov	word ptr ExtStartSecPos[0], ax
		mov	word ptr ExtStartSecPos[2], bx
		mov	word ptr ExtStartSecPos[4], cx
		jmp	@09_PrcBootRec
@08_PrcBootRec:	add	ax, word ptr ExtStartSecPos[0]	; ...otherwise convert
		adc	bx, word ptr ExtStartSecPos[2]	; relative sector
		adc	cx, word ptr ExtStartSecPos[4]	; position to absolute
@09_PrcBootRec:	xor	dh, dh			;Clear MBR flag
		call	PrcBootRec		;Process boot record and exit
		jmp	@00_PrcBootRec
@07_PrcBootRec:	cmp	FollowExt, False	;Skip normal part entries when
		jne	@05_PrcBootRec		; processing ext part entries
		cmp	dl, ptFAT12		;DOS normal parition types
		je	@11_PrcBootRec
		cmp	dl, ptFAT16Max32MB
		je	@11_PrcBootRec
		cmp	dl, ptFAT16
		je	@11_PrcBootRec
		cmp	dl, ptFAT16LBA
		je	@11_PrcBootRec
		cmp	dl, ptFAT32
		je	@11_PrcBootRec
		cmp	dl, ptFAT32LBA
		jne	@12_PrcBootRec
@11_PrcBootRec:	add	ax, word ptr SecPos[0]	;Convert relative sector
		adc	bx, word ptr SecPos[2]	; position to absolute
		adc	cx, word ptr SecPos[4]
		mov	di, Offset BootSec	;Read boot sector from disk
		push	ds
		pop	es
		call	ReadSector		;Exit if an error occurred or
		jc	@12_PrcBootRec		; if signature is missing
		cmp	word ptr BootSec[DefBytePerSec - 2], BootSectorSign
		jne	@12_PrcBootRec
		mov	al, PartNum		;Get number of partitions in
		cmp	al, MaxPartitions	; internal table, skip current
		jae	@12_PrcBootRec		; partition if table is full
		push	dx
		mov	ah, PhysDrvEntSize	;Compute pointer to new
		mul	ah			; partition in internal table
		mov	di, ax
		add	di, Offset PhysDriveTable
		cmp	dl, ptFAT32		;Process extended boot sector
		je	@14_PrcBootRec		; for FAT32 partitions
		cmp	dl, ptFAT32LBA
		jne	@15_PrcBootRec
@14_PrcBootRec:	mov	ax, word ptr BootSec.ExtBootSector.xsFileSysInfo.fiSerialNum[0]
		mov	dx, word ptr BootSec.ExtBootSector.xsFileSysInfo.fiSerialNum[2]
		lea	bx, BootSec.ExtBootSector.xsFileSysInfo.fiVolumeLabel
		jmp	@16_PrcBootRec
@15_PrcBootRec:	mov	ax, word ptr BootSec.BootSector.bsFileSysInfo.fiSerialNum[0]
		mov	dx, word ptr BootSec.BootSector.bsFileSysInfo.fiSerialNum[2]
		lea	bx, BootSec.BootSector.bsFileSysInfo.fiVolumeLabel
@16_PrcBootRec:	push	ds			;Get serial number and volume
		pop	es			; label from boot sector
		mov	word ptr [di].PhysDrvEntry.pdSerialNum[0], ax
		mov	word ptr [di].PhysDrvEntry.pdSerialNum[2], dx
		push	di
		lea	di, [di].PhysDrvEntry.pdVolumeLabel
		call	ReadVolLab
		pop	di
		mov	al, PhysDrvNum		;Store physical drive number
		mov	[di].PhysDrvEntry.pdPhysDriveNum, al
		mov	al, PhysPartNum		;Store partition number
		mov	[di].PhysDrvEntry.pdPartNum, al
		pop	dx
		inc	PartNum			;Increase number of partitions
@12_PrcBootRec:	or	dh, dh			;Increase partition number if
		jne	@05_PrcBootRec		; processing normal boot rec
		inc	PhysPartNum
@05_PrcBootRec:	or	dh, dh			;Increase partition number if
		je	@13_PrcBootRec		; processing MBR and not
		cmp	FollowExt, False	; processing extended
		jne	@13_PrcBootRec		; partition entries
		inc	PhysPartNum
@13_PrcBootRec:	add	si, PartEntrySize	;Continue with next partition table entry
		dec	PartEntryCnt		; table entry, end if all
		jne	@04_PrcBootRec		; entries have been processed
@10_PrcBootRec:	cmp	FollowExt, False	;Exit if partition table has
		jne	@00_PrcBootRec		; already been processed twice
		inc	FollowExt		;Process ext partition entries
		jmp	@01_PrcBootRec		;Process part entries again
@00_PrcBootRec:	retn

;Read volume labels and serial numbers from all DOS partitions on all hard
;  disks
ReadPart:	mov	dl, FirstHardDisk	;Start with first hard disk
		mov	PartNum, 0		; and first partition in table
@02_ReadPart:	mov	PhysDrvNum, dl
		mov	bx, 55AAh		;Determine whether BIOS
		mov	ah, 41h			; supports extended disk
		int	13h			; functions for the drive...
		xor	al, al
		jc	@01_ReadPart
		cmp	bx, 0AA55h
		jne	@01_ReadPart
		test	cl, 1
		je	@01_ReadPart
		inc	al			; ...and set extended disk
@01_ReadPart:	mov	ExtDiskFunc, al		; functions flag accordingly
		xor	ax, ax			;Set sector position to
		mov	bx, ax			; cylinder #0, head #0,
		mov	cx, ax			; sector #1 (for CHS mode) or
		cmp	ExtDiskFunc, False	; LBA sector #0 (for LBA mode)
		jne	@03_ReadPart
		inc	cx
@03_ReadPart:	mov	PhysPartNum, 1		;Start with partition #1
		mov	dh, True		;Set MBR flag
		call	PrcBootRec		;Process boot record
		mov	dl, PhysDrvNum		;Continue with next hard disk
		inc	dl			;Exit if all hard disks have
		cmp	dl, FirstHardDisk + MaxHardDisks	; been
		jb	@02_ReadPart		; processed
		retn

;Process command line
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
CmdLine:
		mov	di, Offset OrigCmdLine	;Copy of command line
		cld
	ifdef DeviceDriver
		push	ds
		lds	si, RequestHeader	;Get pointer to command line
		lds	si, [si].DevReqHeader.drData.DevInitData.diCommandLine
@10_CmdLine:	lodsb				;Skip driver, the first word,
		cmp	al, chCR		; up to the first whitespace,
		je	@07_CmdLine		; in the command line
		cmp	al, ' '
		je	@09_CmdLine
		cmp	al, chTab
		jne	@10_CmdLine
	else
		mov	si, 0081h		;Beginning of command line
	endif
@08_CmdLine:	lodsb				;Get character
		cmp	al, chCR		;Cmd line is CR-terminated
		je	@07_CmdLine
@09_CmdLine:	stosb				;Put character and continue
		jmp	@08_CmdLine		; with the next character
@07_CmdLine:	xor	al, al			;Zero-terminate command line
		stosb
	ifdef DeviceDriver
		pop	ds
	endif
		mov	CommandParNum, 1	;Command is first parameter
@06_CmdLine:	mov	bl, CommandParNum	;Get command
		mov	di, Offset CmdParam
		mov	cx, CmdParamSize
		call	ParamStr
		cmp	bh, bl			;If there are no parameters on
		jae	@01_CmdLine		; the command line, display
		mov	dx, Offset Usage	; usage
		stc
		jmp	@00_CmdLine
@01_CmdLine:	mov	al, byte ptr CmdParam[0]	;Get first character
		cmp	al, '-'			;Options must start with a
		je	@03_CmdLine		; hyphen or a (forward) slash
		cmp	al, '/'
		jne	@04_CmdLine
@03_CmdLine:	mov	al, byte ptr CmdParam[1]	;Get second character
		call	UpCase			; and convert it to uppercase
		cmp	al, 'Q'
		jne	@05_CmdLine
		mov	Quiet, True		;Enable quiet operation
		inc	CommandParNum		;Search command in next par
		jmp	@06_CmdLine
@05_CmdLine:	mov	dx, Offset UnknownOption	;Display an error
		stc				; if option is unknown
		jmp	@00_CmdLine
@04_CmdLine:	mov	si, Offset CmdNames	;Process list of commands
		mov	bx, Offset CmdEntries
@12_CmdLine:	cmp	byte ptr [si], 0	;If end of list reached, end
		je	@11_CmdLine		; loop
		call	StrComp			;Compare specified command
		je	@02_CmdLine		; with that in list
		call	StrLen			;If no match, go to next
		add	si, ax			; command in both lists
		inc	si
		add	bx, 3
		jmp	@12_CmdLine
@11_CmdLine:	mov	dx, Offset UnknownCommand
		stc				;Display error message if the
		jmp	@00_CmdLine		; command is unknown
@02_CmdLine:	mov	ax, word ptr [bx].EntryPt.epOffs	;Get routine
		mov	CoreFunc, ax		; entry point
		cmp	[bx].EntryPt.epPreExec, False	;If pre-exec routine,
		je	@13_CmdLine		; call it right away
		call	CoreFunc
@13_CmdLine:	clc
@00_CmdLine:	retn

;Automatically assign new letters to drives being deleted and to drives having
;  lost their letter because another drive was moved to that letter
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
AutoAssign:	xor	cl, cl			;Process drive table
		mov	si, Offset DriveTable
		mov	al, 'C' - 'A'		;Start auto assign with "C:"
@02_AutoAssign:	test	[si].DriveEntry.ldDriveNum, dlDelFlag	;Skip deleted
		je	@01_AutoAssign		; and non-existing drives
		cmp	[si].DriveEntry.ldPhysDriveNum, -1
		je	@01_AutoAssign
@05_AutoAssign:	xor	ch, ch			;Search for auto assign letter
		mov	di, Offset DriveTable	; in drive table
@04_AutoAssign:	mov	bx, word ptr [di].DriveEntry.ldDriveParBlock[0]
		or	bx, word ptr [di].DriveEntry.ldDriveParBlock[2]
		or	bx, word ptr [di].DriveEntry.ldDrvDatEntry[0]
		or	bx, word ptr [di].DriveEntry.ldDrvDatEntry[2]
		je	@07_AutoAssign		;Skip empty drives
		cmp	al, [di].DriveEntry.ldDriveNum
		je	@03_AutoAssign		;Compare drive letter, if no
@07_AutoAssign:	add	di, DrvEntrySize	; match, go to next drive
		inc	ch
		cmp	ch, MaxDrives
		jb	@04_AutoAssign		;Store auto assign letter
		mov	ah, [si].DriveEntry.ldDriveNum
		cmp	ah, dlAutoAssign
		je	@06_AutoAssign		;When deleting letter, keep
		or	al, dlDelFlag		; the "delete letter" flag
@06_AutoAssign:	mov	[si].DriveEntry.ldDriveNum, al
		and	al, (not dlDelFlag)	;Remove "delete letter" flag
		inc	al
		jmp	@01_AutoAssign
@03_AutoAssign:	inc	al			;If auto assign letter found,
		jmp	@05_AutoAssign		; try next letter
@01_AutoAssign:	add	si, DrvEntrySize	;Continue with next drive
		inc	cl
		cmp	cl, MaxDrives
		jb	@02_AutoAssign
		clc
		retn

;Check the environment, determining whether Windows is running or a disk cache
;  is installed
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
CheckEnv:	mov	dx, Offset WindowsRunning
		cmp	UnderWindows, False
		stc
		jne	@00_CheckEnv
		mov	dx, Offset CacheInstalled
		cmp	DiskCache, False
		stc
		jne	@00_CheckEnv
		clc
@00_CheckEnv:	retn

;List drive letter assignments
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
ListLetters:	mov	ListAssign, True	;Enable listing assignments
		clc
		retn

;Calculate offsets of drives into drive table
;  Input:  DL: source drive (0=A:, 1=B:...)
;          DH: destination drive (0=A:, 1=B:...; -1=empty)
;  Output: SI: offset of source drive into drive table
;          DI: offset of destination drive into drive table
CalcDrvOffs:	mov	al, dl
		mov	ah, DrvEntrySize	;Calculate offset of source
		mul	ah			; drive into drive table
		mov	si, ax
		mov	al, dh
		mov	ah, DrvEntrySize	;Calculate offset of dest
		mul	ah			; drive into drive table
		mov	di, ax
		retn

;Convert a number from decimal string format into unsigned long integer
;  Input : DS:SI: the string
;  Output: CF: when set, an error occurred
;          AX:DX: the unsigned long integer
StrNum:		push	bx			;Save registers
		push	cx
		call	StrLen			;Compute length of string
		mov	cx, ax
		xor	ax, ax			;Set resulting long integer
		xor	dx, dx			; number to zero
		jcxz	@02_StrNum		;Return error if string empty
@03_StrNum:	mov	bl, [si]		;Get character from string
		sub	bl, '0'			;Convert character to digit
		cmp	bl, 9			;Return error if character is
		ja	@02_StrNum		; not a digit
		test	dh, 0F0h		;Return error upon numerical
		jne	@02_StrNum		; overflow
		push	bx
		shl	ax, 1			;Multiply number by 2, to get
		rcl	dx, 1			; "2 * number"
		push	dx			;Save "2 * number"
		push	ax
		shl	ax, 1			;Further multiply number by 4,
		rcl	dx, 1			; to get "8 * number"
		shl	ax, 1
		rcl	dx, 1
		pop	bx			;Load "2 * number" and add it
		add	ax, bx			; to "8 * number", to get
		pop	bx			; number multiplied by 10
		adc	dx, bx
		pop	bx
		xor	bh, bh			;Add digit to number
		add	ax, bx
		adc	dx, 0
		inc	si			;Continue with next character
		loop	@03_StrNum
		clc				;Exit if reached end of string
		jmp	@01_StrNum
@02_StrNum:	stc
@01_StrNum:	pop	cx			;Restore registers
		pop	bx
		retn

;Fetch partition name from the command line
;  Input:  BL: parameter number
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
;          BL: when not zero, a valid partition number was read; otherwise an
;              empty value
;          AL: physical hard disk number (80h: first hard disk; 81h: second
;              hard disk...)
;          AH: partition number
GetPartNam:	push	di			;Save registers
		push	dx
		add	bl, CommandParNum	;Get parameter from command
		mov	di, Offset CmdParam	; line
		mov	cx, CmdParamSize
		call	ParamStr
		cmp	bh, bl			;Display error message if
		jae	@01_GetPartNam		; parameter is not present
@02_GetPartNam:	pop	dx
		mov	dx, Offset InvalidParam
		stc
		jmp	@03_GetPartNam
@01_GetPartNam:	xor	bl, bl			;Clear filter flag
		mov	si, Offset AnyValue	;Compare partition name with
		call	StrComp			; "*" value and exit upon a
		je	@05_GetPartNum		; match
		inc	bl			;Set filter flag
@04_GetPartNum:	cmp	word ptr CmdParam[0], 'DH'	;Error if partition
		jne	@02_GetPartNam		; name doesn't start with "hd"
		lea	si, CmdParam[3]		;Get partition number
		call	StrNum
		jc	@02_GetPartNam		;Error if conversion problem
		or	dx, dx			;Error if partition number
		jne	@02_GetPartNam		; high word is not zero
		or	ax, ax			;Error if partition number is
		je	@02_GetPartNam		; zero
		cmp	ax, MaxPartitions	;Error if partition number is
		ja	@02_GetPartNam		; too high
		mov	ah, al			;Move partition number
		mov	al, CmdParam[2]		;Convert physical hard disk
		add	al, FirstHardDisk - 'A'	; letter to hard disk number
		cmp	al, FirstHardDisk	;Error if too low hard disk
		jb	@02_GetPartNam		; number
		cmp	al, FirstHardDisk + MaxHardDisks	;Error if too
		jae	@02_GetPartNam		; high hard disk number
@05_GetPartNum:	clc
		pop	dx
@03_GetPartNam:	pop	di			;Restore registers
		retn

;Fetch volume serial number from the command line
;  Input:  BL: parameter number
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
;          BL: when not zero, a valid serial number was read; otherwise an
;              empty value
;          CX:AX: serial number
GetSerNum:	push	dx
		add	bl, CommandParNum	;Get parameter from command
		mov	di, Offset CmdParam	; line
		mov	cx, CmdParamSize
		call	ParamStr
		cmp	bh, bl			;Display error message if
		jae	@01_GetSerNum		; parameter is not present
@03_GetSerNum:	pop	dx
		mov	dx, Offset InvalidParam
		stc
		jmp	@00_GetSerNum
@01_GetSerNum:	xor	ax, ax			;Clear serial number
		mov	cx, ax
		xor	bl, bl			;Set "empty value" flag
		mov	si, Offset AnyValue	;Compare volume label with
		call	StrComp			; "*" value, if match, exit
		je	@07_GetSerNum
		xor	dl, dl			;Process serial number string
@06_GetSerNum:	mov	dh, [di]
		cmp	dl, 4			;The fifth character must be
		jne	@02_GetSerNum		; a hyphen, otherwise an error
		cmp	dh, '-'			; message is displayed
		jne	@03_GetSerNum
		jmp	@04_GetSerNum		;Continue with next character
@02_GetSerNum:	cmp	dh, '0'			;Convert hexadecimal digit
		jb	@03_GetSerNum		; from string to binary
		cmp	dh, '9'
		jbe	@05_GetSerNum
		cmp	dh, 'A'
		jb	@03_GetSerNum
		cmp	dh, 'F'
		ja	@03_GetSerNum
		sub	dh, 'A' - '0' - 10
@05_GetSerNum:	sub	dh, '0'
		shl	ax, 1			;Shift serial number four bits
		rcl	cx, 1			; upwards
		shl	ax, 1
		rcl	cx, 1
		shl	ax, 1
		rcl	cx, 1
		shl	ax, 1
		rcl	cx, 1			;Put hexadecimal digit read
		or	al, dh			; into least significant digit
@04_GetSerNum:	inc	di
		inc	dl
		cmp	dl, 9			;Process nine characters
		jb	@06_GetSerNum
		inc	bl			;Set "valid value" flag
		cmp	byte ptr [di], 0	;If not at the end of string,
		jne	@03_GetSerNum		; display error message
@07_GetSerNum:	clc
		pop	dx
@00_GetSerNum:	retn

;Set drive letter according to volume label and/or serial number
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
SetLetter:	call	CheckEnv		;Check environment and exit,
		jc	@00_SetLetter		; if needed
		mov	bl, CommandParNum	;Get drive letter from first
		inc	bl			; parameter
		mov	di, Offset CmdParam
		mov	cx, CmdParamSize
		call	ParamStr
		cmp	bh, bl			;Display error message if
		jb	@08_SetLetter		; parameter is not present
		mov	al, byte ptr CmdParam[0]
		mov	dh, dlDelFlag		;A letter of "-" deletes the
		cmp	al, '-'			; drive letter
		je	@09_SetLetter
		mov	dh, dlAutoAssign	;A letter of "*" auto assigns
		cmp	al, '*'			; the drive letter
		je	@09_SetLetter
		sub	al, 'A'			;Convert drive letter into
		cmp	al, LastDrive		; drive number and display
		jae	@12_SetLetter		; error message if invalid
		mov	dh, al
@09_SetLetter:	mov	bl, 2			;Get partition name from
		call	GetPartNam		; second parameter, return
		jc	@00_SetLetter		; error upon invalid value
		mov	FilterPartNum, bl	;Store part num filter flag
		mov	PhysDrvNum, al		;Store physical hard disk num
		mov	PhysPartNum, ah		;Store partition number
		mov	bl, 4			;Get serial number from fourth
		call	GetSerNum		; parameter and exit, if
		jc	@00_SetLetter		; needed
		mov	FilterSerialNum, bl	;Store serial num filter flag
		mov	word ptr SerialNumber[0], ax	; and serial number
		mov	word ptr SerialNumber[2], cx
		mov	bl, CommandParNum	;Get volume label from third
		add	bl, 3			; parameter
		mov	di, Offset CmdParam
		mov	cx, CmdParamSize
		call	ParamStr
		cmp	bh, bl			;Display error message if
		jae	@01_SetLetter		; parameter is not present
@08_SetLetter:	mov	dx, Offset InvalidParam
		stc
		jmp	@00_SetLetter
@12_SetLetter:	mov	dx, Offset LetterTooHigh
		stc
		jmp	@00_SetLetter
@01_SetLetter:	mov	FilterVolLabel, False	;Clear vol label filter flag
		mov	si, Offset AnyValue	;Compare volume label with
		call	StrComp			; "*" value and, if no match,
		je	@02_SetLetter		; set filter by volume label
		inc	FilterVolLabel		; flag
@02_SetLetter:	xor	cl, cl			;Search for volume label and
		mov	bx, Offset DriveTable	; serial number in drive table
		push	dx
@06_SetLetter:	cmp	FilterPartNum, False	;Skip if not filtering by
		je	@11_SetLetter		; partition number
		mov	al, PhysDrvNum		;Compare phys hard disk num
		cmp	al, [bx].DriveEntry.ldPhysDriveNum
		jne	@05_SetLetter
		mov	al, PhysPartNum		;Compare partition number
		cmp	al, [bx].DriveEntry.ldPartNum
		jne	@05_SetLetter		;Exit if either doesn't match
@11_SetLetter:	cmp	FilterVolLabel, False	;Skip if not filtering by
		je	@03_SetLetter		; volume label
		lea	si, [bx].DriveEntry.ldVolumeLabel
		call	StrComp			;Compare volume labels, exit
		jne	@05_SetLetter		; if no match
@03_SetLetter:	cmp	FilterSerialNum, False	;Skip if not filtering by
		je	@04_SetLetter		; serial number
		mov	ax, word ptr [bx].DriveEntry.ldSerialNum[0]
		cmp	ax, word ptr SerialNumber[0]
		jne	@05_SetLetter		;Compare serial numbers
		mov	ax, word ptr [bx].DriveEntry.ldSerialNum[2]
		cmp	ax, word ptr SerialNumber[2]
		jne	@05_SetLetter		;Exit if serials do not match
@04_SetLetter:	pop	dx
		mov	dl, cl			;Move the drive found to the
		call	CalcDrvOffs		; specified letter
		cmp	dh, dlAutoAssign	;Set destination drive, if
		jae	@10_SetLetter		; any, to auto assign
		mov	DriveTable[di].DriveEntry.ldDriveNum, dlAutoAssign
@10_SetLetter:	mov	DriveTable[si].DriveEntry.ldDriveNum, dh
		jmp	@07_SetLetter
@05_SetLetter:	add	bx, DrvEntrySize	;Continue with next drive
		inc	cl
		cmp	cl, MaxDrives
		jb	@06_SetLetter
		pop	dx
@07_SetLetter:	clc
@00_SetLetter:	retn

;Fetch source and destination drive letters from the command line
;  Input : CF: when set, only source drive letter is needed
;  Output: DL: source drive (0=A:, 1=B:...)
;          DH: destination drive (0=A:, 1=B:...; -1=empty)
;          SI: offset of source drive into drive table
;          DI: offset of destination drive into drive table
GetLetters:	mov	al, 1
		jc	@03_GetLetters
		inc	al
@03_GetLetters:	mov	bl, CommandParNum	;Get first/second parameter
		pushf
		add	bl, al
		mov	di, Offset CmdParam
		mov	cx, CmdParamSize
		call	ParamStr
		cmp	bh, bl			;Display error message if
		jae	@01_GetLetters		; parameter is not present
		popf
@02_GetLetters:	mov	dx, Offset InvalidParam
		stc
		jmp	@00_GetLetters
@01_GetLetters:	mov	al, dlAutoAssign	;Return dummy destination
		popf				; drive letter if only source
		jc	@04_GetLetters		; is needed
		mov	al, byte ptr CmdParam[0]
		sub	al, 'A'			;Convert drive letter into
		cmp	al, LastDrive		; drive number and display
		jae	@02_GetLetters		; error message if invalid
@04_GetLetters:	mov	dh, al
		push	di
		mov	bl, CommandParNum	;Get first parameter
		inc	bl
		mov	di, Offset CmdParam
		mov	cx, CmdParamSize
		call	ParamStr
		pop	di
		mov	al, byte ptr CmdParam[0]
		sub	al, 'A'			;Convert drive letter into
	   	cmp	al, LastDrive		; drive number and display
		jae	@02_GetLetters		; error message if invalid
		mov	dl, al
		call	CalcDrvOffs
		clc
@00_GetLetters:	retn

;Move drive letter
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
MoveLetter:	call	CheckEnv		;Check environment and exit,
		jc	@00_MoveLetter		; if needed
		clc
		call	GetLetters		;Fetch drive letter, move
		jc	@00_MoveLetter		; drive letter
		mov	DriveTable[si].DriveEntry.ldDriveNum, dh
		mov	DriveTable[di].DriveEntry.ldDriveNum, dlAutoAssign
		clc
@00_MoveLetter:	retn

;Delete drive letter
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
DelLetter:	call	CheckEnv		;Check environment and exit,
		jc	@00_DelLetter		; if needed
		stc
		call	GetLetters		;Fetch drive letter, delete
		jc	@00_DelLetter		; drive with empty letter
		or	DriveTable[si].DriveEntry.ldDriveNum, dlDelFlag
		clc
@00_DelLetter:	retn

;Swap drive letters
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
SwapLetter:	call	CheckEnv		;Check environment and exit,
		jc	@00_SwapLetter		; if needed
		clc
		call	GetLetters		;Fetch drive letters, swap
		jc	@00_SwapLetter		; drive letters
		mov	DriveTable[si].DriveEntry.ldDriveNum, dh
		mov	DriveTable[di].DriveEntry.ldDriveNum, dl
		clc
@00_SwapLetter:	retn

;Drive letter reassignment main loop
;  Input : BL: partition number to start each hard disk at
;          BH: partition number to end each hard disk at
;          CL: when True, exit when a partition has been found
;          CH: logical drive number to start assignment with (0=A:, 1=B:...)
ReassMain:	mov	al, StartDisk		;Start with starting hard disk
@06_ReassMain:	cmp	al, EndDisk		;Exit if reached ending hard
		jae	@00_ReassMain		; disk
		mov	ah, bl			;Start with first partition
@05_ReassMain:	cmp	ah, bh			;Exit if beyond ending
		ja	@01_ReassMain		; partition
		xor	dl, dl			;Start with first drive
		mov	si, Offset DriveTable
@04_ReassMain:	cmp	al, [si].DriveEntry.ldPhysDriveNum
		jne	@02_ReassMain
		cmp	ah, [si].DriveEntry.ldPartNum
		jne	@02_ReassMain
		mov	byte ptr [si].DriveEntry.ldPhysDriveNum, -1
		push	ax			;Clear physical drive number
		mov	al, dl			; so that the partition will
		mov	ah, DrvEntrySize	; not be processed again
		mul	ah			;Copy drive number into
		mov	di, ax			; the drive entry of the
		pop	ax			; current drive number
		mov	DriveTable[di].DriveEntry.ldDriveNum, ch
		inc	ch			;Cont with next drive number
		or	cl, cl			;Go to next hard disk if "exit
		jne	@01_ReassMain		; if part found" flag set,
		jmp	@03_ReassMain		; otherwise go to next part
@02_ReassMain:	add	si, DrvEntrySize	;Continue with next drive
		inc	dl
		cmp	dl, MaxDrives
		jb	@04_ReassMain
@03_ReassMain:	inc	ah			;Continue with next partition
		jmp	@05_ReassMain
@01_ReassMain:	inc	al			;Continue with next hard disk
		jmp	@06_ReassMain
@00_ReassMain:	retn

;Reassign drive letters; drives on the first few hard disks get letters from
;  the beginning of the alphabet, using the original DOS algorithm; drives
;  on other hard disks get subsequent letters, in a linear order
;  Output: CF: when set, the program must terminate with a message
;          DS:DX: message
Reassign:	call	CheckEnv		;Check environment and exit,
		jc	@00_Reassign		; if needed
		mov	bl, CommandParNum	;Get first parameter
		inc	bl
		mov	di, Offset CmdParam
		mov	cx, CmdParamSize
		call	ParamStr
		cmp	bh, bl			;Display error message if no
		jae	@01_Reassign		; parameter is present
@02_Reassign:	mov	dx, Offset InvalidParam
		stc
		jmp	@00_Reassign
@01_Reassign:	mov	ah, byte ptr CmdParam[0]
		sub	ah, '0'			;Display error message if the
		cmp	ah, MaxHardDisks	; number of main hard disks is
		jae	@02_Reassign		; invalid
		mov	ch, 2			;Start with letter "C:"
		mov	al, FirstHardDisk	;Starting hard disk is first
		add	ah, al			; hard disk, ending hard disk
@03_Reassign:	mov	StartDisk, al		; is last main hard disk
		mov	EndDisk, ah
		push	ax
		mov	bl, 1			;Starting partition is first,
		mov	bh, PartPerBootRec	; ending partition is fourth,
		mov	cl, True		; end loop if partition found
		call	ReassMain		;Process first primary part
		mov	bl, PartPerBootRec + 1	;Starting partition is fifth,
		mov	bh, MaxPartitions	; ending partition is unset,
		xor	cl, cl			; process all partitions
		call	ReassMain		;Process logical partitions
		mov	bl, 1			;Starting partition is first,
		mov	bh, PartPerBootRec	; ending partition is fourth,
		mov	cl, True		; process all partitions
		call	ReassMain		;Process further primary part
		pop	ax
		mov	bl, FirstHardDisk + MaxHardDisks
		cmp	ah, bl			;Exit if already processed all
		je	@00_Reassign		; hard disks
		mov	al, ah			;Again with non-main hard disk
		mov	ah, bl			; as starting hard disk and
		jmp	@03_Reassign		; last hard disk as ending
@00_Reassign:	retn

;Display a string
;  Input : DS:DX: the zero-terminated string
;          CF: when not 0, a line feed is added
PrintStr:	pushf
		cmp	Quiet, False		;Skip if set to operate
		jne	@00_PrintStr		; quietly
		popf
		push	si			;Save registers
		push	bx
		push	cx
		pushf
		mov	si, dx			;Compute length of string
		mov	bx, 1
		call	StrLen
		or	ax, ax			;Skip printing string if empty
		je	@01_PrintStr
		mov	cx, ax			;Print string
		mov	ah, 40h
		int	21h
@01_PrintStr:	popf
		jnc	@02_PrintStr		;Skip line feed if needed
		mov	dx, Offset LineFeed	;Print line feed string
		mov	cx, 2
		mov	ah, 40h
		int	21h
@02_PrintStr:	pop	cx			;Restore registers
		pop	bx
		pop	si
		retn
@00_PrintStr:	popf
		retn

;Convert number into hexadecimal string
;  Input : AX:DX: the number
;          CH: number of digits; if string is shorter, leading is added
;          CL: leading character to fill short strings with; 0: no leading
;  Output: DS:DX: number in string format
HexStr:		mov	bx, 10h
		jmp	NumStr
;Convert number into decimal string
;  Input : AX:DX: the number
;  Output: DS:DX: number in string format
DecStr:		mov	bx, 10
		xor	cx, cx
;Convert number into string format
;  Input : AX:DX: the number
;          BX: radix
;          CH: number of digits; if string is shorter, leading is added
;          CL: leading character to fill short strings with; 0: no leading
;  Output: DS:DX: number in string format
NumStr:		push	si			;Save registers
		push	di
		push	cx
		mov	si, bx
		mov	di, Offset NumStrBuffer[MaxNumStrLen]
		mov	byte ptr [di], 0	;Start at the end of string
		mov	cx, di			;Save offset to end of string
		mov	bx, dx
@01_NumStr:	xor	dx, dx			;Divide number by radix
		xchg	bx, ax
		div	si
		xchg	bx, ax
		div	si
		add	dl, '0'			;Convert remainder to decimal
		cmp	dl, '9'			; or hexadecimal digit
		jbe	@02_NumStr
		add	dl, 'A' - '0' - 10
@02_NumStr:	dec	di			;Put digit into string, going
		mov	[di], dl		; backwards
		mov	dx, ax			;End if number has been
		or	dx, bx			; reduced to zero
		jne	@01_NumStr
		sub	cx, di			;Compute length of string
		pop	bx
		or	bh, bh			;Skip if empty leading char
		je	@03_NumStr
		sub	bh, cl			;Skip if string is long enough
		jbe	@03_NumStr
@04_NumStr:	dec	di			;Put leading character into
		mov	byte ptr [di], bl	; string, going backwards
		inc	cx
		dec	bh
		jne	@04_NumStr
@03_NumStr:	mov	dx, di
		pop	di			;Restore registers
		pop	si
		retn

;Print drive information
;  Input : CH: logical drive number (0=A:, 1=B:...)
;          DS:SI: drive entry in internal drive table
PrDrvInfo:	cmp	ListAssign, False	;Exit if listing is disabled
		je	@00_PrDrvInfo
		test	[si].DriveEntry.ldAttrib, DriveValidMask
		je	@00_PrDrvInfo		;Exit if empty drive
		push	ax			;Save registers
		push	bx
		push	cx
		push	dx
		push	si
		mov	al, ch			;Put logical drive letter into
		add	al, 'A'			; string
		mov	byte ptr DriveInfo1[0], al
		mov	dx, Offset DriveInfo1	;Print drive letter and Tab
		clc
		call	PrintStr
		mov	al, [si].DriveEntry.ldPhysDriveNum
		cmp	al, LastFloppyDisk	;Up to last floppy disk
		jbe	@01_PrDrvInfo
		cmp	al, FirstHardDisk	;Between first and last hard
		jb	@03_PrDrvInfo		; disk
		cmp	al, FirstHardDisk + MaxHardDisks
		jae	@03_PrDrvInfo
		sub	al, FirstHardDisk - 'a'	;Create name for hard disk,
		mov	dx, 'dh'		; "hda" to "hdh"
		clc				;Partition number is needed
		jmp	@04_PrDrvInfo
@03_PrDrvInfo:	mov	word ptr DiskName[0], '?'	;Strange physical
		stc				; drive number, error
		jmp	@02_PrDrvInfo
@01_PrDrvInfo:	add	al, '0'			;Create name for floppy disk,
		mov	dx, 'df'		; "fd0" to "fd3"
		stc				;Omit partition number
@04_PrDrvInfo:	mov	word ptr DiskName[0], dx
		mov	byte ptr DiskName[2], al
@02_PrDrvInfo:	mov	byte ptr DiskName[3], 0
		pushf
		mov	dx, Offset DiskName	;Print physical drive name
		clc
		call	PrintStr
		popf				;Skip partition number for
		jc	@05_PrDrvInfo		; floppies and strange drives
		mov	al, [si].DriveEntry.ldPartNum
		xor	ah, ah			;Convert partition number to
		xor	dx, dx			; decimal string, without any
		xor	cx, cx			; leading character
		call	DecStr
		clc
		call	PrintStr		;Print partition number
@05_PrDrvInfo:	mov	dx, Offset DriveInfo2	;Print Tab
		clc
		call	PrintStr
		lea	dx, [si].DriveEntry.ldVolumeLabel
		clc				;Print volume label
		call	PrintStr
		mov	dx, Offset DriveInfo2	;Print Tab
		clc
		call	PrintStr
		mov	ax, word ptr [si].DriveEntry.ldSerialNum[2]
		xor	dx, dx			;Convert upper half of serial
		mov	cx, 0430h		; number to hexadecimal
		call	HexStr			; string, filled to four
		clc				; characters with leading
		call	PrintStr		; zeros, and print it
		mov	dx, Offset DriveInfo3	;Print hyphen
		clc
		call	PrintStr
		mov	ax, word ptr [si].DriveEntry.ldSerialNum[0]
		xor	dx, dx			;Print lower half of serial
		mov	cx, 0430h		; number the same way
		call	HexStr
		stc
		call	PrintStr
		pop	si
		pop	dx			;Restore registers
		pop	cx
		pop	bx
		pop	ax
@00_PrDrvInfo:	retn

;Print drive letter changes
;  Input : CL: source logical drive number (0=A:, 1=B:...)
;          CH: destination logical drive number (0=A:, 1=B:...; -1=empty)
PrDriveChg:	push	ax			;Save registers
		push	bx
		push	cx
		push	dx
		test	ch, dlDelFlag		;Determine whether drive
		je	@01_PrDriveChg		; letter deleted or moved
		add	cl, 'A'			;Store source drive letter
		mov	byte ptr DriveChange2[0], cl	; into message
		mov	ax, Offset DriveChange2	;Display "deleting" message
		mov	dx, Offset DriveDelete
		jmp	@02_PrDriveChg
@01_PrDriveChg:	add	cl, 'A'			;Store source drive letter
		mov	byte ptr DriveChange1[0], cl	; into message
		mov	ax, Offset DriveChange1	;Display "moving" message
		mov	dx, Offset DriveMove
		add	ch, 'A'			;Store destination drive
		mov	byte ptr DriveChange2[0], ch	; letter into message
@02_PrDriveChg:	push	ax
		clc
		call	PrintStr
		pop	dx
		stc
		call	PrintStr		;Display messages
		pop	dx			;Restore registers
		pop	cx
		pop	bx
		pop	ax
		retn

;Compute the length of a string
;  Input : DS:SI: the string
;  Output: AX: the length of the string
StrLen:		cld
		push	si			;Save registers
		xor	ax, ax
@02_StrLen:	cmp	byte ptr [si], 0	;Exit if string terminated
		je	@01_StrLen	
		inc	ax			;Increase length
		inc	si			;Continue with next character
		jne	@02_StrLen
@01_StrLen:	pop	si			;Restore registers
		retn

;Compare two string, case sensitively
;  Input : DS:SI: the first string
;          ES:DI: the second string
;  Output: ZF: when set, the two strings match
StrComp:	push	ax			;Save registers
		push	cx
		push	si
		push	di
		call	StrLen			;Get length of first string,
		inc	ax			; add 1 to process terminator
		mov	cx, ax			; zero, as well
		cld				;Do the comparation
		repe	cmpsb
		pop	di			;Restore registers
		pop	si
		pop	cx
		pop	ax
		retn

;Get a parameter from the command line, converted to full uppercase
;  Input : BL: parameter number
;          ES:DI: pointer to put parameter value to
;          CX: length of buffer, maximum length for parameter value
;  Output: BH: number of last parameter processed, if below initial value of
;              BL then too few parameters were specified on the command line
ParamStr:	push	di
		mov	si, Offset OrigCmdLine	;Beginning of command line
		xor	bh, bh			;No parameters processed yet
		xor	ah, ah			;Clear "quoted" flag
@01_ParamStr:	lodsb				;Get character
		or	al, al			;Exit if end of command line
		je	@02_ParamStr
		cmp	al, ' '			;Skip all white spaces in
		je	@01_ParamStr		; front of the parameter
		cmp	al, chTab
		je	@01_ParamStr
		inc	bh			;Increase number of parameters
		cmp	bl, bh			; processed and skip if have
		je	@03_ParamStr		; arrived at desired parameter
@04_ParamStr:	or	al, al			;Exit if end of command line
		je	@02_ParamStr
		cmp	al, '"'			;Toggle "quoted" flag when
		jne	@07_ParamStr		; reading a quotation mark
		xor	ah, 1
		jmp	@08_ParamStr
@07_ParamStr:	or	ah, ah
		jne	@08_ParamStr
		cmp	al, ' '			;Continue with next parameter
		je	@01_ParamStr		; when reading a white space
		cmp	al, chTab
		je	@01_ParamStr
@08_ParamStr:	lodsb				;Skip all characters of the
		jmp	@04_ParamStr		; parameter
@03_ParamStr:	or	di, di			;Exit if buffer points to NULL
		je	@05_ParamStr
@06_ParamStr:	or	al, al			;Exit if end of command line
		je	@02_ParamStr
		cmp	al, '"'			;Toggle "quoted" flag when
		jne	@09_ParamStr		; reading a quotation mark
		xor	ah, 1
		jmp	@10_ParamStr
@09_ParamStr:	or	ah, ah			;White spaces are part of the
		jne	@11_ParamStr		; parameter when quoted
		cmp	al, ' '			;Exit when reading a white
		je	@02_ParamStr		; space
		cmp	al, chTab
		je	@02_ParamStr
@11_ParamStr:	call	UpCase			;Turn character to uppercase
		stosb				; and store it into the buffer
@10_ParamStr:	lodsb				;Continue with next character
		loop	@06_ParamStr
@02_ParamStr:	xor	al, al			;Terminate the string
		stosb
@05_ParamStr:	pop	di			;Restore registers
		retn

;Turn character to uppercase
;  Input : AL: original character
;  Output: AL: uppercase character
UpCase:		cmp	al, 'a'			;Skip if character not between
		jb	@01_UpCase		; lowercase "a" and "z"
		cmp	al, 'z'
		ja	@01_UpCase
		sub	al, 'a' - 'A'		;Turn character to uppercase
@01_UpCase:	retn

Hello:		db	'Drive Letter Manipulator 0.35 beta by Joe Forster/STA', chCR, chLF, 0
Usage		db	'This program displays, moves, deletes, swaps or reassigns drive letters.', chCR, chLF
		db	chCR, chLF
		db	'Usage:', chCR, chLF
		db	'  DLMANIP [-|/<options>] LIST', chCR, chLF
		db	'  DLMANIP [-|/<options>] SET <drive> <volume label> <serial number>', chCR, chLF
		db	'  DLMANIP [-|/<options>] MOVE <src drive> <dest drive>', chCR, chLF
		db	'  DLMANIP [-|/<options>] DELETE <drive>', chCR, chLF
		db	'  DLMANIP [-|/<options>] SWAP <drive #1> <drive #2>', chCR, chLF
		db	'  DLMANIP [-|/<options>] REASSIGN <number of main hard disks>', chCR, chLF
		db	chCR, chLF
		db	'The device driver is run from CONFIG.SYS via the "DEVICE=" command.', 0
CmdNames	db	'LIST', 0		;Command names
		db	'SET', 0
		db	'MOVE', 0
		db	'DELETE', 0
		db	'SWAP', 0
		db	'REASSIGN', 0
		db	0
CmdEntries	EntryPt	<ListLetters, True>	;Command entry points and
		EntryPt	<SetLetter, False>	; pre-exec flags
		EntryPt	<MoveLetter, False>
		EntryPt	<DelLetter, False>
		EntryPt	<SwapLetter, False>
		EntryPt	<Reassign, False>
UnknownOption	db	'Unknown option', 0
UnknownCommand	db	'Unknown command', 0
InvalidParam	db	'Invalid or missing parameter', 0
LetterTooHigh	db	'Drive letter beyond LASTDRIVE value', 0
WrongDOSVersion	db	'Unsupported DOS version', 0
WindowsRunning	db	'Windows running', 0
CacheInstalled	db	'Cache detected', 0
DriveNumInvalid	db	'Invalid LASTDRIVE value', 0
DPBDriveNumInv	db	'Invalid DPB drivenum', 0
BadDriveLetter	db	'CDS drive letter mismatch', 0
BadCDSOrDPB	db	'CDS or DPB chain corrupted', 0
WeirdCDSPath	db	'Invalid CDS structure', 0
DriveInfo1	db	'?', chDriveSep
DriveInfo2	db	chTab, 0
DriveInfo3	db	'-', 0
DriveDelete	db	'Deleting ', 0
DriveMove	db	'Moving ', 0
DriveChange1	db	'?', chDriveSep, ' to '
DriveChange2	db	'?', chDriveSep, 0
NoChanges	db	'No changes', 0
EmptyVolLabel	db	'NO NAME', 0
AnyValue	db	'*', 0
LineFeed	db	chCR, chLF, 0

	ifdef DeviceDriver
RequestHeader	dd	?			;Device request header
	endif

DataStart:

Quiet		db	?			;Quiet operation flag
UnderWindows	db	?			;Windows running flag
UnderFreeDOS	db	?			;FreeDOS running flag
DiskCache	db	?			;Disk cache detected flag
ListAssign	db	?			;List assignments flag
ExtendedStruct	db	?			;Extended structures flag
LettersChanged	db	?			;Drive letters changed flag
FilterPartNum	db	?			;Filter by partition num flag
FilterVolLabel	db	?			;Filter by volume label flag
FilterSerialNum	db	?			;Filter by serial number flag
LastDrive  	db	?			;LASTDRIVE setting
PartNum		db	?			;Number of partitions in table
CommandParNum	db	?			;Parameter number of command
HighestDrvNum	db	?			;Highest drive number
ExtDiskFunc	db	?			;Extended disk functions flag
FollowExt	db	?			;Process ext partition flag
PhysDrvNum	db	?			;Physical drive number
PhysPartNum	db	?			;Partition num in phys drive
PartEntryCnt	db	?			;Partition table entry counter
StartDisk	db	?			;Start hard disk in reassign
EndDisk		db	?			;End hard disk in reassign
CoreFunc	dw	?			;Core function entry point
ListOfLists	dd	?			;Pointer to the list of lists
CurDirStructs	dd	?			;Pointer to cur dir structs
DrvDatTable	dd	?			;Pointer to drive data table
SerialNumber	dd	?			;Volume serial number

OrigCmdLine	db	(CmdLineSize + 1) dup (?)	;Command line
CmdParam	db	(CmdParamSize + 1) dup (?)	;Command line param
NumStrBuffer	db	(MaxNumStrLen + 1) dup (?)
VolumeLabel	db	(VolLabLen + 1) dup (?)	;Volume label
DiskName	db	(3 + 1) dup (?)		;Linux-style disk/part name
DiskFuncPack	ExtDiskFuncPack <?>		;Extended disk function packet
ExtStartSecPos	dw	3 dup (?)		;Start of extended partition
SecPos		dw	3 dup (?)		;Start of current partition
BootRec		Sector <?>			;Boot record
BootSec		Sector <?>			;Boot sector
DriveTable	db	(MaxDrives * DrvEntrySize) dup (?)
PhysDriveTable	db	(MaxPartitions * PhysDrvEntSize) dup (?)
						;Drive tables, working area

DataEnd:

CSeg		ends

		end	Main
