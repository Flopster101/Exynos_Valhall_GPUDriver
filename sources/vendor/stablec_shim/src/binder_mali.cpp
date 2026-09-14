/* SPDX-License-Identifier: MIT */
/* libbinder_ml.so: answers the driver's IAllocator/default lookup locally
 * (interface version 2, mapper suffix). Other symbols forward to
 * libbinder_ndk.so. */

#include <dlfcn.h>
#include <string.h>

#include <android/binder_ibinder.h>
#include <android/binder_parcel.h>
#include <android/binder_status.h>
#include <android/log.h>

#define LOG_TAG "binder_mali"
#define ALOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* IAllocator transact codes. */
static constexpr transaction_code_t kCodeGetSuffix = 4;
static constexpr transaction_code_t kCodeGetVersion = 16777215;
static const char* kSuffix = "mali";

static binder_status_t onTransact(AIBinder* binder, transaction_code_t code,
                                  const AParcel* in, AParcel* out) {
    (void)binder;
    (void)in;
    AStatus* ok = AStatus_newOk();
    binder_status_t ret = STATUS_UNKNOWN_TRANSACTION;
    if (code == kCodeGetVersion) {
        if (AParcel_writeStatusHeader(out, ok) == STATUS_OK &&
            AParcel_writeInt32(out, 2) == STATUS_OK) {
            ret = STATUS_OK;
        }
    } else if (code == kCodeGetSuffix) {
        if (AParcel_writeStatusHeader(out, ok) == STATUS_OK &&
            AParcel_writeString(out, kSuffix, strlen(kSuffix)) == STATUS_OK) {
            ret = STATUS_OK;
        }
    } else {
        ALOGW("unexpected transact code %u", code);
    }
    AStatus_delete(ok);
    return ret;
}

static AIBinder_Class* g_class = nullptr;
static AIBinder* g_binder = nullptr;

static void* fake_onCreate(void* args) {
    return args;
}
static void fake_onDestroy(void* userData) {
    (void)userData;
}

/* Real libbinder_ndk.so handle. */
static void* real_handle() {
    static void* h = nullptr;
    if (!h) {
        h = dlopen("libbinder_ndk.so", RTLD_NOW | RTLD_NOLOAD);
        if (!h) h = dlopen("/system/lib64/libbinder_ndk.so", RTLD_NOW | RTLD_NOLOAD);
        if (!h) h = dlopen("/system/lib64/libbinder_ndk.so", RTLD_NOW);
    }
    return h;
}

/* ndk::SpAIBinder is { AIBinder* }; caller takes +1 ref per call. */
struct SpAIBinder_compat {
    AIBinder* binder;
};
using CheckServiceFn = SpAIBinder_compat (*)(const char*);

extern "C" {

__attribute__((visibility("default"))) bool AStatus_isOk(const AStatus* status) {
    using Fn = bool (*)(const AStatus*);
    static Fn f = (Fn)dlsym(real_handle(), "AStatus_isOk");
    return f(status);
}
__attribute__((visibility("default"))) void AStatus_delete(AStatus* status) {
    using Fn = void (*)(AStatus*);
    static Fn f = (Fn)dlsym(real_handle(), "AStatus_delete");
    return f(status);
}
__attribute__((visibility("default"))) void AIBinder_decStrong(AIBinder* binder) {
    using Fn = void (*)(AIBinder*);
    static Fn f = (Fn)dlsym(real_handle(), "AIBinder_decStrong");
    return f(binder);
}

/* Approve our local binder. */
__attribute__((visibility("default"))) bool AIBinder_associateClass(
    AIBinder* binder, const AIBinder_Class* clazz) {
    if (binder != nullptr && g_binder != nullptr && binder == g_binder) {
        (void)clazz;
        return true;
    }
    using Fn = bool (*)(AIBinder*, const AIBinder_Class*);
    static Fn f = (Fn)dlsym(real_handle(), "AIBinder_associateClass");
    return f(binder, clazz);
}

__attribute__((visibility("default"))) SpAIBinder_compat AServiceManager_checkService(
    const char* instance) {
    SpAIBinder_compat r{nullptr};
    if (instance && strstr(instance, "IAllocator/default") != nullptr) {
        if (!g_binder) {
            g_class = AIBinder_Class_define("mali-fake-allocator", fake_onCreate, fake_onDestroy,
                                              onTransact);
            if (g_class) {
                g_binder = AIBinder_new(g_class, nullptr);
            }
            if (!g_binder) {
                ALOGE("failed to create fake IAllocator binder");
            }
        }
        if (g_binder) {
            AIBinder_incStrong(g_binder);
            r.binder = g_binder;
            return r;
        }
    }
    static CheckServiceFn realFn = (CheckServiceFn)dlsym(real_handle(),
                                                         "AServiceManager_checkService");
    if (realFn) return realFn(instance);
    return r;
}

}  // extern "C"
