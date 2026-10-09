#!/bin/bash
# Run the user's MS-DOS 7.1 boot disk in 86Box (no window) with real ATAPI
# devices that QEMU cannot emulate: an IOMEGA ZIP 100 (IDE primary slave)
# and an ATAPI CD-ROM with audio support (IDE secondary master).  86Box has
# no AHCI controller, so AHCIASPI.SYS runs in its IDE mode here; this checks
# the driver with real ZIP and CD audio devices, the clients (GUEST.EXE,
# ASPICD.SYS) and the drive letter handling.
#
#   test/86box.sh
#
# Environment:
#   MANAGER  ASPI manager line (default AHCIASPI.SYS, e.g. "ATAPIMGR.SYS")
#   CONFIG   extra CONFIG.SYS lines (| separated) after the ASPI manager
#   BATCH    AUTOEXEC.BAT lines (| separated), output goes to the printer
#   CDIMAGE  CD image for the CD-ROM drive (.iso or .cue), default: data ISO
#   HDC2     second disk controller, e.g. ide_cmd646 (PCI IDE card,
#            channels 2 and 3)
#   ZIPCHAN  IDE channel:device of the ZIP drive (default 0:1)
#   CDCHAN   IDE channel:device of the CD-ROM drive (default 1:0)
#   TIMEOUT  seconds to run (default 60)
#
# Output: build/86box/printer/* (everything sent to PRN), screen.png
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/86box
DOS=${DOS_DIR:-$HOME/Iso/Dos}
BOOTIMG=${BOOTIMG:-$DOS/dos71de/Dos7.1_System_deutsch.IMG}

rm -rf "$OUT"; mkdir -p "$OUT/cdroot" "$OUT/zip"
cp "$BOOTIMG" "$OUT/boot.img"; chmod u+w "$OUT/boot.img"
nasm -f bin -o "$OUT/CDSDUMP.COM" "$ROOT/tools/cdsdump.asm"
nasm -f bin -w-reloc-abs-word -I"$ROOT/src/" -o "$OUT/AHCIASPI.SYS" "$ROOT/src/ahciaspi.asm"
nasm -f bin -o "$OUT/CDPLAY.COM" "$ROOT/tools/cdplay.asm"

crlf() { tr '|' '\n' | sed 's/$/\r/'; }
{
    echo "DEVICE=A:\\${MANAGER:-AHCIASPI.SYS}"
    [ -n "${CONFIG:-}" ] && echo "$CONFIG"
    echo 'FILES=40'
    echo 'LASTDRIVE=Z'
    echo 'SHELL=A:\COMMAND.COM A:\ /P'
} | crlf > "$OUT/CONFIG.SYS"
{
    echo '@ECHO OFF'
    echo 'PATH A:\'
    echo "${BATCH:-CDSDUMP}" | tr '|' '\n' | sed 's/$/ > PRN/'
    echo 'ECHO END OF TEST > PRN'
    printf 'ECHO \014> PRN\n'
} | crlf > "$OUT/AUTOEXEC.BAT"
printf '[----scan for existing aspi managers---]\r\nSCAN=ON\r\n' > "$OUT/GUEST.INI"
mcopy -o -i "$OUT/boot.img" "$OUT/CONFIG.SYS" "$OUT/AUTOEXEC.BAT" "$OUT/GUEST.INI" \
      "$OUT/CDSDUMP.COM" "$OUT/CDPLAY.COM" "$OUT/AHCIASPI.SYS" "$ROOT/ref/zip100/GUEST.EXE" ::/
nasm -f bin -w-reloc-abs-word -I"$ROOT/tools/" -o "$OUT/ASPITEST.COM" "$ROOT/tools/aspitest.asm" && mcopy -o -i "$OUT/boot.img" "$OUT/ASPITEST.COM" ::/
[ -f "$ROOT/build/DLMANIPF.COM" ] && mcopy -o -i "$OUT/boot.img" "$ROOT/build/DLMANIPF.COM" ::/

# ZIP 100 medium: like Iomega formats it, FAT16 in partition 4 at sector 32
ZIP_SECTORS=196608
truncate -s $((ZIP_SECTORS * 512)) "$OUT/zip.img"
printf 'label: dos\n4: start=32, type=6\n' | sfdisk -q "$OUT/zip.img"
mkfs.fat -F16 -n ZIPDISK -h 32 --offset 32 "$OUT/zip.img" $(( (ZIP_SECTORS - 32) / 2 )) >/dev/null
printf 'ZIP 100 read OK\r\n' > "$OUT/zip/ZIPTEST.TXT"
mcopy -i "$OUT/zip.img@@16384" "$OUT/zip/ZIPTEST.TXT" ::/

if [ -z "${CDIMAGE:-}" ]; then
    printf 'CD read OK\r\n' > "$OUT/cdroot/CDTEST.TXT"
    xorriso -as mkisofs -quiet -V CDTEST -o "$OUT/cd.iso" "$OUT/cdroot" 2>/dev/null
    CDIMAGE=$OUT/cd.iso
fi

cat > "$OUT/86box.cfg" <<EOF
[General]
vid_renderer = qt_software
confirm_exit = 0
confirm_reset = 0
confirm_save = 0

[Machine]
machine = p55t2p4
cpu_family = pentium_p54c
cpu_speed = 133333333
cpu_multi = 2
mem_size = 32768

[Video]
gfxcard = vga

[Storage controllers]
hdc_1 = internal
${HDC2:+hdc_2 = $HDC2}

[Floppy and CD-ROM drives]
fdd_01_type = 35_2hd
fdd_01_fn = $OUT/boot.img
fdd_02_type = none
cdrom_01_parameters = 1, atapi
cdrom_01_ide_channel = ${CDCHAN:-1:0}
cdrom_01_image_path = $CDIMAGE

[Other removable devices]
rdisk_01_parameters = 1, atapi
rdisk_01_ide_channel = ${ZIPCHAN:-0:1}
rdisk_01_image_path = $OUT/zip.img

[Ports (COM & LPT)]
lpt1_enabled = 1
lpt1_device = text_prt
EOF

# 86Box needs a real X display: run it on a private Xvfb, press F1 for the
# CMOS checksum message of the fresh NVRAM, take screenshots
XDISP=:${XDISP:-77}
Xvfb "$XDISP" -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB=$!
sleep 2
DISPLAY=$XDISP QT_QPA_PLATFORM=xcb WAYLAND_DISPLAY= 86Box -N -P "$OUT" "$OUT/86box.cfg" > "$OUT/86box.log" 2>&1 &
EMU=$!
sleep "${F1DELAY:-12}"
WIN=$(DISPLAY=$XDISP xdotool search --class 86Box 2>/dev/null | tail -1)
DISPLAY=$XDISP xdotool windowfocus --sync "$WIN" 2>/dev/null
DISPLAY=$XDISP xdotool key F1
sleep "${TIMEOUT:-60}"
DISPLAY=$XDISP import -window root "$OUT/screen.png"
kill -9 $EMU 2>/dev/null; kill $XVFB 2>/dev/null; wait 2>/dev/null
echo "=== CONFIG.SYS"; tr -d '\r' < "$OUT/CONFIG.SYS"
echo "=== AUTOEXEC.BAT"; tr -d '\r' < "$OUT/AUTOEXEC.BAT"
echo "=== printer output"
find "$OUT/printer" -type f 2>/dev/null | sort | while read -r f; do tr -d '\r\f' < "$f"; done
