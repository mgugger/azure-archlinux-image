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
        sbsigntools \
        python-pip \
        util-linux \
        git \
        cdrtools \
        sudo \
        nano \
        qemu-system-x86 \
        swtpm \
        edk2-ovmf && \
    pip install --no-cache-dir azure-cli && \
    pacman -Scc --noconfirm

# Codespaces runs as root in custom containers
ENV container=docker
