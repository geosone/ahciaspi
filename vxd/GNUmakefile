# AHCIVXD.386 - Windows 3.1x 32-bit disk access for IDE and AHCI disks
#
#   make -C vxd [WATCOM=...] [ASM=jwasm] [LINK=jwlink]
#
# Tools: Open Watcom (wcc386), JWasm and a JWlink with working "format
# windows vxd" output for Windows 3.x (see the 386MAX project's patched
# JWlink, or https://github.com/Baron-von-Riedesel/jwlink/pull/17).

WATCOM ?= /opt/watcom
ASM    ?= jwasm
LINK   ?= jwlink
export WATCOM

CC   := $(WATCOM)/binl/wcc386
OUT  ?= ../build/vxd
COPT := -q -mf -oxa -ecc -5s -s -zl -zls -wx -I$(WATCOM)/h

OBJS := $(addprefix $(OUT)/,AHCIVXD.obj AHCIRMI.obj ahcivxd_c.obj RTVXD.obj)

all: $(OUT)/AHCIVXD.386

$(OUT):
	mkdir -p $@

$(OUT)/%.obj: %.ASM VXD.INC | $(OUT)
	$(ASM) -q -Fo$@ $<

$(OUT)/ahcivxd_c.obj: AHCIVXD.C | $(OUT)
	$(CC) $(COPT) -fo=$@ $<

$(OUT)/AHCIVXD.386: $(OBJS)
	cd $(OUT) && $(LINK) format windows vxd name AHCIVXD.386 option quiet option map=AHCIVXD.map \
	  $(foreach o,$(OBJS),file $(notdir $(o))) \
	  segment _TEXT PRELOAD NONDISCARDABLE \
	  segment _DATA PRELOAD NONDISCARDABLE \
	  export AHCIVXD_DDB.1=_AHCIVXD_DDB
	python3 lefix.py $@

clean:
	rm -rf $(OUT)

.PHONY: all clean
