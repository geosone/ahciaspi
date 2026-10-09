#!/bin/bash
# BIOS VDS fix of AHCIASPI.SYS (biosfix.inc) under EMM386: boots the WfW
# image (EUSBASPI's test/mkwin311.sh) from an AHCI disk with HIMEM, EMM386
# and AHCIASPI.SYS, copies files through the BIOS (VDS in use) and checks
# the copies.  With QEMU's ICH9 AHCI (Intel) the fix is on by default;
# SeaBIOS has not the bug, so this checks that the filter does no harm.
#   test/biosfix.sh [AHCIASPI options]     (CD=image.iso: a CD drive as well)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/biosfix
BASE=${WIN311IMG:-$HOME/mars/eusbaspi/build/win311/win311.img}
MSCAB=${MSCAB:-"$HOME/Iso/Windows 98/Windows98/WIN95/WIN95_02.CAB"}
rm -rf "$OUT"; mkdir -p "$OUT/c"
cp "$BASE" "$OUT/test.img"
nasm -f bin -w-reloc-abs-word -DE9LOG -I"$ROOT/src/" -o "$OUT/c/AHCIASPI.SYS" "$ROOT/src/ahciaspi.asm" || exit 1
nasm -f bin -o "$OUT/c/QEXIT.COM" "$ROOT/tools/qexit.asm"
(cd "$OUT" && cabextract -q -F emm386.exe "$MSCAB") && cp "$OUT/emm386.exe" "$OUT/c/EMM386.EXE"
crlf() { tr '|' '\n' | sed 's/$/\r/'; }
echo "DEVICE=C:\\HIMEM.SYS|DEVICE=C:\\EMM386.EXE NOEMS|DEVICE=C:\\AHCIASPI.SYS /V $*|FILES=40" | crlf > "$OUT/c/CONFIG.SYS"
echo '@ECHO OFF|MD C:\TST|COPY C:\WINDOWS\SYSTEM\*.* C:\TST > AUX|ECHO --- copied > AUX|QEXIT' | crlf > "$OUT/c/AUTOEXEC.BAT"
P="$OUT/test.img@@32256"
mcopy -o -i "$P" "$OUT"/c/* ::/
{ sleep "${TIMEOUT:-90}"; echo quit; } |
qemu-system-i386 -machine pc ${ACCEL:--accel kvm} -m 32 -display none -vga std -monitor stdio \
    -drive if=none,id=hd,format=raw,file="$OUT/test.img" -device ahci,id=ahci -device ide-hd,drive=hd,bus=ahci.0 \
    -boot c -nic none -debugcon file:"$OUT/e9.log" -serial file:"$OUT/serial.log" \
    ${CD:+-drive if=none,id=cd,media=cdrom,readonly=on,file=$CD -device ide-cd,drive=cd,bus=ahci.1} \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 > "$OUT/monitor.log" 2>&1
echo "=== AHCIASPI"; tr -d '\r' < "$OUT/e9.log" | grep -v "^>" | head -8
echo "=== serial"; tr -d '\r' < "$OUT/serial.log" | grep -c "Datei" ; tr -d '\r' < "$OUT/serial.log" | tail -2
bad=0; n=0
for f in $(mdir -b -i "$P" ::/TST 2>/dev/null); do
    n=$((n+1)); b=$(basename "$f")
    mtype -i "$P" "$f" | cmp -s - <(mtype -i "$P" ::/WINDOWS/SYSTEM/"$b") || { echo "DIFF $b"; bad=1; }
done
echo "=== $n copies checked, bad=$bad"
