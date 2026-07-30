# Android magisk customize.sh - Exynos Valhall GPU Driver

SOC=$(getprop ro.soc.model)
MODVER=$(grep_prop version $MODPATH/module.prop)
DRIVER_VER=$(grep_prop driverVersion $MODPATH/module.prop)
[ -z "$DRIVER_VER" ] && DRIVER_VER="GPU Driver"
CHIP=$(getprop ro.hardware.chipname)
PLATFORM=$(getprop ro.board.platform)

# Detect SoC and set GPU name
case "$CHIP" in
    exynos2100|exynos2100_r)
        GPU_NAME="Mali-G78 MP14"
        SOC_NAME="Exynos 2100"
        COMPAT_PLATFORM="exynos2100"
        ;;
    s5e8825|erd8825)
        GPU_NAME="Mali-G68 MP4"
        SOC_NAME="Exynos 1280"
        COMPAT_PLATFORM="exynos1280"
        ;;
    s5e8835|erd8835|exynos1380)
        GPU_NAME="Mali-G68"
        SOC_NAME="Exynos 1380"
        COMPAT_PLATFORM="exynos1380"
        ;;
    s5e8535|erd8535|exynos1330)
        GPU_NAME="Mali-G68"
        SOC_NAME="Exynos 1330"
        COMPAT_PLATFORM="exynos1330"
        ;;
    *)
        case "$PLATFORM" in
            exynos2100|exynos2100_r)
                GPU_NAME="Mali-G78 MP14"
                SOC_NAME="Exynos 2100"
                COMPAT_PLATFORM="exynos2100"
                ;;
            s5e8825|erd8825)
                GPU_NAME="Mali-G68 MP4"
                SOC_NAME="Exynos 1280"
                COMPAT_PLATFORM="exynos1280"
                ;;
            s5e8835|erd8835|exynos1380)
                GPU_NAME="Mali-G68"
                SOC_NAME="Exynos 1380"
                COMPAT_PLATFORM="exynos1380"
                ;;
            s5e8535|erd8535|exynos1330)
                GPU_NAME="Mali-G68"
                SOC_NAME="Exynos 1330"
                COMPAT_PLATFORM="exynos1330"
                ;;
            *)
                GPU_NAME="Mali-G78/G68"
                SOC_NAME="Exynos 2100/1280"
                COMPAT_PLATFORM=""
                ;;
        esac
        ;;
esac

# Check for conflicting modules
check_conflicting_modules() {
    for mod in gpu_driver_mali exynos_valhall_gpudriver; do
        if [ -d "/data/adb/modules/$mod" ] && [ -f "/data/adb/modules/$mod/module.prop" ] && [ "$mod" != "$(grep_prop id $MODPATH/module.prop)" ]; then
            ui_print " "
            ui_print " ✗ Conflicting module detected: $mod"
            ui_print " Please uninstall it first!"
            ui_print " "
            abort " Installation aborted"
        fi
    done
}

ui_print " "
ui_print " Version: $MODVER"
ui_print " Exynos Valhall GPU Driver - $DRIVER_VER"
ui_print " SoC: $SOC_NAME ($GPU_NAME)"
ui_print " "

check_conflicting_modules

sleep 1

set_perm_recursive $MODPATH/system/vendor 0 0 0755 0644 u:object_r:same_process_hal_file:s0
[ -d "$MODPATH/system/lib64" ] && set_perm_recursive $MODPATH/system/lib64 0 0 0755 0644 u:object_r:system_file:s0

# Keep compatibility payloads outside system/ in the archive. A platform must
# provide its own 64-bit runtime before any public OpenCL replacement or SPHAL
# patch is enabled.
SOC_NUM="${COMPAT_PLATFORM#exynos}"
COMPAT_OPENCL_READY=false
COMPAT_OPENCL_DIR="$MODPATH/compat_opencl"
COMPAT_RUNTIME_64=""

if [ -n "$SOC_NUM" ] && [ -f "$COMPAT_OPENCL_DIR/libOCLc.${SOC_NUM}.so" ]; then
    COMPAT_RUNTIME_64="$COMPAT_OPENCL_DIR/libOCLc.${SOC_NUM}.so"
elif [ -n "$COMPAT_PLATFORM" ] && [ -f "$COMPAT_OPENCL_DIR/libOCLc.${COMPAT_PLATFORM}.so" ]; then
    COMPAT_RUNTIME_64="$COMPAT_OPENCL_DIR/libOCLc.${COMPAT_PLATFORM}.so"
elif [ -n "$COMPAT_PLATFORM" ] && [ -f "$COMPAT_OPENCL_DIR/$COMPAT_PLATFORM/libOCLc.64.so" ]; then
    COMPAT_RUNTIME_64="$COMPAT_OPENCL_DIR/$COMPAT_PLATFORM/libOCLc.64.so"
fi

ARCSOFT_SO="/system/lib64/libsuperresolution.arcsoft.so"
LLHDR_SO="/system/lib64/liblow_light_hdr.arcsoft.so"
DUALCAM_REFOCUS_SO="/vendor/lib64/libdualcam_refocus_image.so"
HAS_SPHAL_OPENCL_CLIENT=false

for sp_hal_client in "$ARCSOFT_SO" "$LLHDR_SO" "$DUALCAM_REFOCUS_SO"; do
    if [ -f "$sp_hal_client" ]; then
        HAS_SPHAL_OPENCL_CLIENT=true
        break
    fi
done

if [ -n "$COMPAT_RUNTIME_64" ] && [ -f "$COMPAT_RUNTIME_64" ] && [ "$HAS_SPHAL_OPENCL_CLIENT" = true ]; then
    mkdir -p "$MODPATH/system/vendor/lib64"
    cp "$COMPAT_RUNTIME_64" "$MODPATH/system/vendor/lib64/libOCLc.so"
    set_perm "$MODPATH/system/vendor/lib64/libOCLc.so" 0 0 0644 u:object_r:same_process_hal_file:s0
    ui_print " - $SOC_NAME private OpenCL compatibility runtime"
    COMPAT_OPENCL_READY=true
elif [ "$HAS_SPHAL_OPENCL_CLIENT" = false ]; then
    ui_print " - No Samsung SPHAL OpenCL clients; keeping $DRIVER_VER OpenCL"
else
    ui_print " - No $SOC_NAME OpenCL compatibility runtime; keeping $DRIVER_VER OpenCL"
fi

# The selected payload is now staged below vendor. Do not retain unused
# platform runtimes in the installed module.
rm -rf "$MODPATH/compat_opencl"

# Direct OpenCL consumers bypass the public dispatcher by opening
# libOpenCL.so through the SPHAL namespace. NoMount cannot redirect that name
# because the stock symlink resolves to the driver blob before lookup. Patch only the
# verified loader argument in known matching binaries to libOCLc.so. These
# clients are optional: some supported devices do not ship every library.
patch_sphal_opencl_loader() {
    local label="$1"
    local source_file="$2"
    local module_file="$3"
    local expected_sha256="$4"
    local offset="$5"
    local selabel="$6"

    if [ ! -f "$source_file" ]; then
        ui_print " - Skipping $label SPHAL patch (library not shipped)"
        return 0
    fi

    actual_sha256=$(sha256sum "$source_file" | awk '{print $1}')
    actual_loader=$(dd if="$source_file" bs=1 skip="$offset" count=13 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$actual_sha256" != "$expected_sha256" ] && [ "$actual_loader" != "6c69624f434c632e736f000000" ] && [ "$actual_loader" != "6c69624f434c33382e736f0000" ]; then
        ui_print " - Skipping $label SPHAL patch (unrecognised binary)"
        return 0
    fi

    mkdir -p "$(dirname "$module_file")"
    cp "$source_file" "$module_file"
    printf 'libOCLc.so\0\0\0' | dd of="$module_file" bs=1 seek="$offset" conv=notrunc 2>/dev/null
    set_perm "$module_file" 0 0 0644 "$selabel"
    if [ "$actual_sha256" = "$expected_sha256" ]; then
        ui_print " - Patched $label SPHAL OpenCL loader to private runtime"
    else
        ui_print " - Reused existing $label SPHAL OpenCL override"
    fi
}

if [ "$COMPAT_OPENCL_READY" = true ]; then
    ARCSOFT_MOD_SO="$MODPATH/system/lib64/libsuperresolution.arcsoft.so"
    ARCSOFT_SHA256="b0c6dbb80ef29d79527982bfe3747d0646717625849fa5c6024068746afacff3"
    ARCSOFT_OFFSET=287457
    patch_sphal_opencl_loader "ArcSoft" "$ARCSOFT_SO" "$ARCSOFT_MOD_SO" "$ARCSOFT_SHA256" "$ARCSOFT_OFFSET" "u:object_r:system_file:s0"

    LLHDR_MOD_SO="$MODPATH/system/lib64/liblow_light_hdr.arcsoft.so"
    LLHDR_SHA256="90ad0c013698eaebccac5412ecaf9abea0c485f08a033aa002b51219c068cd37"
    LLHDR_OFFSET=138534
    patch_sphal_opencl_loader "LLHDR" "$LLHDR_SO" "$LLHDR_MOD_SO" "$LLHDR_SHA256" "$LLHDR_OFFSET" "u:object_r:system_file:s0"

    DUALCAM_REFOCUS_MOD_SO="$MODPATH/system/vendor/lib64/libdualcam_refocus_image.so"
    DUALCAM_REFOCUS_SHA256="035c1e78e2d3d6d73de3926290db1c505b7c8004e3d237d3477ec6c4dcca5748"
    DUALCAM_REFOCUS_OFFSET=251355
    patch_sphal_opencl_loader "DualCam refocus" "$DUALCAM_REFOCUS_SO" "$DUALCAM_REFOCUS_MOD_SO" "$DUALCAM_REFOCUS_SHA256" "$DUALCAM_REFOCUS_OFFSET" "u:object_r:same_process_hal_file:s0"
else
    ui_print " - Camera SPHAL OpenCL patches disabled"
fi

# Copy blob to root lib paths (replaces stock symlinks so NoMount can intercept).
# The optional OpenCL payload is already a regular file and must not be changed
# here: its public shim dispatches 64-bit OpenCL calls into private platform runtimes.
if [ -f "$MODPATH/system/vendor/lib64/egl/libGLES_mali.so" ]; then
    cp "$MODPATH/system/vendor/lib64/egl/libGLES_mali.so" "$MODPATH/system/vendor/lib64/libGLES_mali.so"
fi

if [ -z "$(getprop ro.bionic.2nd_arch)" ]; then
    ui_print " - 64-bit only device, removing 32-bit blobs"
    rm -rf $MODPATH/system/vendor/lib
else
    ui_print " - 32/64-bit device"
    if [ -f "$MODPATH/system/vendor/lib/egl/libGLES_mali.so" ]; then
        cp "$MODPATH/system/vendor/lib/egl/libGLES_mali.so" "$MODPATH/system/vendor/lib/libGLES_mali.so"
    fi
fi

# Strip bundled HAL support libs if already present on real vendor.
MODULE_ID=$(grep_prop id $MODPATH/module.prop)
MODULE_ACTIVE=false
if [ -d "/data/adb/modules/$MODULE_ID" ] && [ ! -f "/data/adb/modules/$MODULE_ID/update" ]; then
    MODULE_ACTIVE=true
fi

if [ "$MODULE_ACTIVE" = false ]; then
    if [ -f "/vendor/lib64/android.hardware.graphics.allocator-V2-ndk.so" ]; then
        ui_print " - Removing redundant 64-bit HAL support libs"
        rm -f $MODPATH/system/vendor/lib64/android.hardware.*.so
        rm -f $MODPATH/system/vendor/lib64/libcxx.so
        rm -f $MODPATH/system/vendor/lib64/libgralloctypes.so
    fi
    if [ -f "/vendor/lib/android.hardware.graphics.allocator-V2-ndk.so" ]; then
        ui_print " - Removing redundant 32-bit HAL support libs"
        rm -f $MODPATH/system/vendor/lib/android.hardware.*.so
        rm -f $MODPATH/system/vendor/lib/libcxx.so
        rm -f $MODPATH/system/vendor/lib/libgralloctypes.so
    fi
else
    ui_print " - Existing module detected, keeping bundled support libs"
fi

sleep 1

ui_print " - Success"
ui_print " "
ui_print " - Please reboot!"
ui_print " "
