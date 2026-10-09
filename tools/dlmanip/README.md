# DLMANIPF - DLMANIP with fixes

`DLMANIP.ASM` is the source of DLMANIP 0.35 beta (Drive Letter
Manipulator) by Joe Forster/STA, unchanged. Its author released the
source into the public domain and asks for a credit in derived works -
many thanks to him.  The original program and its documentation are not
part of this repository.

`prep.py` converts it to JWasm syntax and applies the fixes (see the
comment in `prep.py`); `trim.py` strips the uninitialised end.
`make dlmanip` builds `build/DLMANIPF.SYS` and `build/DLMANIPF.COM`
(needs JWasm: https://github.com/Baron-von-Riedesel/JWasm).
