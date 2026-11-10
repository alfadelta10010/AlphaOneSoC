# ffconf.h of FatFs R0.16 as this port wants it: long file names (static buffer), code
# page 437, relative paths, labels, f_printf/f_gets, no RTC (every file is dated 2026-11-01).
s/^#define FF_USE_LFN[[:space:]].*/#define FF_USE_LFN	1/
s/^#define FF_CODE_PAGE[[:space:]].*/#define FF_CODE_PAGE	437/
s/^#define FF_FS_RPATH[[:space:]].*/#define FF_FS_RPATH	1/
s/^#define FF_USE_LABEL[[:space:]].*/#define FF_USE_LABEL	1/
s/^#define FF_USE_STRFUNC[[:space:]].*/#define FF_USE_STRFUNC	1/
s/^#define FF_FS_NORTC[[:space:]].*/#define FF_FS_NORTC	1/
s/^#define FF_NORTC_YEAR[[:space:]].*/#define FF_NORTC_YEAR	2026/
s/^#define FF_NORTC_MON[[:space:]].*/#define FF_NORTC_MON	11/
