#!/bin/bash
# Check drive letter moving with an installable block driver under MS-DOS 6.22.
#
#   test/dlmanip.sh [DLMANIP.SYS] [command...]
#   e.g. test/dlmanip.sh ref/dlmanip/dlmanip.sys SWAP D: B:
#
# Disk layout: A: boot floppy, B: phantom floppy, C: IDE disk, D: TESTDRV.SYS
# (one-unit RAM disk like MKELS120.SYS or GUEST).  After the letter change
# B: must still reach TESTDRV unit 0.
#
# SCENARIO=ab: two TESTDRV instances (L = LS-120 stand-in on D:, Z = ZIP
# stand-in on E:) are swapped to A: and B:; the floppy then lives on D:.
#
# EXTRA="cmd" runs one more DLMANIP.SYS command from CONFIG.SYS, BATCH="cmd"
# runs DLMANIP.COM (DLCOM=path, default original) from the batch file; both
# then check that E: is gone.
#
# Output: build/dltest/serial.log and, if DOS hangs, build/dltest/screen.png.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/dltest
DOS=${DOS_DIR:-$HOME/Iso/Dos}
MSDOS_7Z=${MSDOS_7Z:-$DOS/Microsoft MS-DOS 6.22 [German] (3.5-1.44mb).7z}
DLSYS=${1:-$ROOT/ref/dlmanip/dlmanip.sys}
shift || true
CMD="${*:-SWAP D: B:}"

rm -rf "$OUT"; mkdir -p "$OUT"
nasm -f bin -w-reloc-abs-word -o "$OUT/TESTDRV.SYS" "$ROOT/tools/testdrv.asm"
nasm -f bin -o "$OUT/QEXIT.COM" "$ROOT/tools/qexit.asm"
nasm -f bin -o "$OUT/CDSDUMP.COM" "$ROOT/tools/cdsdump.asm"
(cd "$OUT" && 7z e -y "$MSDOS_7Z" '*/Disk01.img' >/dev/null && mv Disk01.img boot.img)
cp "$DLSYS" "$OUT/DLMANIP.SYS"
cp "${DLCOM:-$ROOT/ref/dlmanip/dlmanip.com}" "$OUT/DLMANIP.COM"

if [ "${SCENARIO:-}" = ab ]; then
    CMD="${VERB:-SWAP} D: A: / ${VERB:-SWAP} E: B:"
    printf 'DEVICE=A:\\TESTDRV.SYS L\r\nDEVICE=A:\\TESTDRV.SYS Z\r\n' > "$OUT/CONFIG.SYS"
    printf 'DEVICE=A:\\DLMANIP.SYS %s D: A:\r\nDEVICE=D:\\DLMANIP.SYS %s E: B:\r\n' "${VERB:-SWAP}" "${VERB2:-${VERB:-SWAP}}" >> "$OUT/CONFIG.SYS"
    [ -n "${EXTRA:-}" ] && printf 'DEVICE=D:\\DLMANIP.SYS %s\r\n' "$EXTRA" >> "$OUT/CONFIG.SYS"
    printf 'SHELL=D:\\COMMAND.COM D:\\ /K D:\\TEST.BAT\r\n' >> "$OUT/CONFIG.SYS"
    printf '@ECHO OFF\r\n%bD:\\DLMANIP LIST > AUX\r\nD:\\CDSDUMP > AUX\r\nDIR A: > AUX\r\nTYPE A:\\UNIT0.TXT > AUX\r\nDIR B: > AUX\r\nTYPE B:\\UNIT0.TXT > AUX\r\nDIR D:\\IO.SYS > AUX\r\n%bD:\\QEXIT\r\n' "${BATCH:+D:\\DLMANIP $BATCH > AUX\r\n}" "${EXTRA:+DIR E: > AUX\r\nECHO E: CHECKED > AUX\r\n}${BATCH:+DIR E: > AUX\r\nECHO E: CHECKED > AUX\r\n}" > "$OUT/TEST.BAT"
    EXPECT='TESTDRV L unit 0 read OK.*TESTDRV Z unit 0 read OK.*IO       SYS'
else
    printf 'DEVICE=A:\\TESTDRV.SYS\r\nDEVICE=A:\\DLMANIP.SYS %s\r\nSHELL=A:\\COMMAND.COM A:\\ /P\r\n' "$CMD" > "$OUT/CONFIG.SYS"
    printf '@ECHO OFF\r\nDLMANIP LIST > AUX\r\nCDSDUMP > AUX\r\nDIR B: > AUX\r\nTYPE B:\\UNIT0.TXT > AUX\r\nQEXIT\r\n' > "$OUT/TEST.BAT"
    EXPECT='TESTDRV 0 unit 0 read OK'
fi
cp "$OUT/TEST.BAT" "$OUT/AUTOEXEC.BAT"
mcopy -o -i "$OUT/boot.img" "$OUT/CONFIG.SYS" "$OUT/AUTOEXEC.BAT" "$OUT/TEST.BAT" "$OUT/TESTDRV.SYS" \
      "$OUT/DLMANIP.SYS" "$OUT/DLMANIP.COM" "$OUT/QEXIT.COM" "$OUT/CDSDUMP.COM" ::/

truncate -s 16M "$OUT/hd.img"
echo 'start=63, type=6, bootable' | sfdisk -q "$OUT/hd.img"
mkfs.fat -F16 -n HARDDISK --offset 63 "$OUT/hd.img" $(( (16*2048 - 63) / 2 )) >/dev/null

{ sleep "${TIMEOUT:-40}"; echo "screendump $OUT/screen.ppm"; sleep 1; echo quit; } |
qemu-system-i386 -machine pc -m 16 -display none -vga std -monitor stdio \
    -drive if=floppy,format=raw,file="$OUT/boot.img" -boot a \
    -drive if=ide,format=raw,file="$OUT/hd.img" \
    -serial file:"$OUT/serial.log" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 >/dev/null 2>&1

echo "=== CONFIG.SYS: DEVICE=DLMANIP.SYS $CMD"
echo "=== serial.log"; tr -d '\r' < "$OUT/serial.log"
if [ -f "$OUT/screen.ppm" ]; then
    command -v magick >/dev/null && magick "$OUT/screen.ppm" "$OUT/screen.png"
    echo "=== DOS did not finish, screen: $OUT/screen.png"
    exit 1
fi
tr -d '\r\n' < "$OUT/serial.log" | LC_ALL=C grep -aq "$EXPECT"
