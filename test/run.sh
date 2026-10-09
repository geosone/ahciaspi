#!/bin/bash
# Boot SvarDOS in QEMU with an ICH9 AHCI controller (port 0: hard disk used by
# the BIOS as C:, port 1: ATAPI CD-ROM), load AHCIASPI.SYS with the given
# options and run ASPITEST.  Afterwards C: is read through the BIOS to make
# sure the driver left the BIOS-owned port in a working state.
#
#   test/run.sh [driver options]       e.g.  test/run.sh /V /M:F
#
# Output: build/test/debug.log (driver + ASPITEST), build/test/serial.log (C:)
# Environment: EMM=1 loads JEMMEX (V86 mode + VDS) before the driver,
#              HIGH=1 additionally loads the driver into an UMB.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/test
DOS=${DOS_DIR:-$HOME/Iso/Dos}
SVARDOS_ZIP=${SVARDOS_ZIP:-$DOS/svardos-20250427-floppy-1.44M.zip}
JEMM_ZIP=${JEMM_ZIP:-$DOS/JemmB_v586.zip}
OPTS="$*"

rm -rf "$OUT"
mkdir -p "$OUT/cdroot"

nasm -f bin -w-reloc-abs-word -DE9LOG -I"$ROOT/src/" -o "$OUT/AHCIASPI.SYS" "$ROOT/src/ahciaspi.asm"
nasm -f bin -w-reloc-abs-word -I"$ROOT/tools/" -o "$OUT/ASPITEST.COM" "$ROOT/tools/aspitest.asm"
nasm -f bin -o "$OUT/QEXIT.COM" "$ROOT/tools/qexit.asm"

# boot floppy: SvarDOS kernel and shell, our own CONFIG.SYS / AUTOEXEC.BAT
unzip -p "$SVARDOS_ZIP" svdos-1.44M-disk-1.img > "$OUT/boot.img"
for f in $(mdir -b -i "$OUT/boot.img" ::/ | sed 's|^::/||'); do
    case "${f^^}" in KERNEL.SYS|COMMAND.COM) ;; *) mdel -i "$OUT/boot.img" "::/$f" ;; esac
done
{
    if [ "${EMM:-0}" = 1 ]; then
        unzip -p "$JEMM_ZIP" JEMMEX.EXE > "$OUT/JEMMEX.EXE"
        mcopy -i "$OUT/boot.img" "$OUT/JEMMEX.EXE" ::/
        printf 'DEVICE=JEMMEX.EXE NOEMS\r\n'
    fi
    if [ "${HIGH:-0}" = 1 ]; then
        printf 'DOS=UMB\r\nDEVICEHIGH=AHCIASPI.SYS %s\r\n' "$OPTS"
    else
        printf 'DEVICE=AHCIASPI.SYS %s\r\n' "$OPTS"
    fi
    printf 'SHELL=COMMAND.COM /P\r\n'
} > "$OUT/CONFIG.SYS"
printf '@ECHO OFF\r\nASPITEST /E9\r\nTYPE C:\\HELLO.TXT > AUX\r\nDIR C:\\ > AUX\r\nQEXIT\r\n' > "$OUT/AUTOEXEC.BAT"
mcopy -i "$OUT/boot.img" "$OUT/CONFIG.SYS" "$OUT/AUTOEXEC.BAT" \
      "$OUT/AHCIASPI.SYS" "$OUT/ASPITEST.COM" "$OUT/QEXIT.COM" ::/

# ATAPI CD
echo "AHCIASPI test CD" > "$OUT/cdroot/README.TXT"
xorriso -as mkisofs -quiet -V ASPITEST -o "$OUT/cd.iso" "$OUT/cdroot" 2>/dev/null

# hard disk with one FAT16 partition
truncate -s 16M "$OUT/hd.img"
echo 'start=63, type=6, bootable' | sfdisk -q "$OUT/hd.img"
mkfs.fat -F16 -n AHCIDISK --offset 63 "$OUT/hd.img" $(( (16*2048 - 63) / 2 )) >/dev/null
printf 'BIOS disk access OK\r\n' > "$OUT/HELLO.TXT"
mcopy -i "$OUT/hd.img@@32256" "$OUT/HELLO.TXT" ::/

set +e
timeout "${TIMEOUT:-120}" qemu-system-i386 -machine pc -m 32 -display none -vga std \
    -drive if=floppy,format=raw,file="$OUT/boot.img" -boot a \
    -device ich9-ahci,id=ahci \
    -drive id=hd,if=none,format=raw,file="$OUT/hd.img" -device ide-hd,drive=hd,bus=ahci.0 \
    -drive id=cd,if=none,format=raw,media=cdrom,file="$OUT/cd.iso" -device ide-cd,drive=cd,bus=ahci.1 \
    -debugcon file:"$OUT/debug.log" -serial file:"$OUT/serial.log" \
    ${QEMU_EXTRA:-} -device isa-debug-exit,iobase=0xf4,iosize=0x04
rc=$?
set -e

echo "=== debug.log"; tr -d '\r' < "$OUT/debug.log"
echo "=== serial.log"; tr -d '\r' < "$OUT/serial.log"
# isa-debug-exit reports (value << 1) | 1, a timeout gives 124
if [ $rc -eq 124 ]; then echo "QEMU TIMEOUT"; exit 1; fi
grep -qE 'Summary: [1-9][0-9]* OK, 0 FAIL' "$OUT/debug.log" && grep -q 'BIOS disk access OK' "$OUT/serial.log"
