#!/bin/bash
# All six ports of the ICH9 AHCI controller in use: ports 0-4 hard disks
# (FAT16, the BIOS makes them C: .. G:), port 5 an ATAPI CD-ROM.  Loads
# AHCIASPI.SYS, ASPIDISK.SYS (Adaptec EZ-SCSI) and ASPICD.SYS, then reads
# and writes every BIOS disk and reads the CD.  Checks that the driver does
# not disturb the ports the BIOS uses for its hard disks.
#
#   test/satafull.sh [AHCIASPI options]          e.g. test/satafull.sh /V
#
# Environment:
#   HIGH=1    DEVICEHIGH (JEMMEX before the drivers)
#   NODISK=1  without ASPIDISK.SYS
#   TIMEOUT   seconds until the screen is captured (default 60)
#
# Output (build/satafull/): debug.log (driver), serial.log (test output),
#   screen.png; the disk images are checked afterwards with mtools.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/satafull
DOS=${DOS_DIR:-$HOME/Iso/Dos}
BOOTIMG=${BOOTIMG:-$DOS/dos71de/Dos7.1_System_deutsch.IMG}
EZSCSI=${EZSCSI:-$DOS/ez-scsi}
JEMM_ZIP=${JEMM_ZIP:-$DOS/JemmB_v586.zip}
OPTS="$*"

rm -rf "$OUT"; mkdir -p "$OUT/cdroot"
nasm -f bin -w-reloc-abs-word -DE9LOG -I"$ROOT/src/" -o "$OUT/AHCIASPI.SYS" "$ROOT/src/ahciaspi.asm"
nasm -f bin -o "$OUT/QEXIT.COM" "$ROOT/tools/qexit.asm"
cp "$BOOTIMG" "$OUT/boot.img"; chmod u+w "$OUT/boot.img"

DRV=(C D E F G)
{
    if [ "${HIGH:-0}" = 1 ]; then
        unzip -p "$JEMM_ZIP" JEMMEX.EXE > "$OUT/JEMMEX.EXE"
        mcopy -i "$OUT/boot.img" "$OUT/JEMMEX.EXE" ::/
        printf 'DEVICE=A:\\JEMMEX.EXE NOEMS\r\nDOS=HIGH,UMB\r\n'
        D=DEVICEHIGH
    else
        D=DEVICE
    fi
    printf '%s=A:\\AHCIASPI.SYS %s\r\n' $D "$OPTS"
    [ "${NODISK:-0}" = 1 ] || printf '%s=A:\\ASPIDISK.SYS\r\n' $D
    printf '%s=A:\\ASPICD.SYS /D:ASPICD0\r\n' $D
    printf 'FILES=40\r\nLASTDRIVE=Z\r\nSHELL=A:\\COMMAND.COM A:\\ /P\r\n'
} > "$OUT/CONFIG.SYS"
{
    printf '@ECHO OFF\r\nPATH A:\\\r\n'
    for d in "${DRV[@]}"; do
        printf 'ECHO --- %s: > AUX\r\nTYPE %s:\\DISK.TXT > AUX\r\n' $d $d
        printf 'COPY A:\\CONFIG.SYS %s:\\WRITE.TXT > AUX\r\nTYPE %s:\\WRITE.TXT > AUX\r\n' $d $d
    done
    printf 'ECHO --- MSCDEX > AUX\r\nMSCDEX /D:ASPICD0 /L:H > AUX\r\nTYPE H:\\README.TXT > AUX\r\n'
    # BIOS disks again after the CD was used
    for d in "${DRV[@]}"; do printf 'TYPE %s:\\DISK.TXT > AUX\r\n' $d; done
    printf 'ECHO --- END > AUX\r\nQEXIT\r\n'
} > "$OUT/AUTOEXEC.BAT"
cp "$EZSCSI/ASPIDISK.SYS" "$OUT/"
cp "$EZSCSI/ASPICD.SYS" "$OUT/"
mcopy -o -i "$OUT/boot.img" "$OUT/CONFIG.SYS" "$OUT/AUTOEXEC.BAT" "$OUT/AHCIASPI.SYS" \
      "$OUT/ASPIDISK.SYS" "$OUT/ASPICD.SYS" "$OUT/QEXIT.COM" ::/

DISKDEV=()
for i in 0 1 2 3 4; do
    img=$OUT/disk$i.img
    truncate -s 32M "$img"
    echo 'start=63, type=6' | sfdisk -q "$img"
    mkfs.fat -F16 -n "SATA$i" --offset 63 "$img" $(( (32*2048 - 63) / 2 )) >/dev/null
    printf 'SATA port %s disk %s: read OK\r\n' $i ${DRV[$i]} > "$OUT/DISK.TXT"
    mcopy -i "$img@@32256" "$OUT/DISK.TXT" ::/
    DISKDEV+=(-drive id=hd$i,if=none,format=raw,file="$img" -device ide-hd,drive=hd$i,bus=ahci.$i)
done
echo "AHCIASPI CD on SATA port 5" > "$OUT/cdroot/README.TXT"
xorriso -as mkisofs -quiet -V SATAFULL -o "$OUT/cd.iso" "$OUT/cdroot" 2>/dev/null

{ sleep "${TIMEOUT:-60}"; echo "screendump $OUT/screen.ppm"; sleep 1; echo quit; } |
qemu-system-i386 -machine pc -m 32 -display none -vga std -monitor stdio \
    -drive if=floppy,format=raw,file="$OUT/boot.img" -boot a \
    -device ich9-ahci,id=ahci "${DISKDEV[@]}" \
    -drive id=cd,if=none,format=raw,media=cdrom,file="$OUT/cd.iso" -device ide-cd,drive=cd,bus=ahci.5 \
    -device isa-debug-exit,iobase=0xf4 \
    -debugcon file:"$OUT/debug.log" -serial file:"$OUT/serial.log" >/dev/null 2>&1
command -v magick >/dev/null && magick "$OUT/screen.ppm" "$OUT/screen.png" 2>/dev/null

echo "=== CONFIG.SYS"; tr -d '\r' < "$OUT/CONFIG.SYS"
echo "=== debug.log (driver)"; tr -d '\r' < "$OUT/debug.log"
echo "=== serial.log"; tr -d '\r' < "$OUT/serial.log"
echo "=== disk images after the run"
for i in 0 1 2 3 4; do
    printf 'disk%s: ' $i
    mtype -i "$OUT/disk$i.img@@32256" ::/WRITE.TXT 2>/dev/null | head -1 | tr -d '\r' || true
    dd if="$OUT/disk$i.img" of="$OUT/part.img" bs=512 skip=63 status=none
    fsck.fat -n "$OUT/part.img" >/dev/null 2>&1 && echo "   fsck OK" || echo "   fsck: errors"
done
echo "=== screen: $OUT/screen.png"
