#!/usr/bin/env python3
"""lefix.py VXD: mark all 32-bit objects of an LE VxD executable and
refuse a 16-bit object with fixups.

WIN386 of Windows 3.1 silently skips a VxD with an object that isn't
executable (Microsoft's DDK puts locked data into class 'CODE', so LINK386
never produced one); the C data segments (class DATA/BSS) give such an
object.

The 16-bit object is the real mode initialization; WIN386 calls a VxD
whose real mode object has fixup records damaged ("Eine in der
SYSTEM.INI-Datei angegebene Geraetedatei ist beschaedigt") and Windows
does not start.  A JWlink without the Windows 3.x VxD patch writes them."""
import struct
import sys

OBJ_EXECUTABLE = 0x0004
OBJ_BIG = 0x2000

f = sys.argv[1]
d = bytearray(open(f, 'rb').read())
le = struct.unpack_from('<I', d, 0x3c)[0]
objtab = le + struct.unpack_from('<I', d, le + 0x40)[0]
for i in range(struct.unpack_from('<I', d, le + 0x44)[0]):
    o = objtab + 24 * i + 8
    flags = struct.unpack_from('<I', d, o)[0]
    if flags & OBJ_BIG:
        struct.pack_into('<I', d, o, flags | OBJ_EXECUTABLE)
# fixup page table: one offset per page and the end
fpt = le + struct.unpack_from('<I', d, le + 0x68)[0]
for i in range(struct.unpack_from('<I', d, le + 0x44)[0]):
    size, base, flags, first, pages = struct.unpack_from('<5I', d, objtab + 24 * i)
    if flags & OBJ_BIG:
        continue
    for p in range(first, first + pages):
        a, b = struct.unpack_from('<2I', d, fpt + 4 * (p - 1))
        if a != b:
            sys.exit("%s: 16-bit object %d has fixups (page %d): this JWlink "
                     "cannot write Windows 3.x VxDs, see GNUmakefile" % (f, i + 1, p))
open(f, 'wb').write(d)
