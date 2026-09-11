#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES="$SCRIPT_DIR/sources"
OUTPUT="$SCRIPT_DIR/system"
MODULE_PROP="$SCRIPT_DIR/module.prop"

DRIVER_VER="${1:-${DRIVER_VER:-r38p1}}"

BUILD_ITERATION="2"

# Get git hash if available
GIT_HASH=""
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_HASH=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)
fi

VER_STRING="v1.0.0-${BUILD_ITERATION}"
if [ -n "$GIT_HASH" ]; then
    VER_STRING="${VER_STRING}-${GIT_HASH}"
    ZIP_NAME="Exynos_Valhall_GPUDriver-${DRIVER_VER}-${GIT_HASH}-v1.0.0-${BUILD_ITERATION}.zip"
else
    ZIP_NAME="Exynos_Valhall_GPUDriver-${DRIVER_VER}-${VER_STRING}.zip"
fi

echo ""
echo "Exynos Valhall GPU Driver — Build Script"
echo " Driver: $DRIVER_VER"
echo " Version: $VER_STRING"
echo ""

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/vendor" "$OUTPUT/compat_opencl"

# Check sources
MALI_64="$SOURCES/vendor/mali/libGLES_mali.so.64"
MALI_32="$SOURCES/vendor/mali/libGLES_mali.so.32"

if [ ! -f "$MALI_64" ]; then
    echo "Error: $MALI_64 not found!"
    echo "Place your Mali blob as sources/vendor/mali/libGLES_mali.so.64 and .32"
    exit 1
fi

# Mali blobs
echo "[1/6] Copying Mali blobs..."
mkdir -p "$OUTPUT/vendor/lib64/egl" "$OUTPUT/vendor/lib/egl"
cp "$MALI_64" "$OUTPUT/vendor/lib64/egl/libGLES_mali.so"
echo "  64-bit: $(stat -c%s "$OUTPUT/vendor/lib64/egl/libGLES_mali.so") bytes"

if [ -f "$MALI_32" ]; then
    cp "$MALI_32" "$OUTPUT/vendor/lib/egl/libGLES_mali.so"
    echo "  32-bit: $(stat -c%s "$OUTPUT/vendor/lib/egl/libGLES_mali.so") bytes"
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
        exit 1
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
sed -i "s/^version=.*/version=$VER_STRING/" "$STAGING_MODULE_PROP"
sed -i "s/^versionCode=.*/versionCode=${BUILD_ITERATION}/" "$STAGING_MODULE_PROP"
sed -i "s/^name=.*/name=Exynos Valhall GPU Driver \[$DRIVER_VER\] (1280 \/ 2100)/" "$STAGING_MODULE_PROP"
sed -i "s/Updated Mali GPU driver/Updated Mali GPU driver ($DRIVER_VER)/" "$STAGING_MODULE_PROP"
if grep -q "^driverVersion=" "$STAGING_MODULE_PROP"; then
    sed -i "s/^driverVersion=.*/driverVersion=$DRIVER_VER/" "$STAGING_MODULE_PROP"
else
    echo "driverVersion=$DRIVER_VER" >> "$STAGING_MODULE_PROP"
fi

cp "$SCRIPT_DIR/customize.sh" "$TEMP_DIR/"
# Stamp the new-driver DDK tag for tag-patching (derived strings stay native).
SPHAL_STAMP_DDK="v1.${DRIVER_VER}"
SPHAL_STAMP_PREFIX="$(printf '%s' "$SPHAL_STAMP_DDK" | sed 's/[0-9][0-9]*$//')"
sed -i "s/^SPHAL_NEW_DDK=.*/SPHAL_NEW_DDK=\"$SPHAL_STAMP_DDK\"/" "$TEMP_DIR/customize.sh"
sed -i "s/^SPHAL_NEW_PREFIX=.*/SPHAL_NEW_PREFIX=\"$SPHAL_STAMP_PREFIX\"/" "$TEMP_DIR/customize.sh"
cp -r "$SCRIPT_DIR/META-INF" "$TEMP_DIR/"

# Copy LICENSE if present
[ -f "$SCRIPT_DIR/LICENSE" ] && cp "$SCRIPT_DIR/LICENSE" "$TEMP_DIR/"

# Copy optional NOTICE from blob sources if provided
if [ -f "$SOURCES/vendor/mali/NOTICE" ]; then
    cp "$SOURCES/vendor/mali/NOTICE" "$TEMP_DIR/"
elif [ -f "$SOURCES/NOTICE" ]; then
    cp "$SOURCES/NOTICE" "$TEMP_DIR/"
fi

cd "$TEMP_DIR"
rm -f "$SCRIPT_DIR/$ZIP_NAME"
zip -r "$SCRIPT_DIR/$ZIP_NAME" . -x "*.git*" > /dev/null
cd "$SCRIPT_DIR"

rm -rf "$TEMP_DIR"

echo "  Created: $ZIP_NAME"
echo "  Size: $(stat -c%s "$ZIP_NAME") bytes"
echo ""
echo "Build complete!"
