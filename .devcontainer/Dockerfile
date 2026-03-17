FROM archlinux:latest

# Update and install all build dependencies for build.sh
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
        arch-install-scripts \
        squashfs-tools \
        dosfstools \
        btrfs-progs \
        qemu-img \
        mkinitcpio \
        systemd-ukify \
        util-linux \
        git \
        sudo \
        nano && \
    pacman -Scc --noconfirm

# Codespaces runs as root in custom containers
ENV container=docker
