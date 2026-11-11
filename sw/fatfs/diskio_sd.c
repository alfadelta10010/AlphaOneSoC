/* FatFs's disk layer (diskio.h) on the SD card driver in common/sd.c. One drive,
 * 512-byte sectors, blocking, one sector per command (CMD17/CMD24). */
#include "ff.h"
#include "diskio.h"
#include "soc.h"

static int ready;

DSTATUS disk_status(BYTE pdrv)
{
    return (pdrv == 0 && ready) ? 0 : STA_NOINIT;
}

DSTATUS disk_initialize(BYTE pdrv)
{
    if (pdrv != 0)
        return STA_NOINIT;
    if (!ready && sd_init() == 0)
        ready = 1;
    return ready ? 0 : STA_NOINIT;
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count)
{
    if (pdrv != 0 || !ready)
        return RES_NOTRDY;
    for (UINT i = 0; i < count; i++)
        if (sd_read(sector + i, buff + 512 * i)) {
            ready = 0;                   /* the next disk_initialize starts the card again */
            return RES_ERROR;
        }
    return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count)
{
    if (pdrv != 0 || !ready)
        return RES_NOTRDY;
    for (UINT i = 0; i < count; i++)
        if (sd_write(sector + i, buff + 512 * i)) {
            ready = 0;
            return RES_ERROR;
        }
    return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff)
{
    (void)buff;
    if (pdrv != 0 || !ready)
        return RES_NOTRDY;
    switch (cmd) {
    case CTRL_SYNC:                      /* every write finishes before sd_write returns */
        return RES_OK;
    case GET_BLOCK_SIZE:
        *(DWORD *)buff = 1;
        return RES_OK;
    default:
        return RES_PARERR;
    }
}
