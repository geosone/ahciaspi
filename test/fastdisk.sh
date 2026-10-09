#!/bin/bash
# AHCIVXD.386 (32-bit disk access) in Windows for Workgroups 3.11: boots the
# WfW image (EUSBASPI's test/mkwin311.sh, C: on IDE, or AHCI with
# DISK=ahci), loads AHCIVXD.386 with *int13 and 32BitDiskAccess=on, runs a
# DOS box that copies files (C:\T.BAT) and checks the copies afterwards.
#
# Environment: WIN311IMG, DISK=ide|ahci, TIMEOUT (default 120), WINBAT,
#   NOVXD=1 (without AHCIVXD, for comparison)
# Output: build/fastdisk/vxd.log (AHCIVXD log, port E9h), serial.log
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/fastdisk
BASE=${WIN311IMG:-$HOME/mars/eusbaspi/build/win311/win311.img}
[ -f "$BASE" ] || { echo "no WfW image: $BASE"; exit 1; }
make -s -C "$ROOT/vxd" LINK=${LINK:-$HOME/mars/386MAX/linux/bin/jwlink} || exit 1
rm -rf "$OUT"; mkdir -p "$OUT/c"
cp "$BASE" "$OUT/test.img"
cp "$ROOT/build/vxd/AHCIVXD.386" "$OUT/c/"
nasm -f bin -o "$OUT/c/QEXIT.COM" "$ROOT/tools/qexit.asm"
nasm -f bin -o "$OUT/c/EXT13.COM" "$ROOT/tools/ext13.asm"
crlf() { tr '|' '\n' | sed 's/$/\r/'; }
P="$OUT/test.img@@32256"
{ echo '@ECHO OFF'; echo 'PATH C:\;C:\WINDOWS'; echo 'ECHO --- starting Windows > AUX'
  echo 'C:\WINDOWS\WIN /3 C:\T.BAT'; echo 'ECHO --- back > AUX'; echo 'QEXIT'; } | crlf > "$OUT/c/AUTOEXEC.BAT"
{ echo '@ECHO OFF'; echo 'ECHO --- DOS box > AUX'
  echo "${WINBAT:-EXT13|MD C:\\TST|COPY C:\\WINDOWS\\SYSTEM\\*.* C:\\TST > AUX|COPY C:\\WINDOWS\\*.EXE C:\\TST > AUX|DIR C:\\TST}" | tr '|' '\n' | sed 's/$/ > AUX/'
  echo 'ECHO --- DOS box done > AUX'; echo 'QEXIT'; } | crlf > "$OUT/c/T.BAT"
mcopy -o -i "$P" "$OUT"/c/* ::/
[ "${NOVXD:-0}" = 1 ] || mtype -i "$P" ::/WINDOWS/SYSTEM.INI | tr -d '\r' |
    sed 's/^\[386Enh\]$/[386Enh]\ndevice=*int13\ndevice=C:\\AHCIVXD.386\n32BitDiskAccess=on/' |
    sed '$a\\n[AHCIVXD]\nLogPort=233' | sed 's/$/\r/' > "$OUT/SYSTEM.INI"
[ "${NOVXD:-0}" = 1 ] || mcopy -o -i "$P" "$OUT/SYSTEM.INI" ::/WINDOWS/SYSTEM.INI
if [ "${DISK:-ide}" = ahci ]; then
    DRV=(-drive if=none,id=hd,format=raw,file="$OUT/test.img" -device ahci,id=ahci -device ide-hd,drive=hd,bus=ahci.0)
else
    DRV=(-drive if=ide,index=0,format=raw,file="$OUT/test.img")
fi
{ sleep "${TIMEOUT:-120}"; echo "screendump $OUT/screen.ppm"; sleep 1; echo quit; } |
qemu-system-i386 -machine pc ${ACCEL:--accel kvm} -m 32 -display none -vga std -monitor stdio \
    "${DRV[@]}" -boot c -nic none -debugcon file:"$OUT/vxd.log" -serial file:"$OUT/serial.log" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 > "$OUT/monitor.log" 2>&1
[ -f "$OUT/screen.ppm" ] && magick "$OUT/screen.ppm" "$OUT/screen.png" && rm -f "$OUT/screen.ppm"
echo "=== vxd.log"; tr -d '\r' < "$OUT/vxd.log"
echo "=== serial.log"; tr -d '\r' < "$OUT/serial.log" | grep -v "^$" | tail -30
# the copies must equal the originals
bad=0
for f in $(mdir -b -i "$P" ::/TST 2>/dev/null); do
    n=$(basename "$f")
    o=$(mdir -b -i "$P" ::/WINDOWS/SYSTEM/"$n" ::/WINDOWS/"$n" 2>/dev/null | head -1)
    [ -n "$o" ] || continue
    mtype -i "$P" "$f" | cmp -s - <(mtype -i "$P" "$o") || { echo "DIFF $n"; bad=1; }
done
echo "=== copies checked, bad=$bad"
