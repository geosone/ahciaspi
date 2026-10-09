; ahci.inc - AHCI, ATA and SCSI constants

; --- PCI ---------------------------------------------------------------------
PCI_CLASS_AHCI          equ     010601h ; mass storage / SATA / AHCI 1.0
PCI_CMD                 equ     04h
PCI_CMD_IO              equ     0001h
PCI_CMD_MEM             equ     0002h
PCI_CMD_MASTER          equ     0004h
PCI_STATUS_CAPLIST      equ     0010h   ; bit in the status word (reg 06h)
PCI_CAP_PTR             equ     34h
PCI_BAR0                equ     10h
PCI_ABAR                equ     24h     ; BAR5
PCI_CAP_SATA            equ     12h     ; SATA capability (index/data pair)
SATACR1_BARLOC          equ     0Fh
SATACR1_BARLOC_CFG      equ     0Fh     ; index/data pair in config space

; --- HBA (generic host control) registers ------------------------------------
HBA_CAP                 equ     00h
HBA_GHC                 equ     04h
HBA_IS                  equ     08h
HBA_PI                  equ     0Ch
HBA_VS                  equ     10h

CAP_S64A                equ     80000000h
CAP_SSS                 equ     08000000h
CAP_SCLO                equ     01000000h
GHC_AE                  equ     80000000h

; --- port registers (offset from port base) ----------------------------------
PORT_BASE               equ     100h
PORT_SIZE               equ     80h

PxCLB                   equ     00h
PxCLBU                  equ     04h
PxFB                    equ     08h
PxFBU                   equ     0Ch
PxIS                    equ     10h
PxIE                    equ     14h
PxCMD                   equ     18h
PxTFD                   equ     20h
PxSIG                   equ     24h
PxSSTS                  equ     28h
PxSCTL                  equ     2Ch
PxSERR                  equ     30h
PxSACT                  equ     34h
PxCI                    equ     38h

PxCMD_ST                equ     0001h
PxCMD_SUD               equ     0002h
PxCMD_POD               equ     0004h
PxCMD_CLO               equ     0008h
PxCMD_FRE               equ     0010h
PxCMD_FR                equ     4000h
PxCMD_CR                equ     8000h

PxIS_TFES               equ     40000000h
PxIS_OFS                equ     01000000h ; overflow: device sent too much
PxIS_FATAL              equ     78000000h ; TFES | HBFS | HBDS | IFS

TFD_ERR                 equ     01h
TFD_DRQ                 equ     08h
TFD_BSY                 equ     80h

SSTS_DET                equ     0Fh
SSTS_DET_PRESENT        equ     03h

SIG_ATA                 equ     00000101h
SIG_ATAPI               equ     0EB140101h

; --- command header (command list entry, 32 bytes) ---------------------------
CH_CFL5                 equ     0005h   ; command FIS length: 5 dwords
CH_ATAPI                equ     0020h
CH_WRITE                equ     0040h

; --- command table -----------------------------------------------------------
CT_CFIS                 equ     00h
CT_ACMD                 equ     40h
CT_PRDT                 equ     80h
PRD_SIZE                equ     10h
PRD_MAX_BYTES           equ     400000h ; 4 MB per PRD entry

FIS_TYPE_H2D            equ     27h
FIS_H2D_CMD             equ     80h     ; "C" bit: command register update

; --- ATA commands / features -------------------------------------------------
ATA_PACKET              equ     0A0h
ATA_IDENTIFY_PACKET     equ     0A1h
ATA_FEAT_DMA            equ     01h
ATA_FEAT_DMADIR         equ     04h     ; data to host (only if required)

; IDENTIFY PACKET DEVICE words
ID_W0_PKT_MASK          equ     0C000h
ID_W0_ATAPI             equ     08000h
ID_W0_CDB16             equ     0001h
ID_W49_DMA              equ     0100h
ID_W62_DMADIR           equ     8000h

; --- SCSI opcodes ------------------------------------------------------------
SCSI_TEST_UNIT_READY    equ     00h
SCSI_REZERO_UNIT        equ     01h
SCSI_REQUEST_SENSE      equ     03h
SCSI_READ6              equ     08h
SCSI_WRITE6             equ     0Ah
SCSI_SEEK6              equ     0Bh
SCSI_INQUIRY            equ     12h
SCSI_MODE_SELECT6       equ     15h
SCSI_MODE_SENSE6        equ     1Ah
SCSI_READ10             equ     28h
SCSI_WRITE10            equ     2Ah
SCSI_SEEK10             equ     2Bh
SCSI_MODE_SELECT10      equ     55h
SCSI_MODE_SENSE10       equ     5Ah

; sense keys
SENSE_ILLEGAL_REQUEST   equ     05h
