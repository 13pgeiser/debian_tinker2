#!/bin/bash
cd /mnt || exit 1
source bash-scripts/helpers.sh

###############################################################################
# Set globals
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export PLAT=rk3399

###############################################################################
# Build arm-trusted-firmware
git_clone \
	"arm-trusted-firmware" \
	"https://github.com/ARM-software/arm-trusted-firmware.git" \
	"tags/v2.8.0"
BL31="$(pwd)/arm-trusted-firmware/build/rk3399/release/bl31/bl31.elf"
if [ ! -e "$BL31" ]; then
	(
		cd arm-trusted-firmware || exit 1
		make distclean
		make PLAT=rk3399 bl31
	)
fi
if [ ! -e "$BL31" ]; then
	die "Could not build bl31.elf. Bailing out"
fi
export BL31

###############################################################################
# Build trust.img
git_clone \
	"rkbin" \
	"https://github.com/rockchip-linux/rkbin.git" \
	"master"
if [ ! -e rkbin/trust.img ]; then
	(
		cd rkbin || exit 1
		./tools/trust_merger RKTRUST/RK3399TRUST.ini
	)
fi
if [ ! -e rkbin/trust.img ]; then
	die "Could not create trust.img. Bailing out"
fi

###############################################################################
# Build u-boot
git_clone \
	"u-boot" \
	"https://github.com/u-boot/u-boot" \
	"tags/v2022.07"
apply_patches "u-boot" "$(pwd)/patches/u-boot"
if [ ! -e u-boot/u-boot ]; then
	(
		cd u-boot || exit 1
		make mrproper
		# Change baud rate to 115200 bps
		sed -i 's/^CONFIG_BAUDRATE.*/CONFIG_BAUDRATE\=115200/' configs/tinker-2-rk3399_defconfig
		cp -f "$BL31" .
		make tinker-2-rk3399_defconfig
		make -j"$(nproc)" BL31="$BL31"
		make -j"$(nproc)" BL31="$BL31" u-boot.itb
	)
fi

###############################################################################
# Prepare SD card
dd if=/dev/zero of=sdcard.img bs=1M count=32
cat <<EOT | /sbin/parted sdcard.img
mktable gpt
mkpart uboot ext4 16384s 24575s
mkpart trust ext4 24576s 32767s
mkpart misc ext4 32768s 40959s
mkpart root ext4 40960s 100%
set 4 boot on
quit
EOT
/sbin/parted sdcard.img print
/sbin/fdisk -l sdcard.img
# Copy rk3399_ddr_666MHz_v1.27.bin & rk3399_miniloader_v1.26.bin -> idbloader.img
./u-boot/tools/mkimage -n rk3399 -T rksd -d ./rkbin/bin/rk33/rk3399_ddr_666MHz_v1.27.bin idbloader.img
cat ./rkbin/bin/rk33/rk3399_miniloader_v1.26.bin >>idbloader.img
# Prepare uboot.img
./rkbin/tools/loaderimage --pack --uboot ./u-boot/u-boot-dtb.bin uboot.img 0x200000
# Write idbloader, uboot.img and trust.img
dd if=./idbloader.img of=sdcard.img seek=64 conv=notrunc
dd if=./uboot.img of=sdcard.img seek=16384 conv=notrunc
dd if=./rkbin/trust.img of=sdcard.img seek=24576 conv=notrunc
