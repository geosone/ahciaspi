#!/bin/bash
# Run the real ASPI clients (MKELS120.SYS, GUEST.EXE) on top of AHCIASPI.SYS
# under the user's MS-DOS 7.1 boot disk.  QEMU has no ATAPI LS-120 or ZIP,
# so the clients will not find a drive, but the ASPI trace shows whether and
# how they talk to the driver.
#
#   test/clients.sh [AHCIASPI options]          e.g. test/clients.sh /ID:ATAPIMGR
#
# Environment:
#   CDMODEL  model/INQUIRY product string of the emulated ATAPI CD
#            (MKELS120 only accepts "LS-..." / MATSHITA devices), default QEMU
#   MKEOPTS  options for MKELS120.SYS (default /Q: do not stop on errors)
#   ASPICD=1 also load ASPICD.SYS + MSCDEX (CD on the AHCI port as D:) and
#            read the CD
#   DEVICES  replaces the driver lines of CONFIG.SYS (| separated), e.g.
#            'A:\USBASPI.SYS /V|A:\AHCIASPI.SYS|A:\ASPIDISK.SYS'
#   BATCH    replaces the AUTOEXEC.BAT commands (| separated, output > AUX)
#   SCSI=1   SCSI adapter (SCSIHC, default lsi53c895a; dc390 for the Tekram
#            DC-390 with DC390ASP.SYS) with a 32 MB disk (SCSITEST.TXT).
#            QEMU's LSI emulation does not work with ASPI8XX.SYS.
#   USB=1    USB controller (USBHC, default piix3-usb-uhci) with a 64 MB USB
#            stick (FAT16, USBTEST.TXT)
#   TIMEOUT  seconds until the screen is captured (default 40)
#   MM, MMOPTS, HIGH  memory manager, see test/mm.sh
#   QEMU_EXTRA  more QEMU arguments
#
# Output (build/clients/): debug.log (driver init + ASPI trace),
#   serial.log (GUEST.EXE output), screen.png (screen at the end)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/clients
DOS=${DOS_DIR:-$HOME/Iso/Dos}
BOOTIMG=${BOOTIMG:-$DOS/dos71de/Dos7.1_System_deutsch.IMG}
ZIP100=${ZIP100:-$ROOT/ref/zip100}
OPTS="$*"

rm -rf "$OUT"; mkdir -p "$OUT/cdroot"
nasm -f bin -w-reloc-abs-word -DE9LOG -I"$ROOT/src/" -o "$OUT/AHCIASPI.SYS" "$ROOT/src/ahciaspi.asm"
nasm -f bin -o "$OUT/QEXIT.COM" "$ROOT/tools/qexit.asm"
nasm -f bin -o "$OUT/CDPLAY.COM" "$ROOT/tools/cdplay.asm"
nasm -f bin -w-reloc-abs-word -I"$ROOT/tools/" -o "$OUT/ASPITEST.COM" "$ROOT/tools/aspitest.asm"
nasm -f bin -o "$OUT/CDSDUMP.COM" "$ROOT/tools/cdsdump.asm"
cp "$BOOTIMG" "$OUT/boot.img"; chmod u+w "$OUT/boot.img"

. "$ROOT/test/mm.sh"
{
    mm_setup "$OUT" "$OUT/boot.img" || exit 1
    if [ -n "${DEVICES:-}" ]; then
        echo "$DEVICES" | tr '|' '\n' | sed 's/^/DEVICE=/'
    else
        printf 'DEVICE=A:\\AHCIASPI.SYS %s\nDEVICE=A:\\MKELS120.SYS %s\n' "$OPTS" "${MKEOPTS:-/Q}"
        [ "${ASPICD:-0}" = 1 ] && printf 'DEVICE=A:\\ASPICD.SYS /D:ASPICD0\n'
    fi | mm_high
    printf 'FILES=40\nLASTDRIVE=Z\nSHELL=A:\\COMMAND.COM A:\\ /P\n'
} | sed 's/$/\r/' > "$OUT/CONFIG.SYS"
LH=; [ "${HIGH:-0}" = 1 ] && LH='LH '
if [ -n "${BATCH:-}" ]; then
    { printf '@ECHO OFF\r\nPATH A:\\\r\n'
      echo "$BATCH" | tr '|' '\n' | sed 's/$/ > AUX\r/'
    } > "$OUT/AUTOEXEC.BAT"
else
{
    printf '@ECHO OFF\r\nPATH A:\\\r\nECHO --- GUEST > AUX\r\nGUEST > AUX\r\nECHO --- GUEST done > AUX\r\n'
    if [ "${ASPICD:-0}" = 1 ]; then
        printf 'ECHO --- MSCDEX > AUX\r\n%sMSCDEX /D:ASPICD0 /L:D > AUX\r\nMEM /C > AUX\r\n' "$LH"
        printf 'DIR D:\\ > AUX\r\nTYPE D:\\README.TXT > AUX\r\nECHO --- CDPLAY > AUX\r\nCDPLAY > AUX\r\nECHO --- CD done > AUX\r\n'
    fi
} > "$OUT/AUTOEXEC.BAT"
fi
# GUEST: use the ASPI manager that is already loaded, do not load its own
printf '[----scan for existing aspi managers---]\r\nSCAN=ON\r\n' > "$OUT/GUEST.INI"
mcopy -o -i "$OUT/boot.img" "$OUT/CONFIG.SYS" "$OUT/AUTOEXEC.BAT" "$OUT/AHCIASPI.SYS" \
      "$OUT/QEXIT.COM" "$OUT/CDPLAY.COM" "$OUT/ASPITEST.COM" "$OUT/CDSDUMP.COM" "$OUT/GUEST.INI" "$ZIP100/GUEST.EXE" ::/

cp "$ROOT/ref/usbaspi/Usbaspi.sys" "$OUT/USBASPI.SYS"
nasm -f bin -o "$OUT/DELAY.SYS" "$ROOT/tools/delay.asm"
mcopy -o -i "$OUT/boot.img" "$OUT/DELAY.SYS" ::/
mcopy -o -i "$OUT/boot.img" "$OUT/USBASPI.SYS" ::/
for f in ASPI8XX.SYS SYMDISK.SYS SYMCD.SYS; do
    [ -f "$ROOT/ref/lsi/$f" ] && mcopy -o -i "$OUT/boot.img" "$ROOT/ref/lsi/$f" ::/
done
TEK="$ROOT/ref/dc390/Tekram DC390/DOS"      # Tekram DC-390 (QEMU dc390)
if [ -f "$TEK/ASPI.SYS" ]; then
    cp "$TEK/ASPI.SYS" "$OUT/DC390ASP.SYS"
    mcopy -o -i "$OUT/boot.img" "$OUT/DC390ASP.SYS" "$TEK/TRMDISK.SYS" ::/
fi
SCSIDEV=()
HOTPLUG=
if [ "${SCSI:-0}" = 1 ]; then
    truncate -s 32M "$OUT/scsi.img"
    echo 'start=63, type=6' | sfdisk -q "$OUT/scsi.img"
    mkfs.fat -F16 -n SCSIDISK --offset 63 "$OUT/scsi.img" $(( (32*2048 - 63) / 2 )) >/dev/null
    printf 'SCSI disk read OK\r\n' > "$OUT/SCSITEST.TXT"
    mcopy -i "$OUT/scsi.img@@32256" "$OUT/SCSITEST.TXT" ::/
    case "${SCSIHC:-lsi53c895a}" in
    dc390|am53c974)
        # SeaBIOS hangs on AM53C974 adapters with devices attached: plug the
        # disk in after the BIOS (put DELAY.SYS first in DEVICES)
        SCSIDEV=(-device "$SCSIHC",id=scsi)
        HOTPLUG="drive_add 0 if=none,id=scsidisk,format=raw,file=$OUT/scsi.img
device_add scsi-hd,bus=scsi.0,drive=scsidisk,scsi-id=0" ;;
    *)
        SCSIDEV=(-device "${SCSIHC:-lsi53c895a}",id=scsi
                 -drive id=scsidisk,if=none,format=raw,file="$OUT/scsi.img"
                 -device scsi-hd,bus=scsi.0,drive=scsidisk,scsi-id=0) ;;
    esac
fi
USBDEV=()
if [ "${USB:-0}" = 1 ]; then
    truncate -s 64M "$OUT/usb.img"
    echo 'start=63, type=6' | sfdisk -q "$OUT/usb.img"
    mkfs.fat -F16 -n USBSTICK --offset 63 "$OUT/usb.img" $(( (64*2048 - 63) / 2 )) >/dev/null
    printf 'USB stick read OK\r\n' > "$OUT/USBTEST.TXT"
    mcopy -i "$OUT/usb.img@@32256" "$OUT/USBTEST.TXT" ::/
    USBDEV=(-device ${USBHC:-piix3-usb-uhci},id=usbhc
            -drive id=usbdisk,if=none,format=raw,file="$OUT/usb.img"
            -device usb-storage,bus=usbhc.0,drive=usbdisk)
fi

echo "AHCIASPI client test" > "$OUT/cdroot/README.TXT"
xorriso -as mkisofs -quiet -V CLIENTS -o "$OUT/cd.iso" "$OUT/cdroot" 2>/dev/null

{ if [ -n "$HOTPLUG" ]; then sleep 3; echo "$HOTPLUG"; fi
  sleep "${TIMEOUT:-40}"; echo "screendump $OUT/screen.ppm"; sleep 1; echo quit; } |
qemu-system-i386 -machine pc -m 32 -display none -vga std -monitor stdio \
    -drive if=floppy,format=raw,file="$OUT/boot.img" -boot a \
    -device ich9-ahci,id=ahci \
    -drive id=cd,if=none,format=raw,media=cdrom,file="$OUT/cd.iso" \
    -device ide-cd,drive=cd,bus=ahci.0,model="${CDMODEL:-QEMU DVD-ROM}" "${USBDEV[@]}" "${SCSIDEV[@]}" \
    ${QEMU_EXTRA:-} \
    -debugcon file:"$OUT/debug.log" -serial file:"$OUT/serial.log" >/dev/null 2>&1
command -v magick >/dev/null && magick "$OUT/screen.ppm" "$OUT/screen.png"

echo "=== CONFIG.SYS"; tr -d '\r' < "$OUT/CONFIG.SYS"
echo "=== debug.log (driver + ASPI trace)"; tr -d '\r' < "$OUT/debug.log"
echo "=== serial.log (GUEST)"; tr -d '\r' < "$OUT/serial.log"
echo "=== screen: $OUT/screen.png"
