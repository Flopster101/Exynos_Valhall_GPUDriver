#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES="$SCRIPT_DIR/sources"
OUTPUT="$SCRIPT_DIR/system"
MODULE_PROP="$SCRIPT_DIR/module.prop"

DRIVER_VER="r49p1"

BUILD_ITERATION="1"

# Get git hash if available
GIT_HASH=""
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_HASH=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)
fi

VER_STRING="v1.0.0-${BUILD_ITERATION}"

if [ -n "$GIT_HASH" ]; then
    ZIP_NAME="Exynos_Valhall_GPUDriver-${DRIVER_VER}-${GIT_HASH}-${VER_STRING}.zip"
else
    ZIP_NAME="Exynos_Valhall_GPUDriver-${DRIVER_VER}-${VER_STRING}.zip"
fi

echo ""
echo "Exynos Valhall GPU Driver — Build Script"
echo " Driver: $DRIVER_VER"
echo " Version: $VER_STRING"
echo ""

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/vendor"

# Check sources
MALI_64="$SOURCES/vendor/mali/libGLES_mali.so.64"
MALI_32="$SOURCES/vendor/mali/libGLES_mali.so.32"

if [ ! -f "$MALI_64" ]; then
    echo "Error: $MALI_64 not found!"
    echo "Place your Mali blob as sources/vendor/mali/libGLES_mali.so.64 and .32"
    exit 1
fi

# Mali blobs
echo "[1/4] Copying Mali blobs..."
mkdir -p "$OUTPUT/vendor/lib64/egl" "$OUTPUT/vendor/lib/egl"
cp "$MALI_64" "$OUTPUT/vendor/lib64/egl/libGLES_mali.so"
echo "  64-bit: $(stat -c%s "$OUTPUT/vendor/lib64/egl/libGLES_mali.so") bytes"

if [ -f "$MALI_32" ]; then
    cp "$MALI_32" "$OUTPUT/vendor/lib/egl/libGLES_mali.so"
    echo "  32-bit: $(stat -c%s "$OUTPUT/vendor/lib/egl/libGLES_mali.so") bytes"
else
    echo "  32-bit: not found, skipping"
fi

# HAL support libs
echo "[2/4] Copying HAL support libs..."
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

# Vulkan permission files
echo "[3/4] Copying Vulkan permission files..."
PERMS="$SOURCES/vendor/permissions"
if [ -d "$PERMS" ]; then
    mkdir -p "$OUTPUT/vendor/etc/permissions"
    for f in "$PERMS"/*.xml; do
        [ -f "$f" ] && cp "$f" "$OUTPUT/vendor/etc/permissions/" && echo "  $(basename $f)"
    done
fi

# Vulkan HAL shim (optional)
echo "[4/4] Copying Vulkan HAL shim (optional)..."
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

# Update module.prop version
sed -i "s/^version=.*/version=$VER_STRING/" "$MODULE_PROP"
sed -i "s/^versionCode=.*/versionCode=${BUILD_ITERATION}/" "$MODULE_PROP"

# Assemble module
echo ""
echo "Assembling module"
TEMP_DIR=$(mktemp -d)
STAGING="$TEMP_DIR/system/vendor"
mkdir -p "$STAGING"
cp -r "$OUTPUT/vendor"/* "$STAGING/"
cp "$SCRIPT_DIR/module.prop" "$TEMP_DIR/"
cp "$SCRIPT_DIR/customize.sh" "$TEMP_DIR/"
cp -r "$SCRIPT_DIR/META-INF" "$TEMP_DIR/"

# Copy LICENSE if present
[ -f "$SCRIPT_DIR/LICENSE" ] && cp "$SCRIPT_DIR/LICENSE" "$TEMP_DIR/"

cd "$TEMP_DIR"
zip -r "$SCRIPT_DIR/$ZIP_NAME" . -x "*.git*" > /dev/null
cd "$SCRIPT_DIR"

rm -rf "$TEMP_DIR"

echo "  Created: $ZIP_NAME"
echo "  Size: $(stat -c%s "$ZIP_NAME") bytes"
echo ""
echo "Build complete!"
