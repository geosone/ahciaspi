/* SPDX-License-Identifier: GPL-2.0-or-later */
/* AHCIASPI native transports for OpenASPI's native layer: AHCI SATA
 * controllers (ATA disks through SCSI/ATA translation, ATAPI devices -
 * CD/DVD, ZIP, LS-120, tape - also behind IDE-to-SATA adapters) and IDE
 * channels (ATA disks and ATAPI devices, PIO). Polled; the embedding system
 * owns the controller. */

#ifndef AHCIASPI_NATIVE_H
#define AHCIASPI_NATIVE_H

#include "openaspi/types.h"

/* PCI class of an AHCI controller; class/subclass of IDE controllers. */
#define AHCIASPI_PCI_CLASS_AHCI 0x010601ul
#define AHCIASPI_PCI_CLASS_IDE  0x0101u

/* Take over the AHCI controller at PCI address `pci` (OA_PCI_ADDR) and
 * register it as one OpenASPI adapter, one target per port with a device.
 * Returns the number of devices found, or -1 if the controller is not
 * usable. */
int ahciaspi_probe_ahci(oa_u32 pci);

/* Both channels of the PCI IDE controller at `pci` (class 0101h), legacy
 * or native mode, as one adapter (targets 0-3). Returns the number of
 * devices, or -1 if it is not an IDE controller. Needs port I/O. */
int ahciaspi_probe_ide(oa_u32 pci);

/* The same for channels given by port (control port = device control
 * register; cmd[i] == 0: channel absent), e.g. ISA cards or 1F0h/170h
 * without PCI. */
int ahciaspi_probe_ide_ports(const oa_u16 cmd[2], const oa_u16 ctl[2], const char *name);

#endif
