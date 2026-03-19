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

BOOT_MODE=$(cat /run/arch-root/boot-mode 2>/dev/null || cat /etc/arch-root/boot-mode 2>/dev/null || echo "unknown")
ZSTD_LEVEL=6
MAPPER_NAME="arch_root"
VAR_MAPPER_NAME="arch_var"
VAR_CONTAINER_SIZE="768M"
SECURE_BOOT_PRIVATE_KEY_SECRET_NAME="${SECURE_BOOT_PRIVATE_KEY_SECRET_NAME:-secure-boot-private-key}"
SECURE_BOOT_CERTIFICATE_SECRET_NAME="${SECURE_BOOT_CERTIFICATE_SECRET_NAME:-secure-boot-certificate}"

# Explicitly block firmware bundles not needed for Azure VMs.
PACMAN_IGNORE_PACKAGES=(linux-firmware linux-hardened)

# Check whether a disk contains the archboot partition (OS disk).
disk_is_os() {
    local disk="$1" part
    if [[ "$(blkid -s LABEL -o value "${disk}" 2>/dev/null)" == "archboot" ]]; then
        return 0
    fi
    for part in "${disk}"{1,2,3,4} "${disk}p"{1,2,3,4}; do
        [[ -b "$part" ]] || continue
        if [[ "$(blkid -s LABEL -o value "${part}" 2>/dev/null)" == "archboot" ]]; then
            return 0
        fi
    done
    return 1
}

# Re-discover the data disk at runtime — /dev/sd* names from initrd are
# not stable across switch-root because kernel enumeration order can change.
discover_data_disk() {
    local dev

    # Azure SCSI data disks (most reliable path on Azure)
    if [[ -d /dev/disk/azure/scsi1 ]]; then
        for lun in /dev/disk/azure/scsi1/lun*; do
            [[ -b "$lun" ]] || continue
            readlink -f "$lun"
            return 0
        done
    fi

    # Skip the Azure resource disk (identified by /dev/disk/azure/resource)
    local resource_disk=""
    if [[ -b /dev/disk/azure/resource ]]; then
        resource_disk=$(readlink -f /dev/disk/azure/resource)
    fi

    # Fallback: scan all SCSI/virtio/NVMe disks, skipping OS + resource disk
    for dev in /dev/sd{a,b,c,d,e} /dev/vd{a,b,c,d,e} /dev/nvme{0,1,2,3}n1; do
        [[ -b "$dev" ]] || continue
        disk_is_os "$dev" && continue
        [[ "$dev" == "$resource_disk" ]] && continue
        echo "$dev"
        return 0
    done
    return 1
}

DATA_DISK=$(discover_data_disk || echo "")

echo "=== Arch Linux Data Disk Provisioning ==="
echo "Boot mode: ${BOOT_MODE}"
echo "Data disk: ${DATA_DISK}"
echo "Date: $(date -u)"

if [[ "$BOOT_MODE" != "squashfs-provision" ]]; then
    echo "Not in provisioning mode (mode=${BOOT_MODE}). Exiting."
    exit 0
fi

if [[ -z "$DATA_DISK" || ! -b "$DATA_DISK" ]]; then
    echo "ERROR: No valid data disk found"
    exit 1
fi

get_imds_token() {
    curl -fsS -H Metadata:true \
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
        | python -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

get_keyvault_name_from_vm_tag() {
    local compute_json
    compute_json="$(curl -fsS -H Metadata:true \
        "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01")"

    python -c 'import json,sys; tags=json.load(sys.stdin).get("tags","");
for item in tags.split(";"):
    if not item or ":" not in item:
        continue
    k,v=item.split(":",1)
    if k.strip()=="KeyVaultName":
        print(v.strip())
        break' <<<"${compute_json}"
}

fetch_private_key_from_keyvault() {
    local kv_name="$1"
    local secret_name="$2"
    local out_path="$3"
    local token

    token="$(get_imds_token)"

    curl -fsS -H "Authorization: Bearer ${token}" \
        "https://${kv_name}.vault.azure.net/secrets/${secret_name}?api-version=7.4" \
        | python -c 'import json,sys; print(json.load(sys.stdin)["value"], end="")' \
        > "${out_path}"
    chmod 600 "${out_path}"
}

store_secret_in_keyvault() {
    local kv_name="$1"
    local secret_name="$2"
    local secret_value="$3"
    local token

    token="$(get_imds_token)"

    curl -fsS -X PUT \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"value\": \"${secret_value}\"}" \
        "https://${kv_name}.vault.azure.net/secrets/${secret_name}?api-version=7.4" \
        > /dev/null
}

setup_osdisk_var_encryption() {
    local boot_rw="/mnt/archboot-rw"
    local boot_device=""
    local var_img=""
    local var_loop=""
    local var_mount="/mnt/archvar"
    local var_recovery_key=""

    boot_device="$(blkid -L "archboot" 2>/dev/null || true)"
    if [[ -z "${boot_device}" ]]; then
        echo "WARNING: Could not find archboot partition; skipping encrypted /var setup on OS disk."
        return 0
    fi

    # Mount the BTRFS boot partition at a fresh path to avoid conflicts
    # with the initrd's bind mount at /run/archboot (which can't be
    # remounted because the kernel sees it as an overlay after switch-root).
    mkdir -p "${boot_rw}"
    mount -o rw "${boot_device}" "${boot_rw}"
    mkdir -p "${boot_rw}/crypt"
    var_img="${boot_rw}/crypt/var-store.luks"

    if [[ -f "${var_img}" ]]; then
        echo ":: Existing TPM-encrypted os-disk var container detected."
        umount "${boot_rw}"
        return 0
    fi

    echo ":: Creating TPM-encrypted os-disk var container (${VAR_CONTAINER_SIZE})..."
    truncate -s "${VAR_CONTAINER_SIZE}" "${var_img}"

    var_recovery_key=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n')
    local keyfile
    keyfile=$(mktemp /run/.varkey-XXXXXX)
    chmod 600 "${keyfile}"
    printf '%s' "${var_recovery_key}" > "${keyfile}"

    cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --pbkdf argon2id \
        --pbkdf-memory 131072 \
        --iter-time 5000 \
        --pbkdf-parallel 2 \
        --label "arch_var_luks" \
        --batch-mode \
        --key-file "${keyfile}" \
        "${var_img}"

    var_loop=$(losetup --find --show "${var_img}")
    cryptsetup open --key-file "${keyfile}" "${var_loop}" "${VAR_MAPPER_NAME}"

    mkfs.btrfs -f -L "arch_var" "/dev/mapper/${VAR_MAPPER_NAME}"
    mkdir -p "${var_mount}"
    mount -o compress=zstd:${ZSTD_LEVEL},noatime "/dev/mapper/${VAR_MAPPER_NAME}" "${var_mount}"
    mkdir -p "${var_mount}/log" "${var_mount}/cache"
    umount "${var_mount}"

    systemd-cryptenroll --tpm2-device=auto \
        --tpm2-pcrs=11 \
        --unlock-key-file="${keyfile}" \
        "${var_loop}"

    shred -u "${keyfile}" 2>/dev/null || rm -f "${keyfile}"

    cryptsetup close "${VAR_MAPPER_NAME}" 2>/dev/null || true
    losetup -d "${var_loop}" 2>/dev/null || true

    umount "${boot_rw}" 2>/dev/null || true

    echo ":: TPM-encrypted os-disk /var store created and enrolled."
}

########################################################################
# Step 0: Ensure encrypted /var/log + /var/cache on OS disk (TPM)
########################################################################
echo ":: Step 0 — Preparing TPM-encrypted os-disk /var store..."
setup_osdisk_var_encryption

########################################################################
# Step 1: Encrypt data disk with LUKS2 + vTPM
########################################################################
echo ":: Step 1 — Encrypting ${DATA_DISK} with LUKS2..."

# udevd holds block devices open for probing, preventing exclusive access.
# udevadm lock (systemd 254+) tells udevd to release the device temporarily.
udevadm settle
udevadm lock --device="${DATA_DISK}" wipefs -af "${DATA_DISK}"

# Drop stale kernel partition devices left after wiping the partition table
blockdev --rereadpt "${DATA_DISK}" 2>/dev/null || true
udevadm settle

# Generate a random 64-character recovery passphrase
RECOVERY_KEY=$(dd if=/dev/urandom bs=48 count=1 2>/dev/null | base64 | tr -d '\n' | head -c 64)
KEYFILE=$(mktemp /run/.diskkey-XXXXXX)
chmod 600 "${KEYFILE}"
printf '%s' "$RECOVERY_KEY" > "${KEYFILE}"

# Format LUKS2 with strong parameters
udevadm lock --device="${DATA_DISK}" cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --pbkdf-memory 131072 \
    --iter-time 5000 \
    --pbkdf-parallel 2 \
    --label "arch_root_luks" \
    --batch-mode \
    --key-file "${KEYFILE}" \
    "${DATA_DISK}"

# Open for formatting
udevadm lock --device="${DATA_DISK}" cryptsetup open --key-file "${KEYFILE}" "${DATA_DISK}" "${MAPPER_NAME}"

# Enroll TPM2 — binds to PCR 11 (UKI components measured by systemd-stub)
echo ":: Enrolling vTPM key (PCR 11)..."
systemd-cryptenroll --tpm2-device=auto \
    --tpm2-pcrs=11 \
    --unlock-key-file="${KEYFILE}" \
    "${DATA_DISK}"

shred -u "${KEYFILE}" 2>/dev/null || rm -f "${KEYFILE}"

# Attempt to store recovery key in Key Vault; only display on console if that fails
KV_NAME=$(get_keyvault_name_from_vm_tag 2>/dev/null || true)
RECOVERY_KEY_SAVED=0
if [[ -n "${KV_NAME}" ]]; then
    HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo "archlinux")
    SECRET_NAME="luks-recovery-${HOSTNAME}"
    echo ":: Storing recovery key in Key Vault '${KV_NAME}' as '${SECRET_NAME}'..."
    if store_secret_in_keyvault "${KV_NAME}" "${SECRET_NAME}" "${RECOVERY_KEY}"; then
        echo ":: Recovery key stored in Key Vault successfully."
        RECOVERY_KEY_SAVED=1
    else
        echo "WARNING: Failed to store recovery key in Key Vault."
    fi
else
    echo ":: No KeyVaultName VM tag — cannot store recovery key in Key Vault."
fi

if [[ "${RECOVERY_KEY_SAVED}" -eq 0 ]]; then
    echo ""
    echo "============================================================"
    echo "  LUKS RECOVERY KEY — SAVE THIS NOW"
    echo "  (visible only on Azure Serial Console)"
    echo "============================================================"
    echo ""
    echo "  ${RECOVERY_KEY}"
    echo ""
    echo "  Store this key securely. It is the only way to unlock"
    echo "  the data disk if the vTPM is unavailable."
    echo "============================================================"
    echo ""
fi

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
# Try the direct SFS file on the BTRFS boot partition first, then fall back
# to the mounted squashfs, then pacstrap.
SFS_IMAGE=""
SFS_MNT="/mnt/archboot-rw"
SFS_DEV="$(blkid -L "archboot" 2>/dev/null || true)"
if [[ -n "${SFS_DEV}" ]]; then
    mkdir -p "${SFS_MNT}"
    mount -o ro "${SFS_DEV}" "${SFS_MNT}" 2>/dev/null || true
    if [[ -f "${SFS_MNT}/sfs/airootfs.sfs" ]]; then
        SFS_IMAGE="${SFS_MNT}/sfs/airootfs.sfs"
    fi
fi

if [[ -n "$SFS_IMAGE" ]]; then
    echo ":: Extracting squashfs to data disk (this takes a few minutes)..."
    unsquashfs -f -d "${MOUNT_ROOT}" "$SFS_IMAGE"
    umount "${SFS_MNT}" 2>/dev/null || true
elif [[ -d /run/archiso/sfs ]]; then
    echo ":: Squashfs already mounted, copying..."
    cp -a /run/archiso/sfs/. "${MOUNT_ROOT}/"
else
    echo ":: No squashfs found, falling back to pacstrap..."
    if [[ ${#PACMAN_IGNORE_PACKAGES[@]} -gt 0 ]]; then
        PACSTRAP_TMP_CONF="/tmp/pacman.pacstrap.conf"
        cp /etc/pacman.conf "${PACSTRAP_TMP_CONF}"
        {
            printf '\n# Added by provision-data-disk.sh for pacstrap ignore handling\n'
            printf 'IgnorePkg = %s\n' "${PACMAN_IGNORE_PACKAGES[*]}"
        } >> "${PACSTRAP_TMP_CONF}"

        pacstrap -C "${PACSTRAP_TMP_CONF}" -c "${MOUNT_ROOT}" \
            base linux-hardened openssh base-devel apparmor btrfs-progs \
            nano python sudo wireguard-tools audit systemd-ukify \
            tpm2-tools tpm2-tss zram-generator
    else
        pacstrap -c "${MOUNT_ROOT}" base linux-hardened openssh base-devel \
            apparmor btrfs-progs nano python sudo wireguard-tools audit \
            systemd-ukify tpm2-tools tpm2-tss zram-generator
    fi
fi

# Remove squashfs-only artifacts that don't belong on the data disk
rm -f "${MOUNT_ROOT}/usr/local/bin/provision-data-disk.sh"
rm -f "${MOUNT_ROOT}/etc/systemd/system/provision-data-disk.service"

# Ensure the chroot has a pacman.conf (squashfs base may not include one)
if [[ ! -f "${MOUNT_ROOT}/etc/pacman.conf" ]]; then
    cp /etc/pacman.conf "${MOUNT_ROOT}/etc/pacman.conf"
fi
# Apply IgnorePkg to the chroot's pacman.conf
if [[ ${#PACMAN_IGNORE_PACKAGES[@]} -gt 0 ]]; then
    printf 'IgnorePkg = %s\n' "${PACMAN_IGNORE_PACKAGES[*]}" >> "${MOUNT_ROOT}/etc/pacman.conf"
fi

# Ensure mirrorlist is available (squashfs built with pacstrap -M may lack it)
if [[ ! -s "${MOUNT_ROOT}/etc/pacman.d/mirrorlist" ]]; then
    mkdir -p "${MOUNT_ROOT}/etc/pacman.d"
    cp /etc/pacman.d/mirrorlist "${MOUNT_ROOT}/etc/pacman.d/mirrorlist" 2>/dev/null || \
        echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > "${MOUNT_ROOT}/etc/pacman.d/mirrorlist"
fi

# Ensure resolv.conf is available for network access inside chroot
if [[ ! -s "${MOUNT_ROOT}/etc/resolv.conf" ]]; then
    cp -L /etc/resolv.conf "${MOUNT_ROOT}/etc/resolv.conf" 2>/dev/null || true
fi

# Generate fstab
genfstab -U "${MOUNT_ROOT}" > "${MOUNT_ROOT}/etc/fstab"

# Initialise pacman keyring (needed for fresh squashfs extract)
arch-chroot "${MOUNT_ROOT}" bash -c '
    pacman-key --init
    pacman-key --populate archlinux
'

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

# Regenerate locale (squashfs strips /usr/share/i18n/locales to save space;
# the pacman -Syu above restores glibc's locale data)
arch-chroot "${MOUNT_ROOT}" bash -c '
    sed -i "s/^#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    locale-gen
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

# Fetch Secure Boot material into the encrypted root.
# Public cert is on the ESP; only the private key comes from Key Vault.
KEY_VAULT_NAME="$(get_keyvault_name_from_vm_tag || true)"
SECURE_BOOT_ENABLED=0

mkdir -p "${MOUNT_ROOT}/etc/kernel"

# Copy public certificate from ESP
if [[ -f "${MOUNT_ROOT}/efi/keys/secure-boot-certificate.pem" ]]; then
    cp "${MOUNT_ROOT}/efi/keys/secure-boot-certificate.pem" \
       "${MOUNT_ROOT}/etc/kernel/secure-boot-certificate.pem"
    echo ":: Secure Boot certificate copied from ESP."
else
    echo "WARNING: No Secure Boot certificate found on ESP."
fi

# Fetch private key from Key Vault
if [[ -n "${KEY_VAULT_NAME}" ]]; then
    echo ":: Fetching Secure Boot private key from Key Vault '${KEY_VAULT_NAME}'..."
    if fetch_private_key_from_keyvault \
            "${KEY_VAULT_NAME}" \
            "${SECURE_BOOT_PRIVATE_KEY_SECRET_NAME}" \
            "${MOUNT_ROOT}/etc/kernel/secure-boot-private-key.pem" 2>/dev/null; then
        echo ":: Secure Boot private key fetched."
        SECURE_BOOT_ENABLED=1
    else
        echo "WARNING: Could not fetch Secure Boot private key from Key Vault."
    fi
else
    echo "WARNING: No KeyVaultName VM tag found. Skipping Secure Boot private key."
    echo "UKI will not be signed. Set VM tag 'KeyVaultName=<name>' for Secure Boot."
fi

cat > "${MOUNT_ROOT}/etc/arch-keyvault.conf" << EOF
KEY_VAULT_NAME="${KEY_VAULT_NAME}"
SECURE_BOOT_PRIVATE_KEY_SECRET_NAME="${SECURE_BOOT_PRIVATE_KEY_SECRET_NAME}"
SECURE_BOOT_ENABLED=${SECURE_BOOT_ENABLED}
EOF
chmod 0600 "${MOUNT_ROOT}/etc/arch-keyvault.conf"

if [[ "${SECURE_BOOT_ENABLED}" -eq 1 ]]; then
    mkdir -p "${MOUNT_ROOT}/etc/kernel"
    cat > "${MOUNT_ROOT}/etc/kernel/uki.conf" << 'UKICONF'
[UKI]
SecureBootPrivateKey=/etc/kernel/secure-boot-private-key.pem
SecureBootCertificate=/etc/kernel/secure-boot-certificate.pem
UKICONF

mkdir -p "${MOUNT_ROOT}/usr/local/bin"
cat > "${MOUNT_ROOT}/usr/local/bin/secure-boot-resign" << EOF
#!/usr/bin/env bash
set -euo pipefail
export TMPDIR=/var/tmp

KEY_PATH="/etc/kernel/secure-boot-private-key.pem"
CERT_PATH="/etc/kernel/secure-boot-certificate.pem"
SECRET_NAME="${SECURE_BOOT_PRIVATE_KEY_SECRET_NAME}"

log() { echo "[secure-boot-resign] \$*"; }

fetch_keyvault_name() {
    if [[ -f /etc/arch-keyvault.conf ]]; then
        # shellcheck disable=SC1091
        source /etc/arch-keyvault.conf
    fi

    if [[ -n "\${KEY_VAULT_NAME:-}" ]]; then
        echo "\${KEY_VAULT_NAME}"
        return 0
    fi

    local compute_json
    compute_json="\$(curl -fsS -H Metadata:true \
        "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01")" || return 1

    python -c 'import json,sys; tags=json.loads(sys.stdin.read()).get("tags","");
for item in tags.split(";"):
    if not item or ":" not in item:
        continue
    k,v=item.split(":",1)
    if k.strip()=="KeyVaultName":
        print(v.strip())
        break' <<<"\${compute_json}"
}

ensure_private_key() {
    if [[ -s "\${KEY_PATH}" ]]; then
        return 0
    fi

    local kv_name token
    kv_name="\$(fetch_keyvault_name || true)"
    if [[ -z "\${kv_name}" ]]; then
        log "Key is missing and KeyVaultName is not available from /etc/arch-keyvault.conf or VM tags."
        return 1
    fi

    token="\$(curl -fsS -H Metadata:true \
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
        | python -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"

    install -d -m700 /etc/kernel
    curl -fsS -H "Authorization: Bearer \${token}" \
        "https://\${kv_name}.vault.azure.net/secrets/\${SECRET_NAME}?api-version=7.4" \
        | python -c 'import json,sys; print(json.load(sys.stdin)["value"], end="")' \
        > "\${KEY_PATH}"
    chmod 600 "\${KEY_PATH}"
    log "Recovered Secure Boot private key from Key Vault '\${kv_name}'."
}

ensure_private_key

# Detect chainload mode: shim -> UKI directly (no systemd-boot in the chain)
if [[ -f /efi/EFI/BOOT/chainload-uki.marker ]]; then
    # Chainload mode: rebuild UKI and place it as grubx64.efi for shim
    log "Chainload-UKI mode: rebuilding UKI as grubx64.efi..."
    mkinitcpio -P
    if [[ -f /efi/EFI/Linux/arch-linux.efi ]]; then
        sbsign --key "\${KEY_PATH}" --cert "\${CERT_PATH}" \
            --output /efi/EFI/BOOT/grubx64.efi \
            /efi/EFI/Linux/arch-linux.efi
        log "Signed UKI installed as grubx64.efi."
    fi
else
    # Standard mode: update systemd-boot, optionally swap shim
    /usr/bin/bootctl update \
        --certificate "\${CERT_PATH}" \
        --private-key "\${KEY_PATH}" \
        --no-pager || true

    if [[ -f /efi/EFI/BOOT/grubx64.efi ]] && [[ -f /usr/share/shim-signed/shimx64.efi ]]; then
        cp /efi/EFI/BOOT/BOOTX64.EFI /efi/EFI/BOOT/grubx64.efi
        cp /usr/share/shim-signed/shimx64.efi /efi/EFI/BOOT/BOOTX64.EFI
        cp /usr/share/shim-signed/mmx64.efi /efi/EFI/BOOT/mmx64.efi
        log "Shim chain updated."
    else
        log "Direct systemd-boot (no shim)."
    fi
fi
EOF
chmod 0755 "${MOUNT_ROOT}/usr/local/bin/secure-boot-resign"

mkdir -p "${MOUNT_ROOT}/etc/pacman.d/hooks"

# Detect chainload-UKI mode from the ESP marker left at build time
if [[ -f "${MOUNT_ROOT}/efi/EFI/BOOT/chainload-uki.marker" ]]; then
    _HOOK_TARGETS="Target = linux-hardened"
else
    _HOOK_TARGETS=$(printf 'Target = systemd\nTarget = systemd-boot\nTarget = linux-hardened')
fi

cat > "${MOUNT_ROOT}/etc/pacman.d/hooks/90-secure-boot-resign.hook" << EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
${_HOOK_TARGETS}

[Action]
Description = Re-sign Secure Boot artifacts after updates
When = PostTransaction
Exec = /usr/local/bin/secure-boot-resign
EOF
else
    echo ":: Secure Boot disabled — skipping UKI signing config, resign script, and pacman hook."
fi  # SECURE_BOOT_ENABLED

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

# Ensure vconsole.conf exists (required by sd-vconsole hook)
[[ -f "${MOUNT_ROOT}/etc/vconsole.conf" ]] || echo "KEYMAP=us" > "${MOUNT_ROOT}/etc/vconsole.conf"

# Unmount the ESP — we're done reading keys from it.
# NOTE: We do NOT run mkinitcpio -P here. The squashfs UKI on the ESP
# handles data-disk boot via setup-root (discovers LUKS, mounts BTRFS).
# The mkinitcpio config + crypttab above are dormant config for a future
# switch to direct data-disk UKI boot (e.g. via secure-boot-resign).
umount "${MOUNT_ROOT}/efi"

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
