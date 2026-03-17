#!/bin/bash
# provision-data-disk.sh — First-boot provisioning of an attached Azure data disk
#
# Called by provision-data-disk.service when booted into squashfs with a raw data disk.
# This script:
#   1. Encrypts the data disk with LUKS2 + vTPM
#   2. Creates BTRFS filesystem with subvolumes
#   3. Installs full Arch Linux system from squashfs + pacman update
#   4. Regenerates initramfs/UKI for data-disk boot
#   5. Reboots into the new root
set -euo pipefail

LOG="/var/log/provision-data-disk.log"
exec > >(tee -a "$LOG") 2>&1

BOOT_MODE=$(cat /run/arch-root/boot-mode 2>/dev/null || echo "unknown")
DATA_DISK=$(cat /run/arch-root/raw-data-disk 2>/dev/null || echo "")
ZSTD_LEVEL=6
MAPPER_NAME="arch_root"

echo "=== Arch Linux Data Disk Provisioning ==="
echo "Boot mode: ${BOOT_MODE}"
echo "Data disk: ${DATA_DISK}"
echo "Date: $(date -u)"

if [[ "$BOOT_MODE" != "squashfs-provision" ]]; then
    echo "Not in provisioning mode (mode=${BOOT_MODE}). Exiting."
    exit 0
fi

if [[ -z "$DATA_DISK" || ! -b "$DATA_DISK" ]]; then
    echo "ERROR: No valid data disk found at '${DATA_DISK}'"
    exit 1
fi

########################################################################
# Step 1: Encrypt data disk with LUKS2 + vTPM
########################################################################
echo ":: Step 1 — Encrypting ${DATA_DISK} with LUKS2..."

# Wipe any existing signatures
wipefs -a "${DATA_DISK}"

# Generate a random recovery passphrase (displayed once on serial console)
RECOVERY_KEY=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n')

# Format LUKS2 with strong parameters
echo -n "$RECOVERY_KEY" | cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --pbkdf-memory 131072 \
    --iter-time 5000 \
    --pbkdf-parallel 2 \
    --label "arch_root_luks" \
    --batch-mode \
    "${DATA_DISK}" -

# Open for formatting
echo -n "$RECOVERY_KEY" | cryptsetup open "${DATA_DISK}" "${MAPPER_NAME}" -

# Enroll TPM2 — binds to PCR 7 (Secure Boot state) + PCR 11 (unified kernel image)
echo ":: Enrolling vTPM key (PCR 7+11)..."
echo -n "$RECOVERY_KEY" | systemd-cryptenroll --tpm2-device=auto \
    --tpm2-pcrs=7+11 \
    --unlock-password \
    "${DATA_DISK}"

# Display the recovery key on serial console (one-time, Azure RBAC-protected)
echo ""
echo "============================================================"
echo "  LUKS RECOVERY KEY — SAVE THIS NOW"
echo "  (visible only on Azure Serial Console)"
echo "============================================================"
echo ""
echo "  ${RECOVERY_KEY}"
echo ""
echo "  Store this key securely (e.g. Azure Key Vault, password"
echo "  manager). It is the only way to unlock the data disk if"
echo "  the vTPM is unavailable."
echo "============================================================"
echo ""

echo ":: LUKS2 + vTPM enrollment complete."

########################################################################
# Step 2: Create BTRFS filesystem with subvolumes
########################################################################
echo ":: Step 2 — Creating BTRFS filesystem..."

mkfs.btrfs -f -L "arch_root" "/dev/mapper/${MAPPER_NAME}"

# Mount and create subvolumes
MOUNT_ROOT="/mnt/newroot"
mkdir -p "${MOUNT_ROOT}"
mount -o compress=zstd:${ZSTD_LEVEL},noatime "/dev/mapper/${MAPPER_NAME}" "${MOUNT_ROOT}"

btrfs subvolume create "${MOUNT_ROOT}/@"
btrfs subvolume create "${MOUNT_ROOT}/@home"
btrfs subvolume create "${MOUNT_ROOT}/@root"
btrfs subvolume create "${MOUNT_ROOT}/@srv"
btrfs subvolume create "${MOUNT_ROOT}/@log"
btrfs subvolume create "${MOUNT_ROOT}/@cache"
btrfs subvolume create "${MOUNT_ROOT}/@vartmp"

# Set default subvolume
btrfs subvolume set-default "${MOUNT_ROOT}/@"

umount "${MOUNT_ROOT}"

# Remount with subvolumes
mount -o compress=zstd:${ZSTD_LEVEL},noatime,discard=async,autodefrag,subvol=@ \
    "/dev/mapper/${MAPPER_NAME}" "${MOUNT_ROOT}"

mkdir -p "${MOUNT_ROOT}"/{home,root,srv,var/log,var/cache,var/tmp,efi}
mount -o compress=zstd:${ZSTD_LEVEL},noatime,nosuid,nodev,subvol=@home "/dev/mapper/${MAPPER_NAME}" "${MOUNT_ROOT}/home"
mount -o compress=zstd:${ZSTD_LEVEL},noatime,subvol=@root "/dev/mapper/${MAPPER_NAME}" "${MOUNT_ROOT}/root"
mount -o compress=zstd:${ZSTD_LEVEL},noatime,subvol=@srv "/dev/mapper/${MAPPER_NAME}" "${MOUNT_ROOT}/srv"
mount -o compress=zstd:${ZSTD_LEVEL},noatime,nosuid,noexec,nodev,subvol=@log "/dev/mapper/${MAPPER_NAME}" "${MOUNT_ROOT}/var/log"
mount -o compress=zstd:${ZSTD_LEVEL},noatime,nosuid,nodev,subvol=@cache "/dev/mapper/${MAPPER_NAME}" "${MOUNT_ROOT}/var/cache"
mount -o compress=zstd:${ZSTD_LEVEL},noatime,nosuid,noexec,nodev,subvol=@vartmp "/dev/mapper/${MAPPER_NAME}" "${MOUNT_ROOT}/var/tmp"

echo ":: BTRFS subvolumes created."

########################################################################
# Step 3: Install system from squashfs base + update
########################################################################
echo ":: Step 3 — Installing system from squashfs..."

# Extract the squashfs directly onto the data disk. This is faster than pacstrap
# (no network download) and preserves the exact package set from the image.
# cloud-init is not in the squashfs — it gets installed in the next step.
SFS_IMAGE="/run/archboot/sfs/airootfs.sfs"
if [[ -f "$SFS_IMAGE" ]]; then
    echo ":: Extracting squashfs to data disk (this takes a few minutes)..."
    unsquashfs -f -d "${MOUNT_ROOT}" "$SFS_IMAGE"
elif [[ -d /run/archiso/sfs ]]; then
    echo ":: Squashfs already mounted, copying..."
    cp -a /run/archiso/sfs/. "${MOUNT_ROOT}/"
else
    echo ":: No squashfs found, falling back to pacstrap..."
    pacstrap -c "${MOUNT_ROOT}" base linux-hardened linux-firmware \
        openssh base-devel apparmor btrfs-progs nano python sudo \
        wireguard-tools audit systemd-ukify tpm2-tools tpm2-tss zram-generator
fi

# Remove squashfs-only artifacts that don't belong on the data disk
rm -f "${MOUNT_ROOT}/usr/local/bin/provision-data-disk.sh"
rm -f "${MOUNT_ROOT}/etc/systemd/system/provision-data-disk.service"

# Generate fstab
genfstab -U "${MOUNT_ROOT}" > "${MOUNT_ROOT}/etc/fstab"

# Update system and install cloud-init + openssh (not in squashfs to keep it small)
echo ":: Updating system and installing cloud-init, openssh..."
arch-chroot "${MOUNT_ROOT}" pacman -Syu --noconfirm openssh cloud-init cloud-utils

# Enable services on the data disk
arch-chroot "${MOUNT_ROOT}" bash -c '
    systemctl enable sshd
    systemctl enable cloud-init-main.service
    systemctl enable cloud-init-network.service
    systemctl enable cloud-final.service
'

# Clean cloud-init state so it treats the data disk root as a fresh instance
rm -rf "${MOUNT_ROOT}/var/lib/cloud"

########################################################################
# Step 4: Configure the new root
########################################################################
echo ":: Step 4 — Configuring new root..."

# Crypttab for the data disk — use LUKS label for portability
cat > "${MOUNT_ROOT}/etc/crypttab.initramfs" << CRYPTTAB
# <name>       <device>                        <password>  <options>
arch_root      LABEL=arch_root_luks            -           tpm2-device=auto
CRYPTTAB

# Mount the ESP from the boot disk
BOOT_ESP=$(blkid -L "ESP" 2>/dev/null || echo "/dev/sda1")
mount "${BOOT_ESP}" "${MOUNT_ROOT}/efi"

# mkinitcpio config for data-disk boot
cat > "${MOUNT_ROOT}/etc/mkinitcpio.conf.d/azure.conf" << 'MKINITCONF'
MODULES=(hv_vmbus hv_storvsc hv_netvsc hv_utils tpm_crb tpm_tis dm-crypt btrfs)
HOOKS=(systemd autodetect modconf kms sd-vconsole block sd-encrypt btrfs filesystems)
COMPRESSION="zstd"
MKINITCONF

# Kernel command line for data-disk root — labels only, no UUIDs
cat > "${MOUNT_ROOT}/etc/kernel/cmdline" << CMDLINE
rd.luks.name=arch_root_luks=arch_root rd.luks.options=tpm2-device=auto
root=LABEL=arch_root rootflags=subvol=@,compress=zstd:${ZSTD_LEVEL} rw
console=tty0 console=ttyS0,115200 bgrt_disable
lsm=landlock,lockdown,yama,integrity,apparmor,bpf slab_nomerge
init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 pti=on
randomize_kstack_offset=on vsyscall=none debugfs=off oops=panic
intel_iommu=on amd_iommu=on
CMDLINE

# Regenerate initramfs and UKI
echo ":: Regenerating initramfs + UKI for data-disk root..."
arch-chroot "${MOUNT_ROOT}" mkinitcpio -P

# Re-enroll TPM2 with the new PCR measurements (UKI changed)
echo ":: Re-enrolling vTPM with updated PCR values..."
systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto \
    --tpm2-pcrs=7+11 \
    "${DATA_DISK}" || echo "WARNING: TPM re-enrollment may need manual step after reboot"

########################################################################
# Step 5: Mark provisioning complete and reboot
########################################################################
echo ":: Step 5 — Finalizing..."

# Leave a marker so we don't re-provision
touch "${MOUNT_ROOT}/etc/arch-root-provisioned"
echo "provisioned=$(date -uIs)" > "${MOUNT_ROOT}/etc/arch-root-provisioned"
echo "data_disk=${DATA_DISK}" >> "${MOUNT_ROOT}/etc/arch-root-provisioned"

# Sync and unmount
sync
umount -R "${MOUNT_ROOT}"

echo "=== Provisioning complete. Rebooting into data disk root... ==="
systemctl reboot
