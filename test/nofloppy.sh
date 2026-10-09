#!/bin/bash
# MS-DOS 6.22 booting from hard disk on a PC without floppy drives, with two
# TESTDRV.SYS instances (L = LS-120 stand-in, Z = ZIP stand-in).
#
#   test/nofloppy.sh                      just show the drive letters
#   CONFIG='DEVICE=C:\DLMANIPF.SYS SWAP D: A:|...' test/nofloppy.sh
#   BATCH='DLMANIPF SWAP E: B:|...'      test/nofloppy.sh
#
# C: is made bootable on the host (ms-sys MBR, MS-DOS 6.22 boot code, IO.SYS
# and MSDOS.SYS as the first files) and booted with no floppy drive attached.
# CONFIG lines are added after the TESTDRV lines, BATCH lines run before the
# checks.
# Output: build/nofloppy/serial.log, screen.png if DOS hangs.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/nofloppy
DOS=${DOS_DIR:-$HOME/Iso/Dos}
MSDOS_7Z=${MSDOS_7Z:-$DOS/Microsoft MS-DOS 6.22 [German] (3.5-1.44mb).7z}
W98_ZIP=${W98_ZIP:-$DOS/FreeDOS-erweiterte Windows 98 SE Startdiskette.zip}
DOSVER=${DOSVER:-6}                     # 6 = MS-DOS 6.22, 7 = Windows 98 SE
                                        # IOSYS=path / COMMANDCOM=path replace
                                        # the DOS 7 IO.SYS / COMMAND.COM

rm -rf "$OUT"; mkdir -p "$OUT/c"
nasm -f bin -w-reloc-abs-word -o "$OUT/c/TESTDRV.SYS" "$ROOT/tools/testdrv.asm"
nasm -f bin -o "$OUT/c/QEXIT.COM" "$ROOT/tools/qexit.asm"
nasm -f bin -o "$OUT/c/CDSDUMP.COM" "$ROOT/tools/cdsdump.asm"
cp "$ROOT/build/DLMANIPF.SYS" "$ROOT/build/DLMANIPF.COM" "$OUT/c/"
if [ "$DOSVER" = 7 ]; then
    unzip -qo -j "$W98_ZIP" '*EMM386.img' -d "$OUT" && mv "$OUT"/*EMM386.img "$OUT/boot.img"
    mcopy -i "$OUT/boot.img" ::IO.SYS ::COMMAND.COM "$OUT/"
    [ -n "${IOSYS:-}" ] && cp "$IOSYS" "$OUT/IO.SYS"     # e.g. a patched IO.SYS
    [ -n "${COMMANDCOM:-}" ] && cp "$COMMANDCOM" "$OUT/COMMAND.COM"
    printf '[Paths]\r\nWinDir=C:\\WINDOWS\r\nWinBootDir=C:\\WINDOWS\r\nHostWinBootDrv=C\r\n[Options]\r\nBootGUI=0\r\nLogo=0\r\nBootMulti=0\r\n' > "$OUT/MSDOS.SYS"
    printf ';%%0400s\r\n' '' | tr ' ' 'x' >> "$OUT/MSDOS.SYS"   # MSDOS.SYS must be > 1 KB
else
    (cd "$OUT" && 7z e -y "$MSDOS_7Z" '*/Disk01.img' >/dev/null && mv Disk01.img boot.img)
    mcopy -i "$OUT/boot.img" ::IO.SYS ::MSDOS.SYS ::COMMAND.COM "$OUT/"
fi

crlf() { tr '|' '\n' | sed 's/$/\r/'; }
{
    echo 'DEVICE=C:\TESTDRV.SYS L'
    echo 'DEVICE=C:\TESTDRV.SYS Z'
    [ -n "${CONFIG:-}" ] && echo "$CONFIG"
    echo 'SHELL=C:\COMMAND.COM C:\ /P'
} | crlf > "$OUT/c/CONFIG.SYS"
{
    echo '@ECHO OFF'
    echo 'ECHO --- before > AUX'
    echo 'CDSDUMP > AUX'
    [ -n "${BATCH:-}" ] && echo "$BATCH" | tr '|' '\n' | sed 's/$/ > AUX/'
    echo 'ECHO --- after > AUX'
    echo 'CDSDUMP > AUX'
    echo 'TYPE A:\UNIT0.TXT > AUX'
    echo 'TYPE B:\UNIT0.TXT > AUX'
    echo 'DIR C:\IO.SYS > AUX'
    echo 'ECHO DONE > AUX'
    echo 'QEXIT'
} | crlf > "$OUT/c/AUTOEXEC.BAT"

# hard disk: one FAT16 partition with IO.SYS and MSDOS.SYS as the first
# files and the MS-DOS 6.22 boot code from the floppy boot sector (the
# FAT16 boot record of ms-sys is the DOS 7 one), DOS MBR from ms-sys
truncate -s 16M "$OUT/hd.img"
echo 'start=63, type=6, bootable' | sfdisk -q "$OUT/hd.img"
mkfs.fat -F16 -h 63 -g 16/63 --offset 63 "$OUT/hd.img" $(( (16*2048 - 63) / 2 )) >/dev/null
if [ "$DOSVER" = 7 ]; then
    # ms-sys works on whole files: write the FAT16 DOS 7 boot record to a
    # copy of the partition and put its first sector back
    dd if="$OUT/hd.img" of="$OUT/part.img" bs=512 skip=63 status=none
    ms-sys -f -6 "$OUT/part.img" >/dev/null
    dd if="$OUT/part.img" of="$OUT/hd.img" bs=512 seek=63 count=1 conv=notrunc status=none
else
    dd if="$OUT/boot.img" of="$OUT/hd.img" bs=1 skip=62 seek=$((63*512 + 62)) count=448 conv=notrunc status=none
fi
mcopy -i "$OUT/hd.img@@32256" "$OUT/IO.SYS" ::/
mcopy -i "$OUT/hd.img@@32256" "$OUT/MSDOS.SYS" ::/
mcopy -i "$OUT/hd.img@@32256" "$OUT/COMMAND.COM" ::/
mlabel -i "$OUT/hd.img@@32256" ::HARDDISK

ms-sys -f -d "$OUT/hd.img" >/dev/null
mcopy -o -i "$OUT/hd.img@@32256" "$OUT"/c/* ::/

{ sleep "${TIMEOUT:-40}"; echo "screendump $OUT/screen.ppm"; sleep 1; echo quit; } |
qemu-system-i386 -machine pc -m 16 -display none -vga std -monitor stdio \
    -drive if=none,id=hd,format=raw,file="$OUT/hd.img" -device ide-hd,drive=hd,bus=ide.0,cyls=32,heads=16,secs=63,bootindex=0 \
    -serial file:"$OUT/serial.log" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 >/dev/null 2>&1

echo "=== CONFIG.SYS"; tr -d '\r' < "$OUT/c/CONFIG.SYS"
echo "=== serial.log"; tr -d '\r' < "$OUT/serial.log"
if [ -f "$OUT/screen.ppm" ]; then
    command -v magick >/dev/null && magick "$OUT/screen.ppm" "$OUT/screen.png"
    echo "=== DOS did not finish, screen: $OUT/screen.png"
    exit 1
fi
tr -d '\r\n' < "$OUT/serial.log" | LC_ALL=C grep -aq 'TESTDRV L unit 0 read OK.*TESTDRV Z unit 0 read OK.*IO       SYS.*DONE'
