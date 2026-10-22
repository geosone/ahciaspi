AHCIASPI 0.3 - ASPI manager for ATAPI drives on AHCI and IDE controllers
==========================================================================

AHCIASPI.SYS is an ASPI manager (device SCSIMGR$) for DOS.  It makes ATAPI
drives - CD/DVD, ZIP, LS-120, tape and others - usable for DOS ASPI
drivers such as ASPICD.SYS, ASPIDISK.SYS, MKELS120.SYS or GUEST.EXE.

The drives can be connected to
  - an AHCI SATA controller, directly or through a SATA/IDE adapter,
  - the classic IDE channels (1F0h, 170h),
  - PCI IDE and RAID cards in native mode (SiI0680, Promise, HighPoint,
    ITE8212, ...),
  - any other IDE channel given with /P:.

AHCIASPI also works in the DOS boxes of Windows 3.x.

License: GNU General Public License version 3 (see LICENSE.TXT).
Source:  https://github.com/geosone/ahciaspi


Installation
------------

Run INSTALL.EXE from the distribution disk or directory.  It copies the
files to C:\OPENASPI (shared with EUSBASPI and OpenASPI) and adds
AHCIASPI.SYS to CONFIG.SYS.  INSTALL /U in C:\OPENASPI\AHCIASPI removes
it again.

CD-ROM drive (option, on by default): if INSTALL finds ASPICD.SYS and
MSCDEX.EXE or SHSUCDX (in C:\DOS, the PATH, the Windows directory or the
paths in CONFIG.SYS / AUTOEXEC.BAT), it adds

    DEVICE=...\ASPICD.SYS /D:ASPICD0

to CONFIG.SYS and " /D:ASPICD0" to the MSCDEX/SHSUCDX line in
AUTOEXEC.BAT (or a new line "MSCDEX /D:ASPICD0").  In the same way it
adds ASPIDISK.SYS (ZIP, LS-120 etc. as DOS drives) and MKELS120.SYS
(LS-120/LS-240 drives) after AHCIASPI.SYS.

ASPI drivers on the installation disk: copy ASPICD.SYS, ASPIDISK.SYS,
MKELS120.SYS (or MSCDEX.EXE, SHSUCDX.COM) next to INSTALL.EXE, and
INSTALL installs these copies instead of searching the computer.

By hand: copy AHCIASPI.SYS to the hard disk and add it to CONFIG.SYS
before the ASPI drivers that use it, for example:

    DEVICE=C:\AHCIASPI\AHCIASPI.SYS
    DEVICE=C:\CDROM\ASPICD.SYS /D:ASPICD0
    DEVICE=C:\ZIP\ASPIDISK.SYS

and in AUTOEXEC.BAT for the CD-ROM:

    MSCDEX /D:ASPICD0 /L:R


Windows 3.x: 32-bit disk access (AHCIVXD.386)
----------------------------------------------

AHCIVXD.386 is a "FastDisk" for Windows 3.1x enhanced mode, like WDCTRL or
the Micro House driver, but for today's disks: SATA (AHCI) and IDE, LBA
with 48 bit (disks of any size), DMA (AHCI always, IDE bus master when the
BIOS set a DMA mode), 32-bit PIO otherwise.  Windows then reads and writes
the hard disks without the BIOS (32-bit disk access, faster, and needed
for the 32-bit file access of Windows for Workgroups 3.11 to work well).
It also handles INT 13h of the DOS boxes for these disks, including the
extended functions (41h-48h) that MS-DOS 7.x uses for LBA and FAT32
partitions and that Windows 3.1 itself doesn't know.

The BIOS disks 80h-83h are found on the controllers by their first
sector.  INSTALL adds to SYSTEM.INI, [386Enh]:

    device=*int13
    device=C:\AHCIASPI\AHCIVXD.386
    32BitDiskAccess=on

(and removes device=*wdctrl).  Options in SYSTEM.INI, [AHCIVXD]:
DMA=0 (no DMA), PIO32=0 (16-bit PIO), Int13=0 (don't handle the INT 13h
of the DOS boxes), BiosFix=0 (no BIOS VDS fix, see below), LogPort=n
(debug output to I/O port n, e.g. 233 = E9h for QEMU).

BIOS VDS fix (Intel AHCI firmware)
----------------------------------

The INT 13h code of Intel AHCI option ROMs uses the Virtual DMA Services
of memory managers wrongly (unlock with the wrong segment register, data
written over the start of the EBDA), which crashes Windows 3.1 enhanced
mode and can disturb EMM386.  AHCIASPI.SYS works around it in DOS (on by
default with an Intel AHCI controller, /BIOSFIX forces it, /NOBIOSFIX
turns it off; without ATAPI devices only this part stays resident, as
AHCIFIX$), AHCIVXD.386 under Windows.  Based on ahcifix.386 and
ahcifixd.sys by PluMGMK.


Switches
--------

    DEVICE=AHCIASPI.SYS [/C:n] [/ID:name] [/M:x] [/PIO] [/RAWINQ] [/T:s]
                        [/Q] [/V] [/NOAHCI] [/NOIDE] [/NOPCI] [/P:port[,ctl]]
                        [/BIOSFIX] [/NOBIOSFIX]

  /C:n        Use the AHCI controller n (0 = first, the default).
  /ID:name    ASPI manager name reported to the clients (up to 16
              characters, default AHCIASPI).  Some drivers only work with
              a certain name, e.g. MKELS120.SYS finds
              its drive best with /ID:ATAPIMGR.
  /M:x        Register access method of the AHCI controller:
                I  index/data pair in an I/O BAR
                C  index/data pair in the PCI configuration space
                F  flat real mode (only without EMM386/386MAX)
                B  BIOS INT 15h AH=87h (slow, works everywhere)
              Without /M AHCIASPI chooses a method that works.
  /PIO        No DMA, data is transferred by the CPU.
  /RAWINQ     Report CD/DVD drives as they answer INQUIRY; by default they
              are reported as SCSI-2 devices, which old CD-ROM drivers need.
  /T:s        Command timeout in seconds (default 15).
  /Q          Quiet: no messages at boot time.
  /V          Verbose: show details of the controllers and drives.
  /NOAHCI     Do not use AHCI controllers.
  /NOIDE      Do not use IDE channels.
  /NOPCI      Only the standard IDE channels, no PCI IDE cards.
  /P:port[,ctl]
              Additional IDE channel at I/O port "port" (hex) with the
              control port "ctl" (default port+206h).  May be repeated.
  /BIOSFIX    BIOS VDS fix on (default: on with an Intel AHCI controller).
  /NOBIOSFIX  BIOS VDS fix off.

Several ASPI managers: if another ASPI manager (USBASPI.SYS, EUSBASPI.SYS,
ASPI8DOS.SYS, ...) is loaded before AHCIASPI, AHCIASPI chains to it.  Its
host adapters keep their numbers and the AHCIASPI adapter follows them.


Files
-----

  AHCIASPI.SYS   the driver
  AHCIVXD.386    32-bit disk access for Windows 3.1x enhanced mode
  ASPITEST.COM   test program: lists the ASPI host adapters and devices
  README.TXT     this file
  LICENSE.TXT    GNU General Public License version 3
  INSTALL.EXE    GeosOne DOS Installer (https://github.com/geosone/gdi)
  INSTALL.INI    its configuration

Optional (installed when selected):

  DLMANIPF.SYS   Drive Letter Manipulator, fixed version (see DLMANIPF.TXT)
  DLMANIPF.COM
  DLMANIPF.TXT


Notes
-----

  - AHCIASPI polls the drives and uses no interrupts.  The BIOS keeps
    access to hard disks on the same controller.
  - This is a first version.  Please report problems with the output of
    "DEVICE=AHCIASPI.SYS /V" and "ASPITEST" at the GitHub project.
