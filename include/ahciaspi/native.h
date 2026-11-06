/* SPDX-License-Identifier: GPL-2.0-or-later */
/* AHCIASPI native transports for OpenASPI's native layer: AHCI SATA
 * controllers (ATA disks through SCSI/ATA translation, ATAPI devices -
 * CD/DVD, ZIP, LS-120, tape - also behind IDE-to-SATA adapters) and,
 * later, IDE channels. Polled; the embedding system owns the controller. */

#ifndef AHCIASPI_NATIVE_H
#define AHCIASPI_NATIVE_H

#include "openaspi/types.h"

/* PCI class of an AHCI controller. */
#define AHCIASPI_PCI_CLASS_AHCI 0x010601ul

/* Take over the AHCI controller at PCI address `pci` (OA_PCI_ADDR) and
 * register it as one OpenASPI adapter, one target per port with a device.
 * Returns the number of devices found, or -1 if the controller is not
 * usable. */
int ahciaspi_probe_ahci(oa_u32 pci);

#endif
