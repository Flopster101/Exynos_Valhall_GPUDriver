# stable-C shim (mapper + binder interposer)

Lets stable-C Mali drivers (r54p1 and newer) run on pre-stable-C vendor
stacks (HIDL allocator/mapper era) without porting the vendor backend.

- `mapper.mali.so` (`src/mapper_shim.cpp`): AIMapper v5 table answering
  every query from the legacy gralloc handle. The driver dlopens it as
  `mapper.mali` (suffix comes from the fake allocator below).
- `libbinder_ml.so` (`src/binder_mali.cpp`): answers the driver's
  `IAllocator/default` lookup locally (version 2, suffix "mali").
  The driver's `DT_NEEDED libbinder_ndk.so` is patched to this lib.

Run `make` here first (NDK auto-detected, `NDK_BUNDLE=` to override).
It produces the top-level `mapper.mali.64.so` / `libbinder_ml.64.so`,
which are gitignored build outputs like the user-supplied blobs. The
module build consumes them and errors if they are missing. 64-bit
only; 32-bit stacks stay HIDL-era.
