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
ROOT_PASSWORD_SECRET_NAME="${ROOT_PASSWORD_SECRET_NAME:-root-login-password}"
PCR_SIGNING_KEY_DIR="/run/pcr-signing"
PCR_SIGNING_PUBLIC_KEY_PATH="${PCR_SIGNING_KEY_DIR}/pcr-signing-public-key.pem"
PCR_SIGNING_PRIVATE_KEY_PATH="${PCR_SIGNING_KEY_DIR}/pcr-signing-private-key.pem"

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
PACMAN_IGNORE_PACKAGES=(linux-firmware linux-hardened)

secure_boot_enabled() {
    local sb_var sb_state
    sb_var=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -n1 || true)
    [[ -n "$sb_var" ]] || return 1

    # efivar payload starts with 4-byte attributes; byte 5 is SecureBoot state.
    sb_state=$(od -An -t u1 -j4 -N1 "$sb_var" 2>/dev/null | tr -d '[:space:]')
    [[ "$sb_state" == "1" ]]
}

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
# Early: generate PCR signing keypair for TPM2 signed PCR 11 policy.
# Generated fresh on first boot; stored on the encrypted data disk.
# Key Vault backup is attempted later if available.
########################################################################
echo ":: Generating PCR signing keypair for TPM2 enrollment..."
mkdir -p "${PCR_SIGNING_KEY_DIR}"
openssl genrsa -out "${PCR_SIGNING_PRIVATE_KEY_PATH}" 2048 2>/dev/null
openssl rsa -in "${PCR_SIGNING_PRIVATE_KEY_PATH}" -pubout \
    -out "${PCR_SIGNING_PUBLIC_KEY_PATH}" 2>/dev/null
chmod 600 "${PCR_SIGNING_PRIVATE_KEY_PATH}"
PCR_SIGNING_AVAILABLE=1
echo ":: PCR signing keypair generated — will use signed PCR 11 policy."

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

# PCR signing keys — generated at provisioning time, stored on the encrypted
# data disk so they survive reboots and are available for kernel updates.
PCR_SIGNING_ENABLED=0
if [[ "${PCR_SIGNING_AVAILABLE}" -eq 1 ]]; then
    install -Dm644 "${PCR_SIGNING_PUBLIC_KEY_PATH}" \
       "${MOUNT_ROOT}/etc/kernel/pcr-signing-public-key.pem"
    install -Dm600 "${PCR_SIGNING_PRIVATE_KEY_PATH}" \
       "${MOUNT_ROOT}/etc/kernel/pcr-signing-private-key.pem"
    PCR_SIGNING_ENABLED=1
    echo ":: PCR signing keys installed on data disk root."

    # Back up to Key Vault if available
    if [[ -n "${KEY_VAULT_NAME}" ]]; then
        echo ":: Backing up PCR signing keys to Key Vault '${KEY_VAULT_NAME}'..."
        store_secret_in_keyvault "${KEY_VAULT_NAME}" "pcr-signing-private-key" \
            "$(cat "${PCR_SIGNING_PRIVATE_KEY_PATH}")" 2>/dev/null || true
        store_secret_in_keyvault "${KEY_VAULT_NAME}" "pcr-signing-public-key" \
            "$(cat "${PCR_SIGNING_PUBLIC_KEY_PATH}")" 2>/dev/null || true
    fi
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
SECURE_BOOT_ENABLED=${SECURE_BOOT_ENABLED}
PCR_SIGNING_ENABLED=${PCR_SIGNING_ENABLED}
EOF
chmod 0600 "${MOUNT_ROOT}/etc/arch-keyvault.conf"

# Build uki.conf with available signing capabilities
mkdir -p "${MOUNT_ROOT}/etc/kernel"
{
    echo "[UKI]"
    if [[ "${SECURE_BOOT_ENABLED}" -eq 1 ]]; then
        echo "SecureBootPrivateKey=/etc/kernel/secure-boot-private-key.pem"
        echo "SecureBootCertificate=/etc/kernel/secure-boot-certificate.pem"
    fi
    if [[ "${PCR_SIGNING_ENABLED}" -eq 1 ]]; then
        echo "PCRPKey=/etc/kernel/pcr-signing-public-key.pem"
        echo ""
        echo "[PCRSignature:default]"
        echo "PCRPrivateKey=/etc/kernel/pcr-signing-private-key.pem"
        echo "PCRPublicKey=/etc/kernel/pcr-signing-public-key.pem"
        echo "PCRBanks=sha256"
    fi
} > "${MOUNT_ROOT}/etc/kernel/uki.conf"
echo ":: UKI config written (SB=${SECURE_BOOT_ENABLED}, PCR=${PCR_SIGNING_ENABLED})."

# Install secure-boot-resign script — copies the signed UKI to the shim
# chainload position after mkinitcpio rebuilds it.
# Keys are already on disk from provisioning; uki.conf drives signing.
mkdir -p "${MOUNT_ROOT}/usr/local/bin"
cat > "${MOUNT_ROOT}/usr/local/bin/secure-boot-resign" << 'RESIGN_EOF'
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
chmod 0755 "${MOUNT_ROOT}/usr/local/bin/secure-boot-resign"

mkdir -p "${MOUNT_ROOT}/etc/pacman.d/hooks"
cat > "${MOUNT_ROOT}/etc/pacman.d/hooks/91-secure-boot-resign.hook" << 'EOF'
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

# mkinitcpio preset for UKI output — mkinitcpio -P will generate a signed
# UKI on the ESP using /etc/kernel/uki.conf for Secure Boot + PCR signing.
cat > "${MOUNT_ROOT}/etc/mkinitcpio.d/linux-hardened.preset" << 'PRESET'
ALL_kver="/boot/vmlinuz-linux-hardened"
ALL_config="/etc/mkinitcpio.conf.d/azure.conf"

PRESETS=('default')

default_uki="/efi/EFI/Linux/arch-linux.efi"
PRESET

# Build the data-disk UKI. This replaces the squashfs boot UKI on the ESP
# with one that includes sd-encrypt for LUKS unlock, PCR 11 signatures for
# TPM2 sealed policy, and Secure Boot signing (if keys are available).
echo ":: Building data-disk UKI..."
arch-chroot "${MOUNT_ROOT}" mkinitcpio -P

# In chainload mode, copy the signed UKI to grubx64.efi for shim
if [[ -f "${MOUNT_ROOT}/efi/EFI/BOOT/chainload-uki.marker" ]] && \
   [[ -f "${MOUNT_ROOT}/efi/EFI/Linux/arch-linux.efi" ]]; then
    cp "${MOUNT_ROOT}/efi/EFI/Linux/arch-linux.efi" \
       "${MOUNT_ROOT}/efi/EFI/BOOT/grubx64.efi"
    echo ":: Updated grubx64.efi with data-disk UKI."
fi

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
