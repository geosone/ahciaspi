/* SPDX-License-Identifier: GPL-2.0-or-later */
/* AHCI transport for OpenASPI's native layer (polled).
 *
 * Port handling follows AHCIASPI.SYS: stop the port (PxCMD.ST, FRE),
 * COMRESET if it does not stop, install our command list and FIS area,
 * clear errors, wait for BSY/DRQ (command list override if supported),
 * start. Unlike the DOS manager, which hands every port back to the BIOS
 * after each command, the controller stays ours.
 *
 * ATA disks answer SCSI through OpenASPI's SCSI/ATA translation with DMA
 * commands; ATAPI devices get the CDB as a packet (A0h), translated by
 * OpenASPI's ATAPI rules, with REQUEST SENSE as autosense.
 *
 * 32/64-bit only: the HBA registers and DMA memory need a flat address
 * space. The parts a DOS 16-bit build can share (SCSI/ATA translation,
 * ATAPI rules) live in OpenASPI.
 */

#include <string.h>

#include "ahciaspi/native.h"
#include "openaspi/native/atapi.h"
#include "openaspi/native/hba.h"
#include "openaspi/native/host.h"
#include "openaspi/native/sat.h"

#define MAX_PORTS 32
#define MAX_CONTROLLERS 4
#define BOUNCE_SIZE 65536u
#define PRD_MAX 4194304ul /* bytes per PRD entry */
#define NPRD 8

/* HBA registers */
#define HBA_CAP  0x00u
#define HBA_GHC  0x04u
#define HBA_IS   0x08u
#define HBA_PI   0x0Cu
#define HBA_VS   0x10u
#define HBA_CAP2 0x24u
#define HBA_BOHC 0x28u

#define CAP_S64A  0x80000000ul
#define CAP_SCLO  0x01000000ul
#define GHC_AE    0x80000000ul
#define CAP2_BOH  0x00000001ul
#define BOHC_BOS  0x00000001ul
#define BOHC_OOS  0x00000002ul
#define BOHC_BB   0x00000010ul

/* port registers */
#define PxCLB  0x00u
#define PxCLBU 0x04u
#define PxFB   0x08u
#define PxFBU  0x0Cu
#define PxIS   0x10u
#define PxIE   0x14u
#define PxCMD  0x18u
#define PxTFD  0x20u
#define PxSIG  0x24u
#define PxSSTS 0x28u
#define PxSCTL 0x2Cu
#define PxSERR 0x30u
#define PxCI   0x38u

#define PxCMD_ST  0x0001ul
#define PxCMD_SUD 0x0002ul
#define PxCMD_POD 0x0004ul
#define PxCMD_CLO 0x0008ul
#define PxCMD_FRE 0x0010ul
#define PxCMD_FR  0x4000ul
#define PxCMD_CR  0x8000ul

#define PxIS_TFES  0x40000000ul
#define PxIS_FATAL 0x78000000ul /* TFES | HBFS | HBDS | IFS */

#define TFD_ERR 0x01u
#define TFD_DRQ 0x08u
#define TFD_BSY 0x80u

#define SIG_ATAPI 0xEB140101ul

#define CH_ATAPI 0x0020u
#define CH_WRITE 0x0040u

#define ATA_PACKET          0xA0u
#define ATA_IDENTIFY_PACKET 0xA1u

struct port {
    struct ctrl *c;
    unsigned no;
    volatile oa_u8 *regs;
    oa_u8 *cl;            /* command list (1 KiB), slot 0 used */
    oa_u8 *fis;           /* received FIS area (256 bytes) */
    oa_u8 *ct;            /* command table: CFIS, ACMD, PRDT */
    oa_u8 *bounce;
    oa_u64 cl_bus, fis_bus, ct_bus, bounce_bus;
    int is_atapi;
    struct oa_atapi atapi;
    struct oa_sat sat;
};

struct ctrl {
    struct oa_hba hba;
    char name[32];
    volatile oa_u8 *abar;
    oa_u32 cap;
    unsigned nports;
    struct port *ports[MAX_PORTS]; /* by target id */
};

static struct ctrl ctrls[MAX_CONTROLLERS];
static struct port port_pool[MAX_CONTROLLERS * MAX_PORTS];
static unsigned nctrls, nport_pool;

static oa_u32 rd(volatile oa_u8 *base, unsigned off)
{
    return *(volatile oa_u32 *)(base + off);
}

static void wr(volatile oa_u8 *base, unsigned off, oa_u32 v)
{
    *(volatile oa_u32 *)(base + off) = v;
}

/* Wait until (reg & mask) == value; 0 on success, -1 on timeout. */
static int wait_reg(volatile oa_u8 *base, unsigned off, oa_u32 mask, oa_u32 value, oa_u32 ms)
{
    oa_u64 end = oa_host_time_us() + (oa_u64)ms * 1000u;
    for (;;) {
        if ((rd(base, off) & mask) == value) {
            return 0;
        }
        if (oa_host_time_us() > end) {
            return -1;
        }
        oa_host_delay_us(10);
    }
}

static int port_stop(struct port *p)
{
    oa_u32 cmd = rd(p->regs, PxCMD);
    if (cmd & PxCMD_ST) {
        wr(p->regs, PxCMD, cmd & ~PxCMD_ST);
    }
    if (wait_reg(p->regs, PxCMD, PxCMD_CR, 0, 500) < 0) {
        return -1;
    }
    cmd = rd(p->regs, PxCMD);
    if (cmd & PxCMD_FRE) {
        wr(p->regs, PxCMD, cmd & ~PxCMD_FRE);
    }
    return wait_reg(p->regs, PxCMD, PxCMD_FR, 0, 500);
}

/* COMRESET; 0 when a device is back on the link. */
static int port_comreset(struct port *p)
{
    oa_u32 sctl;
    int r;

    sctl = rd(p->regs, PxSCTL) & 0xFFFFF000ul;
    wr(p->regs, PxSCTL, sctl | 0x301u); /* no partial/slumber, DET=1 */
    oa_host_delay_us(2000);
    wr(p->regs, PxSCTL, sctl | 0x300u);
    r = wait_reg(p->regs, PxSSTS, 0x0Fu, 0x03u, 1000);
    wr(p->regs, PxSERR, 0xFFFFFFFFul);
    return r;
}

static int port_start(struct port *p)
{
    oa_u32 cmd;

    wr(p->regs, PxIE, 0);
    wr(p->regs, PxCLB, (oa_u32)p->cl_bus);
    wr(p->regs, PxCLBU, (oa_u32)(p->cl_bus >> 32));
    wr(p->regs, PxFB, (oa_u32)p->fis_bus);
    wr(p->regs, PxFBU, (oa_u32)(p->fis_bus >> 32));
    wr(p->regs, PxSERR, 0xFFFFFFFFul);
    wr(p->regs, PxIS, 0xFFFFFFFFul);
    cmd = rd(p->regs, PxCMD);
    wr(p->regs, PxCMD, cmd | PxCMD_FRE | PxCMD_SUD | PxCMD_POD);
    if (wait_reg(p->regs, PxTFD, TFD_BSY | TFD_DRQ, 0, 1000) < 0 && (p->c->cap & CAP_SCLO)) {
        wr(p->regs, PxCMD, rd(p->regs, PxCMD) | PxCMD_CLO);
        wait_reg(p->regs, PxCMD, PxCMD_CLO, 0, 500);
    }
    wr(p->regs, PxCMD, rd(p->regs, PxCMD) | PxCMD_ST);
    return 0;
}

/* Stop, clear errors and start again after a failed command (AHCI 6.2.2). */
static void port_recover(struct port *p, int reset)
{
    if (port_stop(p) < 0 || reset) {
        port_comreset(p);
        port_stop(p);
    }
    port_start(p);
}

/* One command in slot 0. `cfis` is the 20-byte H2D FIS, `packet` the ATAPI
 * command or NULL. Data in `buf` (len bytes) must be reachable by DMA:
 * even length, word aligned, below 4 GiB without S64A, else it goes through
 * the bounce buffer. Returns OA_HOST_*; *tfd gets the task file data,
 * *xfer the bytes moved. */
static int port_exec(struct port *p, const oa_u8 cfis[20], const oa_u8 *packet, int write,
                     void *buf, oa_u32 len, oa_u32 timeout_ms, oa_u32 *tfd, oa_u32 *xfer)
{
    oa_u8 *ch = p->cl;
    oa_u8 *prd = p->ct + 0x80;
    oa_u64 bus = 0, end;
    oa_u32 left, n, is;
    oa_u16 nprd = 0, flags;
    int bounce = 0;

    *tfd = 0;
    *xfer = 0;
    if (len != 0u) {
        bus = oa_host_virt_to_bus(buf);
        if (bus == 0u || (bus & 1u) || (len & 1u) ||
            (!(p->c->cap & CAP_S64A) && bus + len > (oa_u64)0xFFFFFFFFul + 1u)) {
            if (len > BOUNCE_SIZE) {
                return OA_HOST_UNSUPPORTED;
            }
            bounce = 1;
            bus = p->bounce_bus;
            if (write) {
                memcpy(p->bounce, buf, len);
            }
        }
        left = (len + 1u) & ~1ul;
        while (left != 0u) {
            if (nprd == NPRD) {
                return OA_HOST_UNSUPPORTED;
            }
            n = left > PRD_MAX ? PRD_MAX : left;
            memset(prd + 16u * nprd, 0, 16);
            *(volatile oa_u32 *)(prd + 16u * nprd) = (oa_u32)bus;
            *(volatile oa_u32 *)(prd + 16u * nprd + 4) = (oa_u32)(bus >> 32);
            *(volatile oa_u32 *)(prd + 16u * nprd + 12) = n - 1u;
            bus += n;
            left -= n;
            nprd++;
        }
    }

    memset(p->ct, 0, 0x80);
    memcpy(p->ct, cfis, 20);
    if (packet) {
        memcpy(p->ct + 0x40, packet, 16);
    }
    flags = 5u; /* command FIS length in dwords */
    if (packet) {
        flags |= CH_ATAPI;
    }
    if (write) {
        flags |= CH_WRITE;
    }
    memset(ch, 0, 32);
    *(volatile oa_u16 *)ch = flags;
    *(volatile oa_u16 *)(ch + 2) = nprd;
    *(volatile oa_u32 *)(ch + 8) = (oa_u32)p->ct_bus;
    *(volatile oa_u32 *)(ch + 12) = (oa_u32)(p->ct_bus >> 32);

    wr(p->regs, PxIS, 0xFFFFFFFFul);
    wr(p->regs, PxCI, 1);
    end = oa_host_time_us() + (oa_u64)(timeout_ms ? timeout_ms : 30000u) * 1000u;
    for (;;) {
        is = rd(p->regs, PxIS);
        if (is & PxIS_FATAL) {
            *tfd = rd(p->regs, PxTFD);
            port_recover(p, !(is & PxIS_TFES));
            return (is & PxIS_TFES) ? OA_HOST_OK : OA_HOST_BUS_ERROR;
        }
        if (!(rd(p->regs, PxCI) & 1u)) {
            break;
        }
        if (oa_host_time_us() > end) {
            port_recover(p, 1);
            return OA_HOST_TIMEOUT;
        }
    }
    *tfd = rd(p->regs, PxTFD);
    *xfer = *(volatile oa_u32 *)(ch + 4);
    if (*xfer > len) {
        *xfer = len;
    }
    if (bounce && !write && *xfer) {
        memcpy(buf, p->bounce, *xfer);
    }
    return OA_HOST_OK;
}

/* --- ATA disks: the hook for OpenASPI's SCSI/ATA translation ---------- */

static int ata_cmd(void *ctx, struct oa_ata_cmd *c)
{
    struct port *p = ctx;
    oa_u8 fis[20];
    oa_u32 tfd, xfer;
    int r;

    memset(fis, 0, sizeof(fis));
    fis[0] = 0x27u; /* H2D register FIS */
    fis[1] = 0x80u; /* command */
    fis[2] = c->command;
    fis[3] = c->features;
    fis[4] = (oa_u8)c->lba;
    fis[5] = (oa_u8)(c->lba >> 8);
    fis[6] = (oa_u8)(c->lba >> 16);
    fis[7] = (oa_u8)(c->device | (c->lba48 ? 0u : (oa_u8)((c->lba >> 24) & 0x0Fu)));
    fis[8] = (oa_u8)(c->lba >> 24);
    fis[9] = (oa_u8)(c->lba >> 32);
    fis[10] = (oa_u8)(c->lba >> 40);
    fis[12] = (oa_u8)c->count;
    fis[13] = (oa_u8)(c->count >> 8);
    r = port_exec(p, fis, 0, c->dir == OA_DIR_OUT, c->data, c->len, c->timeout_ms, &tfd, &xfer);
    c->status = (oa_u8)tfd;
    c->error = (oa_u8)(tfd >> 8);
    return r;
}

/* --- ATAPI devices ----------------------------------------------------- */

static int packet_cmd(void *ctx, const oa_u8 packet[16], oa_u8 dir, void *buf, oa_u32 len,
                      oa_u32 timeout_ms, oa_u8 *status, oa_u8 *error, oa_u32 *xfer)
{
    struct port *p = ctx;
    oa_u8 fis[20];
    oa_u32 tfd;
    int r;

    if (dir == OA_DIR_NONE) {
        len = 0;
    }
    memset(fis, 0, sizeof(fis));
    fis[0] = 0x27u;
    fis[1] = 0x80u;
    fis[2] = ATA_PACKET;
    if (len != 0u && p->atapi.dma) {
        fis[3] = 0x01u; /* DMA */
        if (dir == OA_DIR_IN && p->atapi.dmadir) {
            fis[3] |= 0x04u;
        }
    }
    fis[5] = 0xFEu; /* byte count limit FFFEh for PIO data */
    fis[6] = 0xFFu;
    r = port_exec(p, fis, packet, dir == OA_DIR_OUT, buf, len, timeout_ms, &tfd, xfer);
    *status = (oa_u8)tfd;
    *error = (oa_u8)(tfd >> 8);
    return r;
}

/* --- the adapter ------------------------------------------------------- */

static void ahci_execute(struct oa_hba *hba, struct oa_srb *srb)
{
    struct ctrl *c = (struct ctrl *)hba;
    struct port *p = srb->target < c->nports ? c->ports[srb->target] : 0;

    if (p == 0 || srb->lun != 0u) {
        srb->host_status = OA_HOST_NO_DEVICE;
        return;
    }
    if (p->is_atapi) {
        oa_atapi_execute(&p->atapi, srb);
    } else {
        oa_sat_execute(&p->sat, srb);
    }
}

static const struct oa_hba_ops ahci_ops = { ahci_execute, 0 };

static int port_alloc(struct port *p, int below_4g)
{
    oa_u8 *mem;
    oa_u64 bus;

    /* 1 KiB command list, 256 bytes FIS, 256 bytes command table
     * (0x80 + NPRD * 16), all in one 4 KiB page. */
    mem = oa_host_dma_alloc(4096, 1024, below_4g, &bus);
    if (mem == 0) {
        return -1;
    }
    p->cl = mem;
    p->cl_bus = bus;
    p->fis = mem + 1024;
    p->fis_bus = bus + 1024;
    p->ct = mem + 2048;
    p->ct_bus = bus + 2048;
    p->bounce = oa_host_dma_alloc(BOUNCE_SIZE, 4096, below_4g, &p->bounce_bus);
    return p->bounce ? 0 : -1;
}

/* IDENTIFY PACKET DEVICE, then the shared ATAPI setup. */
static int atapi_init(struct port *p)
{
    oa_u8 fis[20];
    oa_u32 tfd, xfer;

    memset(fis, 0, sizeof(fis));
    fis[0] = 0x27u;
    fis[1] = 0x80u;
    fis[2] = ATA_IDENTIFY_PACKET;
    if (port_exec(p, fis, 0, 0, p->sat.identify, 512, 5000, &tfd, &xfer) != OA_HOST_OK ||
        (tfd & TFD_ERR)) {
        return -1;
    }
    return oa_atapi_init(&p->atapi, packet_cmd, p, p->sat.identify) == OA_HOST_OK ? 0 : -1;
}

static void hex(char *out, oa_u32 v, unsigned digits)
{
    while (digits--) {
        out[digits] = "0123456789abcdef"[v & 15u];
        v >>= 4;
    }
}

int ahciaspi_probe_ahci(oa_u32 pci)
{
    struct ctrl *c;
    oa_u32 bar_lo, bar_hi = 0, pi, ssts, cmd;
    oa_u64 abar;
    unsigned i, found = 0;
    int below_4g;

    if (nctrls == MAX_CONTROLLERS ||
        (oa_host_pci_read32(pci, 0x08) >> 8) != AHCIASPI_PCI_CLASS_AHCI) {
        return -1;
    }
    bar_lo = oa_host_pci_read32(pci, 0x24); /* BAR5: ABAR */
    if ((bar_lo & 0x6u) == 0x4u) {
        bar_hi = oa_host_pci_read32(pci, 0x28);
    }
    abar = ((oa_u64)bar_hi << 32) | (bar_lo & 0xFFFFFFF0ul);
    if (abar == 0u) {
        return -1;
    }
    cmd = oa_host_pci_read32(pci, 0x04);
    oa_host_pci_write32(pci, 0x04, (cmd & 0xFFFFu) | 0x0006u); /* memory, bus master */

    c = &ctrls[nctrls];
    memset(c, 0, sizeof(*c));
    c->abar = oa_host_map_mmio(abar, 0x1100);
    if (c->abar == 0) {
        return -1;
    }
    /* BIOS/OS handoff */
    if (rd(c->abar, HBA_CAP2) & CAP2_BOH) {
        wr(c->abar, HBA_BOHC, rd(c->abar, HBA_BOHC) | BOHC_OOS);
        if (wait_reg(c->abar, HBA_BOHC, BOHC_BOS, 0, 25) == 0) {
            oa_host_delay_us(25000);
            if (rd(c->abar, HBA_BOHC) & BOHC_BB) {
                wait_reg(c->abar, HBA_BOHC, BOHC_BB, 0, 2000);
            }
        }
    }
    wr(c->abar, HBA_GHC, rd(c->abar, HBA_GHC) | GHC_AE);
    c->cap = rd(c->abar, HBA_CAP);
    below_4g = !(c->cap & CAP_S64A);
    pi = rd(c->abar, HBA_PI);

    for (i = 0; i < MAX_PORTS; i++) {
        struct port *p;
        if (!(pi & (1ul << i))) {
            continue;
        }
        if (nport_pool == sizeof(port_pool) / sizeof(port_pool[0])) {
            break;
        }
        p = &port_pool[nport_pool];
        memset(p, 0, sizeof(*p));
        p->c = c;
        p->no = i;
        p->regs = c->abar + 0x100u + 0x80u * i;
        ssts = rd(p->regs, PxSSTS);
        if ((ssts & 0x0Fu) != 0x03u) {
            continue; /* no device on the link */
        }
        if (port_stop(p) < 0) {
            if (port_comreset(p) < 0 || port_stop(p) < 0) {
                continue;
            }
        }
        if (port_alloc(p, below_4g) < 0) {
            oa_host_log(OA_LOG_ERROR, "AHCI: out of DMA memory\n");
            break;
        }
        port_start(p);
        p->is_atapi = rd(p->regs, PxSIG) == SIG_ATAPI;
        if (p->is_atapi ? atapi_init(p) < 0
                     : oa_sat_init(&p->sat, ata_cmd, p, 1) != OA_HOST_OK) {
            oa_host_log(OA_LOG_WARN, "AHCI: port %u: device does not answer\n", i);
            port_stop(p);
            continue;
        }
        nport_pool++;
        c->ports[c->nports++] = p;
        found++;
    }

    memcpy(c->name, "AHCI 0000:00:00.0", 18);
    hex(c->name + 5, pci >> 16, 4);
    hex(c->name + 10, (pci >> 8) & 0xFFu, 2);
    hex(c->name + 13, (pci >> 3) & 0x1Fu, 2);
    c->name[16] = (char)('0' + (pci & 7u));
    c->hba.name = c->name;
    c->hba.ops = &ahci_ops;
    c->hba.priv = c;
    c->hba.max_target = (oa_u8)(c->nports ? c->nports - 1u : 0u);
    c->hba.max_lun = 0;
    nctrls++;
    if (c->nports) {
        oa_hba_register(&c->hba);
    }
    return (int)found;
}
