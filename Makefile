# AHCIASPI - ASPI manager for ATAPI devices on AHCI controllers
NASM    = nasm
NFLAGS  = -f bin -w-reloc-abs-word
# JWasm (https://github.com/Baron-von-Riedesel/JWasm) for the DLMANIP fix
JWASM_EXE = jwasm
# DLMANIP 0.35 beta source by Joe Forster/STA (public domain)
DLMANIP_SRC = tools/dlmanip/DLMANIP.ASM

# AHCIVXD.386 (Windows 3.x 32-bit disk access): Open Watcom, JWasm and a
# JWlink with working Windows 3.x VxD output (LINK=path)
LINK ?= jwlink

all: build/AHCIASPI.SYS build/ASPITEST.COM build/vxd/AHCIVXD.386

build/vxd/AHCIVXD.386: vxd/AHCIVXD.C vxd/AHCIVXD.ASM vxd/AHCIRMI.ASM vxd/RTVXD.ASM vxd/VXD.INC
	$(MAKE) -C vxd LINK=$(LINK)

build/AHCIASPI.SYS: src/ahciaspi.asm src/ahci.inc src/aspi.inc src/biosfix.inc | build
	$(NASM) $(NFLAGS) -Isrc/ -l build/ahciaspi.lst -o $@ $<

build/ASPITEST.COM: tools/aspitest.asm src/aspi.inc | build
	$(NASM) $(NFLAGS) -Itools/ -o $@ $<

# DLMANIP 0.35 with the unit number fix for installable block drivers
dlmanip: build/DLMANIPF.SYS build/DLMANIPF.COM

build/dlmanipf.asm: $(DLMANIP_SRC) tools/dlmanip/prep.py | build
	tools/dlmanip/prep.py $< $@

build/DLMANIPF.SYS: build/dlmanipf.asm
	$(JWASM_EXE) -q -bin -DDeviceDriver -Fl=build/dlmanipf_sys.lst -Fo=$@ $<
	tools/dlmanip/trim.py $@ build/dlmanipf_sys.lst 0

build/DLMANIPF.COM: build/dlmanipf.asm
	$(JWASM_EXE) -q -bin -Fl=build/dlmanipf_com.lst -Fo=$@ $<
	tools/dlmanip/trim.py $@ build/dlmanipf_com.lst 0x100

build:
	mkdir -p build

test: all
	test/run.sh /V

clean:
	rm -rf build

.PHONY: all test clean dlmanip

# distribution: INSTALL.EXE comes from the GeosOne DOS Installer
# (https://github.com/geosone/gdi)
GDI ?= ../gdi/build/INSTALL.EXE
PKG = build/pkg
package: all dlmanip
	rm -rf $(PKG) && mkdir -p $(PKG)
	cp build/AHCIASPI.SYS build/ASPITEST.COM build/DLMANIPF.SYS build/DLMANIPF.COM build/vxd/AHCIVXD.386 $(PKG)/
	cp install/INSTALL.INI install/README.TXT install/DLMANIPF.TXT $(PKG)/
	sed 's/$$/\r/' LICENSE > $(PKG)/LICENSE.TXT
	cp $(GDI) $(PKG)/INSTALL.EXE
	cd $(PKG) && rm -f ../ahciaspi.zip && zip -q -9 ../ahciaspi.zip *
	# a 1.44 MB disk (mtools), e.g. for mkdosset.ps1 -Extra of msdosinst
	cd $(PKG) && rm -f ../AHCIASPI.IMG && mformat -C -f 1440 -v AHCIASPI -i ../AHCIASPI.IMG :: && mcopy -i ../AHCIASPI.IMG * ::

.PHONY: package
