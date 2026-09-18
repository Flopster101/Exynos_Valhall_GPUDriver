/* Gralloc private_handle_t field offsets (bytes).
 *
 * Old Exynos handles: version(+0) 0xc, magic(+0x20) 0x3141592,
 * numFds(+4)+numInts(+8) 0x55. Plane entries at +0x58, 0x28 stride each.
 * Shared-metadata region offsets are from the +0x138 mapping. */

#pragma once
#include <stdint.h>

#define PH_OFF_MAGIC        0x20
#define PH_MAGIC            0x3141592
#define PH_FDINT_SUM        0x55

#define PH_WIDTH            0x2c
#define PH_HEIGHT           0x30
#define PH_REQ_FORMAT       0x34
#define PH_USAGE_LO         0x38
#define PH_USAGE_HI         0x40
#define PH_ION_FD_INDEX     0x28 /* u32 in {1..4} selects data[idx] (NOT +0x40) */
#define PH_INTFMT           0x50 /* u64 internal format id */
#define PH_NUMPLANES_AUX1   0x98
#define PH_NUMPLANES_AUX2   0xa8
#define PH_LAYER_COUNT      0xd0
#define PH_BUFFER_ID        0xd8
#define PH_PLANE_ARR        0x58
#define PH_ALLOC_ARR        0x120
#define PH_MAPPED_ADDR      0x138
#define PH_MAPPED_SIZE      0x148
#define PH_RESERVED_FLAG    0x150
#define PH_LOCK_A           0xe0
#define PH_LOCK_B           0xe4
#define PH_LOCK_COUNT       0xf4

/* Per-plane entry at PH_PLANE_ARR + i*0x28. */
#define PL_OFF_BYTES        0x00 /* u64 byte offset */
#define PL_FD_INDEX         0x08 /* fd index for plane */
#define PL_STRIDE_BYTES     0x18 /* u32 byte stride */
#define PL_WIDTH            0x1c /* u32 width samples */
#define PL_HEIGHT           0x20 /* u32 height samples */

#define SHM_DATASPACE_FLAG_EXYNOS2100 0x8080
#define SHM_DATASPACE_VAL_EXYNOS2100  0x8084
#define SHM_DATASPACE_FLAG_EXYNOS1280 0x2460
#define SHM_DATASPACE_VAL_EXYNOS1280  0x2464
