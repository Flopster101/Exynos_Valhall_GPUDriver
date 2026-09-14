/* SPDX-License-Identifier: MIT */
/* mapper.mali.so: AIMapper v5 shim over legacy gralloc handles
 * (version 0xc, magic 0x3141592 @+0x20, numFds+numInts 0x55). */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <android/log.h>

#include <map>
#include <string>
#include <vector>

#include "gralloc_layout.h"

#define LOG_TAG "mali-shim"
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define ALOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ---------------------------------------------------------------------------
// native_handle_t is libcutils-only; declared here.
// ---------------------------------------------------------------------------
struct native_handle_t {
    int version;
    int numFds;
    int numInts;
    int data[0];
};
typedef const struct native_handle_t* buffer_handle_t;

/* native_handle_* resolved from libcutils.so at runtime. */
#include <dlfcn.h>
static struct native_handle_t* (*p_native_handle_clone)(const struct native_handle_t*);
static int (*p_native_handle_close)(const struct native_handle_t*);
static int (*p_native_handle_delete)(struct native_handle_t*);
static pthread_once_t g_cutils_once = PTHREAD_ONCE_INIT;
static void* g_cutils = nullptr;
static void load_cutils() {
    g_cutils = dlopen("libcutils.so", RTLD_NOW | RTLD_NOLOAD);
    if (!g_cutils) g_cutils = dlopen("libcutils.so", RTLD_NOW);
    if (g_cutils) {
        p_native_handle_clone =
            (decltype(p_native_handle_clone))dlsym(g_cutils, "native_handle_clone");
        p_native_handle_close =
            (decltype(p_native_handle_close))dlsym(g_cutils, "native_handle_close");
        p_native_handle_delete =
            (decltype(p_native_handle_delete))dlsym(g_cutils, "native_handle_delete");
    }
    if (!p_native_handle_clone || !p_native_handle_close || !p_native_handle_delete) {
        ALOGE("FATAL: cannot resolve native_handle_* from libcutils");
    }
}
static inline struct native_handle_t* native_handle_clone(const struct native_handle_t* h) {
    pthread_once(&g_cutils_once, load_cutils);
    return p_native_handle_clone ? p_native_handle_clone(h) : nullptr;
}
static inline int native_handle_close(const struct native_handle_t* h) {
    pthread_once(&g_cutils_once, load_cutils);
    return p_native_handle_close ? p_native_handle_close(h) : -1;
}
static inline int native_handle_delete(struct native_handle_t* h) {
    pthread_once(&g_cutils_once, load_cutils);
    return p_native_handle_delete ? p_native_handle_delete(h) : -1;
}

// ---------------------------------------------------------------------------
// AIMapper v5 ABI.
// ---------------------------------------------------------------------------
enum : uint32_t { AIMAPPER_VERSION_5 = 5 };
enum : int32_t {
    AIMAPPER_ERROR_NONE = 0,
    AIMAPPER_ERROR_BAD_DESCRIPTOR = 1,
    AIMAPPER_ERROR_BAD_BUFFER = 2,
    AIMAPPER_ERROR_BAD_VALUE = 3,
    AIMAPPER_ERROR_NO_RESOURCES = 5,
    AIMAPPER_ERROR_UNSUPPORTED = 7,
};
struct AIMapper_MetadataType {
    const char* name;
    int64_t value;
};
struct AIMapper_MetadataTypeDescription {
    AIMapper_MetadataType metadataType;
    const char* description;
    bool isGettable;
    bool isSettable;
    uint8_t reserved[32];
};
struct ARect {
    int32_t left, top, right, bottom;
};
typedef void (*AIMapper_DumpBufferCallback)(void* context, AIMapper_MetadataType metadataType,
                                            const void* value, size_t valueSize);
typedef void (*AIMapper_BeginDumpBufferCallback)(void* context);
struct AIMapperV5 {
    int32_t (*importBuffer)(const native_handle_t* handle, buffer_handle_t* outBufferHandle);
    int32_t (*freeBuffer)(buffer_handle_t buffer);
    int32_t (*getTransportSize)(buffer_handle_t buffer, uint32_t* outNumFds,
                                uint32_t* outNumInts);
    int32_t (*lock)(buffer_handle_t buffer, uint64_t cpuUsage, ARect accessRegion,
                    int acquireFence, void** outData);
    int32_t (*unlock)(buffer_handle_t buffer, int* releaseFence);
    int32_t (*flushLockedBuffer)(buffer_handle_t buffer);
    int32_t (*rereadLockedBuffer)(buffer_handle_t buffer);
    int32_t (*getMetadata)(buffer_handle_t buffer, AIMapper_MetadataType metadataType,
                           void* destBuffer, size_t destBufferSize);
    int32_t (*getStandardMetadata)(buffer_handle_t buffer, int64_t standardMetadataType,
                                   void* destBuffer, size_t destBufferSize);
    int32_t (*setMetadata)(buffer_handle_t buffer, AIMapper_MetadataType metadataType,
                           const void* metadata, size_t metadataSize);
    int32_t (*setStandardMetadata)(buffer_handle_t buffer, int64_t standardMetadataType,
                                   const void* metadata, size_t metadataSize);
    int32_t (*listSupportedMetadataTypes)(
        const AIMapper_MetadataTypeDescription** outDescriptionList,
        size_t* outNumberOfDescriptions);
    int32_t (*dumpBuffer)(buffer_handle_t buffer, AIMapper_DumpBufferCallback dumpBufferCallback,
                          void* context);
    int32_t (*dumpAllBuffers)(AIMapper_BeginDumpBufferCallback beginDumpCallback,
                              AIMapper_DumpBufferCallback dumpBufferCallback, void* context);
    int32_t (*getReservedRegion)(buffer_handle_t buffer, void** outReservedRegion,
                                 uint64_t* outReservedSize);
};
struct AIMapper {
    uint32_t version;
    uint32_t _pad; /* alignas(max_align_t): v5 starts at +8 */
    AIMapperV5 v5;
};
static_assert(sizeof(AIMapper_MetadataTypeDescription) == 0x40, "desc size");
static_assert(offsetof(AIMapper, v5) == 8, "v5 offset");

// StandardMetadataType values.
enum : int64_t {
    SMD_INVALID = 0,
    SMD_BUFFER_ID = 1,
    SMD_NAME = 2,
    SMD_WIDTH = 3,
    SMD_HEIGHT = 4,
    SMD_LAYER_COUNT = 5,
    SMD_PIXEL_FORMAT_REQUESTED = 6,
    SMD_PIXEL_FORMAT_FOURCC = 7,
    SMD_PIXEL_FORMAT_MODIFIER = 8,
    SMD_USAGE = 9,
    SMD_ALLOCATION_SIZE = 10,
    SMD_PROTECTED_CONTENT = 11,
    SMD_COMPRESSION = 12,
    SMD_INTERLACED = 13,
    SMD_CHROMA_SITING = 14,
    SMD_PLANE_LAYOUTS = 15,
    SMD_CROP = 16,
    SMD_DATASPACE = 17,
    SMD_BLEND_MODE = 18,
    SMD_SMPTE2086 = 19,
    SMD_CTA861_3 = 20,
    SMD_SMPTE2094_40 = 21,
    SMD_SMPTE2094_10 = 22,
    SMD_STRIDE = 23,
};
static const char* kStandardMetadataTypeName =
    "android.hardware.graphics.common.StandardMetadataType";

// ---------------------------------------------------------------------------
// Small helpers to read handle fields.
// ---------------------------------------------------------------------------
static inline int32_t h_i32(const native_handle_t* h, size_t off) {
    int32_t v;
    memcpy(&v, (const char*)h + off, 4);
    return v;
}
static inline uint32_t h_u32(const native_handle_t* h, size_t off) {
    uint32_t v;
    memcpy(&v, (const char*)h + off, 4);
    return v;
}
static inline uint64_t h_u64(const native_handle_t* h, size_t off) {
    uint64_t v;
    memcpy(&v, (const char*)h + off, 8);
    return v;
}
static inline void h_put64(native_handle_t* h, size_t off, uint64_t v) {
    memcpy((char*)h + off, &v, 8);
}
static inline void h_put32(native_handle_t* h, size_t off, uint32_t v) {
    memcpy((char*)h + off, &v, 4);
}

// Handle shape check shared by every entry point.
static bool handle_valid(const native_handle_t* h) {
    if (!h) return false;
    if (h->version != 0xc) return false;
    if (h_i32(h, PH_OFF_MAGIC) != (int32_t)PH_MAGIC) return false;
    if ((uint32_t)(h->numFds + h->numInts) != PH_FDINT_SUM) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Imported-handle registry, keyed by pointer.
// ---------------------------------------------------------------------------
struct PoolEntry {
    native_handle_t* handle = nullptr;  // owned clone
    uint64_t lockUsage = 0;             // usage of active lock (0 = unlocked)
    // setMetadata stash (name -> blob).
    std::map<int64_t, std::string> stash;
};
static pthread_mutex_t g_pool_mutex = PTHREAD_MUTEX_INITIALIZER;
static std::map<const native_handle_t*, PoolEntry> g_pool;

static PoolEntry* pool_get(const native_handle_t* h) {
    pthread_mutex_lock(&g_pool_mutex);
    auto it = g_pool.find(h);
    PoolEntry* e = (it == g_pool.end()) ? nullptr : &it->second;
    pthread_mutex_unlock(&g_pool_mutex);
    return e;
}

// ---------------------------------------------------------------------------
// sync fence wait without libsync.
// ---------------------------------------------------------------------------
#ifndef SYNC_IOC_MAGIC
#define SYNC_IOC_MAGIC '>'
#endif
#ifndef SYNC_IOC_WAIT
#define SYNC_IOC_WAIT _IOW(SYNC_IOC_MAGIC, 0, __s32)
#endif
static void fence_wait_and_close(int fence) {
    if (fence < 0) return;
    int32_t timeout = -1;  // infinite wait
    ioctl(fence, (unsigned long)SYNC_IOC_WAIT, &timeout);
    close(fence);
}

// ---------------------------------------------------------------------------
// Slot implementations.
// ---------------------------------------------------------------------------
static int32_t shim_importBuffer(const native_handle_t* handle, buffer_handle_t* out) {
    if (!handle) {
        ALOGE("importBuffer: null handle");
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    native_handle_t* clone = native_handle_clone(handle);
    if (!clone) {
        ALOGE("importBuffer: clone failed");
        return AIMAPPER_ERROR_NO_RESOURCES;
    }
    if (!handle_valid(clone)) {
        ALOGE("importBuffer: corrupt handle %p", (void*)clone);
        native_handle_close(clone);
        native_handle_delete(clone);
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    /* Shared fd index u32(+0x28) in {1..4} selects data[idx]; map +0x148 bytes. */
    uint32_t idx = h_u32(clone, PH_ION_FD_INDEX);
    int ion_fd = -1;
    if (idx >= 1 && idx <= 4) {
        if ((int)idx < clone->numFds) ion_fd = clone->data[idx];
    }
    size_t map_size = (size_t)h_u64(clone, PH_MAPPED_SIZE);
    void* base = MAP_FAILED;
    if (ion_fd >= 0 && map_size > 0) {
        base = mmap(nullptr, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, ion_fd, 0);
    }
    if (base == MAP_FAILED) {
        h_put64(clone, PH_MAPPED_ADDR, 0);
        native_handle_close(clone);
        native_handle_delete(clone);
        return AIMAPPER_ERROR_NO_RESOURCES;
    }
    h_put64(clone, PH_MAPPED_ADDR, (uint64_t)(uintptr_t)base);
    pthread_mutex_lock(&g_pool_mutex);
    PoolEntry e;
    e.handle = clone;
    g_pool[clone] = std::move(e);
    pthread_mutex_unlock(&g_pool_mutex);
    *out = clone;
    return AIMAPPER_ERROR_NONE;
}

static int32_t shim_freeBuffer(buffer_handle_t buffer) {
    if (!buffer) return AIMAPPER_ERROR_BAD_BUFFER;
    pthread_mutex_lock(&g_pool_mutex);
    auto it = g_pool.find(buffer);
    if (it == g_pool.end()) {
        pthread_mutex_unlock(&g_pool_mutex);
        ALOGE("freeBuffer: unregistered %p", (void*)buffer);
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    native_handle_t* h = it->second.handle;
    g_pool.erase(it);
    pthread_mutex_unlock(&g_pool_mutex);
    uint64_t base = h_u64(h, PH_MAPPED_ADDR);
    uint64_t size = h_u64(h, PH_MAPPED_SIZE);
    if (base && size) {
        if (munmap((void*)(uintptr_t)base, (size_t)size) < 0) {
            ALOGW("freeBuffer: munmap: %s", strerror(errno));
        }
        h_put64(h, PH_MAPPED_ADDR, 0);
    }
    native_handle_close(h);
    native_handle_delete(h);
    return AIMAPPER_ERROR_NONE;
}

static int32_t shim_getTransportSize(buffer_handle_t buffer, uint32_t* outNumFds,
                                     uint32_t* outNumInts) {
    PoolEntry* e = pool_get(buffer);
    if (!e || !handle_valid(e->handle)) {
        ALOGE("getTransportSize: bad buffer %p", (void*)buffer);
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    *outNumFds = (uint32_t)e->handle->numFds;
    *outNumInts = (uint32_t)e->handle->numInts;
    return AIMAPPER_ERROR_NONE;
}

/* Bytes per pixel for linear CPU mapping. */
static int hal_format_bpp(int32_t fmt) {
    switch (fmt) {
        case 1:  // RGBA_8888
        case 2:  // RGBX_8888
        case 0x15:  // RGBA_FP16
        case 5:   // RGBA_1010102
            return 4;
        case 3:  // RGB_888
            return 3;
        case 4:  // RGB_565
        case 6:  // BGRA_8888
            return (fmt == 6) ? 4 : 2;
        default:
            return 4;
    }
}

static int32_t shim_lock(buffer_handle_t buffer, uint64_t cpuUsage, ARect accessRegion,
                         int acquireFence, void** outData) {
    if (!buffer) return AIMAPPER_ERROR_BAD_BUFFER;
    if (cpuUsage == 0) return AIMAPPER_ERROR_BAD_VALUE;
    PoolEntry* e = pool_get(buffer);
    native_handle_t* h = e ? e->handle : nullptr;
    if (!e || !handle_valid(h)) {
        ALOGE("lock: invalid buffer %p", (void*)buffer);
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    int fence = acquireFence;
    if (fence >= 0) {
        fence = dup(fence);
        if (fence < 0) {
            ALOGE("lock: dup fence failed");
            return AIMAPPER_ERROR_NO_RESOURCES;
        }
    }
    int32_t w = h_i32(h, PH_WIDTH), hh = h_i32(h, PH_HEIGHT);
    int32_t l = accessRegion.left, t = accessRegion.top;
    int32_t r = accessRegion.right, b = accessRegion.bottom;
    bool allZero = (l == 0 && t == 0 && r == 0 && b == 0);
    if (!allZero && (l < 0 || t < 0 || r > w || b > hh || r <= l || b <= t)) {
        ALOGE("lock: bad region (%d,%d,%d,%d) vs (%d,%d)", l, t, r, b, w, hh);
        if (fence >= 0) close(fence);
        close(acquireFence);
        return AIMAPPER_ERROR_BAD_VALUE;
    }
    /* Compressed buffers are not CPU-mappable. */
    uint64_t intfmt = h_u64(h, PH_INTFMT);
    if ((intfmt & 0x100000000ULL) != 0) {
        if (fence >= 0) close(fence);
        close(acquireFence);
        return AIMAPPER_ERROR_BAD_VALUE;
    }
    fence_wait_and_close(fence);
    uint64_t base = h_u64(h, PH_MAPPED_ADDR);
    if (!base) {
        ALOGE("lock: buffer has no CPU mapping");
        close(acquireFence);
        return AIMAPPER_ERROR_NO_RESOURCES;
    }
    /* Region offset uses single-plane linear math (plane-0 base for YUV). */
    uint32_t stride = h_u32(h, PH_PLANE_ARR + PL_STRIDE_BYTES);
    if (!allZero) {
        int bpp = hal_format_bpp(h_i32(h, PH_REQ_FORMAT));
        uint32_t strideB = stride ? stride : (uint32_t)(w * bpp);
        base += (uint64_t)t * strideB + (uint64_t)l * (uint64_t)bpp;
    }
    e->lockUsage = cpuUsage;
    h_put32(h, PH_LOCK_B, 1);
    h_put32(h, PH_LOCK_COUNT, h_u32(h, PH_LOCK_COUNT) + 1);
    *outData = (void*)(uintptr_t)base;
    close(acquireFence);
    return AIMAPPER_ERROR_NONE;
}

static int32_t shim_unlock(buffer_handle_t buffer, int* releaseFence) {
    if (!buffer) return AIMAPPER_ERROR_BAD_BUFFER;
    *releaseFence = -1;
    PoolEntry* e = pool_get(buffer);
    native_handle_t* h = e ? e->handle : nullptr;
    if (!e || !handle_valid(h)) {
        ALOGE("unlock: invalid buffer %p", (void*)buffer);
        *releaseFence = 0;
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    uint32_t cnt = h_u32(h, PH_LOCK_COUNT);
    if (cnt == 0) {
        ALOGW("unlock: buffer %p not locked", (void*)buffer);
        *releaseFence = 0;
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    /* dma-buf sync END so the GPU reads coherent data. */
    if (e->lockUsage & 0x30) {
        uint32_t idx = h_u32(h, PH_ION_FD_INDEX);
        if (idx >= 1 && idx <= 4 && (int)idx < h->numFds) {
            int fd = h->data[idx];
            struct dma_buf_sync {
                uint64_t flags;
            } sync = {0x4 /* DMA_BUF_SYNC_END */ | 0x2 /* _WRITE */};
            ioctl(fd, _IOW('|', 0, struct dma_buf_sync), &sync);
        }
    }
    e->lockUsage = 0;
    h_put32(h, PH_LOCK_COUNT, cnt - 1);
    if (cnt - 1 == 0) h_put32(h, PH_LOCK_B, 0);
    *releaseFence = -1;
    return AIMAPPER_ERROR_NONE;
}

static int32_t shim_flushLockedBuffer(buffer_handle_t buffer) {
    PoolEntry* e = pool_get(buffer);
    native_handle_t* h = e ? e->handle : nullptr;
    if (!e || !handle_valid(h)) return AIMAPPER_ERROR_BAD_BUFFER;
    if (h_i32(h, PH_LOCK_A) == 0 && h_i32(h, PH_LOCK_B) == 0) {
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    if (e->lockUsage & 0x30) {
        uint32_t idx = h_u32(h, PH_ION_FD_INDEX);
        if (idx >= 1 && idx <= 4 && (int)idx < h->numFds) {
            int fd = h->data[idx];
            struct dma_buf_sync {
                uint64_t flags;
            } sync = {0x4 | 0x2};
            ioctl(fd, _IOW('|', 0, struct dma_buf_sync), &sync);
        }
    }
    return AIMAPPER_ERROR_NONE;
}

static int32_t shim_rereadLockedBuffer(buffer_handle_t buffer) {
    PoolEntry* e = pool_get(buffer);
    if (!e || !handle_valid(e->handle)) return AIMAPPER_ERROR_BAD_BUFFER;
    return AIMAPPER_ERROR_NONE;
}

/* Metadata parcel: u64 0x35 + 53B type name + "dataType" + u64 enum + payload
 * at +0x45. Returns bytes written, or negative on error. */
static const char kStdName[] = "android.hardware.graphics.common.StandardMetadataType";

static int32_t write_desc_prefix(uint8_t* out, size_t size, int64_t value) {
    memset(out, 0, size > 0x45 ? 0x45 : size);
    *(uint64_t*)(out + 0x00) = 0x35;
    if (size > 0x3c) {
        memcpy(out + 0x08, kStdName, sizeof(kStdName));  // incl NUL
        memcpy(out + 0x35, "dataType", 8);
    }
    if (size > 0x44) {
        *(int64_t*)(out + 0x3d) = value;
        return 0;
    }
    return -1;
}

static int32_t write_u64(const native_handle_t* h, int64_t name, uint64_t v, void* out, size_t size) {
    (void)h;
    if (!out || size <= 7) return 0x4d;  // size query
    write_desc_prefix((uint8_t*)out, size, name);
    if (size > 0x44) *(uint64_t*)((uint8_t*)out + 0x45) = v;
    return 0x4d;
}
// ExtendableType parcel: desc(0x45) + u64 nameLen + name bytes + u64 value.
static int32_t write_extendable(const native_handle_t* h, int64_t name, const char* type_name,
                                uint64_t v, void* out, size_t size) {
    (void)h;
    size_t nl = strlen(type_name);
    size_t need = 0x45 + 8 + nl + 8;
    if (!out || size <= 7) return (int32_t)need;
    uint8_t* o = (uint8_t*)out;
    memset(o, 0, size > 0x45 ? 0x45 : size);
    *(uint64_t*)(o + 0x00) = 0x35;
    if (size <= 0x3c) return (int32_t)need;
    memcpy(o + 0x08, kStdName, sizeof(kStdName));
    memcpy(o + 0x35, "dataType", 8);
    if (size <= 0x44) return (int32_t)need;
    *(int64_t*)(o + 0x3d) = name;
    if (size < need) return (int32_t)need;
    uint8_t* p = o + 0x45;
    *(uint64_t*)p = (uint64_t)nl;
    p += 8;
    memcpy(p, type_name, nl);
    p += nl;
    *(uint64_t*)p = v;
    return (int32_t)need;
}
static int32_t write_u32(const native_handle_t* h, int64_t name, uint32_t v, void* out, size_t size) {
    (void)h;
    if (!out || size <= 7) return 0x49;
    uint8_t* o = (uint8_t*)out;
    memset(o, 0, size > 0x45 ? 0x45 : size);
    *(uint64_t*)(o + 0x00) = 0x35;
    if (size > 0x3c) {
        memcpy(o + 0x08, kStdName, sizeof(kStdName));
        memcpy(o + 0x35, "dataType", 8);
    }
    if (size > 0x44 && (((size - 0x3d) & ~3ULL) != 8)) {
        *(int64_t*)(o + 0x3d) = name;
        *(uint32_t*)(o + 0x45) = v;
    } else if (size > 0x44) {
        *(int64_t*)(o + 0x3d) = name;
    }
    return 0x49;
}

/* DRM fourcc by internal format id. */
struct FourccEntry {
    uint64_t intfmt;
    uint32_t fourcc;
    uint32_t pad;
};
static const FourccEntry kFourccTable[] = {
    {0x20, 0x20363152}, {0x1, 0x34324241}, {0x5, 0x34325241}, {0x4, 0x36314752},
    {0x2, 0x34324258}, {0x3, 0x34324742}, {0x2b, 0x30334241}, {0x16, 0x48344241},
    {0x32315659, 0x32315659}, {0x1000, 0x3231564e}, {0x10, 0x3631564e}, {0x11, 0x3132564e},
    {0x1002, 0x324c3059}, {0x1004, 0x30313259}, {0x36, 0x30313050}, {0x1003, 0x30313250},
    {0x1005, 0x30313459}, {0x1001, 0x56595559}, {0x1006, 0x38305559}, {0x1007, 0x30315559},
    {0x14, 0x56595559}, {0x11, 0x3132564e}, {0x36, 0x30313050}, {0x120, 0x3231564e},
    {0x11d, 0x3132564e}, {0x11e, 0x3132564e}, {0x105, 0x3231564e}, {0x11c, 0x32315659},
    {0x101, 0x32315559}, {0x125, 0x3231564e}, {0x107, 0x3231564e}, {0x123, 0x3231564e},
    {0x126, 0x3231564e}, {0x127, 0x30313050}, {0x11f, 0x32315559}, {0x130, 0x3231564e},
    {0x131, 0x3231564e}, {0x132, 0x30313050}, {0x133, 0x30313050}, {0x134, 0x3132564e},
    {0x135, 0x30313050}, {0x140, 0x3231564e}, {0x141, 0x3231564e}, {0x150, 0x3231564e},
    {0x151, 0x3231564e}, {0x160, 0x30313050}, {0x161, 0x30313050}, {0x162, 0x30313050},
    {0x170, 0x30313050}, {0x171, 0x30313050}, {0x172, 0x30313050},
};
static uint32_t drm_fourcc_from_handle(const native_handle_t* h) {
    uint64_t intfmt = h_u64(h, PH_INTFMT);
    for (auto& e : kFourccTable) {
        if (e.intfmt == (intfmt & 0xffffffffu)) {
            if ((intfmt & 0x1ffffffffULL) == 0x100000004ULL) return 0x36314742;  // 'BG16'
            return e.fourcc;
        }
    }
    return 0;
}
static uint64_t drm_modifier_from_handle(const native_handle_t* h) {
    uint64_t fmt = h_u64(h, PH_INTFMT);
    if (((fmt >> 0x20) & 1) == 0) return 0;
    uint64_t f1 = fmt >> 0x1c;
    uint64_t comp;
    if (((fmt >> 0x23) & 1) == 0) {
        comp = ((fmt & 0x2000000000ULL) == 0) ? 1 : 3;
    } else {
        comp = 2;
        if (h_i32(h, PH_NUMPLANES_AUX1) != 0) comp = 4;
    }
    return (((fmt >> 0x1d) & 0x20) | (f1 & 0x100) | (f1 & 0x400) | (f1 & 0x800) |
            ((fmt >> 0x24) & 0x10) | ((fmt >> 0x23) & 0x40) | comp | 0x800000000000000ULL);
}

/* ALLOCATION_SIZE: sum over fd slots. */
static int64_t allocation_size(const native_handle_t* h) {
    uint32_t n = h_u32(h, 0x28);
    int64_t total = 0;
    if ((int32_t)n >= 1) {
        if (n < 4) {
            for (uint32_t i = 0; i < n; i++) total += (int64_t)h_u64(h, 0x120 + i * 8);
        } else {
            uint32_t m = n & 0xfffffffc;
            for (uint32_t i = 0; i < m; i += 4)
                total += (int64_t)h_u64(h, 0x130 + i * 8) + (int64_t)h_u64(h, 0x120 + i * 8) +
                         (int64_t)h_u64(h, 0x138 + i * 8) + (int64_t)h_u64(h, 0x128 + i * 8);
            for (uint32_t i = m; i < n; i++) total += (int64_t)h_u64(h, 0x120 + i * 8);
        }
    }
    return total;
}

/* PlaneLayoutComponentType values. */
enum : int64_t { PLC_Y = 1, PLC_CB = 2, PLC_CR = 4, PLC_R = 1 << 10, PLC_G = 1 << 11,
                 PLC_B = 1 << 12, PLC_A = 1 << 30 };
static const char* kCompTypeName = "android.hardware.graphics.common.PlaneLayoutComponentType";

// Exynos format predicate.
static bool handle_is_exynos(const native_handle_t* h) {
    uint32_t fmt = h_u32(h, PH_INTFMT);
    return (fmt >= 0x100 && fmt < 0x200) || fmt == 0x11 || fmt == 0x14 || fmt == 0x16 ||
           fmt == 0x2b || fmt == 0x20;
}

/* Plane count: exynos format switch, aux-field fallback otherwise. */
static uint32_t num_planes(const native_handle_t* h) {
    uint32_t fmt = h_u32(h, PH_INTFMT);
    bool is_exynos = handle_is_exynos(h);
    /* Non-listed exynos ids fall through to the aux path. */
    if (is_exynos) {
        switch (fmt) {
            case 0x101:
            case 0x11c:
            case 0x11f:
                return 3;
            case 0x105: case 0x107: case 0x11d: case 0x11e: case 0x123: case 0x125:
            case 0x126: case 0x127: case 0x130: case 0x131: case 0x132: case 0x133:
            case 0x134: case 0x135: case 0x140: case 0x141: case 0x150: case 0x151:
            case 0x160: case 0x161: case 0x162: case 0x170: case 0x171: case 0x172:
                return 2;
            default:
                if (fmt == 0x11) return 3;
                break;
        }
    }
    // aux fallback
    if (h_i32(h, PH_NUMPLANES_AUX1) == 0) return 1;
    uint32_t n = 2;
    if (h_u64(h, PH_NUMPLANES_AUX2) != 0) n = 3;
    return n;
}

// Per-plane fields.
static uint64_t plane_offset(const native_handle_t* h, uint32_t i) {
    return h_u64(h, PH_PLANE_ARR + i * 0x28 + PL_OFF_BYTES);
}
/* Plane entry @ +0x58 + i*0x28: +0x18 byte stride, +0x1c width samples,
 * +0x20 height samples. */
static uint32_t plane_byte_stride(const native_handle_t* h, uint32_t i) {
    return h_u32(h, PH_PLANE_ARR + i * 0x28 + PL_STRIDE_BYTES);
}
static uint32_t plane_entry_w(const native_handle_t* h, uint32_t i) {
    return h_u32(h, PH_PLANE_ARR + i * 0x28 + PL_WIDTH);
}
static uint32_t plane_entry_h(const native_handle_t* h, uint32_t i) {
    return h_u32(h, PH_PLANE_ARR + i * 0x28 + PL_HEIGHT);
}
static uint32_t plane_stride_bytes(const native_handle_t* h, uint32_t i) {
    uint32_t raw = plane_byte_stride(h, i);
    if (raw) return raw;
    uint32_t w = plane_entry_w(h, i);
    if (!w) w = (uint32_t)h_i32(h, PH_WIDTH);
    uint32_t bpp = (uint32_t)hal_format_bpp(h_i32(h, PH_REQ_FORMAT));
    if (bpp < 1) bpp = 4;
    return w * bpp;
}
/* Plane byte offset. Exynos handles with i == u32(plane+0x08) use per-plane
 * bases at +0x108: off = *(h+0x108+i*8) - *(h+0x108), signed (multi-fd YUV
 * yields negatives). Otherwise off = raw +0x58. */
static uint64_t plane_parcel_offset(const native_handle_t* h, uint32_t i, bool is_exynos) {
    if (is_exynos && i == h_u32(h, PH_PLANE_ARR + i * 0x28 + 0x08)) {
        int64_t a = (int64_t)h_u64(h, 0x108 + (size_t)i * 8);
        int64_t b = (int64_t)h_u64(h, 0x108);
        return (uint64_t)(a - b);
    }
    return plane_offset(h, i);
}
/* Parcel samples: raw entry values, buffer dims as fallback. */
static uint32_t plane_samples_w(const native_handle_t* h, uint32_t i, uint32_t n) {
    uint32_t bw = (uint32_t)h_i32(h, PH_WIDTH);
    uint32_t raw = plane_entry_w(h, i);
    if (raw == 0) return (n == 1) ? bw : (i == 0 ? bw : (bw + 1) / 2);
    return raw;
}
static uint32_t plane_samples_h(const native_handle_t* h, uint32_t i, uint32_t n) {
    uint32_t bh = (uint32_t)h_i32(h, PH_HEIGHT);
    uint32_t raw = plane_entry_h(h, i);
    if (raw == 0) return (n == 1) ? bh : (i == 0 ? bh : (bh + 1) / 2);
    return raw;
}
static uint64_t plane_total(const native_handle_t* h, uint32_t i, uint32_t nplanes) {
    /* fd-index override, else next plane's offset, else alloc share. */
    /* Signed compare: old handles carry 0xffffffff at +0x28. */
    int32_t fdcount = h_i32(h, 0x28);
    if (fdcount > 1 && i == h_u32(h, PH_PLANE_ARR + i * 0x28 + 0x08)) {
        return h_u64(h, PH_PLANE_ARR + i * 0x28 + 0x10);
    }
    if (i + 1 < nplanes) return plane_offset(h, i + 1);
    uint32_t layers = h_u32(h, PH_LAYER_COUNT);
    uint64_t per = layers ? h_u64(h, PH_ALLOC_ARR) / layers : 0;
    uint64_t off = plane_offset(h, i);
    return per >= off ? per - off : 0;
}

// AIDL-parcel writers.
struct ParcelCursor {
    uint8_t* p;
    size_t remain;
    int32_t total = 0;  // bytes that would be written (0xfffffffd on overflow)
    bool ok() const { return total >= 0; }
    void put_u64(uint64_t v) {
        if (!ok()) return;
        if (remain < 8) {
            remain = 0;
            total = -3;  // overflow
            return;
        }
        if (p) {
            memcpy(p, &v, 8);
            p += 8;
        }
        remain -= 8;
        total += 8;
    }
    void put_bytes(const void* src, size_t n) {
        if (!ok()) return;
        if (remain < n) {
            remain = 0;
            total = -3;
            return;
        }
        if (p && n) {
            memcpy(p, src, n);
            p += n;
        }
        remain -= n;
        total += (int32_t)n;
    }
    void put_cstr(const char* s) {
        size_t n = strlen(s);
        put_u64(n);
        put_bytes(s, n);
    }
};

// NAME value: u64 len + bytes.
static int32_t write_name(const native_handle_t* h, void* out, size_t size) {
    (void)h;
    // v1: empty name.
    const char* nm = "";
    size_t n = 0;
    // desc + u64 len + bytes; returns 0x4d + len.
    if (!out || size <= 7) return (int32_t)(0x4d + n);
    uint8_t* o = (uint8_t*)out;
    memset(o, 0, size > 0x45 ? 0x45 : size);
    *(uint64_t*)(o + 0x00) = 0x35;
    if (size <= 0x3c) return (int32_t)(0x4d + n);
    memcpy(o + 0x08, kStdName, sizeof(kStdName));
    memcpy(o + 0x35, "dataType", 8);
    if (size <= 0x44) return (int32_t)(0x4d + n);
    *(int64_t*)(o + 0x3d) = SMD_NAME;
    size_t off = 0x45;
    if (size < off + 8) return (int32_t)(0x4d + n);
    *(uint64_t*)(o + off) = n;
    off += 8;
    if (size < off + n) return (int32_t)(0x4d + n);
    memcpy(o + off, nm, n);
    return (int32_t)(0x4d + n);
}

/* PLANE_LAYOUTS value: u64 count + per-plane parcel. */
static int32_t write_plane_layouts(const native_handle_t* h, void* out, size_t size) {
    uint32_t n = num_planes(h);
    uint64_t intfmt = h_u64(h, PH_INTFMT);
    bool afbc = (intfmt & 0x100000000ULL) != 0;
    // Component assignment: RGB* -> R,G,B,(A); YUV -> Y + CbCr.
    struct Comp {
        int64_t type;
        uint64_t offBits, sizeBits;
    };
    uint8_t tmp[2048];
    ParcelCursor c{tmp, sizeof(tmp), 0};
    c.put_u64(n);
    for (uint32_t i = 0; i < n; i++) {
        int32_t req = h_i32(h, PH_REQ_FORMAT);
        Comp comps[4];
        int ncomps = 0;
        int bpp = hal_format_bpp(req);
        if (n == 1) {
            // Single plane.
            if (req == 4) {  // RGB_565
                comps[0] = {PLC_R, 11, 5};
                comps[1] = {PLC_G, 5, 6};
                comps[2] = {PLC_B, 0, 5};
                ncomps = 3;
            } else if (bpp == 3) {
                comps[0] = {PLC_R, 0, 8};
                comps[1] = {PLC_G, 8, 8};
                comps[2] = {PLC_B, 16, 8};
                ncomps = 3;
            } else {
                comps[0] = {PLC_R, 0, 8};
                comps[1] = {PLC_G, 8, 8};
                comps[2] = {PLC_B, 16, 8};
                comps[3] = {PLC_A, 24, 8};
                ncomps = 4;
            }
        } else {
            if (i == 0) {
                comps[0] = {PLC_Y, 0, 8};
                ncomps = 1;
            } else {
                /* Interleaved VU order. */
                comps[0] = {PLC_CR, 0, 8};
                comps[1] = {PLC_CB, 8, 8};
                ncomps = 2;
            }
        }
        c.put_u64((uint64_t)ncomps);
        for (int k = 0; k < ncomps; k++) {
            c.put_cstr(kCompTypeName);
            c.put_u64((uint64_t)comps[k].type);
            c.put_u64(comps[k].offBits);
            c.put_u64(comps[k].sizeBits);
        }
        uint64_t stride = plane_stride_bytes(h, i);
        uint32_t w = plane_samples_w(h, i, n), hh = plane_samples_h(h, i, n);
        if (!w) w = (uint32_t)h_i32(h, PH_WIDTH);
        if (!hh) hh = (uint32_t)h_i32(h, PH_HEIGHT);
        if (!stride) stride = (uint64_t)w * (uint32_t)hal_format_bpp(req);
        /* sampleIncrement = sum of component sizes. */
        uint64_t sampInc = 0;
        for (int k = 0; k < ncomps; k++) sampInc += (uint64_t)comps[k].sizeBits;
        uint64_t total = plane_total(h, i, n);
        if (!total) total = (uint64_t)stride * hh;
        c.put_u64(plane_parcel_offset(h, i, handle_is_exynos(h)));
        c.put_u64(sampInc);
        c.put_u64(stride);
        c.put_u64(w);
        c.put_u64(hh);
        c.put_u64(total);
        /* 4:2:0 chroma planes report 2,2. */
        uint64_t hs = 1, vs = 1;
        if (n > 1 && i > 0) {
            hs = 2;
            vs = 2;
        }
        c.put_u64(hs);
        c.put_u64(vs);
        (void)afbc;
    }
    if (!c.ok()) return -3;
    /* Payload starts at +0x45 (desc is 69 bytes). */
    size_t need = 0x45 + (size_t)c.total;
    if (!out || size <= 7) return (int32_t)need > 0 ? (int32_t)need : -3;
    uint8_t* o = (uint8_t*)out;
    memset(o, 0, size > 0x45 ? 0x45 : size);
    *(uint64_t*)(o + 0x00) = 0x35;
    if (size <= 0x3c) return (int32_t)need;
    memcpy(o + 0x08, kStdName, sizeof(kStdName));
    memcpy(o + 0x35, "dataType", 8);
    if (size <= 0x44) return (int32_t)need;
    *(int64_t*)(o + 0x3d) = SMD_PLANE_LAYOUTS;
    if (size < 0x45 + (size_t)c.total) return (int32_t)need;
    memcpy(o + 0x45, tmp, (size_t)c.total);
    return (int32_t)need;
}

// ---------------------------------------------------------------------------
// getStandardMetadata dispatcher.
// ---------------------------------------------------------------------------
static int32_t shim_getStandardMetadata(const native_handle_t* buffer, int64_t name, void* out,
                                        size_t size) {
    if (!buffer) return -2;
    if (name < 1 || name > 23) return -7;
    if (!handle_valid(buffer)) return -2;
    /* HDR types 19,20,21 additionally require registration. */
    if ((name == 19 || name == 20 || name == 21) && !pool_get(buffer)) return -2;
    const native_handle_t* h = buffer;
    switch (name) {
        case SMD_BUFFER_ID:
            return write_u64(h, name, h_u64(h, PH_BUFFER_ID), out, size);
        case SMD_NAME:
            return write_name(h, out, size);
        case SMD_WIDTH:
            return write_u64(h, name, (uint64_t)(int64_t)h_i32(h, PH_WIDTH), out, size);
        case SMD_HEIGHT:
            return write_u64(h, name, (uint64_t)(int64_t)h_i32(h, PH_HEIGHT), out, size);
        case SMD_LAYER_COUNT:
            return write_u64(h, name, h_u32(h, PH_LAYER_COUNT), out, size);
        case SMD_PIXEL_FORMAT_REQUESTED:
            return write_u32(h, name, (uint32_t)h_i32(h, PH_REQ_FORMAT), out, size);
        case SMD_PIXEL_FORMAT_FOURCC:
            return write_u32(h, name, drm_fourcc_from_handle(h), out, size);
        case SMD_PIXEL_FORMAT_MODIFIER:
            return write_u64(h, name, drm_modifier_from_handle(h), out, size);
        case SMD_USAGE:
            return write_u64(h, name, h_u64(h, PH_USAGE_LO) | h_u64(h, PH_USAGE_HI), out, size);
        case SMD_ALLOCATION_SIZE:
            return write_u64(h, name, (uint64_t)allocation_size(h), out, size);
        case SMD_PROTECTED_CONTENT:
            return write_u64(h, name,
                             (((uint32_t)h_u32(h, PH_USAGE_LO) | (uint32_t)h_u32(h, PH_USAGE_HI)) >>
                              0xe) &
                                 1,
                             out, size);
        /* ExtendableType parcel: desc + u64 nameLen + name + u64 value. */
        case SMD_COMPRESSION: {
            bool afbc = (h_u64(h, PH_INTFMT) & 0x100000000ULL) != 0;
            return write_extendable(
                h, name, afbc ? "arm.graphics.Compression"
                              : "android.hardware.graphics.common.Compression",
                0, out, size);
        }
        case SMD_INTERLACED:
            return write_extendable(h, name, "android.hardware.graphics.common.Interlaced",
                                    0, out, size);
        case SMD_CHROMA_SITING:
            return write_extendable(h, name,
                                    "android.hardware.graphics.common.ChromaSiting",
                                    num_planes(h) > 1 ? 1 : 0, out, size);
        case SMD_PLANE_LAYOUTS:
            return write_plane_layouts(h, out, size);
        case SMD_CROP: {
            /* Payload: u64 plane count + per-plane (l,t,r,b) u32 rects. */
            uint32_t n = num_planes(h);
            size_t need = 0x45 + 8 + (size_t)n * 16;
            if (!out || size <= 7) return (int32_t)need;
            uint8_t* o = (uint8_t*)out;
            memset(o, 0, size > 0x45 ? 0x45 : size);
            *(uint64_t*)(o + 0x00) = 0x35;
            if (size <= 0x3c) return (int32_t)need;
            memcpy(o + 0x08, kStdName, sizeof(kStdName));
            memcpy(o + 0x35, "dataType", 8);
            if (size <= 0x44) return (int32_t)need;
            *(int64_t*)(o + 0x3d) = SMD_CROP;
            if (size < need) return (int32_t)need;
            uint8_t* p = o + 0x45;
            *(uint64_t*)p = n;
            p += 8;
            for (uint32_t i = 0; i < n; i++) {
                /* Rect = min(plane dims, buffer dims). */
                uint32_t bw = (uint32_t)h_i32(h, PH_WIDTH);
                uint32_t bh = (uint32_t)h_i32(h, PH_HEIGHT);
                uint32_t w = plane_samples_w(h, i, n), hh = plane_samples_h(h, i, n);
                if (!w || w > bw) w = bw;
                if (!hh || hh > bh) hh = bh;
                *(uint32_t*)(p + 0) = 0;
                *(uint32_t*)(p + 4) = 0;
                *(uint32_t*)(p + 8) = w;
                *(uint32_t*)(p + 12) = hh;
                p += 16;
            }
            return (int32_t)need;
        }
        case SMD_DATASPACE: {
            uint32_t ds = 0;
            uint64_t base = h_u64(h, PH_MAPPED_ADDR);
            if (base) {
                int32_t flag = 0;
                memcpy(&flag, (void*)(uintptr_t)(base + SHM_DATASPACE_FLAG), 4);
                if (flag) {
                    uint32_t v = 0;
                    memcpy(&v, (void*)(uintptr_t)(base + SHM_DATASPACE_VAL), 4);
                    ds = (uint32_t)(((uint64_t)(v & 0xffffff00) | 0x100000000ULL) | (v & 0xff));
                }
            }
            return write_u32(h, name, ds, out, size);
        }
        case SMD_BLEND_MODE:
            return write_u32(h, name, 0, out, size);
        case SMD_SMPTE2086:
        case SMD_CTA861_3:
        case SMD_SMPTE2094_40:
        case SMD_SMPTE2094_10:
            return -7;
        case SMD_STRIDE:
            return write_u32(h, name, plane_samples_w(h, 0, num_planes(h)), out, size);
        default:
            return -7;
    }
}

static int32_t shim_getMetadata(buffer_handle_t buffer, AIMapper_MetadataType type, void* out,
                                size_t size) {
    if (!buffer) return -2;
    if (!type.name || strcmp(type.name, kStandardMetadataTypeName) != 0) {
        ALOGW("getMetadata: unsupported namespace '%s'", type.name ? type.name : "(null)");
        return -7;
    }
    if (type.value == 0) return -7;
    return shim_getStandardMetadata(buffer, type.value, out, size);
}

static int32_t shim_setStandardMetadata(const native_handle_t* buffer, int64_t name,
                                        const void* data, size_t size);

static int32_t shim_setMetadata(buffer_handle_t buffer, AIMapper_MetadataType type,
                                const void* data, size_t size) {
    if (!buffer) return AIMAPPER_ERROR_BAD_BUFFER;
    if (!type.name || strcmp(type.name, kStandardMetadataTypeName) != 0) {
        return AIMAPPER_ERROR_UNSUPPORTED;
    }
    return shim_setStandardMetadata(buffer, type.value, data, size);
}

static int32_t shim_setStandardMetadata(buffer_handle_t buffer, int64_t name, const void* data,
                                        size_t size) {
    if (!buffer) return AIMAPPER_ERROR_BAD_BUFFER;
    PoolEntry* e = pool_get(buffer);
    if (!e || !handle_valid(e->handle)) return AIMAPPER_ERROR_BAD_BUFFER;
    /* Read-only set. */
    if (name == 1 || name == 2 || name == 3 || name == 4 || name == 5 || name == 7) {
        return AIMAPPER_ERROR_BAD_VALUE;
    }
    native_handle_t* h = e->handle;
    if (name == SMD_DATASPACE && data && size >= 4) {
        uint64_t base = h_u64(h, PH_MAPPED_ADDR);
        if (!base) return AIMAPPER_ERROR_NO_RESOURCES;
        uint32_t v;
        memcpy(&v, data, 4);
        uint64_t w = ((uint64_t)v << 32) | 1;
        memcpy((void*)(uintptr_t)(base + SHM_DATASPACE_FLAG), &w, 8);
        return AIMAPPER_ERROR_NONE;
    }
    if ((name >= 16 && name <= 21) || name == SMD_BLEND_MODE) {
        e->stash[name] = std::string((const char*)data, data ? size : 0);
        return AIMAPPER_ERROR_NONE;
    }
    return AIMAPPER_ERROR_UNSUPPORTED;
}

struct DescSlot {
    AIMapper_MetadataTypeDescription d;
    uint64_t value_payload;  // zeroed
};
static DescSlot g_descs[22];
static pthread_once_t g_descs_once = PTHREAD_ONCE_INIT;
static void build_descs() {
    for (int i = 0; i < 22; i++) {
        g_descs[i].d.metadataType.name = kStandardMetadataTypeName;
        g_descs[i].d.metadataType.value = i + 1;
        g_descs[i].d.description = "";
        g_descs[i].d.isGettable = true;
        int64_t v = i + 1;
        g_descs[i].d.isSettable = (v >= 16 && v <= 21) || v == 18;
        memset(g_descs[i].d.reserved, 0, sizeof(g_descs[i].d.reserved));
        g_descs[i].value_payload = 0;
    }
}

static int32_t shim_listSupportedMetadataTypes(const AIMapper_MetadataTypeDescription** out,
                                               size_t* count) {
    pthread_once(&g_descs_once, build_descs);
    *out = &g_descs[0].d;
    *count = 22;
    return AIMAPPER_ERROR_NONE;
}

static int32_t shim_dumpBuffer(buffer_handle_t buffer, AIMapper_DumpBufferCallback cb,
                               void* ctx) {
    PoolEntry* e = pool_get(buffer);
    if (!e || !handle_valid(e->handle)) return AIMAPPER_ERROR_BAD_BUFFER;
    uint8_t tmp[2048];
    for (int64_t n = 1; n <= 17; n++) {
        int32_t rc = shim_getStandardMetadata(buffer, n, tmp, sizeof(tmp));
        if (rc > 0) {
            AIMapper_MetadataType t{kStandardMetadataTypeName, n};
            cb(ctx, t, tmp, (size_t)rc);
        }
    }
    return AIMAPPER_ERROR_NONE;
}

static int32_t shim_dumpAllBuffers(AIMapper_BeginDumpBufferCallback begin,
                                   AIMapper_DumpBufferCallback cb, void* ctx) {
    pthread_mutex_lock(&g_pool_mutex);
    std::vector<const native_handle_t*> keys;
    for (auto& kv : g_pool) keys.push_back(kv.first);
    pthread_mutex_unlock(&g_pool_mutex);
    for (auto k : keys) {
        begin(ctx);
        shim_dumpBuffer(k, cb, ctx);
    }
    return AIMAPPER_ERROR_NONE;
}

static int32_t shim_getReservedRegion(buffer_handle_t buffer, void** out, uint64_t* size) {
    PoolEntry* e = pool_get(buffer);
    native_handle_t* h = e ? e->handle : nullptr;
    if (!e || !handle_valid(h)) return AIMAPPER_ERROR_BAD_BUFFER;
    if (h_u64(h, PH_RESERVED_FLAG) == 0) return AIMAPPER_ERROR_BAD_BUFFER;
    uint64_t base = h_u64(h, PH_MAPPED_ADDR);
    if (!base) return AIMAPPER_ERROR_BAD_BUFFER;
    *out = (void*)(uintptr_t)(base + 0x33d0);
    *size = 0;
    return AIMAPPER_ERROR_NONE;
}

// ---------------------------------------------------------------------------
// Table + entry point.
// ---------------------------------------------------------------------------
static AIMapper g_mapper = {
    AIMAPPER_VERSION_5,
    0,
    {
        shim_importBuffer,
        shim_freeBuffer,
        shim_getTransportSize,
        shim_lock,
        shim_unlock,
        shim_flushLockedBuffer,
        shim_rereadLockedBuffer,
        shim_getMetadata,
        shim_getStandardMetadata,
        shim_setMetadata,
        shim_setStandardMetadata,
        shim_listSupportedMetadataTypes,
        shim_dumpBuffer,
        shim_dumpAllBuffers,
        shim_getReservedRegion,
    },
};

extern "C" __attribute__((visibility("default"), used)) int32_t AIMapper_loadIMapper(
    AIMapper** out) {
    ALOGI("mali-shim: AIMapper v5 ready");
    if (!out) return AIMAPPER_ERROR_BAD_VALUE;
    *out = &g_mapper;
    return AIMAPPER_ERROR_NONE;
}
