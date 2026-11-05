# Exynos Valhall GPU Driver

KSU/Magisk module shipping updated Mali Valhall userspace drivers.

## Targets

All targets are tested on Exynos 2100 and 1280.

| Target | OpenCL runtimes | HAL support libs | Stable-C shim |
| --- | --- | --- | --- |
| `r38p1` | yes | no | no |
| `r49p1` | yes | yes | no |
| `r54p1` | yes | yes | yes |

## Platforms

| SoC | GPU | Stock OpenCL DDK |
| --- | --- | --- |
| Exynos 2100 | Mali-G78 | r38p0 |
| Exynos 1280 | Mali-G68 | r32p1 |
| Exynos 1380 | Mali-G68 | r38p1 |
| Exynos 1330 | Mali-G68 | r38p1 |

Exynos 1380 and 1330 ship r38p1 on stock, so the targets above serve the
first two.

## Layout

`sources/` holds code built from source in this repository. Run `make` in
`sources/stablec_shim` to produce the libraries the build consumes.

`sources_<target>/` holds the inputs for one target:

```
sources_<target>/
  vendor/mali/              libGLES_mali.so.64, libGLES_mali.so.32, NOTICE
  vendor/support/lib{,64}/  HAL support libraries
  vendor/vkshim/            vulkan.mali.64.so, vulkan.mali.32.so
  vendor/permissions/       Vulkan feature XML
  vendor/opencl_compat/     per-platform libOpenCL.64.so runtimes
```

Only the folder structure and helper files are tracked. Supply your own blobs
to build.

`opencl_compat` runtimes follow the stock DDK of each platform.

## Building

```
make -C sources/stablec_shim      # once, for r54p1 builds
./build.sh r54p1                  # one target
./build.sh all                    # r38p1 r49p1 r54p1
./build.sh all --skip-missing     # only targets with blobs
```

With no argument the script lists the targets and exits non-zero. `all`
stops at the first target with no blob unless `--skip-missing` is given.

Zips are written to the repository root as
`Exynos_Valhall_GPUDriver-<target>-<hash>-v1.0.0-<iteration>.zip`.
