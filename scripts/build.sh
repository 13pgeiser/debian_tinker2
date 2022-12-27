#!/bin/bash
set -ex
cd /mnt || exit 1
source bash-scripts/helpers.sh

###############################################################################
# Set globals
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export PLAT=rk3399
BL31="$TOOLS_FOLDER/arm-trusted-firmware/build/rk3399/release/bl31/bl31.elf"

###############################################################################
# Build arm-trusted-firmware
arm_trusted() {
	git_clone \
		"arm-trusted-firmware" \
		"https://github.com/ARM-software/arm-trusted-firmware.git" \
		"tags/v2.8.0"

	if [ ! -e "$BL31" ]; then
		(
			cd "$TOOLS_FOLDER/arm-trusted-firmware" || exit 1
			make distclean
			make PLAT=rk3399 bl31
		)
	fi
	if [ ! -e "$BL31" ]; then
		die "Could not build bl31.elf. Bailing out"
	fi
}

###############################################################################
# Build trust.img
trust_img() {
	git_clone \
		"rkbin" \
		"https://github.com/rockchip-linux/rkbin.git" \
		"master"
	if [ ! -e "$TOOLS_FOLDER/rkbin/trust.img" ]; then
		(
			cd "$TOOLS_FOLDER/rkbin" || exit 1
			./tools/trust_merger RKTRUST/RK3399TRUST.ini
		)
	fi
	if [ ! -e "$TOOLS_FOLDER/rkbin/trust.img" ]; then
		die "Could not create trust.img. Bailing out"
	fi
}

###############################################################################
# Build u-boot
uboot() {
	git_clone \
		"u-boot" \
		"https://github.com/u-boot/u-boot" \
		"tags/v2022.07"
	apply_patches "$TOOLS_FOLDER/u-boot" "$(pwd)/patches/u-boot"
	if [ ! -e "$TOOLS_FOLDER/u-boot/u-boot" ]; then
		(
			export BL31
			cd "$TOOLS_FOLDER/u-boot" || exit 1
			make mrproper
			# Change baud rate to 115200 bps
			sed -i 's/^CONFIG_BAUDRATE.*/CONFIG_BAUDRATE\=115200/' configs/tinker-2-rk3399_defconfig
			cp -f "$BL31" .
			make tinker-2-rk3399_defconfig
			make -j"$(nproc)" BL31="$BL31"
			make -j"$(nproc)" BL31="$BL31" u-boot.itb
		)
	fi
	if [ ! -e "$TOOLS_FOLDER/u-boot/u-boot" ]; then
		die "Could not build u-boot. Bailing out"
	fi
}

###############################################################################
# Builder Asus tinker2 kernel
kernel_version="TinkerBoard2-kernel-d4aa6a0"
kernel_folder="$TOOLS_FOLDER/$kernel_version"
dtb="$kernel_folder/arch/arm64/boot/dts/rockchip/rk3399-tinker_board_2.dtb"
kernel() {
	download_unpack \
		"dd0ec71e8848bd1a5ab48a782238b7cf" \
		"https://github.com/TinkerBoard2/kernel/tarball/linux4.19-rk3399-debian10" \
		"e" \
		"TinkerBoard2-kernel-tinker_board_2-debian_10-2.1.6-3471-gd4aa6a0.tar.gz" \
		"$kernel_version"
	if [ ! -e "$TOOLS_FOLDER/kernel_built" ]; then
		(
			cd "$kernel_folder" || exit 1
			make tinker_board_2_defconfig
			make rockchip/rk3399-tinker_board_2.dtb
			make Image -j"$(nproc)"
			make bindeb-pkg "-j$(nproc)"
		)
		touch "$TOOLS_FOLDER/kernel_built"
	fi
	if [ ! -e "$TOOLS_FOLDER/kernel_built" ]; then
		die "Could not build kernel. Bailing out"
	fi
}

###############################################################################
# Get debian root
debian_root() {
	if [ ! -d "$TOOLS_FOLDER/debian_root" ]; then
		(
			cd "$TOOLS_FOLDER" || exit 1
			# Make sure qemu-arm can execute transparently ARM binaries.
			sudo mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc
			sudo update-binfmts --enable qemu-arm
			sudo /etc/init.d/binfmt-support start
			# Extract debian!
			sudo debootstrap --arch=arm64 bullseye debian_root http://httpredir.debian.org/debian
		)
	fi
}

###############################################################################
# Prepare SD card
sdcard() {
	dd if=/dev/zero of="$TOOLS_FOLDER/sdcard.img" bs=1M count=2048
	cat <<EOF | /sbin/parted "$TOOLS_FOLDER/sdcard.img"
	mktable gpt
	mkpart uboot ext4 16384s 24575s
	mkpart trust ext4 24576s 32767s
	mkpart misc ext4 32768s 40959s
	mkpart root ext4 40960s 100%
	set 4 boot on
	quit
EOF
	/sbin/parted "$TOOLS_FOLDER/sdcard.img" print
	/sbin/fdisk -l "$TOOLS_FOLDER/sdcard.img"

	# Copy rk3399_ddr_666MHz_v1.27.bin & rk3399_miniloader_v1.26.bin -> idbloader.img
	"$TOOLS_FOLDER//u-boot/tools/mkimage" -n rk3399 -T rksd -d "$TOOLS_FOLDER/rkbin/bin/rk33/rk3399_ddr_666MHz_v1.27.bin" "$TOOLS_FOLDER/idbloader.img"
	cat "$TOOLS_FOLDER/rkbin/bin/rk33/rk3399_miniloader_v1.26.bin" >>"$TOOLS_FOLDER/idbloader.img"
	# Prepare uboot.img
	"$TOOLS_FOLDER/rkbin/tools/loaderimage" --pack --uboot "$TOOLS_FOLDER//u-boot/u-boot-dtb.bin" "$TOOLS_FOLDER/uboot.img" 0x200000
	# Write idbloader, uboot.img and trust.img
	dd if="$TOOLS_FOLDER/idbloader.img" of="$TOOLS_FOLDER/sdcard.img" seek=64 conv=notrunc
	dd if="$TOOLS_FOLDER/uboot.img" of="$TOOLS_FOLDER/sdcard.img" seek=16384 conv=notrunc
	dd if="$TOOLS_FOLDER/rkbin/trust.img" of="$TOOLS_FOLDER/sdcard.img" seek=24576 conv=notrunc

	# Create u-boot boot script
	mkimage -A arm -O linux -T script -C none -n "U-Boot boot script" -d boot.txt "$TOOLS_FOLDER/boot.scr"

	# Create loop device partitions (for docker)...
	loop="$(sudo losetup -f --show -P "$TOOLS_FOLDER/sdcard.img")"
	echo "loop device: $loop"
	sudo lsblk --raw --noheadings "$loop" | tail -n +2 | while IFS= read -r line; do
		dev="$(echo "$line" | cut -d' ' -f1)"
		major_minor="$(echo "$line" | cut -d' ' -f2)"
		major="$(echo "$major_minor" | cut -d: -f1)"
		minor="$(echo "$major_minor" | cut -d: -f2)"
		if [ ! -e "/dev/$dev" ]; then
			echo "mknod /dev/$dev b $major $minor"
			sudo mknod "/dev/$dev" b "$major" "$minor"
		fi
	done

	run_in_chroot() {
		sudo mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc
		sudo update-binfmts --enable qemu-arm
		sudo /etc/init.d/binfmt-support start
		sudo mount -t proc proc /media/proc
		sudo mount -o bind /dev/ /media/dev/
		sudo mount -o bind /dev/pts /media/dev/pts
		sudo chmod +x /media/root/third-stage
		sudo LANG=C chroot /media /root/third-stage
		sudo umount /media/dev/pts
		sudo umount /media/dev/
		sudo umount /media/proc
		sudo rm -f debian_root/root/third-stage
		sudo rm -f /media/root/.bash_history
	}

	# create filesystem and copy files.
	sudo mkfs.ext4 -L root "${loop}p4"
	sudo mount "${loop}p4" /media
	sudo mkdir -p /media/boot/dtbs/rockchip/
	sudo cp "$dtb" /media/boot/dtbs/rockchip/
	sudo cp "$kernel_folder/arch/arm64/boot/Image" /media/boot
	sudo cp "$TOOLS_FOLDER/boot.scr" /media/boot/
	sudo rsync -ax "$TOOLS_FOLDER"/debian_root/* /media
	sudo cp "$TOOLS_FOLDER"/*.deb /media/

	# Update Apt sources for bullseye
	sudo bash -c 'cat >/media/etc/apt/sources.list' <<'EOF'
	deb http://httpredir.debian.org/debian bullseye main non-free contrib
	deb-src http://httpredir.debian.org/debian bullseye main non-free contrib
	deb https://security.debian.org/debian-security bullseye-security main contrib non-free
EOF

	# Add loopback interface
	sudo mkdir -p /media/etc/network
	sudo bash -c 'cat >/media/etc/network/interfaces' <<'EOF'
	auto lo
	iface lo inet loopback
EOF

	# Make sure to get new SSH keys on installation
	# Taken as-is from https://github.com/RPi-Distro/raspberrypi-sys-mods/blob/master/debian/raspberrypi-sys-mods.regenerate_ssh_host_keys.service
	sudo bash -c 'cat >/media/etc/systemd/system/regenerate_ssh_host_keys.service' <<'EOF'
	[Unit]
	Description=Regenerate SSH host keys
	Before=ssh.service
	ConditionFileIsExecutable=/usr/bin/ssh-keygen

	[Service]
	Type=oneshot
	ExecStartPre=-/bin/dd if=/dev/hwrng of=/dev/urandom count=1 bs=4096
	ExecStartPre=-/bin/sh -c "/bin/rm -f -v /etc/ssh/ssh_host_*_key*"
	ExecStart=/usr/bin/ssh-keygen -A -v
	ExecStartPost=/bin/systemctl disable regenerate_ssh_host_keys

	[Install]
	WantedBy=multi-user.target
EOF

	sudo bash -c 'cat >/media/root/resize.sh' <<'EOF'
	#!/bin/bash
	BOOT_PART="$(mount | grep 'on / type' | cut -d' ' -f1)"
	echo "BOOT_PART: $BOOT_PART"
	BOOT_DEV="/dev/$(lsblk -no pkname "$BOOT_PART")"
	echo "BOOT_DEV: $BOOT_DEV"
	BLOCK_DEV="$(echo "$BOOT_PART" | cut -d'/' -f3)"
	echo "BLOCK_DEV $BLOCK_DEV"
	PART_NUM="$(cat /sys/class/block/$BLOCK_DEV/partition)"
	printf "fix\n" | parted ---pretend-input-tty "$BOOT_DEV" print
	parted -s "$BOOT_DEV" "resizepart $PART_NUM -1" quit
	partprobe
	resize2fs "$BOOT_PART"
	sync
	reboot
EOF
	sudo chmod +x /media/root/resize.sh

	sudo bash -c 'cat >/media/etc/systemd/system/resize_root.service' <<'EOF'
	[Unit]
	Description=Resize root partition
	After=systemd-fsck-root.service

	[Service]
	Type=oneshot
	ExecStartPre=/bin/systemctl disable resize_root
	ExecStart=/bin/bash /root/resize.sh

	[Install]
	WantedBy=multi-user.target
EOF

	sudo bash -c 'cat >/media/root/third-stage' <<'EOF'
		#!/bin/bash
		set -x
		echo "root:toor" | chpasswd
		cat /etc/apt/sources.list
		cat /etc/resolv.conf
		export DEBIAN_FRONTEND=noninteractive
		apt-get update
		apt-get -y --no-install-recommends install ca-certificates
		set -ex
		apt-get update
		apt-get -y --no-install-recommends install \
			sudo xz-utils ntp wpasupplicant  \
			locales-all initramfs-tools u-boot-tools locales \
			console-common less network-manager laptop-mode-tools \
			python3 task-ssh-server firmware-realtek firmware-linux parted
		apt-get clean
		dpkg -i /*.deb
		apt-get -y dist-upgrade
		apt-get -y autoremove
		apt-get clean
		depmod -a "$(ls /lib/modules)"
		# Enable ssh key regeneration
		systemctl enable regenerate_ssh_host_keys
		systemctl enable resize_root
EOF
	run_in_chroot
	sudo rm -f /media/*.deb
	sudo chmod +x /media/root/resize.sh
	sudo df -h | grep /media
	sudo dd if=/dev/zero of=/media/fill || true
	sudo rm -f /media/fill
	sudo umount /media
	sudo losetup -d "$loop"
}

release() {
	# compress image
	zstd "$TOOLS_FOLDER/sdcard.img"
	mkdir -p release
	mv "$TOOLS_FOLDER/sdcard.img.zst" release/
}

if [ -z "$1" ]; then
	steps="arm_trusted trust_img uboot kernel debian_root sdcard release"
else
	steps="$*"
fi
for step in $steps; do
	figlet "$step"
	case $step in
	"arm_trusted")
		arm_trusted
		;;
	"trust_img")
		trust_img
		;;
	"uboot")
		uboot
		;;
	"kernel")
		kernel
		;;
	"debian_root")
		debian_root
		;;
	"sdcard")
		sdcard
		;;
	"release")
		release
		;;
	*)
		echo "Unsupported step: $step"
		exit 1
		;;

	esac
done
