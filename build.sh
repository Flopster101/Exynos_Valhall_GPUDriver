#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Source-built artifacts only (stable-C shim). Never holds driver blobs.
BUILT="$SCRIPT_DIR/sources"
MODULE_PROP="$SCRIPT_DIR/module.prop"

BUILD_ITERATION="1"

VARIANT_ORDER="r38p1 r49p1 r54p1"

# Stable-C shim and the interposer DT_NEEDED patch are only needed by drivers
# that load the stable-C mapper. Everything else keeps the plain HIDL stack.
needs_stablec() {
    [ "$1" = "r54p1" ]
}

# Newer vendor images link a libc++ that no vendor namespace provides. Point
# the driver at the bundled copy under a distinct name so every other library
# keeps resolving the platform one.
patch_libcxx() {
    local so="$1" support="$2"
    [ -f "$support/libcxx.so" ] || return 0
    python3 - "$so" <<'EOF'
import sys
path = sys.argv[1]
with open(path, 'rb') as f:
    d = bytearray(f.read())
old, new = b"libc++.so", b"libcxx.so"
assert len(old) == len(new)
assert d.count(old) <= 1, "expected 0-1 libc++.so NEEDED"
i = d.find(old)
if i < 0:
    print("  libc++ already redirected, skipping")
else:
    d[i:i + len(old)] = new
    with open(path, 'wb') as f:
        f.write(d)
    print("  libc++ -> libcxx")
EOF
}

# Get git hash if available
GIT_HASH=""
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_HASH=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)
fi

usage() {
    echo "Usage: $0 <target|all> [--skip-missing]"
    echo "Targets: $VARIANT_ORDER"
}

build_target() {
    local DRIVER_VER="$1"
    local SOURCES="$SCRIPT_DIR/sources_$DRIVER_VER"
    local OUTPUT="$SCRIPT_DIR/system/$DRIVER_VER"

    local VER_STRING="v1.0.0-${BUILD_ITERATION}"
    local ZIP_NAME
    if [ -n "$GIT_HASH" ]; then
        VER_STRING="${VER_STRING}-${GIT_HASH}"
        ZIP_NAME="Exynos_Valhall_GPUDriver-${DRIVER_VER}-${GIT_HASH}-v1.0.0-${BUILD_ITERATION}.zip"
    else
        ZIP_NAME="Exynos_Valhall_GPUDriver-${DRIVER_VER}-${VER_STRING}.zip"
    fi

    local MODULE_ID="exynos_valhall_gpudriver"
    local MODULE_NAME="Exynos Valhall GPU Driver [$DRIVER_VER] (1280 / 2100)"
    local MODULE_AUTHOR="Flopster101"
    local MODULE_DESC="Updated Mali GPU driver ($DRIVER_VER) for Exynos 1280 (Mali-G68) and Exynos 2100 (Mali-G78)."

    echo ""
    echo "Exynos Valhall GPU Driver — Build Script"
    echo " Driver: $DRIVER_VER"
    echo " Version: $VER_STRING"
    echo ""

    rm -rf "$OUTPUT"
    mkdir -p "$OUTPUT/vendor" "$OUTPUT/compat_opencl"

    # Check sources
    local MALI_64="$SOURCES/vendor/mali/libGLES_mali.so.64"
    local MALI_32="$SOURCES/vendor/mali/libGLES_mali.so.32"

    if [ ! -f "$MALI_64" ]; then
        echo "Error: $MALI_64 not found!"
        echo "Place your Mali blobs as:"
        echo "  sources_$DRIVER_VER/vendor/mali/libGLES_mali.so.64"
        echo "  sources_$DRIVER_VER/vendor/mali/libGLES_mali.so.32"
        return 1
    fi

# Mali blobs
echo "[1/6] Copying Mali blobs..."
mkdir -p "$OUTPUT/vendor/lib64/egl" "$OUTPUT/vendor/lib/egl"
cp "$MALI_64" "$OUTPUT/vendor/lib64/egl/libGLES_mali.so"
echo "  64-bit: $(stat -c%s "$OUTPUT/vendor/lib64/egl/libGLES_mali.so") bytes"

# Stable-C 64-bit DT_NEEDED to the bundled interposer.
# 32-bit untouched.
if needs_stablec "$DRIVER_VER"; then
python3 - "$OUTPUT/vendor/lib64/egl/libGLES_mali.so" <<'EOF'
import sys
path = sys.argv[1]
with open(path, 'rb') as f:
    d = bytearray(f.read())

old, new = b"libbinder_ndk.so", b"libbinder_ml.so"
new = new + b"\0" * (len(old) - len(new))
idxs = []
i = 0
while True:
    i = d.find(old, i)
    if i < 0:
        break
    idxs.append(i)
    i += 1
assert len(idxs) <= 1, f"expected 0-1 DT_NEEDED, found {len(idxs)}"
if len(idxs) == 1:
    d[idxs[0]:idxs[0] + len(old)] = new
    print(f"  DT_NEEDED patched @ {hex(idxs[0])}")
    with open(path, 'wb') as f:
        f.write(d)
else:
    print("  DT_NEEDED already interposed, skipping")
EOF
fi
patch_libcxx "$OUTPUT/vendor/lib64/egl/libGLES_mali.so" "$SOURCES/vendor/support/lib64"

if [ -f "$MALI_32" ]; then
    cp "$MALI_32" "$OUTPUT/vendor/lib/egl/libGLES_mali.so"
    echo "  32-bit: $(stat -c%s "$OUTPUT/vendor/lib/egl/libGLES_mali.so") bytes"
    patch_libcxx "$OUTPUT/vendor/lib/egl/libGLES_mali.so" "$SOURCES/vendor/support/lib"
else
    echo "  32-bit: not found, skipping"
fi

# OpenCL compatibility is private to patched Samsung SPHAL clients. Normal
# public libOpenCL.so clients must continue using the main driver runtime.
echo "[2/6] Staging platform OpenCL compatibility payloads (optional)..."
OCL_COMPAT_ROOT="$SOURCES/vendor/opencl_compat"
OCL_COMPAT_PLATFORMS="exynos2100 exynos1280 exynos1380 exynos1330"
OCL_COMPAT_COUNT=0

OUTPUT_COMPAT="$OUTPUT/compat_opencl"
rm -rf "$OUTPUT_COMPAT"
mkdir -p "$OUTPUT_COMPAT"

for platform in $OCL_COMPAT_PLATFORMS; do
    platform_dir="$OCL_COMPAT_ROOT/$platform"
    runtime_64="$platform_dir/libOpenCL.64.so"
    if [ ! -f "$runtime_64" ]; then
        continue
    fi
    if ! readelf -d "$runtime_64" | grep -q 'Library soname: \[libOpenCL.so\]'; then
        echo "Error: $runtime_64 must have SONAME libOpenCL.so"
        return 1
    fi

    soc_num="${platform#exynos}"
    target_file="$OUTPUT_COMPAT/libOCLc.${soc_num}.so"
    cp "$runtime_64" "$target_file"
    patchelf --set-soname libOCLc.so "$target_file"
    if [ -f "$platform_dir/NOTICE" ]; then
        cp "$platform_dir/NOTICE" "$OUTPUT_COMPAT/NOTICE.${soc_num}"
    fi
    echo "  $platform: 64-bit compatibility runtime (libOCLc.${soc_num}.so)"
    OCL_COMPAT_COUNT=$((OCL_COMPAT_COUNT + 1))
done

if [ "$OCL_COMPAT_COUNT" -gt 0 ]; then
    echo "  Private runtime only; public OpenCL remains $DRIVER_VER"
else
    echo "  No platform compatibility runtime supplied; OpenCL patches disabled"
fi

# HAL support libs
echo "[3/6] Copying HAL support libs..."
SUPPORT_64="$SOURCES/vendor/support/lib64"
SUPPORT_32="$SOURCES/vendor/support/lib"

if [ -d "$SUPPORT_64" ]; then
    mkdir -p "$OUTPUT/vendor/lib64"
    for f in "$SUPPORT_64"/*.so; do
        [ -f "$f" ] && cp "$f" "$OUTPUT/vendor/lib64/" && echo "  64-bit: $(basename $f)"
    done
fi
if [ -d "$SUPPORT_32" ]; then
    mkdir -p "$OUTPUT/vendor/lib"
    for f in "$SUPPORT_32"/*.so; do
        [ -f "$f" ] && cp "$f" "$OUTPUT/vendor/lib/" && echo "  32-bit: $(basename $f)"
    done
fi

# Stable-C mapper shim + binder interposer (stable-C drivers only).
if needs_stablec "$DRIVER_VER"; then
    STABLEC_SHIM_DIR="$BUILT/stablec_shim"
    if [ ! -f "$STABLEC_SHIM_DIR/mapper.mali.64.so" ] || [ ! -f "$STABLEC_SHIM_DIR/libbinder_ml.64.so" ]; then
        echo "Error: stable-C shim not built. Run 'make' in $STABLEC_SHIM_DIR first."
        return 1
    fi
    mkdir -p "$OUTPUT/vendor/lib64/hw"
    cp "$STABLEC_SHIM_DIR/mapper.mali.64.so" "$OUTPUT/vendor/lib64/hw/mapper.mali.so"
    cp "$STABLEC_SHIM_DIR/libbinder_ml.64.so" "$OUTPUT/vendor/lib64/libbinder_ml.so"
    echo "  stable-C mapper shim + binder interposer installed"
fi

# These direct OpenCL clients hard-code the SPHAL library name. customize.sh
# copies and patches only matching files from the target device at install
# time, so a device never receives camera libraries it did not ship with.
echo "[4/6] Camera SPHAL patches are applied from device files at install time"

# Vulkan permission files
echo "[5/6] Copying Vulkan permission files..."
PERMS="$SOURCES/vendor/permissions"
if [ -d "$PERMS" ]; then
    mkdir -p "$OUTPUT/vendor/etc/permissions"
    for f in "$PERMS"/*.xml; do
        [ -f "$f" ] && cp "$f" "$OUTPUT/vendor/etc/permissions/" && echo "  $(basename $f)"
    done
fi

# Vulkan HAL shim (optional)
echo "[6/6] Copying Vulkan HAL shim (optional)..."
VKSHIM_64="$SOURCES/vendor/vkshim/vulkan.mali.64.so"
VKSHIM_32="$SOURCES/vendor/vkshim/vulkan.mali.32.so"

if [ -f "$VKSHIM_64" ] || [ -f "$VKSHIM_32" ]; then
    mkdir -p "$OUTPUT/vendor/lib64/hw" "$OUTPUT/vendor/lib/hw"
    if [ -f "$VKSHIM_64" ]; then
        cp "$VKSHIM_64" "$OUTPUT/vendor/lib64/hw/vulkan.mali.so"
        echo "  64-bit shim: $(stat -c%s "$OUTPUT/vendor/lib64/hw/vulkan.mali.so") bytes"
    fi
    if [ -f "$VKSHIM_32" ]; then
        cp "$VKSHIM_32" "$OUTPUT/vendor/lib/hw/vulkan.mali.so"
        echo "  32-bit shim: $(stat -c%s "$OUTPUT/vendor/lib/hw/vulkan.mali.so") bytes"
    fi
else
    echo "  No shim found -- module will use stock vulkan.mali.so stub"
fi

# Assemble module
echo ""
echo "Assembling module"
TEMP_DIR=$(mktemp -d)
STAGING_VENDOR="$TEMP_DIR/system/vendor"
mkdir -p "$STAGING_VENDOR"
cp -r "$OUTPUT/vendor"/* "$STAGING_VENDOR/"
if [ -n "$(find "$OUTPUT/compat_opencl" -mindepth 1 -print -quit)" ]; then
    cp -r "$OUTPUT/compat_opencl" "$TEMP_DIR/"
fi

# Generate build-time module.prop in staging directory from template
STAGING_MODULE_PROP="$TEMP_DIR/module.prop"
cp "$SCRIPT_DIR/module.prop" "$STAGING_MODULE_PROP"
sed -i "s|@ID@|$MODULE_ID|;s|@NAME@|$MODULE_NAME|;s|@VERSION_CODE@|$BUILD_ITERATION|;s|@VERSION@|$VER_STRING|;s|@AUTHOR@|$MODULE_AUTHOR|;s|@DESCRIPTION@|$MODULE_DESC|;s|@DRIVER_VERSION@|$DRIVER_VER|" "$STAGING_MODULE_PROP"
grep -q "@[A-Z_]*@" "$STAGING_MODULE_PROP" && { echo "Error: unreplaced token in module.prop"; return 1; }

cp "$SCRIPT_DIR/customize.sh" "$TEMP_DIR/"
# Stamp the new-driver DDK tag for tag-patching (derived strings stay native).
SPHAL_STAMP_DDK="v1.${DRIVER_VER}"
sed -i "s/^SPHAL_NEW_DDK=.*/SPHAL_NEW_DDK=\"$SPHAL_STAMP_DDK\"/" "$TEMP_DIR/customize.sh"
# Exact blob build (revisions share one DDK tag); JIT wipe keys on this.
SPHAL_STAMP_BUILD="$(strings -a "$MALI_64" 2>/dev/null | grep -a -o -m1 'U:r[0-9][0-9]*p[0-9][A-Za-z0-9_.-]*' || true)"
[ -n "$SPHAL_STAMP_BUILD" ] || SPHAL_STAMP_BUILD="$SPHAL_STAMP_DDK"
sed -i "s/^SPHAL_DRIVER_BUILD=.*/SPHAL_DRIVER_BUILD=\"$SPHAL_STAMP_BUILD\"/" "$TEMP_DIR/customize.sh"
cp -r "$SCRIPT_DIR/META-INF" "$TEMP_DIR/"

# Copy LICENSE if present
[ -f "$SCRIPT_DIR/LICENSE" ] && cp "$SCRIPT_DIR/LICENSE" "$TEMP_DIR/"

# Copy optional NOTICE from blob sources if provided
if [ -f "$SOURCES/vendor/mali/NOTICE" ]; then
    cp "$SOURCES/vendor/mali/NOTICE" "$TEMP_DIR/"
elif [ -f "$SOURCES/NOTICE" ]; then
    cp "$SOURCES/NOTICE" "$TEMP_DIR/"
fi

# Record every file this build installs. The installer prunes anything not
# listed, so flashing a different DDK version cannot leave stale payloads.
(cd "$TEMP_DIR" && find system -type f | LC_ALL=C sort) > "$TEMP_DIR/.manifest"

cd "$TEMP_DIR"
rm -f "$SCRIPT_DIR/$ZIP_NAME"
zip -r "$SCRIPT_DIR/$ZIP_NAME" . -x "*.git*" > /dev/null
cd "$SCRIPT_DIR"

rm -rf "$TEMP_DIR"

echo "  Created: $ZIP_NAME"
echo "  Size: $(stat -c%s "$ZIP_NAME") bytes"
echo ""
echo "Build complete!"
}

TARGET=""
SKIP_MISSING=no
for arg in "$@"; do
    case "$arg" in
        --skip-missing) SKIP_MISSING=yes ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: unknown option $arg"; usage; exit 2 ;;
        *) TARGET="$arg" ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "Error: no target specified."
    echo "Available: $VARIANT_ORDER"
    usage
    exit 1
fi

if [ "$TARGET" = "all" ]; then
    if [ "$SKIP_MISSING" = "no" ]; then
        for v in $VARIANT_ORDER; do
            if [ ! -f "$SCRIPT_DIR/sources_$v/vendor/mali/libGLES_mali.so.64" ]; then
                echo "Error: missing blob for $v"
                echo "  expected: sources_$v/vendor/mali/libGLES_mali.so.64"
                echo "  use --skip-missing to build only the targets that are set up"
                exit 1
            fi
        done
    fi
    for v in $VARIANT_ORDER; do
        if [ ! -f "$SCRIPT_DIR/sources_$v/vendor/mali/libGLES_mali.so.64" ]; then
            echo ""
            echo "Skipping $v (no blob)"
            continue
        fi
        build_target "$v"
    done
else
    case " $VARIANT_ORDER " in
        *" $TARGET "*) ;;
        *) echo "Error: unknown target '$TARGET'"; usage; exit 2 ;;
    esac
    build_target "$TARGET"
fi
