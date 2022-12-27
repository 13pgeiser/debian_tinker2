#!/bin/bash
set -e
source bash-scripts/helpers.sh
if [ -z "$1" ]; then
	run_shfmt_and_shellcheck ./*.sh
	run_shfmt_and_shellcheck ./scripts/*.sh
fi
docker_configure
docker_setup "tinker2"
dockerfile_create
dockerfile_sudo
docker_build_image_and_create_volume
dockerfile_setup_debootstrap
cat >>"$DOCKERFILE" <<'EOF'
RUN set -ex \
    && apt-get update \
    && apt-get dist-upgrade -y \
    && apt-get install -y --no-install-recommends \
    	crossbuild-essential-arm64 \
	gcc-arm-none-eabi \
    && apt-get clean \
    && rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/*
EOF
docker_build_image_and_create_volume
sudo modprobe loop
sudo losetup -f
echo "$DOCKER_RUN_BASE" --privileged "$IMAGE_NAME" /mnt/scripts/build.sh "$1"
$DOCKER_RUN_BASE --privileged "$IMAGE_NAME" /mnt/scripts/build.sh "$1"
