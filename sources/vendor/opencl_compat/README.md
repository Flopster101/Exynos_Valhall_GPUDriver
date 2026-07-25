# Platform OpenCL Compatibility Runtimes

The r49 EGL/Vulkan DDK can stay shared across supported Valhall devices, but
OpenCL compatibility must match the stock DDK family for each platform.

Place unmodified OpenCL libraries in the platform directory below. Both files
must have ELF SONAME `libOpenCL.so`.

| Platform | Stock OpenCL DDK | Directory |
| --- | --- | --- |
| Exynos 2100 | r38p1 | `exynos2100/` |
| Exynos 1280 | r32p1 | `exynos1280/` |
| Exynos 1380 | r38p1 | `exynos1380/` |
| Exynos 1330 | r38p1 | `exynos1330/` |

Required per enabled platform: `libOpenCL.64.so`.

An optional `libOpenCL.32.so` may be retained here for future 32-bit direct
SPHAL clients, but it is not packaged or mounted today. Public 32-bit and
64-bit `libOpenCL.so` calls remain on r49.

If a platform has no 64-bit runtime, its camera SPHAL patches are disabled.
The installer leaves r49 OpenCL untouched for that platform.

The build changes the staged 64-bit runtime's SONAME to `libOCLc.so`. Only the
patched SPHAL clients load this private file, so normal OpenCL users continue
to use r49 and the module carries one 64-bit compatibility runtime per enabled
platform.
