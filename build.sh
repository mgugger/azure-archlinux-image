#!/bin/bash
# build.sh — Build a minimal Arch Linux VHD for Azure with squashfs fallback root
# Replaces the Packer-based build entirely. Runs on an Arch Linux host.
#
# Usage: sudo ./build.sh [--upload]
#   --upload: Convert to VHD and upload to Azure Storage after build
#
# Requirements: arch-install-scripts, squashfs-tools, dosfstools, btrfs-progs,
#               qemu-img (for VHD conversion), mkinitcpio, systemd-ukify
set -euo pipefail

### Configuration ###
IMAGE_SIZE="1536M"
ARCHBOOT_PARTITION_SIZE="400M"
IMAGE_NAME="archlinux"
WORK_DIR="$(pwd)/work"
OUT_DIR="$(pwd)/out"
SQUASHFS_PACKAGES="packages.conf"
ESP_LOOP_DEV=""
ROOT_LOOP_DEV=""
KEY_VAULT_NAME="${KEY_VAULT_NAME:-}"
SECURE_BOOT_PRIVATE_KEY_SECRET_NAME="${SECURE_BOOT_PRIVATE_KEY_SECRET_NAME:-secure-boot-private-key}"
SECURE_BOOT_CERTIFICATE_SECRET_NAME="${SECURE_BOOT_CERTIFICATE_SECRET_NAME:-secure-boot-certificate}"
ROOT_PASSWORD_SECRET_NAME="${ROOT_PASSWORD_SECRET_NAME:-root-login-password}"

SECURE_BOOT_PRIVATE_KEY_PATH="${WORK_DIR}/secure-boot-private-key.pem"
SECURE_BOOT_CERTIFICATE_PATH="${WORK_DIR}/secure-boot-certificate.pem"

# Set USE_SHIM=0 to skip shim and boot the signed UKI or systemd-boot directly.
# Default is on: shim provides MOK-based Secure Boot trust, and with CHAINLOAD_UKI=1
# it chainloads the UKI directly — no systemd-boot NVRAM overhead.
USE_SHIM="${USE_SHIM:-1}"

# Set CHAINLOAD_UKI=0 to keep systemd-boot in the shim chain (shim -> sd-boot -> UKI).
# Default is on: shim chainloads the UKI directly as grubx64.efi, bypassing
# systemd-boot entirely. This eliminates the Loader* NVRAM variables that
# systemd-boot writes on every boot — important on Azure Hyper-V where UEFI
# NVRAM is limited to ~32 KB.
CHAINLOAD_UKI="${CHAINLOAD_UKI:-1}"

# Source package lists
# shellcheck disable=SC1090
source "${SQUASHFS_PACKAGES}"

generate_password_64() {
    # Base64 output is trimmed to 64 chars for a fixed-length high-entropy password.
    openssl rand -base64 96 | tr -d '\n' | head -c 64
}

# Ensure IgnorePkg is placed under [options], not appended at EOF.
ensure_ignore_pkg_in_pacman_conf() {
    local conf_path="$1"
    local ignore_value="$2"

    if grep -Eq '^IgnorePkg[[:space:]]*=' "$conf_path"; then
        sed -i -E "s|^IgnorePkg[[:space:]]*=.*|IgnorePkg = ${ignore_value}|" "$conf_path"
        return
    fi

    awk -v ignore_line="IgnorePkg = ${ignore_value}" '
        BEGIN { in_options=0; inserted=0 }
        /^\[options\][[:space:]]*$/ { in_options=1; print; next }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_options && !inserted) {
                print ignore_line
                inserted=1
            }
            in_options=0
            print
            next
        }
        { print }
        END {
            if (!inserted) {
                if (!in_options) {
                    print "[options]"
                }
                print ignore_line
            }
        }
    ' "$conf_path" > "${conf_path}.tmp"
    mv "${conf_path}.tmp" "$conf_path"
}

cleanup() {
    echo ":: Cleaning up..."
    if mountpoint -q "${WORK_DIR}/mnt/efi" 2>/dev/null; then
        umount "${WORK_DIR}/mnt/efi" || true
    fi
    if mountpoint -q "${WORK_DIR}/mnt" 2>/dev/null; then
        umount -R "${WORK_DIR}/mnt" || true
    fi
    if mountpoint -q "${WORK_DIR}/squashfs-root" 2>/dev/null; then
        umount -R "${WORK_DIR}/squashfs-root" || true
    fi
    if [[ -n "${ESP_LOOP_DEV}" ]]; then
        losetup -d "${ESP_LOOP_DEV}" 2>/dev/null || true
    fi
    if [[ -n "${ROOT_LOOP_DEV}" ]]; then
        losetup -d "${ROOT_LOOP_DEV}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

ensure_loop_nodes() {
    # In some container environments, loop device nodes are not present or become stale.
    # Ensure a usable baseline of loop nodes before losetup allocates one.
    if [[ ! -e /dev/loop-control ]]; then
        mknod /dev/loop-control c 10 237 2>/dev/null || true
    fi

    local i
    for i in $(seq 0 31); do
        if [[ ! -e "/dev/loop${i}" ]]; then
            mknod "/dev/loop${i}" b 7 "${i}" 2>/dev/null || true
        fi
    done
}

attach_partition_loop_devices() {
    local image_path="$1"
    local attempt=1

    # Read the actual partition geometry back from the GPT that sfdisk wrote.
    # We MUST set --sizelimit on the root partition's loop device; without it
    # the loop device extends to EOF (including the backup GPT), causing
    # mkfs.btrfs to record a device size larger than the real partition —
    # which makes BTRFS refuse to mount at boot.
    #
    # We use sfdisk -J (JSON) + python to parse reliably.
    local part_json
    part_json=$(sfdisk -J "${image_path}")

    local esp_start esp_size root_start root_size
    read -r esp_start esp_size root_start root_size < <(
        python3 -c "
import json, sys
pt = json.loads(sys.stdin.read())['partitiontable']['partitions']
esp = next(p for p in pt if 'C12A7328' in p['type'].upper())
root = next((p for p in pt if p.get('name') == 'Arch Root'), None)
if root is None:
    root = next(p for p in pt if '0FC63DAF' in p['type'].upper())
print(esp['start']*512, esp['size']*512, root['start']*512, root['size']*512)
" <<< "${part_json}"
    )

    if (( root_size <= 0 )); then
        echo "Error: sfdisk reports root partition size ${root_size} — aborting" >&2
        return 1
    fi

    echo ":: Partition geometry (from GPT) — ESP: offset=${esp_start} size=${esp_size}  Root: offset=${root_start} size=${root_size}"

    ensure_loop_nodes

    while (( attempt <= 3 )); do
        ESP_LOOP_DEV=$(losetup --find --show \
            --offset "${esp_start}" \
            --sizelimit "${esp_size}" \
            "${image_path}" 2>/dev/null || true)

        ROOT_LOOP_DEV=$(losetup --find --show \
            --offset "${root_start}" \
            --sizelimit "${root_size}" \
            "${image_path}" 2>/dev/null || true)

        if [[ -n "${ESP_LOOP_DEV}" && -n "${ROOT_LOOP_DEV}" ]]; then
            return 0
        fi

        if [[ -n "${ESP_LOOP_DEV}" ]]; then
            losetup -d "${ESP_LOOP_DEV}" 2>/dev/null || true
            ESP_LOOP_DEV=""
        fi
        if [[ -n "${ROOT_LOOP_DEV}" ]]; then
            losetup -d "${ROOT_LOOP_DEV}" 2>/dev/null || true
            ROOT_LOOP_DEV=""
        fi

        sleep 1
        ensure_loop_nodes
        ((attempt++))
    done

    echo "Error: failed to attach loop devices for partitions in ${image_path}" >&2
    return 1
}

### Preflight checks ###
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root" >&2
    exit 1
fi

for cmd in pacstrap mksquashfs mkfs.btrfs mkfs.vfat losetup sfdisk \
           mkinitcpio ukify qemu-img az openssl sbsign; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' not found" >&2
        exit 1
    fi
done

if [[ -z "${KEY_VAULT_NAME}" ]]; then
    echo "Error: Set KEY_VAULT_NAME to store Secure Boot private key in Azure Key Vault" >&2
    exit 1
fi

### Prepare working directories ###
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"/{mnt,squashfs-root} "${OUT_DIR}"

########################################################################
# PHASE 1: Build the squashfs minimal root
########################################################################
echo ":: Phase 1 — Building squashfs minimal root..."

# pacstrap a minimal system into squashfs-root
if [[ ${#PACMAN_IGNORE_PACKAGES[@]} -gt 0 ]]; then
    # pacstrap does not support pacman's --ignore flag directly.
    # Use a temporary pacman.conf with IgnorePkg and pass it via -C.
    PACSTRAP_TMP_CONF="${WORK_DIR}/pacman.pacstrap.conf"
    cp /etc/pacman.conf "${PACSTRAP_TMP_CONF}"
    ensure_ignore_pkg_in_pacman_conf "${PACSTRAP_TMP_CONF}" "${PACMAN_IGNORE_PACKAGES[*]}"

    pacstrap -C "${PACSTRAP_TMP_CONF}" -c -G -M \
        "${WORK_DIR}/squashfs-root" "${SQUASHFS_BASE_PACKAGES[@]}"
else
    pacstrap -c -G -M "${WORK_DIR}/squashfs-root" "${SQUASHFS_BASE_PACKAGES[@]}"
fi

# Configure the minimal root
cat > "${WORK_DIR}/squashfs-root/etc/hostname" <<< "archlinux-recovery"
cat > "${WORK_DIR}/squashfs-root/etc/locale.conf" <<< "LANG=en_US.UTF-8"

# Ensure pacman.conf and mirrorlist are present (pacstrap -G -M skips them)
if [[ ! -f "${WORK_DIR}/squashfs-root/etc/pacman.conf" ]]; then
    cp /etc/pacman.conf "${WORK_DIR}/squashfs-root/etc/pacman.conf"
fi
if [[ ! -s "${WORK_DIR}/squashfs-root/etc/pacman.d/mirrorlist" ]]; then
    mkdir -p "${WORK_DIR}/squashfs-root/etc/pacman.d"
    cp /etc/pacman.d/mirrorlist "${WORK_DIR}/squashfs-root/etc/pacman.d/mirrorlist" 2>/dev/null || \
        echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > "${WORK_DIR}/squashfs-root/etc/pacman.d/mirrorlist"
fi
cat > "${WORK_DIR}/squashfs-root/etc/systemd/zram-generator.conf" << 'EOF'
[zram0]
# Keep bootstrap resilient on low-memory VM sizes.
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
EOF

# Enable essential services in squashfs.
# cloud-init/sshd packages are pre-baked for the data-disk root copy, but services
# are enabled later in provisioning after disk migration.
# Emergency access in squashfs remains Azure Serial Console.
arch-chroot "${WORK_DIR}/squashfs-root" bash -c '
    sed -i "s/^#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    locale-gen
    systemctl enable systemd-networkd
    systemctl enable systemd-resolved
    # Keep cloud-init inactive in squashfs; it is enabled later on the data-disk root.
    systemctl mask cloud-init.target cloud-init-local.service cloud-init-network.service cloud-init-main.service cloud-final.service
    systemctl mask systemd-boot-update.service
    if ! ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; then
        echo "WARNING: could not update /etc/resolv.conf in squashfs root; keeping existing file." >&2
    fi
'

# Network config for Azure (DHCP on all ethernet)
cat > "${WORK_DIR}/squashfs-root/etc/systemd/network/20-wired.network" << 'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
DNS=168.63.129.16
EOF

# Set a strong root password for recovery console access.
# Try Key Vault first to reuse an existing password; generate a fresh one otherwise.
ROOT_LOGIN_PASSWORD=""
EXISTING_ROOT_PASSWORD=""
if az keyvault secret show \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${ROOT_PASSWORD_SECRET_NAME}" \
        --only-show-errors >/dev/null 2>&1; then
    EXISTING_ROOT_PASSWORD="$(az keyvault secret show \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${ROOT_PASSWORD_SECRET_NAME}" \
        --query value -o tsv --only-show-errors)"
fi

if [[ -n "${EXISTING_ROOT_PASSWORD}" ]]; then
    echo ":: Reusing existing root login password from Key Vault."
    ROOT_LOGIN_PASSWORD="${EXISTING_ROOT_PASSWORD}"
else
    ROOT_LOGIN_PASSWORD="$(generate_password_64)"
fi
printf 'root:%s\n' "${ROOT_LOGIN_PASSWORD}" | arch-chroot "${WORK_DIR}/squashfs-root" chpasswd

# Install first-boot service and script
install -Dm755 first-boot/provision-data-disk.sh \
    "${WORK_DIR}/squashfs-root/usr/local/bin/provision-data-disk.sh"
install -Dm644 first-boot/provision-data-disk.service \
    "${WORK_DIR}/squashfs-root/etc/systemd/system/provision-data-disk.service"
install -Dm755 first-boot/azure-report-ready.sh \
    "${WORK_DIR}/squashfs-root/usr/local/bin/azure-report-ready.sh"
install -Dm644 first-boot/azure-report-ready.service \
    "${WORK_DIR}/squashfs-root/etc/systemd/system/azure-report-ready.service"
install -Dm644 packages.conf \
    "${WORK_DIR}/squashfs-root/usr/local/share/arch-image/packages.conf"

# Install staged provisioning helpers and root overlay assets
install -Dm755 first-boot/provision.d/20-hardening-overlay.sh \
    "${WORK_DIR}/squashfs-root/usr/local/lib/provision.d/20-hardening-overlay.sh"
install -Dm755 first-boot/provision.d/25-hardening-config.sh \
    "${WORK_DIR}/squashfs-root/usr/local/lib/provision.d/25-hardening-config.sh"
install -Dm755 first-boot/provision.d/30-cloud-init-services.sh \
    "${WORK_DIR}/squashfs-root/usr/local/lib/provision.d/30-cloud-init-services.sh"
install -d -m755 "${WORK_DIR}/squashfs-root/usr/local/share/provision-overlay"
cp -a first-boot/root-overlay/. "${WORK_DIR}/squashfs-root/usr/local/share/provision-overlay/"

# Enable first-boot provisioning (ConditionFirstBoot or check file)
arch-chroot "${WORK_DIR}/squashfs-root" systemctl enable provision-data-disk.service
arch-chroot "${WORK_DIR}/squashfs-root" systemctl enable azure-report-ready.service

# Install secure-boot resign script and pacman hook into the base image.
# After a kernel update, mkinitcpio -P rebuilds the UKI (with SB + PCR signatures
# via uki.conf), then this hook copies it into the shim chainload position.
install -d -m755 "${WORK_DIR}/squashfs-root/usr/local/bin"
cat > "${WORK_DIR}/squashfs-root/usr/local/bin/secure-boot-resign" << 'RESIGN_EOF'
#!/usr/bin/env bash
set -euo pipefail
log() { echo "[secure-boot-resign] $*"; }

# mkinitcpio -P already ran (triggered by pacman's 90-mkinitcpio-install.hook).
# The UKI at /efi/EFI/Linux/arch-linux.efi is already signed via uki.conf.
# Copy it to grubx64.efi so shim chainloads the updated UKI.
if [[ -f /efi/EFI/Linux/arch-linux.efi ]]; then
    cp /efi/EFI/Linux/arch-linux.efi /efi/EFI/BOOT/grubx64.efi
    log "Updated grubx64.efi with latest signed UKI."
else
    log "WARNING: /efi/EFI/Linux/arch-linux.efi not found after mkinitcpio."
fi
RESIGN_EOF
chmod 0755 "${WORK_DIR}/squashfs-root/usr/local/bin/secure-boot-resign"

install -d -m755 "${WORK_DIR}/squashfs-root/etc/pacman.d/hooks"
cat > "${WORK_DIR}/squashfs-root/etc/pacman.d/hooks/91-secure-boot-resign.hook" << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux-hardened

[Action]
Description = Copy signed UKI to shim chainload position
When = PostTransaction
Exec = /usr/local/bin/secure-boot-resign
EOF

# Build and install shim-signed from AUR (needed for Secure Boot chain)
if [[ "${USE_SHIM}" -eq 1 ]]; then
echo ":: Building shim-signed from AUR..."
arch-chroot "${WORK_DIR}/squashfs-root" bash -c '
    # Create temporary build user (makepkg cannot run as root)
    useradd -m _builduser
    echo "_builduser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

    # Initialise pacman keyring
    pacman-key --init
    pacman-key --populate archlinux

    # Install build dependencies
    pacman -Sy --noconfirm --needed base-devel git

    # Build shim-signed
    cd /tmp
    sudo -u _builduser bash -c "
        git clone https://aur.archlinux.org/shim-signed.git /tmp/shim-signed
        cd /tmp/shim-signed
        makepkg -s --noconfirm
    "
    pacman -U --noconfirm /tmp/shim-signed/shim-signed-*.pkg.tar.*

    # Clean up build user and artefacts
    rm -rf /tmp/shim-signed
    userdel -r _builduser 2>/dev/null || true
    sed -i "/_builduser/d" /etc/sudoers

    # Remove build-only packages (base-devel, git and their unique deps)
    pacman -Rns --noconfirm base-devel git 2>/dev/null || true
'
echo ":: shim-signed installed."
else
    echo ":: Skipping shim-signed build (USE_SHIM=0)."
fi

# Trim squashfs-root before compression
echo ":: Trimming squashfs-root..."
SQROOT="${WORK_DIR}/squashfs-root"

# Pacman package cache (biggest win)
rm -rf "${SQROOT}/var/cache/pacman/pkg/"*

# Pacman sync databases (will be refreshed on provision)
rm -rf "${SQROOT}/var/lib/pacman/sync/"*

# Man pages, info pages, doc
rm -rf "${SQROOT}/usr/share/man" \
       "${SQROOT}/usr/share/info" \
       "${SQROOT}/usr/share/doc" \
       "${SQROOT}/usr/share/gtk-doc"

# Locale data except en_US
find "${SQROOT}/usr/share/locale" -mindepth 1 -maxdepth 1 \
    ! -name 'en_US' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true

# i18n not needed
rm -rf "${SQROOT}/usr/share/i18n/locales" 2>/dev/null || true
rm -rf "${SQROOT}/usr/share/i18n/charmaps" 2>/dev/null || true

# Python bytecode caches
find "${SQROOT}" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "${SQROOT}" -name '*.pyc' -delete 2>/dev/null || true

# Static libraries (not needed at runtime)
find "${SQROOT}/usr/lib" -name '*.a' -delete 2>/dev/null || true

# Header files (not needed at runtime)
rm -rf "${SQROOT}/usr/include" 2>/dev/null || true

# Pacman GnuPG trust DB — strip private keys and non-essential files but keep
# the pubring so pacman signature verification works on the data-disk copy.
rm -rf "${SQROOT}/etc/pacman.d/gnupg/private-keys-v1.d" \
       "${SQROOT}/etc/pacman.d/gnupg/S."* \
       "${SQROOT}/etc/pacman.d/gnupg/openpgp-revocs.d" \
       2>/dev/null || true

# Unused kernel modules — keep only what Azure Hyper-V and provisioning need
KVER_TRIM=$(ls "${SQROOT}/lib/modules/" | head -1)
if [[ -n "${KVER_TRIM}" ]]; then
    KMOD="${SQROOT}/lib/modules/${KVER_TRIM}/kernel"
    # Remove entire subsystems not needed on Azure
    rm -rf "${KMOD}/sound" \
           "${KMOD}/drivers/gpu" \
           "${KMOD}/drivers/media" \
           "${KMOD}/drivers/staging" \
           "${KMOD}/drivers/usb" \
           "${KMOD}/drivers/bluetooth" \
           "${KMOD}/drivers/infiniband" \
           "${KMOD}/drivers/isdn" \
           "${KMOD}/drivers/firewire" \
           "${KMOD}/drivers/input/joystick" \
           "${KMOD}/drivers/input/touchscreen" \
           "${KMOD}/drivers/input/gameport" \
           "${KMOD}/drivers/nfc" \
           "${KMOD}/drivers/iio" \
           "${KMOD}/drivers/hwmon" \
           "${KMOD}/drivers/leds" \
           "${KMOD}/drivers/parport" \
           "${KMOD}/drivers/pcmcia" \
           "${KMOD}/drivers/ssb" \
           "${KMOD}/drivers/thunderbolt" \
           "${KMOD}/drivers/w1" \
           "${KMOD}/net/wireless" \
           "${KMOD}/net/bluetooth" \
           "${KMOD}/net/mac80211" \
           2>/dev/null || true
    # Rebuild module dependency index after pruning
    depmod -a -b "${SQROOT}" "${KVER_TRIM}" 2>/dev/null || true
fi

# Leftover log files from chroot operations
rm -rf "${SQROOT}/var/log/"* 2>/dev/null || true

# /tmp cruft
rm -rf "${SQROOT}/tmp/"* 2>/dev/null || true

echo ":: Trimmed size: $(du -sh "${SQROOT}" | cut -f1)"

# Compress into squashfs
echo ":: Compressing squashfs image..."
mksquashfs "${WORK_DIR}/squashfs-root" "${WORK_DIR}/airootfs.sfs" \
    -comp zstd -Xcompression-level 15 -b 1M -no-duplicates -noappend

echo ":: Squashfs size: $(du -h "${WORK_DIR}/airootfs.sfs" | cut -f1)"

########################################################################
# PHASE 2: Build the VHD image
########################################################################
echo ":: Phase 2 — Building VHD image..."

# Create raw disk image
truncate -s "${IMAGE_SIZE}" "${WORK_DIR}/${IMAGE_NAME}.raw"

# Partition: 256MB ESP + fixed Arch Root + remaining free space reserved as Arch Var
sfdisk "${WORK_DIR}/${IMAGE_NAME}.raw" << EOF
label: gpt
size=256M, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI System"
size=${ARCHBOOT_PARTITION_SIZE}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="Arch Root"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="Arch Var"
EOF

# Read back the exact root partition size (in sectors) that sfdisk wrote.
# This accounts for GPT backup and MiB alignment automatically.
ROOT_PART_SECTORS=$(sfdisk -J "${WORK_DIR}/${IMAGE_NAME}.raw" | python3 -c '
import json, sys
parts = json.load(sys.stdin)["partitiontable"]["partitions"]
root = next((p for p in parts if p.get("name") == "Arch Root"), None)
if root is None:
    raise SystemExit(1)
print(root["size"])
')
ROOT_PART_BYTES=$(( ROOT_PART_SECTORS * 512 ))
echo ":: Root partition: ${ROOT_PART_SECTORS} sectors = ${ROOT_PART_BYTES} bytes"

if [[ -z "${ROOT_PART_SECTORS}" ]] || (( ROOT_PART_BYTES <= 0 )); then
    echo "Error: could not determine root partition size from sfdisk" >&2
    exit 1
fi

# Setup loop devices for partitions via explicit offsets.
# This avoids relying on /dev/loopXp1 nodes, which may not appear in some containers.
attach_partition_loop_devices "${WORK_DIR}/${IMAGE_NAME}.raw"
ESP_PART="${ESP_LOOP_DEV}"
ROOT_PART="${ROOT_LOOP_DEV}"

# Format partitions — pass -b to mkfs.btrfs so the filesystem's recorded
# total_bytes matches the real partition size.  Without this, the loop
# device (which may lack proper --sizelimit in container environments)
# exposes extra bytes from the backup GPT, and BTRFS will refuse to mount
# at boot when the kernel sees the smaller real partition.
mkfs.vfat -F 32 -n "ESP" "${ESP_PART}"
mkfs.btrfs -f -L "archboot" -b "${ROOT_PART_BYTES}" "${ROOT_PART}"

# Mount
mount "${ROOT_PART}" "${WORK_DIR}/mnt"
mkdir -p "${WORK_DIR}/mnt/efi"
mount "${ESP_PART}" "${WORK_DIR}/mnt/efi"

# Create mount structure
mkdir -p "${WORK_DIR}/mnt"/{sfs,crypt}

# Copy squashfs image to boot disk
cp "${WORK_DIR}/airootfs.sfs" "${WORK_DIR}/mnt/sfs/airootfs.sfs"

########################################################################
# PHASE 3: Build UKI + initramfs with custom hooks
########################################################################
echo ":: Phase 3 — Building UKI..."

# We need a kernel + initramfs. Use the squashfs-root's kernel.
KVER=$(ls "${WORK_DIR}/squashfs-root/lib/modules/" | head -1)
echo ":: Kernel version: ${KVER}"

# Copy kernel modules to boot disk (needed for initramfs)
cp -a "${WORK_DIR}/squashfs-root/lib/modules/${KVER}" \
    "${WORK_DIR}/mnt/lib/modules/${KVER}" 2>/dev/null || true

# Install our custom mkinitcpio hooks into the squashfs-root for building
install -Dm644 initcpio/install/squashfs-overlay \
    "${WORK_DIR}/squashfs-root/usr/lib/initcpio/install/squashfs-overlay"

# Install systemd initrd service and setup script (used instead of run_hook)
install -Dm644 initcpio/systemd/arch-root-setup.service \
    "${WORK_DIR}/squashfs-root/usr/lib/systemd/system/arch-root-setup.service"
install -Dm755 initcpio/systemd/setup-root \
    "${WORK_DIR}/squashfs-root/usr/lib/arch-root/setup-root"

# Some systemd hook versions expect this path under /usr/lib/systemd.
# Ensure it exists in the chroot when only /usr/bin contains the binary.
if [[ ! -e "${WORK_DIR}/squashfs-root/usr/lib/systemd/systemd-tty-ask-password-agent" \
      && -e "${WORK_DIR}/squashfs-root/usr/bin/systemd-tty-ask-password-agent" ]]; then
    mkdir -p "${WORK_DIR}/squashfs-root/usr/lib/systemd"
    ln -sf ../../bin/systemd-tty-ask-password-agent \
        "${WORK_DIR}/squashfs-root/usr/lib/systemd/systemd-tty-ask-password-agent"
fi

# Create mkinitcpio preset for the boot image
cat > "${WORK_DIR}/squashfs-root/etc/mkinitcpio.conf.d/azure-boot.conf" << 'MKINITCONF'
# Azure/Hyper-V drivers, squashfs overlay stack, LUKS + BTRFS for data disk,
# virtio/NVMe for alternative VM types.  Explicit list avoids pulling in
# the entire block subsystem (parport, pcmcia, InfiniBand, etc.) which
# linux-hardened does not build.
MODULES=(hv_vmbus hv_storvsc hv_netvsc hv_utils
         squashfs overlay loop
         dm-crypt btrfs vfat
         virtio_blk virtio_scsi virtio_pci nvme)
HOOKS=(systemd modconf sd-encrypt squashfs-overlay)
COMPRESSION="zstd"
MKINITCONF

# Generate initramfs inside chroot
arch-chroot "${WORK_DIR}/squashfs-root" \
    mkinitcpio -k "${KVER}" \
    -c /etc/mkinitcpio.conf.d/azure-boot.conf \
    -g /boot/initramfs-azure.img

# Kernel cmdline — uses labels for portability (no UUIDs baked in)
cat > "${WORK_DIR}/cmdline.txt" << CMDLINE
root=LABEL=archboot rootflags=compress=zstd:6 rw
console=tty0 console=ttyS0,115200 bgrt_disable
lsm=landlock,lockdown,yama,integrity,apparmor,bpf
slab_nomerge init_on_alloc=1 init_on_free=1
page_alloc.shuffle=1 pti=on randomize_kstack_offset=on
vsyscall=none debugfs=off oops=panic
intel_iommu=on amd_iommu=on
arch_boot=squashfs
CMDLINE

# Retrieve or create Secure Boot signing keys.
# Reuse existing Key Vault secrets when both private key and certificate are
# present.  If only the private key exists (no public certificate), regenerate
# the pair so both halves are always in sync.
EXISTING_PRIVATE_KEY=""
EXISTING_CERTIFICATE=""

echo ":: Checking Azure Key Vault '${KEY_VAULT_NAME}' for existing Secure Boot secrets..."
if az keyvault secret show \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${SECURE_BOOT_PRIVATE_KEY_SECRET_NAME}" \
        --only-show-errors >/dev/null 2>&1; then
    EXISTING_PRIVATE_KEY="$(az keyvault secret show \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${SECURE_BOOT_PRIVATE_KEY_SECRET_NAME}" \
        --query value -o tsv --only-show-errors)"
fi

if az keyvault secret show \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${SECURE_BOOT_CERTIFICATE_SECRET_NAME}" \
        --only-show-errors >/dev/null 2>&1; then
    EXISTING_CERTIFICATE="$(az keyvault secret show \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${SECURE_BOOT_CERTIFICATE_SECRET_NAME}" \
        --query value -o tsv --only-show-errors)"
fi

if [[ -n "${EXISTING_PRIVATE_KEY}" && -n "${EXISTING_CERTIFICATE}" ]]; then
    echo ":: Reusing existing Secure Boot keypair from Key Vault."
    printf '%s\n' "${EXISTING_PRIVATE_KEY}" > "${SECURE_BOOT_PRIVATE_KEY_PATH}"
    printf '%s\n' "${EXISTING_CERTIFICATE}" > "${SECURE_BOOT_CERTIFICATE_PATH}"
else
    if [[ -n "${EXISTING_PRIVATE_KEY}" && -z "${EXISTING_CERTIFICATE}" ]]; then
        echo ":: Private key found without matching certificate — regenerating keypair."
    else
        echo ":: No existing Secure Boot secrets found — generating new keypair."
    fi

    openssl req -new -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
        -subj "/CN=ArchLinux Azure Secure Boot/" \
        -keyout "${SECURE_BOOT_PRIVATE_KEY_PATH}" \
        -out "${SECURE_BOOT_CERTIFICATE_PATH}"

    echo ":: Uploading Secure Boot private key to Azure Key Vault '${KEY_VAULT_NAME}'..."
    az keyvault secret set \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${SECURE_BOOT_PRIVATE_KEY_SECRET_NAME}" \
        --file "${SECURE_BOOT_PRIVATE_KEY_PATH}" \
        --only-show-errors \
        >/dev/null

    echo ":: Uploading Secure Boot certificate to Azure Key Vault '${KEY_VAULT_NAME}'..."
    az keyvault secret set \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${SECURE_BOOT_CERTIFICATE_SECRET_NAME}" \
        --file "${SECURE_BOOT_CERTIFICATE_PATH}" \
        --only-show-errors \
        >/dev/null
fi

# Upload root login password to Key Vault if it was freshly generated.
if [[ -z "${EXISTING_ROOT_PASSWORD}" ]]; then
    echo ":: Uploading root login password to Azure Key Vault '${KEY_VAULT_NAME}'..."
    az keyvault secret set \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${ROOT_PASSWORD_SECRET_NAME}" \
        --value "${ROOT_LOGIN_PASSWORD}" \
        --only-show-errors \
        >/dev/null
fi

# Build UKI
mkdir -p "${WORK_DIR}/mnt/efi/EFI/Linux"
ukify build \
    --linux="${WORK_DIR}/squashfs-root/boot/vmlinuz-linux-hardened" \
    --initrd="${WORK_DIR}/squashfs-root/boot/initramfs-azure.img" \
    --cmdline="@${WORK_DIR}/cmdline.txt" \
    --os-release="@${WORK_DIR}/squashfs-root/usr/lib/os-release" \
    --output="${WORK_DIR}/mnt/efi/EFI/Linux/arch-linux.efi"

echo ":: Signing UKI with Secure Boot key..."
sbsign \
    --key "${SECURE_BOOT_PRIVATE_KEY_PATH}" \
    --cert "${SECURE_BOOT_CERTIFICATE_PATH}" \
    --output "${WORK_DIR}/mnt/efi/EFI/Linux/arch-linux.efi" \
    "${WORK_DIR}/mnt/efi/EFI/Linux/arch-linux.efi"

mkdir -p "${WORK_DIR}/mnt/efi/EFI/BOOT"

if [[ "${USE_SHIM}" -eq 1 ]] && [[ "${CHAINLOAD_UKI}" -eq 1 ]] && \
   [[ -f "${WORK_DIR}/squashfs-root/usr/share/shim-signed/shimx64.efi" ]]; then
    # Chainload mode: shim (BOOTX64.EFI) -> signed UKI (grubx64.efi), no systemd-boot
    cp "${WORK_DIR}/squashfs-root/usr/share/shim-signed/shimx64.efi" \
        "${WORK_DIR}/mnt/efi/EFI/BOOT/BOOTX64.EFI"
    cp "${WORK_DIR}/squashfs-root/usr/share/shim-signed/mmx64.efi" \
        "${WORK_DIR}/mnt/efi/EFI/BOOT/mmx64.efi"
    cp "${WORK_DIR}/mnt/efi/EFI/Linux/arch-linux.efi" \
        "${WORK_DIR}/mnt/efi/EFI/BOOT/grubx64.efi"
    # Marker so the resign script knows to update grubx64.efi instead of bootctl
    touch "${WORK_DIR}/mnt/efi/EFI/BOOT/chainload-uki.marker"
    echo ":: Shim chainload-UKI: BOOTX64.EFI (shim) -> grubx64.efi (signed UKI)"
else
    # systemd-boot loader config (only needed when sd-boot is in the chain)
    mkdir -p "${WORK_DIR}/mnt/efi/loader"
    cat > "${WORK_DIR}/mnt/efi/loader/loader.conf" << 'EOF'
default arch-linux.efi
timeout 5
console-mode max
editor no
EOF

    # Install systemd-boot as the default bootloader (BOOTX64.EFI)
    sbsign \
        --key "${SECURE_BOOT_PRIVATE_KEY_PATH}" \
        --cert "${SECURE_BOOT_CERTIFICATE_PATH}" \
        --output "${WORK_DIR}/mnt/efi/EFI/BOOT/BOOTX64.EFI" \
        "${WORK_DIR}/squashfs-root/usr/lib/systemd/boot/efi/systemd-bootx64.efi"

    if [[ "${USE_SHIM}" -eq 1 ]] && [[ -f "${WORK_DIR}/squashfs-root/usr/share/shim-signed/shimx64.efi" ]]; then
        # Shim + systemd-boot mode
        mv "${WORK_DIR}/mnt/efi/EFI/BOOT/BOOTX64.EFI" \
            "${WORK_DIR}/mnt/efi/EFI/BOOT/grubx64.efi"
        cp "${WORK_DIR}/squashfs-root/usr/share/shim-signed/shimx64.efi" \
            "${WORK_DIR}/mnt/efi/EFI/BOOT/BOOTX64.EFI"
        cp "${WORK_DIR}/squashfs-root/usr/share/shim-signed/mmx64.efi" \
            "${WORK_DIR}/mnt/efi/EFI/BOOT/mmx64.efi"
        echo ":: Shim chain: BOOTX64.EFI (shim) -> grubx64.efi (signed systemd-boot)"
    else
        echo ":: Direct boot: BOOTX64.EFI (signed systemd-boot), no shim."
    fi
fi

# Public certificate on ESP (PEM + DER for MOK enrollment / Secure Boot).
# Only the private key is kept exclusively in Key Vault.
mkdir -p "${WORK_DIR}/mnt/efi/keys"
cp "${SECURE_BOOT_CERTIFICATE_PATH}" "${WORK_DIR}/mnt/efi/keys/secure-boot-certificate.pem"
openssl x509 -in "${SECURE_BOOT_CERTIFICATE_PATH}" -outform DER \
    -out "${WORK_DIR}/mnt/efi/mok-manager.crt"

########################################################################
# PHASE 4: Finalize image
########################################################################
echo ":: Phase 4 — Finalizing..."

# Ensure build-time private key is removed before image finalization.
if [[ -f "${SECURE_BOOT_PRIVATE_KEY_PATH}" ]]; then
    if command -v shred &>/dev/null; then
        shred -u "${SECURE_BOOT_PRIVATE_KEY_PATH}"
    else
        rm -f "${SECURE_BOOT_PRIVATE_KEY_PATH}"
    fi
fi

# Remove the cleartext root password from process memory as soon as possible.
unset ROOT_LOGIN_PASSWORD

# Unmount
sync
umount "${WORK_DIR}/mnt/efi"
umount "${WORK_DIR}/mnt"
if [[ -n "${ESP_LOOP_DEV}" ]]; then
    losetup -d "${ESP_LOOP_DEV}" || true
    ESP_LOOP_DEV=""
fi
if [[ -n "${ROOT_LOOP_DEV}" ]]; then
    losetup -d "${ROOT_LOOP_DEV}" || true
    ROOT_LOOP_DEV=""
fi
# Convert to VHD (Azure requires fixed-size VHD aligned to 1MB)
RAW_SIZE=$(stat --format=%s "${WORK_DIR}/${IMAGE_NAME}.raw")
ALIGNED_SIZE=$(( (RAW_SIZE + 1048576 - 1) / 1048576 * 1048576 ))
truncate -s "${ALIGNED_SIZE}" "${WORK_DIR}/${IMAGE_NAME}.raw"

qemu-img convert -f raw -o subformat=fixed,force_size -O vpc \
    "${WORK_DIR}/${IMAGE_NAME}.raw" \
    "${OUT_DIR}/${IMAGE_NAME}.vhd"

echo ":: Built: ${OUT_DIR}/${IMAGE_NAME}.vhd"
echo ":: Size: $(du -h "${OUT_DIR}/${IMAGE_NAME}.vhd" | cut -f1)"

########################################################################
# PHASE 5: Upload to Azure (optional)
########################################################################
if [[ "${1:-}" == "--upload" ]]; then
    echo ":: Phase 5 — Uploading to Azure..."
    if [[ -z "${AZURE_STORAGE_ACCOUNT:-}" || -z "${AZURE_STORAGE_CONTAINER:-}" ]]; then
        echo "Error: Set AZURE_STORAGE_ACCOUNT and AZURE_STORAGE_CONTAINER" >&2
        exit 1
    fi
    azcopy copy "${OUT_DIR}/${IMAGE_NAME}.vhd" \
        "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/${IMAGE_NAME}.vhd"
    echo ":: Upload complete. Create managed image with:"
    echo "   az image create --resource-group <rg> --name ${IMAGE_NAME} \\"
    echo "     --os-type Linux --hyper-v-generation V2 \\"
    echo "     --source https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/${IMAGE_NAME}.vhd"
fi

echo ":: Done."
