# Android magisk customize.sh - Exynos Valhall GPU Driver

SOC=$(getprop ro.soc.model)
MODVER=$(grep_prop version $MODPATH/module.prop)
CHIP=$(getprop ro.hardware.chipname)
PLATFORM=$(getprop ro.board.platform)

# Detect SoC and set GPU name
case "$CHIP" in
    exynos2100|exynos2100_r)
        GPU_NAME="Mali-G78 MP14"
        SOC_NAME="Exynos 2100"
        ;;
    s5e8825|erd8825)
        GPU_NAME="Mali-G68 MP4"
        SOC_NAME="Exynos 1280"
        ;;
    *)
        case "$PLATFORM" in
            exynos2100|exynos2100_r)
                GPU_NAME="Mali-G78 MP14"
                SOC_NAME="Exynos 2100"
                ;;
            s5e8825|erd8825)
                GPU_NAME="Mali-G68 MP4"
                SOC_NAME="Exynos 1280"
                ;;
            *)
                GPU_NAME="Mali-G78/G68"
                SOC_NAME="Exynos 2100/1280"
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
ui_print " Exynos Valhall GPU Driver - r49p1"
ui_print " SoC: $SOC_NAME ($GPU_NAME)"
ui_print " "

check_conflicting_modules

sleep 1

set_perm_recursive $MODPATH/system/vendor 0 0 0755 0644 u:object_r:same_process_hal_file:s0

# Copy blob to root lib paths (replaces stock symlinks so NoMount can intercept)
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
