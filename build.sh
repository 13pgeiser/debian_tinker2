#!/bin/bash
source bash-scripts/helpers.sh
run_shfmt_and_shellcheck ./*.sh
run_shfmt_and_shellcheck ./scripts/*.sh
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
#$DOCKER_RUN_IT /bin/bash
sudo modprobe loop
sudo losetup -f
$DOCKER_RUN_BASE --privileged -it "$IMAGE_NAME" /mnt/scripts/build.sh
