/* SPDX-License-Identifier: GPL-2.0-or-later */
/* IDE (PATA) transport for OpenASPI's native layer: PIO, polled.
 *
 * Channels come from PCI IDE controllers, in legacy (1F0h/3F6h, 170h/376h)
 * or native mode (BAR0-3), or are given by port. Each channel pair is one
 * adapter, targets 0-3 = primary master, primary slave, secondary master,
 * secondary slave. ATA disks answer SCSI through OpenASPI's SCSI/ATA
 * translation with PIO commands; ATAPI devices get the CDB as a PACKET
 * command with OpenASPI's shared ATAPI handling. The packet protocol
 * follows AHCIASPI.SYS's ide_packet: device interrupts off (nIEN), byte
 * count limit FFFEh, data phases as the device asks for them, extra bytes
 * read and dropped or padded with zeros.
 *
 * Needs port I/O, nothing else from the host: C90 and 16-bit clean.
 */

#include <string.h>

#include "ahciaspi/native.h"
#include "openaspi/native/atapi.h"
#include "openaspi/native/hba.h"
#include "openaspi/native/host.h"
#include "openaspi/native/sat.h"

#define MAX_ADAPTERS 4

/* command block registers (offset from the command port) */
#define IDE_DATA    0u
#define IDE_ERROR   1u
#define IDE_FEATURE 1u
#define IDE_COUNT   2u /* sector count / interrupt reason */
#define IDE_LBA0    3u
#define IDE_LBA1    4u /* byte count low (packet) */
#define IDE_LBA2    5u /* byte count high (packet) */
#define IDE_SELECT  6u
#define IDE_STATUS  7u
#define IDE_COMMAND 7u

/* device control register (control port) */
#define CTL_NIEN 0x02u
#define CTL_SRST 0x04u
#define CTL_HOB  0x80u

#define ST_ERR  0x01u
#define ST_DRQ  0x08u
#define ST_BSY  0x80u

#define ATA_PACKET          0xA0u
#define ATA_IDENTIFY_PACKET 0xA1u
#define ATA_DEVICE_RESET    0x08u

#define PACKET_BCL 0xFFFEu

struct ide_chan;

struct ide_dev {
    struct ide_chan *ch;
    oa_u8 slave;
    oa_u8 present;
    oa_u8 is_atapi;
    struct oa_atapi atapi;
    struct oa_sat sat;
};

struct ide_chan {
    oa_u16 cmd, ctl;
    struct ide_dev dev[2];
};

struct ide_adapter {
    struct oa_hba hba;
    char name[32];
    struct ide_chan chan[2];
    unsigned nchan;
};

static struct ide_adapter adapters[MAX_ADAPTERS];
static unsigned nadapters;

static oa_u8 rd(struct ide_chan *ch, unsigned reg)
{
    return oa_host_inb((oa_u16)(ch->cmd + reg));
}

static void wr(struct ide_chan *ch, unsigned reg, oa_u8 v)
{
    oa_host_outb((oa_u16)(ch->cmd + reg), v);
}

/* ~400 ns: four reads of the alternate status register */
static oa_u8 delay400(struct ide_chan *ch)
{
    oa_host_inb(ch->ctl);
    oa_host_inb(ch->ctl);
    oa_host_inb(ch->ctl);
    return oa_host_inb(ch->ctl);
}

/* Wait until (status & mask) == value. Returns the status, or -1 on a
 * timeout or a floating bus (FFh). */
static int wait_status(struct ide_chan *ch, oa_u8 mask, oa_u8 value, oa_u32 ms)
{
    oa_u64 end = oa_host_time_us() + (oa_u64)ms * 1000u;
    oa_u8 st;

    for (;;) {
        st = rd(ch, IDE_STATUS);
        if (st == 0xFFu) {
            return -1;
        }
        if ((st & mask) == value) {
            return st;
        }
        if (oa_host_time_us() > end) {
            return -1;
        }
        oa_host_delay_us(1);
    }
}

static int select_dev(struct ide_dev *d, oa_u8 bits)
{
    struct ide_chan *ch = d->ch;

    if (wait_status(ch, ST_BSY | ST_DRQ, 0, 1000) < 0) {
        return -1;
    }
    wr(ch, IDE_SELECT, (oa_u8)(0xA0u | (d->slave ? 0x10u : 0u) | bits));
    delay400(ch);
    return wait_status(ch, ST_BSY | ST_DRQ, 0, 1000) < 0 ? -1 : 0;
}

/* Data phase helpers: `n` bytes offered (in) or requested (out) by the
 * device, `*left` bytes of room or data left in the buffer at `*p`. */
static void pio_in(struct ide_chan *ch, oa_u8 **p, oa_u32 *left, oa_u32 n, oa_u32 *xfer)
{
    oa_u32 words = (n + 1u) / 2u;
    oa_u16 w;

    while (words--) {
        w = oa_host_inw((oa_u16)(ch->cmd + IDE_DATA));
        if (*left >= 2u) {
            (*p)[0] = (oa_u8)w;
            (*p)[1] = (oa_u8)(w >> 8);
            *p += 2;
            *left -= 2u;
            *xfer += 2u;
        } else if (*left == 1u) {
            (*p)[0] = (oa_u8)w;
            *p += 1;
            *left = 0;
            *xfer += 1u;
        }
    }
}

static void pio_out(struct ide_chan *ch, const oa_u8 **p, oa_u32 *left, oa_u32 n, oa_u32 *xfer)
{
    oa_u32 words = (n + 1u) / 2u;
    oa_u16 w;

    while (words--) {
        w = 0;
        if (*left >= 2u) {
            w = (oa_u16)((*p)[0] | ((oa_u16)(*p)[1] << 8));
            *p += 2;
            *left -= 2u;
            *xfer += 2u;
        } else if (*left == 1u) {
            w = (*p)[0];
            *p += 1;
            *left = 0;
            *xfer += 1u;
        }
        oa_host_outw((oa_u16)(ch->cmd + IDE_DATA), w);
    }
}

/* DEVICE RESET for a hung ATAPI device (the channel's other drive stays). */
static void device_reset(struct ide_dev *d)
{
    struct ide_chan *ch = d->ch;

    wr(ch, IDE_SELECT, (oa_u8)(0xA0u | (d->slave ? 0x10u : 0u)));
    delay400(ch);
    wr(ch, IDE_COMMAND, ATA_DEVICE_RESET);
    delay400(ch);
    wait_status(ch, ST_BSY, 0, 5000);
}

/* --- ATA disks: PIO commands for OpenASPI's SCSI/ATA translation ------- */

static int ata_cmd(void *ctx, struct oa_ata_cmd *c)
{
    struct ide_dev *d = ctx;
    struct ide_chan *ch = d->ch;
    oa_u32 block = 512u, left = c->len, xfer = 0;
    oa_u32 timeout = c->timeout_ms ? c->timeout_ms : 30000u;
    oa_u8 *p = c->data;
    const oa_u8 *q = c->data;
    int st;

    if (c->dma) {
        return OA_HOST_UNSUPPORTED;
    }
    if (d->sat.emu.block_size > 512u && c->len >= d->sat.emu.block_size &&
        c->len % d->sat.emu.block_size == 0u) {
        block = d->sat.emu.block_size;
    }
    if (select_dev(d, (oa_u8)(c->device | (c->lba48 ? 0u : (oa_u8)((c->lba >> 24) & 0x0Fu)))) < 0) {
        return OA_HOST_TIMEOUT;
    }
    if (c->lba48) {
        wr(ch, IDE_FEATURE, 0);
        wr(ch, IDE_COUNT, (oa_u8)(c->count >> 8));
        wr(ch, IDE_LBA0, (oa_u8)(c->lba >> 24));
        wr(ch, IDE_LBA1, (oa_u8)(c->lba >> 32));
        wr(ch, IDE_LBA2, (oa_u8)(c->lba >> 40));
    }
    wr(ch, IDE_FEATURE, c->features);
    wr(ch, IDE_COUNT, (oa_u8)c->count);
    wr(ch, IDE_LBA0, (oa_u8)c->lba);
    wr(ch, IDE_LBA1, (oa_u8)(c->lba >> 8));
    wr(ch, IDE_LBA2, (oa_u8)(c->lba >> 16));
    wr(ch, IDE_COMMAND, c->command);
    delay400(ch);

    if (c->dir == OA_DIR_OUT) {
        while (left != 0u) {
            st = wait_status(ch, ST_BSY, 0, timeout);
            if (st < 0) {
                return OA_HOST_TIMEOUT;
            }
            if ((st & ST_ERR) || !(st & ST_DRQ)) {
                break;
            }
            pio_out(ch, &q, &left, block, &xfer);
            delay400(ch);
        }
    } else if (c->dir == OA_DIR_IN) {
        while (left != 0u) {
            st = wait_status(ch, ST_BSY, 0, timeout);
            if (st < 0) {
                return OA_HOST_TIMEOUT;
            }
            if ((st & ST_ERR) || !(st & ST_DRQ)) {
                break;
            }
            pio_in(ch, &p, &left, block, &xfer);
            delay400(ch);
        }
    }
    st = wait_status(ch, ST_BSY, 0, timeout);
    if (st < 0) {
        return OA_HOST_TIMEOUT;
    }
    c->status = (oa_u8)st;
    c->error = (st & ST_ERR) ? rd(ch, IDE_ERROR) : 0u;
    if (!(st & ST_ERR) && left != 0u) {
        c->status |= ST_ERR; /* device ended the data phase early */
        c->error = 0x04u;    /* ABRT */
    }
    return OA_HOST_OK;
}

/* --- ATAPI devices: the PACKET protocol ------------------------------- */

static int packet_cmd(void *ctx, const oa_u8 packet[16], oa_u8 dir, void *data, oa_u32 len,
                      oa_u32 timeout_ms, oa_u8 *status, oa_u8 *error, oa_u32 *xfer)
{
    struct ide_dev *d = ctx;
    struct ide_chan *ch = d->ch;
    oa_u32 timeout = timeout_ms ? timeout_ms : 30000u, left = len, n;
    oa_u8 *p = data;
    const oa_u8 *q = data;
    unsigned i;
    int st;

    *status = 0;
    *error = 0;
    *xfer = 0;
    if (dir == OA_DIR_NONE) {
        left = 0;
    }
    if (select_dev(d, 0) < 0) {
        device_reset(d);
        return OA_HOST_TIMEOUT;
    }
    wr(ch, IDE_FEATURE, 0); /* PIO, no overlap */
    wr(ch, IDE_COUNT, 0);
    wr(ch, IDE_LBA1, (oa_u8)PACKET_BCL);
    wr(ch, IDE_LBA2, (oa_u8)(PACKET_BCL >> 8));
    wr(ch, IDE_COMMAND, ATA_PACKET);
    delay400(ch);
    st = wait_status(ch, ST_BSY, 0, 1000);
    if (st < 0) {
        device_reset(d);
        return OA_HOST_TIMEOUT;
    }
    if (!(st & ST_ERR)) {
        if (!(st & ST_DRQ)) {
            device_reset(d);
            return OA_HOST_BUS_ERROR; /* no packet request: protocol error */
        }
        for (i = 0; i < d->atapi.packet_size; i += 2u) {
            oa_host_outw((oa_u16)(ch->cmd + IDE_DATA),
                         (oa_u16)(packet[i] | ((oa_u16)packet[i + 1u] << 8)));
        }
        delay400(ch);
        for (;;) {
            st = wait_status(ch, ST_BSY, 0, timeout);
            if (st < 0) {
                device_reset(d);
                return OA_HOST_TIMEOUT;
            }
            if ((st & ST_ERR) || !(st & ST_DRQ)) {
                break;
            }
            n = rd(ch, IDE_LBA1) | ((oa_u32)rd(ch, IDE_LBA2) << 8);
            if (rd(ch, IDE_COUNT) & 0x02u) { /* I/O: to the host */
                pio_in(ch, &p, &left, n, xfer);
            } else {
                pio_out(ch, &q, &left, n, xfer);
            }
            delay400(ch);
        }
    }
    *status = (oa_u8)st;
    if (st & ST_ERR) {
        *error = rd(ch, IDE_ERROR);
    }
    return OA_HOST_OK;
}

/* --- the adapter ------------------------------------------------------ */

static void ide_execute(struct oa_hba *hba, struct oa_srb *srb)
{
    struct ide_adapter *a = (struct ide_adapter *)hba;
    struct ide_dev *d = 0;

    if (srb->target < 2u * a->nchan) {
        d = &a->chan[srb->target >> 1].dev[srb->target & 1u];
    }
    if (d == 0 || !d->present) {
        srb->host_status = OA_HOST_NO_DEVICE;
        return;
    }
    if (d->is_atapi) {
        oa_atapi_execute(&d->atapi, srb);
    } else {
        oa_sat_execute(&d->sat, srb);
    }
}

static const struct oa_hba_ops ide_ops = { ide_execute, 0 };

/* Software reset of the channel, then wait for both drives. Returns 0 when
 * the channel has registers at all. */
static int chan_reset(struct ide_chan *ch)
{
    /* the register file must hold a value: no IDE channel otherwise */
    wr(ch, IDE_SELECT, 0xA0u);
    delay400(ch);
    wr(ch, IDE_LBA0, 0x55u);
    wr(ch, IDE_LBA1, 0xAAu);
    if (rd(ch, IDE_LBA0) != 0x55u || rd(ch, IDE_LBA1) != 0xAAu) {
        wr(ch, IDE_SELECT, 0xB0u);
        delay400(ch);
        wr(ch, IDE_LBA0, 0x55u);
        wr(ch, IDE_LBA1, 0xAAu);
        if (rd(ch, IDE_LBA0) != 0x55u || rd(ch, IDE_LBA1) != 0xAAu) {
            return -1;
        }
    }
    oa_host_outb(ch->ctl, CTL_NIEN | CTL_SRST);
    oa_host_delay_us(10);
    oa_host_outb(ch->ctl, CTL_NIEN);
    oa_host_delay_us(2000);
    wait_status(ch, ST_BSY, 0, 5000);
    return 0;
}

static void dev_probe(struct ide_dev *d)
{
    struct ide_chan *ch = d->ch;
    oa_u8 sig1, sig2;
    int st;
    struct oa_ata_cmd c;

    wr(ch, IDE_SELECT, (oa_u8)(0xA0u | (d->slave ? 0x10u : 0u)));
    delay400(ch);
    if (rd(ch, IDE_STATUS) == 0xFFu) {
        return; /* floating bus */
    }
    st = wait_status(ch, ST_BSY, 0, 5000);
    if (st < 0) {
        return;
    }
    /* signature left by the reset; ATAPI devices report status 00h then
     * (no DRDY), which would otherwise look like an empty position */
    sig1 = rd(ch, IDE_LBA1);
    sig2 = rd(ch, IDE_LBA2);
    if ((sig1 == 0x14u && sig2 == 0xEBu) || (sig1 == 0x69u && sig2 == 0x96u)) {
        memset(&c, 0, sizeof(c));
        c.command = ATA_IDENTIFY_PACKET;
        c.dir = OA_DIR_IN;
        c.data = d->sat.identify;
        c.len = 512;
        c.timeout_ms = 5000;
        if (ata_cmd(d, &c) != OA_HOST_OK || (c.status & ST_ERR)) {
            return;
        }
        d->atapi.packet_size = (oa_u8)OA_ATAPI_PACKET_SIZE(d->sat.identify[0]);
        d->is_atapi = 1; /* packet_cmd needs the packet size for INQUIRY */
        if (oa_atapi_init(&d->atapi, packet_cmd, d, d->sat.identify) != OA_HOST_OK) {
            return;
        }
        d->atapi.dma = 0; /* PIO only on this transport */
    } else {
        if (st == 0x00u) {
            return; /* nothing there */
        }
        if (oa_sat_init(&d->sat, ata_cmd, d, 0) != OA_HOST_OK) {
            return;
        }
    }
    d->present = 1;
}

static void hex(char *out, oa_u32 v, unsigned digits)
{
    while (digits--) {
        out[digits] = "0123456789abcdef"[v & 15u];
        v >>= 4;
    }
}

int ahciaspi_probe_ide_ports(const oa_u16 cmd[2], const oa_u16 ctl[2], const char *name)
{
    struct ide_adapter *a;
    unsigned i, j, found = 0;

    if (!oa_host_has_port_io() || nadapters == MAX_ADAPTERS) {
        return -1;
    }
    a = &adapters[nadapters];
    memset(a, 0, sizeof(*a));
    for (i = 0; i < 2; i++) {
        struct ide_chan *ch = &a->chan[a->nchan];
        if (cmd[i] == 0u) {
            continue;
        }
        ch->cmd = cmd[i];
        ch->ctl = ctl[i];
        a->nchan++;
        if (chan_reset(ch) < 0) {
            continue;
        }
        for (j = 0; j < 2; j++) {
            ch->dev[j].ch = ch;
            ch->dev[j].slave = (oa_u8)j;
            dev_probe(&ch->dev[j]);
            found += ch->dev[j].present;
        }
    }
    if (found == 0u) {
        return 0;
    }
    for (i = 0; i < sizeof(a->name) - 1u && name[i]; i++) {
        a->name[i] = name[i];
    }
    a->hba.name = a->name;
    a->hba.ops = &ide_ops;
    a->hba.priv = a;
    a->hba.max_target = (oa_u8)(2u * a->nchan - 1u);
    a->hba.max_lun = 0;
    nadapters++;
    oa_hba_register(&a->hba);
    return (int)found;
}

int ahciaspi_probe_ide(oa_u32 pci)
{
    oa_u32 cc = oa_host_pci_read32(pci, 0x08) >> 8, cmdreg, bar;
    oa_u16 cmd[2], ctl[2];
    unsigned i;
    char name[24];

    if ((cc >> 8) != AHCIASPI_PCI_CLASS_IDE) {
        return -1;
    }
    for (i = 0; i < 2; i++) {
        if (cc & (1u << (2u * i))) { /* native mode: BARs */
            bar = oa_host_pci_read32(pci, 0x10u + 8u * i);
            cmd[i] = (bar & 1u) ? (oa_u16)(bar & 0xFFFCu) : 0u;
            bar = oa_host_pci_read32(pci, 0x14u + 8u * i);
            ctl[i] = (bar & 1u) ? (oa_u16)((bar & 0xFFFCu) + 2u) : 0u;
            if (ctl[i] == 0u) {
                cmd[i] = 0;
            }
        } else {
            cmd[i] = i ? 0x170u : 0x1F0u;
            ctl[i] = i ? 0x376u : 0x3F6u;
        }
    }
    cmdreg = oa_host_pci_read32(pci, 0x04);
    oa_host_pci_write32(pci, 0x04, (cmdreg & 0xFFFFu) | 0x0001u); /* I/O decoding */
    memcpy(name, "IDE 0000:00:00.0", 17);
    hex(name + 4, pci >> 16, 4);
    hex(name + 9, (pci >> 8) & 0xFFu, 2);
    hex(name + 12, (pci >> 3) & 0x1Fu, 2);
    name[15] = (char)('0' + (pci & 7u));
    return ahciaspi_probe_ide_ports(cmd, ctl, name);
}
