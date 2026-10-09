#!/usr/bin/env python3
# Convert DLMANIP.ASM 0.35 beta (Joe Forster/STA, public domain source,
# TASM syntax) to JWasm syntax and apply the AHCIASPI fixes:
#
#  - keep the unit number of drives that belong to installable block drivers
#    (MKELS120.SYS, GUEST.EXE, ...).  The original sets the DPB unit number
#    to the new drive number, which is only right for the drives of the DOS
#    built-in driver; installable drivers then get requests for units they
#    do not have ("invalid unit").
#  - do not write through a NULL DPB pointer when a letter is swapped with
#    a letter that has no drive (e.g. B: on a system without floppy drives);
#    the original overwrites the INT 0 vector at 0000:0000
#  - skip letters left unassigned by MOVE (0FFh); the original indexes the
#    CDS array with 7Fh and writes far behind its end
#  - copy the CDS of redirected drives (MSCDEX CD-ROMs, network drives) into
#    their own drive table entry; the original reuses the entry of the
#    previous drive, so swapping that drive gave it the CD-ROM's CDS
#  - remove the debugging INT 3
#
# Usage: prep.py <dlmanip.asm> <output.asm> [--repro]
#   --repro rebuilds the released 0.35 binary (to verify the toolchain).
import re, sys

src = open(sys.argv[1], 'rb').read().decode('cp437').replace('\r', '')
repro = '--repro' in sys.argv
out, stack = [], []
fixed = fixed_null = fixed_auto = fixed_cds = False
lines = src.split('\n')
for i, line in enumerate(lines):
    m = re.match(r'^(\w+)\s+struc\b', line)
    if m:
        stack.append(m.group(1))
    if re.match(r'^\s+ends\s*(;.*)?$', line) and stack:
        line = stack.pop() + '\t' + line.strip()
    if re.match(r'^\s+jumps\b', line):
        line = ';' + line
    if line.startswith('CSeg\t\tsegment'):
        line = 'option oldstructs\n' + line
    line = re.sub(r'PartitionEntry \((\w+)\) dup \(\?\)', r'PartitionEntry \1 dup (<>)', line)
    line = re.sub(r'^(\w+):(\s+d[bwd]\s)', r'\1\2', line)
    line = re.sub(r'(\w+\s+\w+\s+)<\?>', r'\1<>', line)
    if re.match(r'^\s+int\s+3\s*$', line):
        line = ';' + line
    # TASM encodings: shift by 2 as two 8086 shifts, LEA of direct operands as MOV
    m = re.match(r'^(\S*\s+)(ror|rol)(\s+)(\w+),\s*2\b(.*)$', line)
    if m:
        line = (m.group(1) + m.group(2) + m.group(3) + m.group(4) + ', 1' + m.group(5)
                + '\n\t\t' + m.group(2) + '\t' + m.group(4) + ', 1')
    m = re.match(r'^(\S*\s+)lea(\s+)(\w+),\s*([A-Za-z_][\w.]*)(\s*(;.*)?)$', line)
    if m:
        line = m.group(1) + 'mov' + m.group(2) + m.group(3) + ', Offset ' + m.group(4) + m.group(5)
    line = line.replace('lea\tsi, CmdParam[3]', 'mov\tsi, Offset CmdParam+3')
    if repro and line.startswith('PrcBootRec:'):
        line = 'PrcBootRec:\tint\t3\n' + line[len('PrcBootRec:'):]
    if not repro:
        if line.startswith('Hello\t\tdb\t'):
            line = line.replace("Joe Forster/STA'", "Joe Forster/STA (AHCIASPI unit fix)'")
        if re.match(r'^\s+mov\s+es:\[bx\]\.DriveParBlock\.dpDriveNum, ch', line):
            line = ('\t\tmov\tax, es\n'
                    '\t\tor\tax, bx\n'
                    '\t\tje\t@19\t\t\t;No drive behind this letter\n'
                    + line)
            fixed_null = True
        if re.match(r'^@20:\s+mov\s+ch, \[si\]\.DriveEntry\.ldDriveNum', lines[i-2] if i >= 2 else '') \
                and re.match(r'^\s+je\s+@19', line):
            line = line + '\n\t\tcmp\tch, dlAutoAssign\t;Letter left unassigned by MOVE\n\t\tje\t@19'
            fixed_auto = True
        if line.startswith('@14:\t\tpush\tcx'):
            line = ('@14:\t\tmov\tal, cl\t\t\t;Table entry of this drive, also for\n'
                    '\t\tmov\tdl, DrvEntrySize\t; redirected drives\n'
                    '\t\tmul\tdl\n'
                    '\t\tmov\tdi, ax\n'
                    '\t\tpush\tcx' + line[len('@14:\t\tpush\tcx'):])
            fixed_cds = True
        if re.match(r'^\s+mov\s+es:\[bx\]\.DriveParBlock\.dpUnitNum, ch', line):
            line = ('\t\tmov\tax, word ptr DriveTable[di].DriveEntry.ldDrvDatEntry[0]\n'
                    '\t\tor\tax, word ptr DriveTable[di].DriveEntry.ldDrvDatEntry[2]\n'
                    '\t\tje\t@19\t\t\t;Installable driver: keep its unit\n'
                    + line)
            fixed = True
    out.append(line)
if not repro and not (fixed and fixed_null and fixed_auto and fixed_cds):
    sys.exit('fix not applied: unit %s, null DPB %s, auto %s, cds %s' % (fixed, fixed_null, fixed_auto, fixed_cds))
open(sys.argv[2], 'w', encoding='cp437').write('\n'.join(out))
