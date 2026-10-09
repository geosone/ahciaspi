/* AHCIVXD.C: 32-bit disk access ("FastDisk") for Windows 3.1x enhanced
 * mode on IDE and AHCI controllers.
 *
 * The BIOS hard disks (80h..83h) are found on the controllers by comparing
 * their size (EDD) and first sector with what the BIOS returns (called in
 * the system VM during Device_Init).  Each disk found is registered with BlockDev, so
 * Windows (paging, 32-bit file access, the Int13 device for the DOS boxes)
 * sends its requests to us; INT 13h of the VMs for these disks is handled
 * here as well, including the extended functions (41h-44h) which the Int13
 * device of Windows 3.1 doesn't know (MS-DOS 7.x uses them for LBA and
 * FAT32 partitions).  Commands are executed polled.
 *
 * SYSTEM.INI [AHCIVXD]: LogPort (debug output port, e.g. 0E9h for QEMU),
 * PIO32=0 (16-bit PIO), Int13=0 (don't handle INT 13h of the VMs),
 * IgnoreChain=1 (load although a program hooked DOS's Int 13h path).
 *
 * Copyright (C) 2026 GeosOne.  GNU General Public License version 3. */

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned long u32;
typedef unsigned long long u64;

/* --- services (AHCIVXD.ASM) -------------------------------------------- */
int      vxd_register( void *bdd );
void     vxd_complete( void *bdd, void *cmd );
struct v86regs { u32 eax, ebx, ecx, edx, esi, edi; u16 ds, es; u32 flags; };
void     vxd_exec_int( int intno, struct v86regs *r );
u32      vxd_temp_v86( u32 bytes );
u32      vxd_v86_callback( void );
int      vxd_hook_int4b( void );
u32      vxd_unswap_callback( void );
void     vxd_free_temp_v86( void );
u32      vxd_time( void );
int      vxd_profile_int( const char *key, int def );
int      vxd_hook_int13( void );
void    *vxd_page_alloc( u32 pages );
u32      vxd_lin_to_phys( void *lin );
void    *vxd_map_phys( u32 phys, u32 size );
u32      vxd_high_linear( u32 vm );
extern void command_proc( void );
extern void sync_cmd_proc( void );
extern void hw_int_proc( void );

/* --- port I/O ------------------------------------------------------------- */
u8 inb( u16 port );
#pragma aux inb = "in al, dx" parm [dx] value [al]
u16 inw( u16 port );
#pragma aux inw = "in ax, dx" parm [dx] value [ax]
u32 ind( u16 port );
#pragma aux ind = "in eax, dx" parm [dx] value [eax]
void outb( u16 port, u8 v );
#pragma aux outb = "out dx, al" parm [dx] [al]
void outd( u16 port, u32 v );
#pragma aux outd = "out dx, eax" parm [dx] [eax]
void insw( u16 port, void *buf, u32 n );
#pragma aux insw = "rep insw" parm [dx] [edi] [ecx] modify [edi ecx]
void insd( u16 port, void *buf, u32 n );
#pragma aux insd = "rep insd" parm [dx] [edi] [ecx] modify [edi ecx]
void outsw( u16 port, const void *buf, u32 n );
#pragma aux outsw = "rep outsw" parm [dx] [esi] [ecx] modify [esi ecx]
void outsd( u16 port, const void *buf, u32 n );
#pragma aux outsd = "rep outsd" parm [dx] [esi] [ecx] modify [esi ecx]
u32 irqsave( void );
#pragma aux irqsave = "pushfd" "pop eax" "cli" value [eax]
void irqrestore( u32 );
#pragma aux irqrestore = "push eax" "popfd" parm [eax]

static void mem_cpy( void *d, const void *s, u32 n ) { u8 *a = d; const u8 *b = s; while ( n-- ) *a++ = *b++; }
static void mem_set( void *d, u8 v, u32 n ) { u8 *a = d; while ( n-- ) *a++ = v; }

/* --- debug output (SYSTEM.INI [AHCIVXD] LogPort=...) --------------------- */
static u16 logport;

static void lputc( char c ) { if ( logport ) outb( logport, c ); }
static void lputs( const char *s ) { while ( *s ) lputc( *s++ ); }
static void lhex( u32 v, int digits )
{
	while ( digits-- )
		lputc( "0123456789ABCDEF"[( v >> ( digits * 4 ) ) & 15] );
}
static void ldec( u32 v )
{
	char b[12];
	int i = 0;
	do b[i++] = '0' + v % 10; while ( v /= 10 );
	while ( i ) lputc( b[--i] );
}

/* --- BlockDev structures (Windows 3.1) ------------------------------------ */
#pragma pack( push, 1 )
typedef struct {
	u32 next;
	u8  major, minor, type, int13;
	u32 flags;
	const char *name;
	u64 max_sector;
	u32 sector_size, heads, cylinders, spt;
	void ( *sync_proc )( void );
	void ( *cmd_proc )( void );
	void ( *hwint_proc )( void );
	u8  reserved[0x30];
	struct disk *disk;           /* ours */
} BDD;

typedef struct {
	u32 next;
	u16 command, status;
	u32 flags;
	u32 cplt_proc;
	u64 sector;
	u32 count;
	u32 buffer;
	u32 res_client, res_blockdev, res_fastdisk;
} BCB;

typedef struct {                 /* scatter/gather list entry */
	u32 count;                   /* sectors, 0 = end */
	u32 buffer;
} BSG;

/* what the BIOS says about a hard disk */
struct rmi_drive {
	u8  bios, valid, edd, pad;
	u16 cyl, heads, spt, pad2;
	u64 sectors;                 /* EDD, 0 = unknown */
	u32 crc;                     /* CRC-32 of the first sector */
};
#pragma pack( pop )

#define BDF_INT13     0x01
#define BDF_WRITEABLE 0x02
#define BDF_SERIAL    0x10
#define BDT_FIXED     0x05
#define BDC_READ      0
#define BDC_WRITE     1
#define BDC_VERIFY    2
#define BDCF_SG       0x02
#define BDS_OK        0x00
#define BDS_BAD_SECTOR 0x10
#define BDS_MEDIA     0x14
#define BDS_DEVICE    0x15
#define BDS_BAD_CMD   0x16

/* --- disks ------------------------------------------------------------------ */
enum { T_IDE, T_AHCI };
enum { E_OK, E_TIMEOUT, E_DEVICE, E_RANGE };

struct disk {
	int type;
	u16 base, ctl;               /* IDE */
	u8  slave;
	u16 bm;                      /* IDE bus master registers, 0 = PIO only */
	u8  dma;                     /* IDE: a DMA mode is set: use bus master DMA */
	volatile u32 *port;          /* AHCI: port registers */
	u8  lba48;
	u64 sectors;
	char model[41];
	u8  bios;                    /* BIOS drive number, 0 = not matched */
	u16 cyl, heads, spt;         /* BIOS geometry */
	BDD bdd;
};

#define MAXDISK 8
static struct disk disks[MAXDISK];
static int ndisks;
static int pio32 = 1, do_int13 = 1, logall, use_dma = 1;
static u8 sector[512];           /* identify / compare buffer */
static u32 n_bd[3], n_i13[3], s_bd, s_i13;   /* statistics (log at exit) */
static u32 n_dma, kb_dma;        /* DMA commands, KB the controller transferred */
static u32 n_fix;                /* BIOS VDS fixes */
static char names[4][8] = { "AHCI80", "AHCI81", "AHCI82", "AHCI83" };

/* --- IDE, polled PIO --------------------------------------------------------- */
#define IDE_DATA   0
#define IDE_ERROR  1
#define IDE_COUNT  2
#define IDE_LBA0   3
#define IDE_LBA1   4
#define IDE_LBA2   5
#define IDE_DEVICE 6
#define IDE_STATUS 7
#define IDE_CMD    7
#define ST_ERR  0x01
#define ST_DRQ  0x08
#define ST_DF   0x20
#define ST_BSY  0x80

static void ide_delay( struct disk *d )
{
	inb( d->ctl ); inb( d->ctl ); inb( d->ctl ); inb( d->ctl );   /* 400 ns */
}

/* wait until BSY is clear (and DRQ set if drq); status or -1 on timeout */
static int ide_wait( struct disk *d, int drq, u32 ms )
{
	u32 t0 = vxd_time();
	for ( ;; ) {
		u8 st = inb( d->ctl );   /* alternate status */
		if ( st == 0xFF )
			return -1;           /* floating bus */
		if ( !( st & ST_BSY ) ) {
			if ( st & ( ST_ERR | ST_DF ) )
				return st;
			if ( !drq || ( st & ST_DRQ ) )
				return st;
		}
		if ( vxd_time() - t0 > ms )
			return -1;
	}
}

static int ide_select( struct disk *d, u8 head )
{
	if ( ide_wait( d, 0, 2000 ) < 0 )
		return -1;
	outb( d->base + IDE_DEVICE, 0xE0 | ( d->slave << 4 ) | head );
	ide_delay( d );
	return ide_wait( d, 0, 2000 ) < 0 ? -1 : 0;
}

/* one ATA command (up to 256 sectors, 65536 with lba48) */
static int ide_command( struct disk *d, u64 lba, u32 count, u8 *buf, int op )
{
	static const u8 cmd28[3] = { 0x20, 0x30, 0x40 }, cmd48[3] = { 0x24, 0x34, 0x42 };
	int ext = d->lba48 && ( lba + count > 0x0FFFFFFFULL || count > 256 );
	int st, rc = E_OK;
	u32 i;

	if ( ide_select( d, ext ? 0 : (u8)( ( lba >> 24 ) & 0x0F ) ) )
		return E_TIMEOUT;
	outb( d->ctl, 0x02 );        /* nIEN: polled */
	if ( ext ) {
		outb( d->base + IDE_COUNT, (u8)( count >> 8 ) );
		outb( d->base + IDE_LBA0, (u8)( lba >> 24 ) );
		outb( d->base + IDE_LBA1, (u8)( lba >> 32 ) );
		outb( d->base + IDE_LBA2, (u8)( lba >> 40 ) );
	}
	outb( d->base + IDE_COUNT, (u8)count );
	outb( d->base + IDE_LBA0, (u8)lba );
	outb( d->base + IDE_LBA1, (u8)( lba >> 8 ) );
	outb( d->base + IDE_LBA2, (u8)( lba >> 16 ) );
	outb( d->base + IDE_CMD, ext ? cmd48[op] : cmd28[op] );
	ide_delay( d );
	if ( op == BDC_VERIFY ) {
		st = ide_wait( d, 0, 30000 );
		rc = st < 0 ? E_TIMEOUT : ( st & ( ST_ERR | ST_DF ) ) ? E_DEVICE : E_OK;
	} else {
		for ( i = 0; i < count; i++, buf += 512 ) {
			st = ide_wait( d, 1, 10000 );
			if ( st < 0 ) { rc = E_TIMEOUT; break; }
			if ( st & ( ST_ERR | ST_DF ) ) { rc = E_DEVICE; break; }
			if ( op == BDC_READ ) {
				if ( pio32 ) insd( d->base, buf, 128 ); else insw( d->base, buf, 256 );
			} else {
				if ( pio32 ) outsd( d->base, buf, 128 ); else outsw( d->base, buf, 256 );
			}
		}
		if ( rc == E_OK && op == BDC_WRITE ) {
			st = ide_wait( d, 0, 10000 );
			if ( st < 0 ) rc = E_TIMEOUT;
			else if ( st & ( ST_ERR | ST_DF ) ) rc = E_DEVICE;
		}
	}
	inb( d->base + IDE_STATUS );     /* clears a pending interrupt */
	outb( d->ctl, 0x00 );            /* interrupts on again (for the BIOS) */
	return rc;
}

static int ide_identify( struct disk *d )
{
	u16 *id = (u16 *)sector;
	int st, i;
	u8 v = inb( d->base + IDE_STATUS );
	if ( v == 0xFF || v == 0x7F )
		return -1;               /* no device / no channel */
	outb( d->base + IDE_DEVICE, 0xA0 | ( d->slave << 4 ) );
	ide_delay( d );
	if ( ide_wait( d, 0, 500 ) < 0 )
		return -1;
	if ( inb( d->base + IDE_LBA1 ) == 0x14 && inb( d->base + IDE_LBA2 ) == 0xEB )
		return -1;               /* ATAPI */
	outb( d->ctl, 0x02 );
	outb( d->base + IDE_CMD, 0xEC );
	ide_delay( d );
	if ( inb( d->ctl ) == 0 ) {
		outb( d->ctl, 0x00 );
		return -1;
	}
	st = ide_wait( d, 1, 3000 );
	if ( st < 0 || ( st & ( ST_ERR | ST_DF ) ) || !( st & ST_DRQ ) ) {
		inb( d->base + IDE_STATUS );
		outb( d->ctl, 0x00 );
		return -1;
	}
	insw( d->base, sector, 256 );
	inb( d->base + IDE_STATUS );
	outb( d->ctl, 0x00 );
	if ( !( id[49] & 0x0200 ) )
		return -1;               /* no LBA: leave it to the BIOS */
	d->sectors = id[60] | (u32)id[61] << 16;
	if ( id[83] & 0x0400 ) {
		u64 s48 = id[100] | (u64)id[101] << 16 | (u64)id[102] << 32 | (u64)id[103] << 48;
		if ( s48 > d->sectors ) {
			d->sectors = s48;
			d->lba48 = 1;
		}
		d->lba48 = 1;
	}
	for ( i = 0; i < 20; i++ ) {
		d->model[2 * i] = sector[54 + 2 * i + 1];
		d->model[2 * i + 1] = sector[54 + 2 * i];
	}
	for ( i = 40; i && d->model[i - 1] == ' '; i-- );
	d->model[i] = 0;
	return 0;
}

/* --- AHCI ------------------------------------------------------------------------ */
#define PxCLB  0
#define PxCLBU 1
#define PxFB   2
#define PxFBU  3
#define PxIS   4
#define PxIE   5
#define PxCMD  6
#define PxTFD  8
#define PxSIG  9
#define PxSSTS 10
#define PxSERR 12
#define PxCI   14
#define CMD_ST  0x0001
#define CMD_CLO 0x0008
#define CMD_FRE 0x0010
#define CMD_FR  0x4000
#define CMD_CR  0x8000
#define IS_FATAL 0x78000000UL
#define BOUNCE_PAGES 16          /* 64 KB */

static u8 *amem;                 /* command list (0), FIS (400h), table (500h) */
static u32 amem_phys;
static u8 *bounce;
static u32 bounce_phys[BOUNCE_PAGES];

static int alloc_dma( void );

static int wait_clear( volatile u32 *r, u32 mask, u32 ms )
{
	u32 t0 = vxd_time();
	while ( *r & mask )
		if ( vxd_time() - t0 > ms )
			return -1;
	return 0;
}

static int port_stop( volatile u32 *p )
{
	p[PxCMD] &= ~(u32)CMD_ST;
	if ( wait_clear( &p[PxCMD], CMD_CR, 600 ) )
		return -1;
	p[PxCMD] &= ~(u32)CMD_FRE;
	return wait_clear( &p[PxCMD], CMD_FR, 600 );
}

static int port_start( volatile u32 *p )
{
	p[PxCMD] |= CMD_FRE;
	if ( wait_clear( &p[PxTFD], 0x88, 2000 ) ) {   /* BSY, DRQ */
		p[PxCMD] |= CMD_CLO;
		wait_clear( &p[PxCMD], CMD_CLO, 600 );
	}
	p[PxCMD] |= CMD_ST;
	return 0;
}

/* one command in slot 0 with the BIOS's port state saved and restored:
 * cmd = ATA command, n sectors at lba, data in the bounce buffer */
static int ahci_cmd( struct disk *d, u8 cmd, u64 lba, u32 n, int write, u32 bytes )
{
	volatile u32 *p = d->port;
	u32 sv[6], *ch = (u32 *)amem, t0;
	u8 *fis = amem + 0x500;
	u32 *prd = (u32 *)( amem + 0x580 );
	int i, rc = E_OK, nprd = 0;

	sv[0] = p[PxCLB]; sv[1] = p[PxCLBU]; sv[2] = p[PxFB]; sv[3] = p[PxFBU]; sv[4] = p[PxIE]; sv[5] = p[PxCMD];
	if ( port_stop( p ) )
		return E_TIMEOUT;
	p[PxIE] = 0;
	p[PxCLB] = amem_phys;
	p[PxCLBU] = 0;
	p[PxFB] = amem_phys + 0x400;
	p[PxFBU] = 0;
	p[PxSERR] = 0xFFFFFFFFUL;
	p[PxIS] = 0xFFFFFFFFUL;
	port_start( p );

	for ( i = 0; bytes && i < BOUNCE_PAGES; i++ ) {
		u32 b = bytes > 4096 ? 4096 : bytes;
		prd[4 * i] = bounce_phys[i];
		prd[4 * i + 1] = 0;
		prd[4 * i + 2] = 0;
		prd[4 * i + 3] = b - 1;
		bytes -= b;
		nprd++;
	}
	ch[0] = 5 | ( write ? 0x40 : 0 ) | (u32)nprd << 16;
	ch[1] = 0;
	ch[2] = amem_phys + 0x500;
	ch[3] = 0;
	mem_set( fis, 0, 0x80 );
	fis[0] = 0x27;               /* register FIS, host to device */
	fis[1] = 0x80;
	fis[2] = cmd;
	fis[4] = (u8)lba; fis[5] = (u8)( lba >> 8 ); fis[6] = (u8)( lba >> 16 );
	fis[7] = 0x40;               /* LBA */
	fis[8] = (u8)( lba >> 24 ); fis[9] = (u8)( lba >> 32 ); fis[10] = (u8)( lba >> 40 );
	fis[12] = (u8)n; fis[13] = (u8)( n >> 8 );
	p[PxCI] = 1;
	t0 = vxd_time();
	for ( ;; ) {
		if ( p[PxIS] & IS_FATAL ) {
			rc = ( p[PxTFD] & 0x01 ) ? E_DEVICE : E_TIMEOUT;
			break;
		}
		if ( !( p[PxCI] & 1 ) ) {
			if ( p[PxTFD] & 0x01 )
				rc = E_DEVICE;
			break;
		}
		if ( vxd_time() - t0 > 30000 ) {
			rc = E_TIMEOUT;
			break;
		}
	}
	if ( rc == E_OK && nprd ) {  /* bytes the HBA moved by DMA (PRD byte count) */
		n_dma++;
		kb_dma += ch[1] >> 10;
	}
	/* the BIOS's state back */
	port_stop( p );
	p[PxSERR] = 0xFFFFFFFFUL;
	p[PxIS] = 0xFFFFFFFFUL;
	p[PxCLB] = sv[0]; p[PxCLBU] = sv[1]; p[PxFB] = sv[2]; p[PxFBU] = sv[3];
	if ( sv[5] & CMD_FRE ) p[PxCMD] |= CMD_FRE;
	if ( sv[5] & CMD_ST ) p[PxCMD] |= CMD_ST;
	p[PxIE] = sv[4];
	return rc;
}

static int ahci_io( struct disk *d, u64 lba, u32 n, u8 *buf, int op )
{
	static const u8 cmds[3] = { 0x25, 0x35, 0x42 };   /* READ/WRITE DMA EXT, READ VERIFY EXT */
	int rc;
	if ( op == BDC_WRITE )
		mem_cpy( bounce, buf, n * 512 );
	rc = ahci_cmd( d, cmds[op], lba, n, op == BDC_WRITE, op == BDC_VERIFY ? 0 : n * 512 );
	if ( rc == E_OK && op == BDC_READ )
		mem_cpy( buf, bounce, n * 512 );
	return rc;
}

static int ahci_identify( struct disk *d )
{
	u16 *id = (u16 *)bounce;
	int i;
	if ( ahci_cmd( d, 0xEC, 0, 0, 0, 512 ) )
		return -1;
	if ( !( id[83] & 0x0400 ) )
		return -1;               /* LBA48 is needed (all SATA disks have it) */
	d->lba48 = 1;
	d->sectors = id[100] | (u64)id[101] << 16 | (u64)id[102] << 32 | (u64)id[103] << 48;
	for ( i = 0; i < 20; i++ ) {
		d->model[2 * i] = bounce[54 + 2 * i + 1];
		d->model[2 * i + 1] = bounce[54 + 2 * i];
	}
	for ( i = 40; i && d->model[i - 1] == ' '; i-- );
	d->model[i] = 0;
	return 0;
}

static void add_ahci( u32 abar )
{
	volatile u32 *hba;
	u32 pi;
	int i;
	if ( alloc_dma() )
		return;
	hba = (volatile u32 *)vxd_map_phys( abar, 0x1100 );
	if ( (u32)hba == 0xFFFFFFFFUL || !hba )
		return;
	hba[1] |= 0x80000000UL;      /* GHC.AE */
	pi = hba[3];
	for ( i = 0; i < 32 && ndisks < MAXDISK; i++ ) {
		volatile u32 *p = hba + ( 0x100 + i * 0x80 ) / 4;
		struct disk *d = &disks[ndisks];
		if ( !( pi & ( 1UL << i ) ) || ( p[PxSSTS] & 0x0F ) != 3 || p[PxSIG] != 0x00000101UL )
			continue;
		mem_set( d, 0, sizeof(*d) );
		d->type = T_AHCI;
		d->port = p;
		if ( ahci_identify( d ) == 0 ) {
			lputs( "AHCIVXD: AHCI " ); lhex( abar, 8 ); lputs( " port " ); ldec( i ); lputc( ' ' );
			lputs( d->model ); lputs( ", " ); ldec( (u32)( d->sectors >> 11 ) ); lputs( " MB\n" );
			ndisks++;
		}
	}
}

/* the page for the AHCI structures / IDE PRD table and the bounce buffer */
static int alloc_dma( void )
{
	int i;
	if ( amem )
		return 0;
	if ( !( amem = vxd_page_alloc( 1 ) ) || !( bounce = vxd_page_alloc( BOUNCE_PAGES ) ) ) {
		amem = 0;
		return -1;
	}
	amem_phys = vxd_lin_to_phys( amem );
	for ( i = 0; i < BOUNCE_PAGES; i++ )
		bounce_phys[i] = vxd_lin_to_phys( bounce + i * 4096 );
	return 0;
}

/* IDE bus master DMA: n sectors through the bounce buffer */
static int ide_dma( struct disk *d, u64 lba, u32 n, u8 *buf, int op )
{
	static const u8 cmd28[2] = { 0xC8, 0xCA }, cmd48[2] = { 0x25, 0x35 };
	u32 *prd = (u32 *)( amem + 0x800 ), bytes = n * 512, t0;
	int ext = d->lba48 && ( lba + n > 0x0FFFFFFFULL || n > 256 );
	int i, rc = E_OK, st;
	u8 bst;
	for ( i = 0; bytes; i++ ) {
		u32 b = bytes > 4096 ? 4096 : bytes;
		bytes -= b;
		prd[2 * i] = bounce_phys[i];
		prd[2 * i + 1] = b | ( bytes ? 0 : 0x80000000UL );
	}
	if ( op == BDC_WRITE )
		mem_cpy( bounce, buf, n * 512 );
	if ( ide_select( d, ext ? 0 : (u8)( ( lba >> 24 ) & 0x0F ) ) )
		return E_TIMEOUT;
	outb( d->bm, 0 );                    /* stop */
	outb( d->bm + 2, 0x06 );             /* clear interrupt and error */
	outd( d->bm + 4, amem_phys + 0x800 );
	outb( d->bm, op == BDC_READ ? 0x08 : 0x00 );   /* direction: 8 = to memory */
	outb( d->ctl, 0x02 );                /* nIEN: polled */
	if ( ext ) {
		outb( d->base + IDE_COUNT, (u8)( n >> 8 ) );
		outb( d->base + IDE_LBA0, (u8)( lba >> 24 ) );
		outb( d->base + IDE_LBA1, (u8)( lba >> 32 ) );
		outb( d->base + IDE_LBA2, (u8)( lba >> 40 ) );
	}
	outb( d->base + IDE_COUNT, (u8)n );
	outb( d->base + IDE_LBA0, (u8)lba );
	outb( d->base + IDE_LBA1, (u8)( lba >> 8 ) );
	outb( d->base + IDE_LBA2, (u8)( lba >> 16 ) );
	outb( d->base + IDE_CMD, ext ? cmd48[op] : cmd28[op] );
	outb( d->bm, ( op == BDC_READ ? 0x08 : 0x00 ) | 0x01 );   /* start */
	t0 = vxd_time();
	for ( ;; ) {                         /* until the device and the DMA are done */
		bst = inb( d->bm + 2 );
		st = inb( d->ctl );
		if ( !( st & ST_BSY ) && ( !( bst & 1 ) || ( st & ( ST_ERR | ST_DF ) ) ) )
			break;
		if ( vxd_time() - t0 > 30000 ) {
			rc = E_TIMEOUT;
			break;
		}
	}
	outb( d->bm, 0 );                    /* stop */
	if ( rc == E_OK && ( ( st & ( ST_ERR | ST_DF ) ) || ( bst & 2 ) ) )
		rc = E_DEVICE;
	outb( d->bm + 2, 0x06 );
	inb( d->base + IDE_STATUS );
	outb( d->ctl, 0x00 );
	if ( rc == E_OK ) {
		n_dma++;
		kb_dma += n / 2;
		if ( op == BDC_READ )
			mem_cpy( buf, bounce, n * 512 );
	}
	return rc;
}

/* --- disk access ------------------------------------------------------------ */
static int disk_io( struct disk *d, u64 lba, u32 count, u8 *buf, int op )
{
	if ( lba + count > d->sectors )
		return E_RANGE;
	while ( count ) {
		u32 n = count > 128 ? 128 : count;
		int rc = d->type == T_AHCI ? ahci_io( d, lba, n, buf, op ) :
		         d->dma && op != BDC_VERIFY ? ide_dma( d, lba, n, buf, op ) : ide_command( d, lba, n, buf, op );
		if ( rc )
			return rc;
		lba += n;
		count -= n;
		if ( op != BDC_VERIFY )
			buf += n * 512;
	}
	return E_OK;
}

/* --- PCI -------------------------------------------------------------------- */
static u32 pci_read( u32 bdf, int reg )
{
	outd( 0xCF8, 0x80000000UL | bdf << 8 | ( reg & 0xFC ) );
	return ind( 0xCFC );
}

static void pci_write( u32 bdf, int reg, u32 v )
{
	outd( 0xCF8, 0x80000000UL | bdf << 8 | ( reg & 0xFC ) );
	outd( 0xCFC, v );
}

static int alloc_dma( void );

static void add_ide( u16 base, u16 ctl, u16 bm )
{
	int s;
	for ( s = 0; s < 2 && ndisks < MAXDISK; s++ ) {
		struct disk *d = &disks[ndisks];
		mem_set( d, 0, sizeof(*d) );
		d->type = T_IDE;
		d->base = base;
		d->ctl = ctl;
		d->slave = s;
		if ( ide_identify( d ) == 0 ) {
			u16 *id = (u16 *)sector;
			/* bus master DMA if the BIOS set a (U)DMA mode */
			if ( bm && use_dma && ( ( id[53] & 4 && id[88] & 0x7F00 ) || ( id[63] & 0x0700 ) ) && !alloc_dma() ) {
				d->bm = bm;
				d->dma = 1;
			}
			lputs( "AHCIVXD: IDE " ); lhex( base, 4 ); lputs( s ? " slave " : " master " );
			lputs( d->model ); lputs( ", " ); ldec( (u32)( d->sectors >> 11 ) ); lputs( d->dma ? " MB, DMA\n" : " MB, PIO\n" );
			ndisks++;
		}
	}
}

static void find_ide( void )
{
	u32 bdf;
	int legacy = 0;
	for ( bdf = 0; bdf < 256 * 32 * 8; bdf++ ) {
		u32 id = pci_read( bdf, 0 ), cls;
		if ( ( id & 0xFFFF ) == 0xFFFF ) {
			if ( !( bdf & 7 ) )
				bdf += 7;        /* no device: skip its functions */
			continue;
		}
		cls = pci_read( bdf, 8 );
		if ( ( cls >> 8 ) == 0x010601UL ) {   /* AHCI */
			u32 abar = pci_read( bdf, 0x24 ) & 0xFFFFFFF0UL;
			if ( abar )
				add_ahci( abar );
		}
		if ( ( cls >> 16 ) == 0x0101 ) {
			u8 pif = (u8)( cls >> 8 );
			u32 b4 = pci_read( bdf, 0x20 );
			u16 bm = ( pif & 0x80 ) && ( b4 & 1 ) ? (u16)( b4 & 0xFFFC ) : 0;
			if ( bm )            /* bus master enable */
				pci_write( bdf, 0x04, ( pci_read( bdf, 0x04 ) & 0xFFFF ) | 0x04 );
			if ( pif & 0x01 ) {  /* primary channel native */
				u16 b = (u16)( pci_read( bdf, 0x10 ) & 0xFFFC ), c = (u16)( pci_read( bdf, 0x14 ) & 0xFFFC );
				if ( b && c ) add_ide( b, c + 2, bm );
			} else if ( !( legacy & 1 ) ) {
				legacy |= 1;
				add_ide( 0x1F0, 0x3F6, bm );
			}
			if ( pif & 0x04 ) {  /* secondary channel native */
				u16 b = (u16)( pci_read( bdf, 0x18 ) & 0xFFFC ), c = (u16)( pci_read( bdf, 0x1C ) & 0xFFFC );
				if ( b && c ) add_ide( b, c + 2, bm ? bm + 8 : 0 );
			} else if ( !( legacy & 2 ) ) {
				legacy |= 2;
				add_ide( 0x170, 0x376, bm ? bm + 8 : 0 );
			}
		}
		if ( !( bdf & 7 ) && !( pci_read( bdf, 0x0C ) & 0x00800000UL ) )
			bdf += 7;            /* single function device */
	}
	if ( !legacy ) {             /* no PCI IDE found: try the ISA ports */
		add_ide( 0x1F0, 0x3F6, 0 );
		add_ide( 0x170, 0x376, 0 );
	}
}

/* --- BIOS disks -> controller disks ------------------------------------------ */
static u32 crc32( const u8 *p, u32 n )
{
	u32 c = 0xFFFFFFFFUL;
	int k;
	while ( n-- ) {
		c ^= *p++;
		for ( k = 0; k < 8; k++ )
			c = c & 1 ? ( c >> 1 ) ^ 0xEDB88320UL : c >> 1;
	}
	return ~c;
}

/* find BIOS drive dl (first sector's CRC-32 = crc) on the controllers */
static void match_bios( u8 dl, u32 crc )
{
	struct disk *found = 0;
	int i, n = 0;
	for ( i = 0; i < ndisks; i++ ) {
		struct disk *d = &disks[i];
		if ( d->bios )
			continue;
		if ( disk_io( d, 0, 1, sector, BDC_READ ) || crc32( sector, 512 ) != crc )
			continue;
		found = d;
		n++;
	}
	lputs( "AHCIVXD: BIOS drive " ); lhex( dl, 2 );
	if ( n != 1 ) {
		lputs( n ? ": more than one disk matches, left to the BIOS\n" : ": not found, left to the BIOS\n" );
		return;
	}
	found->bios = dl;
	lputs( " = " ); lputs( found->model ); lputc( '\n' );
}

static void register_disk( struct disk *d )
{
	BDD *b = &d->bdd;
	mem_set( b, 0, sizeof(*b) );
	b->major = 3;
	b->minor = 0x0A;
	b->type = BDT_FIXED;
	b->int13 = d->bios;
	b->flags = BDF_INT13 | BDF_WRITEABLE | BDF_SERIAL;
	b->name = names[d->bios & 3];
	b->max_sector = d->sectors - 1;
	b->sector_size = 512;
	b->heads = d->heads;
	b->cylinders = d->cyl;
	b->spt = d->spt;
	b->sync_proc = sync_cmd_proc;
	b->cmd_proc = command_proc;
	b->hwint_proc = hw_int_proc;
	b->disk = d;
	if ( vxd_register( b ) ) {
		lputs( "AHCIVXD: BlockDev did not register drive " ); lhex( d->bios, 2 ); lputc( '\n' );
		d->bios = 0;
	}
}

/* --- BIOS queries (system VM) --------------------------------------------------- */
static u32 v86buf;               /* temporary V86 buffer: linear address < 1 MB */
#define VSEG ( (u16)( v86buf >> 4 ) )
#define VOFS( o ) ( (u16)( ( v86buf & 15 ) + ( o ) ) )

static int bios13( struct v86regs *r )
{
	vxd_exec_int( 0x13, r );
	return r->flags & 1;
}

static void bios_drive( u8 dl, struct rmi_drive *r )
{
	struct v86regs g;
	mem_set( r, 0, sizeof(*r) );
	r->bios = dl;
	mem_set( &g, 0, sizeof(g) );
	g.eax = 0x0800;
	g.edx = dl;
	if ( bios13( &g ) )
		return;
	r->spt = (u16)( g.ecx & 0x3F );
	r->cyl = (u16)( ( ( ( g.ecx >> 8 ) & 0xFF ) | ( ( g.ecx & 0xC0 ) << 2 ) ) + 1 );
	r->heads = (u16)( ( ( g.edx >> 8 ) & 0xFF ) + 1 );
	mem_set( &g, 0, sizeof(g) );
	g.eax = 0x4100;
	g.ebx = 0x55AA;
	g.edx = dl;
	if ( !bios13( &g ) && ( g.ebx & 0xFFFF ) == 0xAA55 && ( g.ecx & 1 ) ) {
		u8 *p = (u8 *)( v86buf + 512 );
		mem_set( p, 0, 76 );
		*(u16 *)p = 74;
		mem_set( &g, 0, sizeof(g) );
		g.eax = 0x4800;
		g.edx = dl;
		g.ds = VSEG;
		g.esi = VOFS( 512 );
		if ( !bios13( &g ) ) {
			mem_cpy( &r->sectors, p + 0x10, 8 );
			r->edd = 1;
		}
	}
	r->valid = 1;
}

/* the logical geometry of drive 80h/81h from the BIOS fixed disk parameter
 * table (INT 41h/46h vector; with translation, signature A0h, the logical
 * values are at the same offsets); others until Device_Init: 255/63 */
static void fdpt_geometry( struct disk *d )
{
	u32 vec = d->bios == 0x80 ? *(u32 *)( 0x41 * 4 ) : d->bios == 0x81 ? *(u32 *)( 0x46 * 4 ) : 0;
	d->heads = 255;
	d->spt = 63;
	d->cyl = 1024;
	if ( vec ) {
		u8 *t = (u8 *)( ( vec >> 16 ) * 16 + ( vec & 0xFFFF ) );
		if ( t[2] && t[0x0E] && ( t[0x0E] & 0x3F ) == t[0x0E] ) {
			d->cyl = *(u16 *)t;
			d->heads = t[2];
			d->spt = t[0x0E];
		}
	}
	lputs( "AHCIVXD: drive " ); lhex( d->bios, 2 ); lputs( " FDPT CHS " ); ldec( d->cyl ); lputc( '/' );
	ldec( d->heads ); lputc( '/' ); ldec( d->spt ); lputc( '\n' );
}

/* --- system control ------------------------------------------------------------ */
int ahci_sys_critical_init( u32 ref )
{
	int i;
	logport = (u16)vxd_profile_int( "LogPort", 0 );
	pio32 = vxd_profile_int( "PIO32", 1 );
	use_dma = vxd_profile_int( "DMA", 1 );
	do_int13 = vxd_profile_int( "Int13", 1 );
	logall = vxd_profile_int( "LogAll", 0 );
	lputs( "AHCIVXD 0.2, reference data " ); lhex( ref, 8 ); lputc( '\n' );
	if ( ( ref >> 24 ) != 0xA5 ) {
		lputs( "AHCIVXD: no data from the real mode part\n" );
		return 0;
	}
	if ( ( ref & 0x100 ) && !vxd_profile_int( "IgnoreChain", 0 ) ) {
		lputs( "AHCIVXD: DOS's Int 13h path is hooked by a program, not loaded\n" );
		return 0;
	}
	find_ide();
	for ( i = 0; i < 4; i++ )
		if ( ref & ( 1UL << i ) )
			match_bios( (u8)( 0x80 + i ), ( (u32 *)0x4F0 )[i] );
	for ( i = 0; i < 4; i++ )    /* the Intra-Application Communication Area */
		( (u32 *)0x4F0 )[i] = 0;
	for ( i = 0; i < ndisks; i++ )
		if ( disks[i].bios ) {
			fdpt_geometry( &disks[i] );
			register_disk( &disks[i] );
		}
	return 0;
}

static void hook_dos13( void );
static void hook_biosfix( void );

/* the BIOS geometry for CHS requests, the size from EDD as a check */
int ahci_device_init( void )
{
	struct rmi_drive r;
	int i, any = 0;
	hook_biosfix();              /* also for disks left to the BIOS */
	for ( i = 0; i < ndisks; i++ )
		any |= disks[i].bios != 0;
	if ( !any )
		return 0;
	if ( !( v86buf = vxd_temp_v86( 1024 ) ) ) {
		lputs( "AHCIVXD: no V86 buffer\n" );
		return 0;
	}
	for ( i = 0; i < ndisks; i++ ) {
		struct disk *d = &disks[i];
		if ( !d->bios )
			continue;
		bios_drive( d->bios, &r );
		if ( r.heads && r.spt ) {
			d->heads = d->bdd.heads = r.heads;
			d->spt = d->bdd.spt = r.spt;
			d->cyl = d->bdd.cylinders = r.cyl;
		}
		lputs( "AHCIVXD: drive " ); lhex( d->bios, 2 ); lputs( " CHS " ); ldec( d->cyl ); lputc( '/' );
		ldec( d->heads ); lputc( '/' ); ldec( d->spt );
		if ( r.edd && r.sectors != d->sectors ) {
			lputs( ", EDD size " ); ldec( (u32)r.sectors ); lputs( " differs from " ); ldec( (u32)d->sectors );
		}
		lputc( '\n' );
	}
	vxd_free_temp_v86();
	if ( do_int13 ) {
		if ( vxd_hook_int13() )
			lputs( "AHCIVXD: can't hook INT 13h\n" );
		hook_dos13();
	}
	return 0;
}

static void log_stats( void );

int ahci_system_exit( void )
{
	log_stats();
	return 0;
}

static void log_stats( void )
{
	lputs( "AHCIVXD: BlockDev read/write/verify " ); ldec( n_bd[0] ); lputc( '/' ); ldec( n_bd[1] ); lputc( '/' ); ldec( n_bd[2] );
	lputs( " (" ); ldec( s_bd ); lputs( " sectors), INT 13h " ); ldec( n_i13[0] ); lputc( '/' ); ldec( n_i13[1] ); lputc( '/' ); ldec( n_i13[2] );
	lputs( " (" ); ldec( s_i13 ); lputs( " sectors)" );
	if ( n_fix ) {
		lputs( ", BIOS VDS fixes " ); ldec( n_fix );
	}
	if ( n_dma ) {
		lputs( ", DMA " ); ldec( n_dma ); lputs( " commands, " ); ldec( kb_dma ); lputs( " KB" );
	}
	lputc( '\n' );
}

/* --- BlockDev commands ----------------------------------------------------------- */
static u16 bd_status( int rc )
{
	return rc == E_OK ? BDS_OK : rc == E_RANGE ? BDS_BAD_SECTOR : rc == E_DEVICE ? BDS_MEDIA : BDS_DEVICE;
}

void ahci_command( BDD *b, BCB *c )
{
	struct disk *d = b->disk;
	int rc;
	if ( c->command <= BDC_VERIFY ) {
		n_bd[c->command]++;
		s_bd += c->count;
		if ( !( ( n_bd[0] + n_bd[1] + n_bd[2] ) % 200 ) )
			log_stats();
	}
	if ( c->command > BDC_VERIFY )
		c->status = BDS_BAD_CMD;
	else if ( c->flags & BDCF_SG ) {
		BSG *sg = (BSG *)c->buffer;
		u64 lba = c->sector;
		rc = E_OK;
		for ( ; sg->count && rc == E_OK; sg++ ) {
			rc = disk_io( d, lba, sg->count, (u8 *)sg->buffer, c->command );
			lba += sg->count;
		}
		c->status = bd_status( rc );
	} else
		c->status = bd_status( disk_io( d, c->sector, c->count, (u8 *)c->buffer, c->command ) );
	if ( logport && ( c->status || n_bd[0] + n_bd[1] + n_bd[2] <= 8 || logall ) ) {
		lputs( "AHCIVXD: cmd " ); ldec( c->command ); lputs( " sector " ); lhex( (u32)c->sector, 8 );
		lputs( " count " ); ldec( c->count ); lputs( " status " ); lhex( c->status, 2 ); lputc( '\n' );
	}
	vxd_complete( b, c );
}

/* --- INT 13h of the VMs -------------------------------------------------------------- */
#define C_EBX  0x10
#define C_EDX  0x14
#define C_ECX  0x18
#define C_EAX  0x1C
#define C_EFL  0x2C
#define C_ES   0x38
#define C_DS   0x3C
#define C_ESI  0x04
#define C_EIP  0x24
#define C_CS   0x28
#define C_ESP  0x30
#define C_SS   0x34
#define CREG( p, o ) ( *(u32 *)( (u8 *)( p ) + ( o ) ) )
#define CREGW( p, o ) ( *(u16 *)( (u8 *)( p ) + ( o ) ) )

static struct disk *bios_disk( u8 dl )
{
	int i;
	for ( i = 0; i < ndisks; i++ )
		if ( disks[i].bios == dl && dl )
			return &disks[i];
	return 0;
}

static u8 int13_status( int rc )
{
	return rc == E_OK ? 0x00 : rc == E_RANGE ? 0x04 : rc == E_DEVICE ? 0x10 : 0x80;
}

/* returns 0 when handled */
int ahci_v86_int13( u32 vm, void *cl )
{
	u8 ah = (u8)( CREG( cl, C_EAX ) >> 8 ), dl = (u8)CREG( cl, C_EDX );
	struct disk *d = bios_disk( dl );
	u32 base, fl;
	int rc = E_OK;
	if ( !d )
		return 1;
	base = vxd_high_linear( vm );
	if ( logport && ( logall || n_i13[0] + n_i13[1] + n_i13[2] < 8 ) ) {
		lputs( "AHCIVXD: INT 13h AX=" ); lhex( CREG( cl, C_EAX ), 4 ); lputc( '\n' );
	}
	switch ( ah ) {
	case 0x00:                   /* reset: nothing to do */
	case 0x0D:
	case 0x47:                   /* extended seek */
		break;
	case 0x02:                   /* CHS read / write / verify */
	case 0x03:
	case 0x04: {
		u32 cx = CREG( cl, C_ECX ), dh = ( CREG( cl, C_EDX ) >> 8 ) & 0xFF;
		u32 cyl = ( ( cx >> 8 ) & 0xFF ) | ( ( cx & 0xC0 ) << 2 ), s = cx & 0x3F;
		u32 n = CREG( cl, C_EAX ) & 0xFF;
		u8 *buf = (u8 *)( base + CREGW( cl, C_ES ) * 16 + CREGW( cl, C_EBX ) );
		if ( !s || s > d->spt || dh >= d->heads || !n ) {
			rc = E_RANGE;
			break;
		}
		n_i13[ah - 0x02]++;
		s_i13 += n;
		if ( !( ( n_i13[0] + n_i13[1] + n_i13[2] ) % 1000 ) )
			log_stats();
		fl = irqsave();
		rc = disk_io( d, ( cyl * d->heads + dh ) * d->spt + s - 1, n, buf, ah - 0x02 );
		irqrestore( fl );
		if ( rc == E_OK )
			CREG( cl, C_EAX ) = n;     /* AH = 0, AL = sectors */
		break;
	}
	case 0x41:                   /* extensions present */
		if ( (u16)CREG( cl, C_EBX ) != 0x55AA )
			return 1;
		CREG( cl, C_EBX ) = ( CREG( cl, C_EBX ) & 0xFFFF0000UL ) | 0xAA55;
		CREG( cl, C_ECX ) = ( CREG( cl, C_ECX ) & 0xFFFF0000UL ) | 0x0001;
		CREG( cl, C_EAX ) = ( CREG( cl, C_EAX ) & 0xFFFF00FFUL ) | 0x2100;
		CREG( cl, C_EFL ) &= ~1UL;
		return 0;
	case 0x42:                   /* extended read / write / verify */
	case 0x43:
	case 0x44: {
		u8 *dap = (u8 *)( base + CREGW( cl, C_DS ) * 16 + CREGW( cl, C_ESI ) );
		u16 n = *(u16 *)( dap + 2 );
		u32 bp = *(u32 *)( dap + 4 );
		u64 lba;
		u8 *buf = (u8 *)( base + ( bp >> 16 ) * 16 + ( bp & 0xFFFF ) );
		mem_cpy( &lba, dap + 8, 8 );
		if ( bp == 0xFFFFFFFFUL ) {      /* 64-bit flat buffer address */
			rc = E_RANGE;
			break;
		}
		n_i13[ah - 0x42]++;
		s_i13 += n;
		if ( !( ( n_i13[0] + n_i13[1] + n_i13[2] ) % 1000 ) )
			log_stats();
		fl = irqsave();
		rc = disk_io( d, lba, n, buf, ah == 0x42 ? BDC_READ : ah == 0x43 ? BDC_WRITE : BDC_VERIFY );
		irqrestore( fl );
		if ( rc != E_OK )
			*(u16 *)( dap + 2 ) = 0;
		break;
	}
	case 0x48: {                 /* extended drive parameters */
		u8 *bp = (u8 *)( base + CREGW( cl, C_DS ) * 16 + CREGW( cl, C_ESI ) );
		u16 size = *(u16 *)bp;
		if ( size < 26 ) {
			rc = E_RANGE;
			break;
		}
		*(u16 *)( bp + 2 ) = 0x0002;     /* CHS information valid */
		*(u32 *)( bp + 4 ) = d->cyl;
		*(u32 *)( bp + 8 ) = d->heads;
		*(u32 *)( bp + 12 ) = d->spt;
		mem_cpy( bp + 16, &d->sectors, 8 );
		*(u16 *)( bp + 24 ) = 512;
		if ( size >= 30 ) {
			*(u32 *)( bp + 26 ) = 0xFFFFFFFFUL;   /* no configuration parameters */
			*(u16 *)bp = 30;
		} else
			*(u16 *)bp = 26;
		break;
	}
	default:
		return 1;                /* 08h, 15h, ...: Windows' Int13 device or the BIOS */
	}
	CREG( cl, C_EAX ) = ( CREG( cl, C_EAX ) & 0xFFFF00FFUL ) | (u32)int13_status( rc ) << 8;
	if ( rc == E_OK )
		CREG( cl, C_EFL ) &= ~1UL;
	else
		CREG( cl, C_EFL ) |= 1;
	return 0;
}

/* --- MS-DOS's direct calls of the BIOS INT 13h code ------------------------------ */
static u32 old_dos13;            /* segment:offset DOS called before */

/* DOS does PUSHF + CALL FAR [pointer]: our disks are handled and the call
 * returns like an IRET (with our carry flag), others continue at the old
 * code with the same stack */
void ahci_dos13( u32 vm, void *cl )
{
	if ( logall ) {
		lputs( "AHCIVXD: DOS call from SS:SP " ); lhex( CREGW( cl, C_SS ), 4 ); lputc( ':' ); lhex( CREGW( cl, C_ESP ), 4 );
		lputc( '\n' );
	}
	if ( ahci_v86_int13( vm, cl ) == 0 ) {
		u32 base = vxd_high_linear( vm );
		u16 *sp = (u16 *)( base + CREGW( cl, C_SS ) * 16 + CREGW( cl, C_ESP ) );
		if ( logall ) {
			lputs( "AHCIVXD: return to " ); lhex( sp[1], 4 ); lputc( ':' ); lhex( sp[0], 4 ); lputs( " flags " ); lhex( sp[2], 4 );
			lputs( " AX=" ); lhex( CREG( cl, C_EAX ), 4 ); lputc( '\n' );
		}
		CREG( cl, C_EIP ) = sp[0];
		CREGW( cl, C_CS ) = sp[1];
		CREG( cl, C_EFL ) = ( CREG( cl, C_EFL ) & 0xFFFF0001UL ) | ( sp[2] & 0xFFFEU );
		CREGW( cl, C_ESP ) = (u16)( CREGW( cl, C_ESP ) + 6 );
	} else {
		if ( logall ) lputs( "AHCIVXD: -> old\n" );
		CREG( cl, C_EIP ) = old_dos13 & 0xFFFF;
		CREGW( cl, C_CS ) = (u16)( old_dos13 >> 16 );
	}
}

/* point DOS's Int 13h pointer at our V86 callback (Device_Init) */
static void hook_dos13( void )
{
	struct v86regs g, h;
	u32 cb = vxd_v86_callback();
	if ( !cb ) {
		lputs( "AHCIVXD: no V86 callback\n" );
		return;
	}
	mem_set( &g, 0, sizeof(g) );
	g.eax = 0x1300;              /* DOS's handler = callback; returns the old ones */
	g.ds = g.es = (u16)( cb >> 16 );
	g.edx = g.ebx = cb & 0xFFFF;
	vxd_exec_int( 0x2F, &g );
	old_dos13 = (u32)g.ds << 16 | ( g.edx & 0xFFFF );
	h = g;                       /* the ROM handler as it was */
	h.eax = 0x1300;
	h.ds = (u16)( cb >> 16 );
	h.edx = cb & 0xFFFF;
	vxd_exec_int( 0x2F, &h );
	lputs( "AHCIVXD: DOS's Int 13h " ); lhex( old_dos13, 8 ); lputs( " -> " ); lhex( cb, 8 ); lputc( '\n' );
}

/* --- BIOS VDS fix (as ahcifix.386 by PluMGMK, written anew) -------------------------
 * The INT 13h code of Intel AHCI firmware unlocks VDS regions with the
 * descriptor's segment in DS instead of ES, and puts the descriptor at the
 * start of the EBDA.  For disks still driven by the BIOS: a lock of a
 * region at the start of the EBDA saves its first 6Ch bytes; an unlock
 * whose ES:DI descriptor has physical address 0 while DS:DI has a valid one
 * gets ES and DS swapped (back after the call, V86 callback), and the
 * saved EBDA bytes are restored. */
#define EBDA_SAVE 0x6C
static u32 unswap_cb, unswap_ret;
static u8 ebda_save[EBDA_SAVE];
static int ebda_saved, unswap_restore;

void ahci_v86_int4b( u32 vm, void *cl )
{
	u32 ax = CREG( cl, C_EAX ) & 0xFFFF, base = vxd_high_linear( vm );
	u16 ebda = *(u16 *)( base + 0x40E ), di = (u16)CREG( cl, 0x00 );
	u8 *dd = (u8 *)( base + CREGW( cl, C_ES ) * 16 + di );
	if ( ( ax >> 8 ) != 0x81 || !ebda )
		return;
	if ( ax == 0x8103 ) {                /* lock: descriptor in the EBDA? */
		if ( *(u16 *)( dd + 8 ) == ebda && *(u32 *)( dd + 4 ) < EBDA_SAVE ) {
			mem_cpy( ebda_save, (u8 *)( base + ebda * 16 ), EBDA_SAVE );
			ebda_saved = 1;
		}
		return;
	}
	if ( ax != 0x8104 && ax != 0x8106 )
		return;
	if ( *(u32 *)( dd + 12 ) == 0 && unswap_cb && !unswap_ret ) {
		u8 *alt = (u8 *)( base + CREGW( cl, C_DS ) * 16 + di );
		if ( *(u32 *)( alt + 12 ) != 0 ) {  /* the firmware's wrong register */
			u16 t = CREGW( cl, C_ES );
			CREGW( cl, C_ES ) = CREGW( cl, C_DS );
			CREGW( cl, C_DS ) = t;
			unswap_ret = (u32)CREGW( cl, C_CS ) << 16 | ( CREG( cl, C_EIP ) & 0xFFFF );
			CREG( cl, C_EIP ) = unswap_cb & 0xFFFF;
			CREGW( cl, C_CS ) = (u16)( unswap_cb >> 16 );
			dd = alt;
			n_fix++;
		}
	}
	if ( ebda_saved && *(u16 *)( dd + 8 ) == ebda && *(u32 *)( dd + 4 ) < EBDA_SAVE ) {
		if ( unswap_ret )
			unswap_restore = 1;          /* after the unlock */
		else {
			mem_cpy( (u8 *)( base + ebda * 16 ), ebda_save, EBDA_SAVE );
			ebda_saved = 0;
		}
	}
}

void ahci_unswap( u32 vm, void *cl )
{
	u16 t = CREGW( cl, C_ES );
	CREGW( cl, C_ES ) = CREGW( cl, C_DS );
	CREGW( cl, C_DS ) = t;
	CREG( cl, C_EIP ) = unswap_ret & 0xFFFF;
	CREGW( cl, C_CS ) = (u16)( unswap_ret >> 16 );
	unswap_ret = 0;
	if ( unswap_restore ) {
		u32 base = vxd_high_linear( vm );
		u16 ebda = *(u16 *)( base + 0x40E );
		mem_cpy( (u8 *)( base + ebda * 16 ), ebda_save, EBDA_SAVE );
		ebda_saved = unswap_restore = 0;
	}
}

static void hook_biosfix( void )
{
	if ( !vxd_profile_int( "BiosFix", 1 ) )
		return;
	unswap_cb = vxd_unswap_callback();
	if ( !unswap_cb || vxd_hook_int4b() )
		lputs( "AHCIVXD: BIOS VDS fix not installed\n" );
}
