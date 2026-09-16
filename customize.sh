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

# Compatibility payload present? Actual staging happens after the SPHAL
# scan: with no clients (e.g. AOSP), the runtime is not staged at all.
if [ -n "$COMPAT_RUNTIME_64" ] && [ -f "$COMPAT_RUNTIME_64" ]; then
    COMPAT_OPENCL_READY=true
else
    ui_print " - No $SOC_NAME OpenCL compatibility runtime; keeping $DRIVER_VER OpenCL"
fi

# KMD (kbase) compatibility check
# $DRIVER_VER userspace needs a same-era Mali KMD; older KMDs break
# stuff. Warn-only: GL/HWUI still run on older KMDs usually.
KMD_VER="$(cat /sys/module/mali_kbase/version 2>/dev/null)"
KMD_VER="${KMD_VER%% \(*}"
KMD_VER="${KMD_VER%"${KMD_VER##*[![:space:]]}"}"
KMD_FLOPPY=no
case "$(uname -r 2>/dev/null)" in
    *Floppy*) KMD_FLOPPY=yes ;;
esac
if [ -z "$KMD_VER" ]; then
    ui_print " ⚠️ Could not read /sys/module/mali_kbase/version!"
else
    KMD_OK=no
    case "$DRIVER_VER" in
        r54p1) case "$KMD_VER" in r5*p*)       KMD_OK=yes ;; esac ;;
        r49p1) case "$KMD_VER" in r44p*|r49p1*) KMD_OK=yes ;; esac ;;
        r38p1) case "$KMD_VER" in r38p*)       KMD_OK=yes ;; esac ;;
    esac
    if [ "$KMD_OK" = yes ]; then
        ui_print " ✅ Detected Mali KMD: $KMD_VER"
    else
        ui_print " "
        ui_print " ⚠️ Detected Mali KMD: $KMD_VER"
        ui_print " ! Your kernel driver is outdated!"
        if [ "$KMD_FLOPPY" = yes ]; then
            ui_print " ! Fix: switch KMD via FloppyCompanion or a"
            ui_print " ! MaliVersion patcher, then reboot."
        else
            ui_print " ! Fix: flash a kernel with a compatible Mali KMD."
        fi
        ui_print " "
    fi
fi
# Busybox tools ($BB_BIN); installer PATH may use toybox instead.
# Never grep -b: busybox grep has no byte-offset flag.
BB_BIN=""
for _bb_cand in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    if [ -x "$_bb_cand" ]; then
        BB_BIN="$_bb_cand"
        break
    fi
done
if [ -z "$BB_BIN" ] && command -v busybox >/dev/null 2>&1; then
    BB_BIN="busybox"
fi
if [ -z "$BB_BIN" ]; then
    ui_print " ! No busybox found; SPHAL patcher will use system tools (may fail)"
fi
# Slow fallback: od hex output -> match offsets (trailing 00 is the check).
SPHAL_FIND_AWK='BEGIN { n=0; s=0; start=0; split("69 62 4f 70 65 6e 43 4c 2e 73 6f 00", w, " ") } { for (i = 1; i <= NF; i++) { b=$i; o=n; n++; if (s == 0) { if (b == "6c") { s=1; start=o } } else if (b == w[s]) { s++; if (s > 12) { print start; s=0 } } else if (b == "6c") { s=1; start=o } else { s=0 } } }'

# Fast locator: strings offsets -> file offsets (NUL re-checked by caller).
SPHAL_OFFS_AWK='{ o=$1+0; sub(/^ *[^ ]+ +/, ""); base=o; line=$0; while ((p=index(line, "libOpenCL.so")) > 0) { print base+p-1; line=substr(line, p+1); base+=p } }'
SPHAL_OFFS2_AWK='{ o=$1+0; sub(/^ *[^ ]+ +/, ""); base=o; line=$0; while ((p=index(line, "libGLES_mali.so")) > 0) { print base+p-1; line=substr(line, p+1); base+=p } }'

# New-driver DDK tag (build.sh stamps it from DRIVER_VER). Only the snap
# JIT cache-wipe key derives from it.
SPHAL_NEW_DDK="v1.r54p1"
SPHAL_DRIVER_BUILD=""

# Snap has no whitelist; armnn needs the stock compiler.
SPHAL_SNAP="libsnap_compute.so libsnap_compute_secure.so"
_sphal_snap() {
    case " $SPHAL_SNAP " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# Set to yes by the scan probe when `strings -a -t d` works end to end.
SPHAL_USE_STRINGS=no

# Rewrites "libOpenCL.so\0" -> "libOCLc.so\0\0\0" in place (same 13 bytes).
patch_sphal_binary() {
    local src="$1" dst="$2" selabel="$3"
    local name offsets count offset _runs _cands _o _b
    name="$(basename "$src")"

    [ ! -f "$src" ] && return 0

    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"

    count=0
    if [ "$SPHAL_USE_STRINGS" = yes ]; then
        # Fast path: strings lists candidates, 1-byte dd checks NUL.
        _runs=$(strings -a -t d "$dst" 2>/dev/null | $BB_BIN grep -F "libOpenCL.so" || true)
        if [ -n "$_runs" ]; then
            _cands=$(printf '%s\n' "$_runs" | $BB_BIN awk "$SPHAL_OFFS_AWK" || true)
            for _o in $_cands; do
                _b=$($BB_BIN dd if="$dst" bs=1 skip=$((_o + 12)) count=1 2>/dev/null \
                    | $BB_BIN od -t x1 | $BB_BIN awk 'NR==1{print $2}')
                if [ "$_b" = "00" ]; then
                    $BB_BIN printf 'libOCLc.so\000\000\000' | $BB_BIN dd of="$dst" bs=1 seek="$_o" \
                                                         conv=notrunc 2>/dev/null
                    count=$((count + 1))
                fi
            done
            # Snap fallback name: same 16 bytes, 5 pad NULs.
            if _sphal_snap "$name"; then
                _runs=$(strings -a -t d "$dst" 2>/dev/null | $BB_BIN grep -F "libGLES_mali.so" || true)
                if [ -n "$_runs" ]; then
                    _cands=$(printf '%s\n' "$_runs" | $BB_BIN awk "$SPHAL_OFFS2_AWK" || true)
                    for _o in $_cands; do
                        _b=$($BB_BIN dd if="$dst" bs=1 skip=$((_o + 15)) count=1 2>/dev/null \
                            | $BB_BIN od -t x1 | $BB_BIN awk 'NR==1{print $2}')
                        if [ "$_b" = "00" ]; then
                            $BB_BIN printf 'libOCLc.so\000\000\000\000\000\000' | $BB_BIN dd of="$dst" bs=1 seek="$_o" \
                                                                 conv=notrunc 2>/dev/null
                            count=$((count + 1))
                        fi
                    done
                fi
            fi
        fi
    else
        # Fallback: od+awk finds offsets (slow on big libs, always works).
        offsets=$($BB_BIN od -A n -t x1 -v "$dst" 2>/dev/null | $BB_BIN awk "$SPHAL_FIND_AWK" || true)
        for offset in $offsets; do
            # \000 octal: portable across printf builtins (bare \0 is not).
            $BB_BIN printf 'libOCLc.so\000\000\000' | $BB_BIN dd of="$dst" bs=1 seek="$offset" \
                                         conv=notrunc 2>/dev/null
            count=$((count + 1))
        done
    fi

    if [ "$count" -gt 0 ]; then
        set_perm "$dst" 0 0 0644 "$selabel"
        ui_print " - Patched $name"
    else
        rm -f "$dst"
    fi
}

# Every OpenCL client (camera post-processing, ArcSoft, snap) runs on the
# stock compat runtime: these libs ship with the ROM and are built for it.
# Whitelist tag-patching for the new driver was never needed and re-arms
# the fail-closed path. Skips driver libs.

scan_and_patch_dir() {
    local device_dir="$1" module_dir="$2" selabel="$3"
    local src name scanned matched
    # patched is global: it feeds the runtime-staging decision below.

    [ ! -d "$device_dir" ] && { ui_print " ! SPHAL scan dir missing: $device_dir"; return 0; }

    # Probe strings support; else use the od+awk fallback.
    SPHAL_USE_STRINGS=no
    if command -v strings >/dev/null 2>&1; then
        mkdir -p "$module_dir"
        printf 'xlibOpenCL.so\000y' > "$module_dir/.sphal_probe" 2>/dev/null
        if [ -f "$module_dir/.sphal_probe" ] \
           && strings -a -t d "$module_dir/.sphal_probe" 2>/dev/null \
              | $BB_BIN grep -q -F "libOpenCL.so"; then
            SPHAL_USE_STRINGS=yes
        fi
        rm -f "$module_dir/.sphal_probe"
    fi

    # ONE grep (-f patterns; -e/-- are broken here) prefilters the dir.
    scanned=0
    matched=0
    patched=0
    mkdir -p "$module_dir"
    _spf="$module_dir/.sphal_patterns"
    printf 'libOpenCL.so\nlibOCLc.so\n' > "$_spf" 2>/dev/null
    candidates=$($BB_BIN grep -l -a -F -s -f "$_spf" "$device_dir"/lib*.so 2>/dev/null || true)
    rm -f "$_spf"
    if [ -z "$candidates" ]; then
        for src in "$device_dir"/lib*.so; do
            [ -f "$src" ] || continue
            name="$(basename "$src")"
            case "$name" in
                libGLES_mali.so|libOpenCL.so|libOCLc.so|libMali.so|libtensorflowlite_gpu_jni.so) continue ;;
            esac
            scanned=$((scanned + 1))
            if $BB_BIN grep -q -a -F "libOpenCL.so" "$src" 2>/dev/null; then
                matched=$((matched + 1))
                patch_sphal_binary "$src" "$module_dir/$name" "$selabel"
                [ -f "$module_dir/$name" ] && patched=$((patched + 1))
            fi
            # Carry forward already-redirected bytes across updates.
            if [ ! -f "$module_dir/$name" ] && $BB_BIN grep -q -a -F "libOCLc.so" "$src" 2>/dev/null; then
                cp "$src" "$module_dir/$name"
                set_perm "$module_dir/$name" 0 0 0644 "$selabel"
                ui_print " - Carried forward $name"
                patched=$((patched + 1))
            fi
        done
    else
        _n=$(printf '%s' "$candidates" | $BB_BIN grep -c '^')
        ui_print " - SPHAL: $_n candidate files, patching..."
        _oldifs="$IFS"; IFS="
";
        for src in $candidates; do
            IFS="$_oldifs"
            case "$src" in *.so) ;; *) continue ;; esac
            [ -f "$src" ] || continue
            name="$(basename "$src")"
            case "$name" in
                libGLES_mali.so|libOpenCL.so|libOCLc.so|libMali.so|libtensorflowlite_gpu_jni.so) continue ;;
            esac
            scanned=$((scanned + 1))
            if $BB_BIN grep -q -a -F "libOpenCL.so" "$src" 2>/dev/null; then
                matched=$((matched + 1))
                patch_sphal_binary "$src" "$module_dir/$name" "$selabel"
                [ -f "$module_dir/$name" ] && patched=$((patched + 1))
            fi
            # Carry forward already-redirected bytes across updates.
            if [ ! -f "$module_dir/$name" ] && $BB_BIN grep -q -a -F "libOCLc.so" "$src" 2>/dev/null; then
                cp "$src" "$module_dir/$name"
                set_perm "$module_dir/$name" 0 0 0644 "$selabel"
                ui_print " - Carried forward $name"
                patched=$((patched + 1))
            fi
        done
        IFS="$_oldifs"
    fi
    ui_print " - SPHAL scan: $scanned checked, $matched with refs, $patched patched/carried"
    SPHAL_PATCHED_TOTAL=$((SPHAL_PATCHED_TOTAL + patched))
}

if [ "$COMPAT_OPENCL_READY" = true ]; then
    SPHAL_PATCHED_TOTAL=0
    ui_print " - Scanning for SPHAL OpenCL clients..."
    # System libraries (camera post-processing, vision, ArcSoft, etc.)
    scan_and_patch_dir "/system/lib64" \
                       "$MODPATH/system/lib64" \
                       "u:object_r:system_file:s0"
    # Vendor libraries (dualcam refocus/bokeh, night, VDIS, etc.). The stock
    # libOpenCL.so symlinks resolve to the replaced blob, so these need the
    # same redirection as the system clients.
    scan_and_patch_dir "/vendor/lib64" \
                       "$MODPATH/system/vendor/lib64" \
                       "u:object_r:same_process_hal_file:s0"
    if [ "$SPHAL_PATCHED_TOTAL" -gt 0 ]; then
        mkdir -p "$MODPATH/system/vendor/lib64"
        cp "$COMPAT_RUNTIME_64" "$MODPATH/system/vendor/lib64/libOCLc.so"
        set_perm "$MODPATH/system/vendor/lib64/libOCLc.so" 0 0 0644 \
                 u:object_r:same_process_hal_file:s0
        _pub_libs="/vendor/etc/public.libraries.txt"
        if [ -f "$_pub_libs" ]; then
            mkdir -p "$MODPATH/system/vendor/etc"
            umount "$_pub_libs" 2>/dev/null
            if grep -q "libOCLc.so" "$_pub_libs"; then
                cp "$_pub_libs" "$MODPATH/system/vendor/etc/public.libraries.txt"
            else
                { cat "$_pub_libs"; printf '\nlibOCLc.so\n'; } \
                    > "$MODPATH/system/vendor/etc/public.libraries.txt"
            fi
            set_perm "$MODPATH/system/vendor/etc/public.libraries.txt" \
                     0 0 0644 u:object_r:vendor_configs_file:s0
            ui_print " - libOCLc.so exposed to app namespaces"
        fi
        ui_print " - $SOC_NAME private OpenCL compatibility runtime"
        # Stale snap JIT wedges processing; wipe once per blob build.
        [ -n "$SPHAL_DRIVER_BUILD" ] || SPHAL_DRIVER_BUILD="$SPHAL_NEW_DDK"
        if [ -d /data/vendor/snap ]; then
            _sphal_ver="$(cat /data/vendor/snap/.sphal_ddk 2>/dev/null)"
            if [ "$_sphal_ver" != "$SPHAL_DRIVER_BUILD" ]; then
                rm -f /data/vendor/snap/snap_gpu_kernel_64.bin \
                      /data/vendor/snap/snaplite_cache.bin \
                      /data/vendor/snap/*cache* 2>/dev/null
                printf '%s' "$SPHAL_DRIVER_BUILD" > /data/vendor/snap/.sphal_ddk 2>/dev/null
            fi
        fi
    else
        ui_print " - No OpenCL clients; keeping $DRIVER_VER OpenCL native"
    fi
    # Fix perms for dirs created after the early set_perm_recursive.
    [ -d "$MODPATH/system/lib64" ] && set_perm_recursive $MODPATH/system/lib64 0 0 0755 0644 u:object_r:system_file:s0
    [ -d "$MODPATH/system/vendor/lib64" ] && set_perm_recursive $MODPATH/system/vendor/lib64 0 0 0755 0644 u:object_r:same_process_hal_file:s0
else
    ui_print " - Camera SPHAL OpenCL patches disabled"
fi
rm -rf "$MODPATH/compat_opencl"

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
