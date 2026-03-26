#!/bin/bash
# provision-data-disk.sh — First-boot provisioning of an attached Azure data disk
#
# Called by provision-data-disk.service when booted into squashfs with a raw data disk.
# This script:
#   1. Encrypts the data disk with LUKS2 + vTPM
#   2. Creates BTRFS filesystem with subvolumes
#   3. Installs full Arch Linux system from squashfs + pacman update
#   4. Preserves prebuilt UKI state; later key-sync handles future UKI rebuild prep
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
ROOT_PASSWORD_SECRET_NAME="${ROOT_PASSWORD_SECRET_NAME:-root-login-password}"
PCR_SIGNING_AVAILABLE=0
PCR_SIGNING_PUBLIC_KEY_PATH="/run/archboot/keys/pcr-signing-public-key.pem"

FULL_INSTALL_PACKAGES=()
if [[ -r /usr/local/share/arch-image/packages.conf ]]; then
    # shellcheck disable=SC1091
    source /usr/local/share/arch-image/packages.conf
fi

if [[ ${#FULL_INSTALL_PACKAGES[@]} -eq 0 ]]; then
    FULL_INSTALL_PACKAGES=(
        base linux-hardened openssh base-devel apparmor btrfs-progs
        nano python sudo wireguard-tools audit systemd-ukify
        tpm2-tools tpm2-tss zram-generator
    )
fi

# Explicitly block firmware bundles not needed for Azure VMs.
PACMAN_IGNORE_PACKAGES=(linux-firmware)

enroll_tpm2_with_policy() {
    local luks_dev="$1"
    local unlock_key_file="$2"
    local enroll_args=(--tpm2-device=auto --unlock-key-file="$unlock_key_file")

    if [[ "${PCR_SIGNING_AVAILABLE:-0}" -eq 1 ]]; then
        echo ":: Enrolling TPM2 key with signed PCR 11 policy"
        enroll_args+=(--tpm2-public-key="${PCR_SIGNING_PUBLIC_KEY_PATH}" --tpm2-public-key-pcrs=11)
    else
        echo ":: Enrolling TPM2 key without PCR policy (PCR signing keys not available)"
    fi

    systemd-cryptenroll "${enroll_args[@]}" "$luks_dev"
}

# Ensure IgnorePkg is placed under [options], not at EOF where it may be ignored.
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

run_provision_stage_scripts() {
    local stage_dir="/usr/local/lib/provision.d"
    local stage

    [[ -d "${stage_dir}" ]] || return 0

    while IFS= read -r -d '' stage; do
        echo ":: Running provision stage: $(basename "${stage}")"
        MOUNT_ROOT="${MOUNT_ROOT}" bash "${stage}"
    done < <(find "${stage_dir}" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)
}

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

fetch_secret_value_from_keyvault() {
    local kv_name="$1"
    local secret_name="$2"
    local token

    token="$(get_imds_token)"

    curl -fsS -H "Authorization: Bearer ${token}" \
        "https://${kv_name}.vault.azure.net/secrets/${secret_name}?api-version=7.4" \
        | python -c 'import json,sys; print(json.load(sys.stdin)["value"], end="")'
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

    enroll_tpm2_with_policy "${var_loop}" "${keyfile}"

    shred -u "${keyfile}" 2>/dev/null || rm -f "${keyfile}"

    cryptsetup close "${VAR_MAPPER_NAME}" 2>/dev/null || true
    losetup -d "${var_loop}" 2>/dev/null || true

    umount "${boot_rw}" 2>/dev/null || true

    echo ":: TPM-encrypted os-disk /var store created and enrolled."
}

########################################################################
# Enroll TPM with a stable signed PCR11 policy from the prebuilt UKI.
# The corresponding public key is published on the boot ESP at image build.
########################################################################
if [[ -f "${PCR_SIGNING_PUBLIC_KEY_PATH}" ]]; then
    PCR_SIGNING_AVAILABLE=1
    echo ":: Using build-time PCR signing public key for TPM2 policy enrollment."
else
    echo "WARNING: ${PCR_SIGNING_PUBLIC_KEY_PATH} not found; enrolling TPM2 without signed PCR policy."
fi

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

# Enroll TPM2 key for arch_root. Use PCR 7 only when Secure Boot is enabled;
# otherwise enroll without a PCR policy so non-Secure-Boot test boots work.
echo ":: Enrolling vTPM key..."
enroll_tpm2_with_policy "${DATA_DISK}" "${KEYFILE}"

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
        ensure_ignore_pkg_in_pacman_conf "${PACSTRAP_TMP_CONF}" "${PACMAN_IGNORE_PACKAGES[*]}"

        pacstrap -C "${PACSTRAP_TMP_CONF}" -c "${MOUNT_ROOT}" \
            "${FULL_INSTALL_PACKAGES[@]}"
    else
        pacstrap -c "${MOUNT_ROOT}" "${FULL_INSTALL_PACKAGES[@]}"
    fi
fi

# Remove squashfs-only artifacts that don't belong on the data disk
rm -f "${MOUNT_ROOT}/usr/local/bin/provision-data-disk.sh"
rm -f "${MOUNT_ROOT}/etc/systemd/system/provision-data-disk.service"
rm -rf "${MOUNT_ROOT}/usr/local/lib/provision.d"
rm -rf "${MOUNT_ROOT}/usr/local/share/provision-overlay"

# Ensure the chroot has a pacman.conf (squashfs base may not include one)
if [[ ! -f "${MOUNT_ROOT}/etc/pacman.conf" ]]; then
    cp /etc/pacman.conf "${MOUNT_ROOT}/etc/pacman.conf"
fi
# Apply IgnorePkg to the chroot's pacman.conf
if [[ ${#PACMAN_IGNORE_PACKAGES[@]} -gt 0 ]]; then
    ensure_ignore_pkg_in_pacman_conf "${MOUNT_ROOT}/etc/pacman.conf" "${PACMAN_IGNORE_PACKAGES[*]}"
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

# Packages are pre-baked into squashfs to keep first-boot deterministic.
# Do not run pacman transactions here; package upgrades can trigger initramfs
# rebuilds and alter PCR measurements during the provisioning boot.
echo ":: Using pre-baked openssh/cloud-init/cloud-utils from squashfs copy."

run_provision_stage_scripts

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

# Fetch Secure Boot metadata into the encrypted root.
# Public cert is on the ESP. Private key retrieval is intentionally deferred
# to post-provision key-sync automation.
KEY_VAULT_NAME="$(get_keyvault_name_from_vm_tag || true)"

mkdir -p "${MOUNT_ROOT}/etc/kernel"

# Copy public certificate from ESP
if [[ -f "${MOUNT_ROOT}/efi/keys/secure-boot-certificate.pem" ]]; then
    cp "${MOUNT_ROOT}/efi/keys/secure-boot-certificate.pem" \
       "${MOUNT_ROOT}/etc/kernel/secure-boot-certificate.pem"
    echo ":: Secure Boot certificate copied from ESP."
else
    echo "WARNING: No Secure Boot certificate found on ESP."
fi

echo ":: Deferring Secure Boot private key retrieval to post-provision key-sync."

# PCR signing public key copied from the prebuilt image ESP for TPM policy use.
PCR_SIGNING_ENABLED=0
if [[ "${PCR_SIGNING_AVAILABLE}" -eq 1 ]]; then
    install -Dm644 "${PCR_SIGNING_PUBLIC_KEY_PATH}" \
       "${MOUNT_ROOT}/etc/kernel/pcr-signing-public-key.pem"
    PCR_SIGNING_ENABLED=1
fi

# Fetch and apply root password from Key Vault so console access requires auth.
if [[ -n "${KEY_VAULT_NAME}" ]]; then
    echo ":: Fetching root password from Key Vault '${KEY_VAULT_NAME}'..."
    ROOT_PASSWORD_VALUE="$(fetch_secret_value_from_keyvault "${KEY_VAULT_NAME}" "${ROOT_PASSWORD_SECRET_NAME}" 2>/dev/null || true)"
    if [[ -n "${ROOT_PASSWORD_VALUE}" ]]; then
        printf 'root:%s\n' "${ROOT_PASSWORD_VALUE}" | arch-chroot "${MOUNT_ROOT}" chpasswd
        echo ":: Root password updated from Key Vault secret '${ROOT_PASSWORD_SECRET_NAME}'."
    else
        echo "WARNING: Could not fetch root password secret '${ROOT_PASSWORD_SECRET_NAME}' from Key Vault."
    fi
else
    echo "WARNING: No KeyVaultName VM tag found. Skipping root password fetch."
fi

cat > "${MOUNT_ROOT}/etc/arch-keyvault.conf" << EOF
KEY_VAULT_NAME="${KEY_VAULT_NAME}"
SECURE_BOOT_PRIVATE_KEY_SECRET_NAME="${SECURE_BOOT_PRIVATE_KEY_SECRET_NAME}"
ROOT_PASSWORD_SECRET_NAME="${ROOT_PASSWORD_SECRET_NAME}"
PCR_SIGNING_ENABLED=${PCR_SIGNING_ENABLED}
EOF
chmod 0600 "${MOUNT_ROOT}/etc/arch-keyvault.conf"

# Build uki.conf with available signing capabilities
mkdir -p "${MOUNT_ROOT}/etc/kernel"
{
    echo "[UKI]"
    echo "SecureBootPrivateKey=/etc/kernel/secure-boot-private-key.pem"
    echo "SecureBootCertificate=/etc/kernel/secure-boot-certificate.pem"
    if [[ "${PCR_SIGNING_ENABLED}" -eq 1 ]]; then
        echo "PCRPKey=/etc/kernel/pcr-signing-public-key.pem"
    fi
} > "${MOUNT_ROOT}/etc/kernel/uki.conf"
echo ":: UKI config written (PCR=${PCR_SIGNING_ENABLED})."

# secure-boot-resign script + pacman hook are already shipped in the
# prebuilt squashfs image and copied to the data-disk root in Step 3.

# Preserve the prebuilt signed UKI from image build time.
# The initrd logic in that UKI already chooses data-disk root when available
# and falls back to squashfs otherwise.
echo ":: Keeping prebuilt signed UKI (no first-boot rebuild)."

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
