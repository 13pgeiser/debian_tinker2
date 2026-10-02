# AGENTS.md

Builds Debian (Bullseye default, Bookworm optional) SD card images for the Tinker Board 2 (RK3399, arm64). Patches are derived from Armbian (see `Readme.rst`).

## Building

- Full build: `./build.sh` (no args). No-args is also the only path that runs shfmt + shellcheck over all shell scripts.
- Single step: `./build.sh <step>`; steps in order: `rkbin uboot kernel debian_root sdcard release`. `release` zstds the image and moves it to `release/`.
- Root `./build.sh` is a host-side wrapper: inits the `bash-scripts` submodule, regenerates `docker/Dockerfile`, rebuilds the image, then runs `scripts/build.sh` inside a `--privileged` docker container (repo mounted at `/mnt`). Real build logic is in `scripts/build.sh`. The wrapper only forwards `$1` (one step per invocation, matching the CI workflow).
- Host prerequisites: docker or podman, sudo (wrapper runs `sudo modprobe loop` / `sudo losetup`).

## Dockerfile and helpers

- `docker/Dockerfile` is auto-generated (marked "DO NOT EDIT") and is rewritten on every `./build.sh` run. For persistent image changes: the heredoc appended in root `build.sh`, or the `bash-scripts` submodule.
- The `bash-scripts` git submodule provides all helper functions (`docker_*`, `git_clone`, `apply_patches`, `download_unpack`). It currently carries local uncommitted fixes in `helpers_docker.sh` (e2fsprogs, libelf-dev, lsb-release, qemu-user-binfmt); do not reset or checkout the submodule.

## Version pinning (fragile)

- Kernel selection is at the top of `scripts/build.sh`: `distrib=bullseye` → kernel 5.10 (`4.19` commented out due to drm issues; `bookworm` → 6.1). 4.19 comes from the official TinkerBoard2 tarball; 5.10/6.1 from kernel.org with pinned version + md5.
- DTB name differs per kernel: `rk3399-tinker_board_2.dtb` (4.19) vs `rk3399-tinker-2.dtb` (5.10/6.1). `boot.txt` is a template; the `setenv fdtfile` line is sed-replaced with the right DTB in the `sdcard` step.
- u-boot: pinned to `tags/v2021.07`, `tinker-2-rk3399_defconfig`. rkbin is cloned from `master`, but BL31/DDR/miniloader filenames are hardcoded (`rk3399_bl31_v1.36.elf`, `rk3399_ddr_800MHz_v1.30.bin`, `rk3399_miniloader_v1.30.bin`) — the build breaks if rkbin master renames them.

## Idempotency and caches

- Artifacts and markers live in gitignored `_tools/` (rkbin, u-boot, kernel tree, debian_root, sdcard.img). Marker files (`kernel_patched`, `kernel_built`, `u-boot/.patched`, `.<archive>`) make steps idempotent; delete them to force re-patching/rebuilding after changing patches or configs.
- `release/` is gitignored; the final artifact is `release/sdcard.img.zst`.

## Image internals (`sdcard` step)

- 2 GB GPT image: `uboot` / `trust` / `misc` / `root`; root is partition 4 (boot). Boots via `boot.scr` (mkimage of `boot.txt`), loading `/boot/Image` + dtb + `uInitrd`.
- Debian rootfs via `debootstrap --arch=arm64` (qemu-user-static binfmt). The kernel `.deb` from `make bindeb-pkg` is installed in the chroot's `third-stage` script via `dpkg -i /*.deb`, which also sets the root password (`root:toor`). The Dockerfile therefore needs arm64 cross toolchain (`crossbuild-essential-arm64`, `libssl-dev:arm64`).
- First boot runs one-shot, self-disabling systemd services `resize_root.service` and `regenerate_ssh_host_keys.service`.

## CI

- `.github/workflows/publish.yml` (on tag push): runs each build step as a separate `bash build.sh <step>` invocation, then uploads `release/*` as a GitHub release.
- `.buildbot` (custom CI): runs `./build.sh`, uploads `release/`.
