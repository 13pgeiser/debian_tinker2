#!/bin/bash
set -ex
cd /mnt || exit 1
source bash-scripts/helpers.sh

###############################################################################

distrib=bullseye
#distrib=bookworm

###############################################################################

case $distrib in
"bullseye")
	#kernel="4.19"
	kernel="5.10" # Issues with drm
	;;
"bookworm")
	kernel="6.1"
	;;
*)
	echo "Unsupported"
	;;
esac

###############################################################################
# Set globals
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export BL31="$TOOLS_FOLDER/rkbin/bin/rk33/rk3399_bl31_v1.36.elf"
export DDR="rk3399_ddr_800MHz_v1.30.bin"
export MINILOADER="rk3399_miniloader_v1.30.bin"
###############################################################################

case $kernel in
"4.19")
	# Official Tinker2 kernel
	kernel_version_short="4.19.232"
	kernel_version="TinkerBoard2-kernel-d4aa6a0"
	kernel_md5="dd0ec71e8848bd1a5ab48a782238b7cf"
	kernel_url="https://github.com/TinkerBoard2/kernel/tarball/linux4.19-rk3399-debian10"
	dtb="rk3399-tinker_board_2.dtb"
	;;
"5.10")
	kernel_version_short="5.10.186"
	kernel_md5="f73e35d77a00d59c31ccec3b185b3c37"
	kernel_version="linux-${kernel_version_short}"
	kernel_url="https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/${kernel_version}.tar.xz"
	dtb="rk3399-tinker-2.dtb"
	;;
"6.1")
	kernel_version_short="6.1.19"
	kernel_md5="fb8f9f396e6415cfcd81c69eba3c42be"
	kernel_version="linux-${kernel_version_short}"
	kernel_url="https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x/${kernel_version}.tar.xz"
	dtb="rk3399-tinker-2.dtb"
	;;
*)
	echo "Unsupported"
	;;
esac

###############################################################################
# Build trust.img
rkbin() {
	git_clone \
		"rkbin" \
		"https://github.com/rockchip-linux/rkbin.git" \
		"master"
}

###############################################################################
# Build u-boot
uboot() {
	git_clone \
		"u-boot" \
		"https://github.com/u-boot/u-boot" \
		"tags/v2021.07"
	apply_patches "$TOOLS_FOLDER/u-boot" "$(pwd)/patches/u-boot"
	if [ ! -e "$TOOLS_FOLDER/u-boot/u-boot" ]; then
		(
			cd "$TOOLS_FOLDER/u-boot" || exit 1
			make mrproper
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
# Kernel
kernel_folder="$TOOLS_FOLDER/$kernel_version"

kernel() {
	extension="${kernel_url##*.}"
	if [ "$extension" != 'xz' ]; then
		extension="gz"
	fi
	download_unpack \
		"$kernel_md5" \
		"$kernel_url" \
		"e" \
		"linux-${kernel_version_short}.tar.${extension}" \
		"$kernel_version"
	if [ ! -e "$TOOLS_FOLDER/kernel_patched" ]; then
		patch_folder="$(pwd)/patches/linux-${kernel}"
		if [ -d "$patch_folder" ]; then
			(
				cd "$kernel_folder" || exit 1
				for patch in "$patch_folder"/*.patch; do
					echo "$patch"
					patch -p1 <"$patch"
				done
			)
		fi
		touch "$TOOLS_FOLDER/kernel_patched"
	fi
	if [ ! -e "$TOOLS_FOLDER/kernel_built" ]; then
		config="$(pwd)/configs/linux-${kernel}.config"
		(
			cd "$kernel_folder" || exit 1
			cp "$config" .config
			make oldconfig
			#make menuconfig
			make rockchip/"$dtb"
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
			sudo debootstrap --arch=arm64 ${distrib} debian_root http://httpredir.debian.org/debian
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

	mkimage -n rk3399 -T rksd -d "$TOOLS_FOLDER/rkbin/bin/rk33/$DDR" "$TOOLS_FOLDER/idbloader.img"
	cat "$TOOLS_FOLDER/rkbin/bin/rk33/$MINILOADER" >>"$TOOLS_FOLDER/idbloader.img"
	"$TOOLS_FOLDER/rkbin/tools/loaderimage" --pack --uboot "$TOOLS_FOLDER/u-boot/u-boot-dtb.bin" "$TOOLS_FOLDER/uboot.img" 0x200000
	(
		cd "$TOOLS_FOLDER/u-boot" || exit 1
		"$TOOLS_FOLDER/rkbin/tools/trust_merger" --replace bl31.elf $"$BL31" trust.ini
	)

	# Write idbloader, uboot.img and trust.img
	dd if="$TOOLS_FOLDER/idbloader.img" of="$TOOLS_FOLDER/sdcard.img" seek=64 conv=notrunc
	dd if="$TOOLS_FOLDER/uboot.img" of="$TOOLS_FOLDER/sdcard.img" seek=16384 conv=notrunc
	dd if="$TOOLS_FOLDER/u-boot/trust.bin" of="$TOOLS_FOLDER/sdcard.img" seek=24576 conv=notrunc

	# Create u-boot boot script
	cp -f boot.txt "$TOOLS_FOLDER/boot.txt"
	sed -i "s/^setenv fdtfile.*/setenv fdtfile rockchip\/$dtb/" "$TOOLS_FOLDER/boot.txt"
	# Create u-boot boot script
	mkimage -A arm -O linux -T script -C none -n "U-Boot boot script" -d "$TOOLS_FOLDER/boot.txt" "$TOOLS_FOLDER/boot.scr"

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
		sudo mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc || true
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
		sudo rm -f /media/root/third-stage
		sudo rm -f /media/root/.bash_history
	}

	# create filesystem and copy files.
	sudo mkfs.ext4 -L root "${loop}p4"
	sudo mount "${loop}p4" /media
	sudo mkdir -p /media/boot/dtbs/rockchip/
	sudo cp "$kernel_folder/arch/arm64/boot/dts/rockchip/$dtb" /media/boot/dtbs/rockchip/
	sudo cp "$kernel_folder/arch/arm64/boot/Image" /media/boot
	sudo cp "$TOOLS_FOLDER/boot.scr" /media/boot/
	sudo cp "$TOOLS_FOLDER/boot.txt" /media/boot/
	sudo rsync -ax "$TOOLS_FOLDER"/debian_root/* /media
	sudo cp "$TOOLS_FOLDER"/*.deb /media/

	# Update Apt sources
	if [ "$distrib" == "bullseye" ]; then
		sudo bash -c 'cat >/media/etc/apt/sources.list' <<'EOF'
	deb http://httpredir.debian.org/debian bullseye main non-free contrib
	deb-src http://httpredir.debian.org/debian bullseye main non-free contrib
	deb https://security.debian.org/debian-security bullseye-security main contrib non-free
EOF
	else
		sudo bash -c 'cat >/media/etc/apt/sources.list' <<'EOF'
	deb http://httpredir.debian.org/debian bookworm main non-free non-free-firmware contrib
	deb-src http://httpredir.debian.org/debian bookworm main non-free non-free-firmware contrib
EOF
	fi

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
	printf "yes\n" | parted ---pretend-input-tty "$BOOT_DEV" "resizepart $PART_NUM -1" quit
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

	# Make mkinitramfs happy.
	sudo bash -c 'cat >>/media/etc/fstab' <<'EOF'
/dev/mmcblk0p1 / ext4 defaults 0 1
EOF

	sudo bash -c 'cat >/media/root/third-stage' <<'EOF'
		#!/bin/bash
		set -x
		echo "root:toor" | chpasswd
		cat /etc/apt/sources.list
		cat /etc/resolv.conf
		export DEBIAN_FRONTEND=noninteractive
		apt-get update
		apt-get -y --no-install-recommends install ca-certificates zstd
		set -ex
		apt-get update
		apt-get -y --no-install-recommends install \
			sudo xz-utils ntp wpasupplicant e2fsprogs \
			locales-all initramfs-tools u-boot-tools locales \
			console-common less network-manager laptop-mode-tools \
			python3 task-ssh-server firmware-realtek \
			firmware-linux-free parted firmware-misc-nonfree
		apt-get clean
		dpkg -i /*.deb
		apt-get -y dist-upgrade
		apt-get -y remove dmidecode
		apt-get -y autoremove
		apt-get clean
		depmod -a "$(ls /lib/modules)"
		update-initramfs -v -u -k all
		# Enable ssh key regeneration
		systemctl enable regenerate_ssh_host_keys
		systemctl enable resize_root
EOF
	run_in_chroot
	(
		cd /media/boot/ || exit 1
		sudo ls -1 /media/boot/
		sudo mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd -d "initrd.img-$kernel_version_short" uInitrd
		sudo mkimage -A arm64 -T kernel -C none -d "$kernel_folder/arch/arm64/boot/Image" uImage
	)
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
	steps="rkbin uboot kernel debian_root sdcard release"
else
	steps="$*"
fi
for step in $steps; do
	figlet "$step"
	case $step in
	"rkbin")
		rkbin
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
