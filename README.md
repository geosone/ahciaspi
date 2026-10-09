# AHCIASPI - ASPI manager for ATAPI drives on AHCI and IDE controllers

`AHCIASPI.SYS` is an ASPI manager (device `SCSIMGR$`) for DOS. It makes ATAPI drives - CD/DVD, ZIP, LS-120/LS-240, tape and others - usable for DOS ASPI drivers such as `ASPICD.SYS`, `ASPIDISK.SYS`, `MKELS120.SYS` or `GUEST.EXE`.

The drives can be connected to:
- an AHCI SATA controller, directly or through a SATA/IDE adapter,
- the classic IDE channels (1F0h, 170h),
- PCI IDE and RAID cards in native mode (SiI0680, Promise, HighPoint, ITE8212, ...),
- any other IDE channel given with `/P:`.

It also works in the DOS boxes of Windows 3.x, and together with other ASPI managers (USBASPI, [EUSBASPI](https://github.com/geosone/eusbaspi), ASPI8DOS, ...): AHCIASPI chains to a manager loaded before it.

**Status:** first version. Tested in QEMU (AHCI and IDE), 86Box (IDE, ZIP, CD audio) and VirtualBox; not yet on much real hardware. Reports with the output of `DEVICE=AHCIASPI.SYS /V` and `ASPITEST` are welcome.

## Installation

Download the ZIP of the [latest release](https://github.com/geosone/ahciaspi/releases), unpack it to a disk or directory and run `INSTALL.EXE` (the [GeosOne DOS Installer](https://github.com/geosone/gdi)). It copies the files to `C:\AHCIASPI`, adds the driver to `CONFIG.SYS` and can set up:

| Option | |
|---|---|
| CD-ROM drive | `ASPICD.SYS` in `CONFIG.SYS`, `/D:ASPICD0` for `MSCDEX` or `SHSUCDX` in `AUTOEXEC.BAT` |
| ZIP, LS-120 etc. as DOS drives | `ASPIDISK.SYS` |
| LS-120/LS-240 drives | `MKELS120.SYS` |
| Drive letter tools | `DLMANIPF.SYS`/`.COM` (see below) |

**ASPI drivers.** `ASPICD.SYS`, `ASPIDISK.SYS` and `MKELS120.SYS` are not free software and are not part of AHCIASPI. The installer finds them:
1. **on the installation disk:** copy them next to `INSTALL.EXE` (e.g. onto the AHCIASPI disk), and the installer installs these copies to `C:\AHCIASPI`;
2. otherwise **on the computer:** in `C:\DOS`, the `PATH`, the Windows directory or the paths named in `CONFIG.SYS`/`AUTOEXEC.BAT` (MS-DOS 7.1 has `ASPICD.SYS` and `MSCDEX.EXE` in `C:\DOS`).

The same holds for `MSCDEX.EXE` / `SHSUCDX.COM`. Options whose driver is found nowhere are left out.

`INSTALL /U` in `C:\AHCIASPI` removes the installation again.

By hand, `CONFIG.SYS`:

    DEVICE=C:\AHCIASPI\AHCIASPI.SYS
    DEVICE=C:\ASPI\ASPICD.SYS /D:ASPICD0
    DEVICE=C:\ASPI\ASPIDISK.SYS

and `AUTOEXEC.BAT`:

    MSCDEX /D:ASPICD0

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

## DLMANIPF

`DLMANIPF.SYS`/`.COM` are DLMANIP 0.35 beta (Drive Letter Manipulator) by Joe Forster/STA, built from his public domain source with fixes for drives of installable block drivers (`MKELS120.SYS`, `GUEST.EXE`, `ASPIDISK.SYS`), see [tools/dlmanip](tools/dlmanip). Typical use: give an LS-120 drive the letter A: and a ZIP drive B:.

## Building

Linux (or any system with the tools), GNU make:
- [NASM](https://nasm.us) for `AHCIASPI.SYS` and the tools,
- [JWasm](https://github.com/Baron-von-Riedesel/JWasm) for DLMANIPF,
- the [GeosOne DOS Installer](https://github.com/geosone/gdi) (`../gdi/build/INSTALL.EXE`, or `make package GDI=path`) for the package.

| Command | |
|---|---|
| `make` | `build/AHCIASPI.SYS`, `build/ASPITEST.COM` |
| `make dlmanip` | `build/DLMANIPF.SYS`, `build/DLMANIPF.COM` |
| `make package` | `build/pkg/` and `build/ahciaspi.zip` |

Build with `-DE9LOG` (nasm) to get every ASPI command on the QEMU debug console (`-debugcon file:e9.log`).

## Tests

`test/*.sh` run DOS in QEMU, 86Box or with Windows for Workgroups 3.11. They need your own DOS boot disk image and, for some tests, third-party drivers (ASPICD, MKELS120, GUEST, USBASPI, ...) in a directory `ref/`, which is not part of the repository.

## License

GNU General Public License version 3, see [LICENSE](LICENSE). DLMANIP source: public domain, Joe Forster/STA.
