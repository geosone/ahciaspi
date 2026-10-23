# AHCIASPI - ASPI manager for ATAPI drives on AHCI and IDE controllers

`AHCIASPI.SYS` is an ASPI manager (device `SCSIMGR$`) for DOS. It makes ATAPI drives - CD/DVD, ZIP, LS-120/LS-240, tape and others - usable for DOS ASPI drivers: the [OpenASPI](https://github.com/geosone/OpenAspi) drivers that come with it, or others such as Adaptec's `ASPICD.SYS`, `ASPIDISK.SYS`, `MKELS120.SYS` or `GUEST.EXE`.

The drives can be connected to:
- an AHCI SATA controller, directly or through a SATA/IDE adapter,
- the classic IDE channels (1F0h, 170h),
- PCI IDE and RAID cards in native mode (SiI0680, Promise, HighPoint, ITE8212, ...),
- any other IDE channel given with `/P:`.

It also works in the DOS boxes of Windows 3.x, and together with other ASPI managers (USBASPI, [EUSBASPI](https://github.com/geosone/eusbaspi), ASPI8DOS, ...): AHCIASPI chains to a manager loaded before it.

**Status:** first version. Tested in QEMU (AHCI and IDE), 86Box (IDE, ZIP, CD audio) and VirtualBox; not yet on much real hardware. Reports with the output of `DEVICE=AHCIASPI.SYS /V` and `ASPITEST` are welcome.

## Installation

Download the ZIP of the [latest release](https://github.com/geosone/ahciaspi/releases), unpack it to a disk or directory and run `INSTALL.EXE` (the [GeosOne DOS Installer](https://github.com/geosone/gdi)). It copies the files to `C:\OPENASPI` (shared with EUSBASPI and OpenASPI; the installer itself goes to `C:\OPENASPI\AHCIASPI`), adds the driver to `CONFIG.SYS` and can set up the [OpenASPI](https://github.com/geosone/OpenAspi) drivers that come with it, each one an option, loaded after `AHCIASPI.SYS`:

| Option | |
|---|---|
| CD/DVD drives (on) | `ASPICDA.SYS /D:ASPICDA0`; [SHSUCDX](https://github.com/geosone/shsucd) in the place of `MSCDEX` (MS-DOS) or `NWCDEX` (DR-DOS) in `AUTOEXEC.BAT`, with digital CD audio through [VSBHDA](https://github.com/geosone/VSBHDA) (`CDAUDIO.COM`) |
| ZIP, LS-120, LS-240, Clik!, Jaz (on) | `ASPIFDD.SYS` |
| Disks, card readers, USB sticks | `ASPIDSK.SYS` |
| Tape drives | `ASPITAP.SYS`, `TAPECTL.COM` |
| Drive letter tools | `DLMANIPF.SYS`/`.COM` (see below) |
| Windows 3.x (on) | `AHCIVXD.386` (see below) |
| PATH (on) | `C:\OPENASPI` in the `PATH` |

With AHCIASPI already loaded, `ASPISCAN.COM` finds disks and tape drives and preselects their options. OpenASPI and SHSUCD have installers of their own; all of them share `C:\OPENASPI`, so each can be installed alone or together.

**CD-ROM.** The installer takes the CD-ROM extension in this order: `SHSUCDX.COM` of the installation disk, else `SHSUCDX`, `MSCDEX.EXE`, `NWCDEX.EXE` on the computer. An existing `MSCDEX`/`NWCDEX` line keeps its drivers and drive letters, starts SHSUCDX instead (SHSUCDX ignores the MSCDEX options it doesn't have) and gets `/D:ASPICDA0`; `INSTALL /U` puts MSCDEX or NWCDEX back.

**From 0.3:** remove 0.3 first (`INSTALL /U` in `C:\OPENASPI\AHCIASPI`): it loaded Adaptec's `ASPICD.SYS`, `ASPIDISK.SYS` and `MKELS120.SYS`, which use the same drives as the OpenASPI drivers.

`INSTALL /U` in `C:\OPENASPI\AHCIASPI` removes the installation again; `C:\OPENASPI` stays while EUSBASPI or OpenASPI are still there.

By hand, `CONFIG.SYS`:

    DEVICE=C:\OPENASPI\AHCIASPI.SYS
    DEVICE=C:\OPENASPI\ASPICDA.SYS /D:ASPICDA0
    DEVICE=C:\OPENASPI\ASPIFDD.SYS

and `AUTOEXEC.BAT`:

    C:\OPENASPI\SHSUCDX.COM /D:ASPICDA0

(Adaptec's `ASPICD.SYS /D:ASPICD0` with `MSCDEX` works the same way.)

## Windows 3.x: 32-bit disk access (AHCIVXD.386)

`AHCIVXD.386` is an open source "FastDisk" for Windows 3.1x enhanced mode - what WDCTRL (and the Micro House driver for larger disks) did for old IDE disks, for today's hardware:

- SATA disks on AHCI controllers and IDE disks (PCI native and legacy channels),
- LBA48 (any size), DMA (AHCI always; IDE bus master when the BIOS set a DMA mode), else 32-bit PIO,
- registers the BIOS disks 80h-83h with BlockDev, so Windows (paging, 32-bit file access of WfW 3.11, DOS boxes) uses them without the BIOS,
- handles INT 13h of the DOS boxes for these disks, including the extended functions 41h-48h that MS-DOS 7.x uses for LBA/FAT32 partitions (Windows 3.1's Int13 device doesn't know them),
- the BIOS VDS fix for Intel AHCI firmware (see below) for disks still driven by the BIOS.

The installer option adds `device=*int13`, `device=C:\OPENASPI\AHCIVXD.386` and `32BitDiskAccess=on` to `[386Enh]` of `SYSTEM.INI` (and removes `*wdctrl`). Settings in `[AHCIVXD]`: `DMA=0`, `PIO32=0`, `Int13=0`, `BiosFix=0`, `LogPort=233` (debug output to port E9h in QEMU).

How it works: the real mode part reads each BIOS disk's first sector through the BIOS and passes its CRC-32 in the BIOS intra-application area; in `Sys_Critical_Init` the VxD finds the disks on the controllers by it and registers them with BlockDev (as WDCTRL does, the geometry from the BIOS fixed disk tables); in `Device_Init` it asks the BIOS (nested V86 execution) for the geometry and size and hooks INT 13h. Each AHCI command saves and restores the BIOS's port state, so the BIOS (and AHCIASPI in DOS boxes) keep working on the same controller. Written from the documented BlockDev/Int13/VMM interfaces.

**Status:** first version, tested in QEMU with Windows for Workgroups 3.11 (IDE with bus master DMA, AHCI): Windows' BlockDev requests and the DOS boxes' INT 13h (CHS and 41h-48h) run through it, copies are byte-identical. Not yet tested on real hardware.

## BIOS VDS fix (Intel AHCI firmware)

The INT 13h code of Intel AHCI option ROMs uses the Virtual DMA Services of memory managers wrongly: it unlocks a region with the descriptor in DS instead of ES, and puts the descriptor at the start of the EBDA (overwriting e.g. the PS/2 mouse data). This crashes Windows 3.1 enhanced mode and can disturb EMM386. `AHCIASPI.SYS` works around it in DOS - on by default with an Intel AHCI controller, `/BIOSFIX` forces it, `/NOBIOSFIX` turns it off; without ATAPI devices only this part stays resident (as `AHCIFIX$`) - and `AHCIVXD.386` under Windows. Based on [ahcifix.386](https://github.com/PluMGMK/ahcifix.386) and [ahcifixd.sys](https://github.com/PluMGMK/ahcifixd.sys) (MIT) by PluMGMK.

## Switches

    DEVICE=AHCIASPI.SYS [/C:n] [/ID:name] [/M:x] [/PIO] [/RAWINQ] [/T:s]
                        [/Q] [/V] [/NOAHCI] [/NOIDE] [/NOPCI] [/P:port[,ctl]]

| Switch | |
|---|---|
| `/C:n` | AHCI controller n (0 = first, default) |
| `/ID:name` | ASPI manager name (up to 16 characters, default `AHCIASPI`); `MKELS120.SYS` finds its drive best with `/ID:ATAPIMGR` |
| `/M:x` | register access of the AHCI controller: `I` index/data pair in an I/O BAR, `C` index/data pair in PCI config space, `F` flat real mode (not with EMM386), `B` BIOS INT 15h AH=87h; default: one that works |
| `/PIO` | no DMA |
| `/RAWINQ` | report CD/DVD drives as they answer INQUIRY (default: as SCSI-2 devices, which old CD-ROM drivers need for audio) |
| `/T:s` | command timeout in seconds (default 15) |
| `/Q`, `/V` | quiet, verbose |
| `/NOAHCI`, `/NOIDE` | no AHCI controllers, no IDE channels |
| `/NOPCI` | only the standard IDE channels, no PCI IDE cards |
| `/P:port[,ctl]` | additional IDE channel (hex), control port default port+206h; may be repeated |
| `/BIOSFIX`, `/NOBIOSFIX` | BIOS VDS fix on / off (default: on with an Intel AHCI controller) |

## DLMANIPF

`DLMANIPF.SYS`/`.COM` are DLMANIP 0.35 beta (Drive Letter Manipulator) by Joe Forster/STA, built from his public domain source with fixes for drives of installable block drivers (`MKELS120.SYS`, `GUEST.EXE`, `ASPIDISK.SYS`), see [tools/dlmanip](tools/dlmanip). Typical use: give an LS-120 drive the letter A: and a ZIP drive B:.

## Building

Linux (or any system with the tools), GNU make:
- [NASM](https://nasm.us) for `AHCIASPI.SYS` and the tools,
- [JWasm](https://github.com/Baron-von-Riedesel/JWasm) for DLMANIPF and AHCIVXD,
- Open Watcom (`wcc386`) and a JWlink with working Windows 3.x VxD output (`LINK=path`, see [jwlink PR #17](https://github.com/Baron-von-Riedesel/jwlink/pull/17)) for AHCIVXD,
- for the package: the [GeosOne DOS Installer](https://github.com/geosone/gdi) 1.14 (`../gdi/build/INSTALL.EXE`, or `make package GDI=path`), the OpenASPI drivers (`make` in [OpenAspi](https://github.com/geosone/OpenAspi): `../OpenAspi/build/dos`, or `OPENASPI=dir`) and SHSUCDX/CDAUDIO (`install/mkpkg.sh` in [shsucd](https://github.com/geosone/shsucd): `../shsucd/build/pkg`, or `SHSUCD=dir`).

| Command | |
|---|---|
| `make` | `build/AHCIASPI.SYS`, `build/ASPITEST.COM`, `build/vxd/AHCIVXD.386` |
| `make dlmanip` | `build/DLMANIPF.SYS`, `build/DLMANIPF.COM` |
| `make package` | `build/pkg/`, `build/ahciaspi.zip` and the disk image `build/AHCIASPI.IMG` (mtools) |

Build with `-DE9LOG` (nasm) to get every ASPI command on the QEMU debug console (`-debugcon file:e9.log`).

## Tests

`test/install.sh` installs the package (`make package`) in QEMU with MS-DOS 7.1 (`BOOTIMG`, a boot floppy with XMGR, UDVD2 and MSCDEX): an IDE CD with MSCDEX before, an AHCI CD after setup; both get their letters from SHSUCDX, and `INSTALL /U` restores `CONFIG.SYS` and the MSCDEX line.

`test/fastdisk.sh` (AHCIVXD in WfW 3.11, `DISK=ide|ahci`, runs `EXT13.COM` and copies files) and `test/biosfix.sh` (the BIOS VDS fix under EMM386) need the WfW image of EUSBASPI's `test/mkwin311.sh`.

`test/*.sh` run DOS in QEMU, 86Box or with Windows for Workgroups 3.11. They need your own DOS boot disk image and, for some tests, third-party drivers (ASPICD, MKELS120, GUEST, USBASPI, ...) in a directory `ref/`, which is not part of the repository.

## License

GNU General Public License version 3, see [LICENSE](LICENSE). DLMANIP source: public domain, Joe Forster/STA.
