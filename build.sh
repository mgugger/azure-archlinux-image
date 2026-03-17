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
IMAGE_SIZE="4G"
IMAGE_NAME="azure-archlinux"
WORK_DIR="$(pwd)/work"
OUT_DIR="$(pwd)/out"
SQUASHFS_PACKAGES="packages.conf"
LOOP_DEV=""

# Source package lists
source "${SQUASHFS_PACKAGES}"

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
    if [[ -n "${LOOP_DEV}" ]]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

### Preflight checks ###
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root" >&2
    exit 1
fi

for cmd in pacstrap mksquashfs mkfs.btrfs mkfs.vfat losetup sfdisk \
           mkinitcpio ukify qemu-img; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' not found" >&2
        exit 1
    fi
done

### Prepare working directories ###
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"/{mnt,squashfs-root} "${OUT_DIR}"

########################################################################
# PHASE 1: Build the squashfs minimal root
########################################################################
echo ":: Phase 1 — Building squashfs minimal root..."

# pacstrap a minimal system into squashfs-root
pacstrap -c -G -M "${WORK_DIR}/squashfs-root" "${SQUASHFS_BASE_PACKAGES[@]}"

# Configure the minimal root
cat > "${WORK_DIR}/squashfs-root/etc/hostname" <<< "archlinux-recovery"
cat > "${WORK_DIR}/squashfs-root/etc/locale.conf" <<< "LANG=en_US.UTF-8"

# Enable essential services in squashfs (NO cloud-init — it runs on data disk only)
# Emergency access is via Azure Serial Console, no SSH needed in squashfs
arch-chroot "${WORK_DIR}/squashfs-root" bash -c '
    sed -i "s/^#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    locale-gen
    systemctl enable systemd-networkd
    systemctl enable systemd-resolved
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
'

# Network config for Azure (DHCP on all ethernet)
cat > "${WORK_DIR}/squashfs-root/etc/systemd/network/20-wired.network" << 'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
DNS=168.63.129.16
EOF

# Install the first-boot provisioning scripts into squashfs
install -Dm755 initcpio/hooks/arch-root-discover \
    "${WORK_DIR}/squashfs-root/usr/lib/initcpio/hooks/arch-root-discover" 2>/dev/null || true
install -Dm644 initcpio/install/arch-root-discover \
    "${WORK_DIR}/squashfs-root/usr/lib/initcpio/install/arch-root-discover" 2>/dev/null || true

# Install first-boot service and script
install -Dm755 first-boot/provision-data-disk.sh \
    "${WORK_DIR}/squashfs-root/usr/local/bin/provision-data-disk.sh"
install -Dm644 first-boot/provision-data-disk.service \
    "${WORK_DIR}/squashfs-root/etc/systemd/system/provision-data-disk.service"

# Enable first-boot provisioning (ConditionFirstBoot or check file)
arch-chroot "${WORK_DIR}/squashfs-root" systemctl enable provision-data-disk.service

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

# Partition: 512MB ESP + rest for root
sfdisk "${WORK_DIR}/${IMAGE_NAME}.raw" << 'EOF'
label: gpt
size=512M, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI System"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="Arch Root"
EOF

# Setup loop device
LOOP_DEV=$(losetup --find --show --partscan "${WORK_DIR}/${IMAGE_NAME}.raw")
ESP_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

# Format partitions
mkfs.vfat -F 32 -n "ESP" "${ESP_PART}"
mkfs.btrfs -f -L "archboot" "${ROOT_PART}"

# Mount
mount "${ROOT_PART}" "${WORK_DIR}/mnt"
mkdir -p "${WORK_DIR}/mnt/efi"
mount "${ESP_PART}" "${WORK_DIR}/mnt/efi"

# Create BTRFS subvolumes for persistent data on the boot disk
# The 4GB OS disk has ~3.5GB after ESP — used for squashfs + /var/log + /var/cache
btrfs subvolume create "${WORK_DIR}/mnt/@log"
btrfs subvolume create "${WORK_DIR}/mnt/@cache"

# Create mount structure
mkdir -p "${WORK_DIR}/mnt"/{var/log,var/cache,sfs}

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
install -Dm644 initcpio/install/arch-root-discover \
    "${WORK_DIR}/squashfs-root/usr/lib/initcpio/install/arch-root-discover"
install -Dm755 initcpio/hooks/arch-root-discover \
    "${WORK_DIR}/squashfs-root/usr/lib/initcpio/hooks/arch-root-discover"
install -Dm644 initcpio/install/squashfs-overlay \
    "${WORK_DIR}/squashfs-root/usr/lib/initcpio/install/squashfs-overlay"
install -Dm755 initcpio/hooks/squashfs-overlay \
    "${WORK_DIR}/squashfs-root/usr/lib/initcpio/hooks/squashfs-overlay"

# Create mkinitcpio preset for the boot image
cat > "${WORK_DIR}/squashfs-root/etc/mkinitcpio.conf.d/azure-boot.conf" << 'MKINITCONF'
MODULES=(hv_vmbus hv_storvsc hv_netvsc hv_utils squashfs overlay loop)
BINARIES=(btrfs cryptsetup tpm2_unseal)
HOOKS=(systemd autodetect modconf kms block arch-root-discover squashfs-overlay filesystems)
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

# Build UKI
ukify build \
    --linux="${WORK_DIR}/squashfs-root/boot/vmlinuz-linux-hardened" \
    --initrd="${WORK_DIR}/squashfs-root/boot/initramfs-azure.img" \
    --cmdline="@${WORK_DIR}/cmdline.txt" \
    --os-release="@${WORK_DIR}/squashfs-root/usr/lib/os-release" \
    --output="${WORK_DIR}/mnt/efi/EFI/Linux/arch-linux.efi"

# systemd-boot loader config
mkdir -p "${WORK_DIR}/mnt/efi/loader"
cat > "${WORK_DIR}/mnt/efi/loader/loader.conf" << 'EOF'
default arch-linux.efi
timeout 5
console-mode max
editor no
EOF

# Install systemd-boot
arch-chroot "${WORK_DIR}/squashfs-root" \
    bootctl install --esp-path=/efi 2>/dev/null || \
    cp "${WORK_DIR}/squashfs-root/usr/lib/systemd/boot/efi/systemd-bootx64.efi" \
       "${WORK_DIR}/mnt/efi/EFI/BOOT/BOOTX64.EFI"

mkdir -p "${WORK_DIR}/mnt/efi/EFI/BOOT"
cp "${WORK_DIR}/squashfs-root/usr/lib/systemd/boot/efi/systemd-bootx64.efi" \
   "${WORK_DIR}/mnt/efi/EFI/BOOT/BOOTX64.EFI"

########################################################################
# PHASE 4: Finalize image
########################################################################
echo ":: Phase 4 — Finalizing..."

# Unmount
sync
umount "${WORK_DIR}/mnt/efi"
umount "${WORK_DIR}/mnt"
losetup -d "${LOOP_DEV}"
LOOP_DEV=""

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
