#!/usr/bin/env python3
# Cut a JWasm -bin output of DLMANIP at the DataStart label, like TLINK did
# for the released binaries.  DLMANIP clears DataStart..DataEnd itself.
# Usage: trim.py <binary> <listing> <org>
import re, sys
lst = open(sys.argv[2], 'rb').read().decode('cp437')
m = re.search(r'^DataStart[ .]+L Near\s+([0-9A-F]+)h', lst, re.M)
if not m:
    sys.exit('DataStart not found in listing')
size = int(m.group(1), 16) - int(sys.argv[3], 0)
data = open(sys.argv[1], 'rb').read()
if any(data[size:]):
    sys.exit('non-zero data after DataStart')
open(sys.argv[1], 'wb').write(data[:size])
