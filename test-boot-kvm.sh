#!/bin/bash
# test-boot-kvm.sh — Boot the built image locally with QEMU/KVM for testing
# Usage: sudo ./test-boot-kvm.sh [path-to-vhd] [options...]
#
# Options:
#   --data-disk              Attach a blank 4GB virtio data disk (simulates Azure data disk)
#   --tpm                    Attach a software TPM 2.0 device (requires swtpm)
#   --ovmf-vars PATH         Use PATH for writable OVMF variable store
#                            (default: out/ovmf-vars-secboot-ms.fd)
#   --cloud-init             Generate a NoCloud seed ISO that verifies cloud-init on data-disk
#                            boot, then powers off the VM.  Implies --data-disk and --tpm.
#   --no-reboot              Exit on reboot instead of allowing the VM to restart (old default)
#
# This script enforces Secure Boot capable OVMF firmware for local parity tests.
#
# The default mode allows reboots so the full provisioning cycle can be tested:
#   1st boot: squashfs → provision data disk → reboot
#   2nd boot: setup-root unlocks LUKS via swtpm → mounts data disk → cloud-init → poweroff
#
# Requires: qemu-system-x86_64, OVMF (edk2-ovmf package on Arch)
#           swtpm (for --tpm), genisoimage or xorriso (for --cloud-init)
set -euo pipefail

VHD=""
DATA_DISK=0
USE_TPM=0
CLOUD_INIT=0
NO_REBOOT=0
OVMF_VARS_RW=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-disk)
            DATA_DISK=1
            ;;
        --tpm)
            USE_TPM=1
            ;;
        --cloud-init)
            CLOUD_INIT=1
            ;;
        --no-reboot)
            NO_REBOOT=1
            ;;
        --ovmf-vars)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --ovmf-vars requires a path" >&2
                exit 1
            fi
            OVMF_VARS_RW="$2"
            shift
            ;;
        --ovmf-vars=*)
            OVMF_VARS_RW="${1#*=}"
            ;;
        *)
            VHD="$1"
            ;;
    esac
    shift
done

# --cloud-init implies --data-disk and --tpm (cloud-init only runs on data-disk root)
if [[ "$CLOUD_INIT" -eq 1 ]]; then
    DATA_DISK=1
    USE_TPM=1
fi

VHD="${VHD:-out/archlinux.vhd}"
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
OVMF_VARS="/usr/share/edk2/x64/OVMF_VARS.4m.fd"

# Secure Boot OVMF paths (varies by distro)
for candidate in \
    /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
    /usr/share/edk2/x64/OVMF_CODE.secboot.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.fd \
    /usr/share/OVMF/OVMF_CODE.secboot.fd; do
    if [[ -f "$candidate" ]]; then
        OVMF_CODE="$candidate"
        break
    fi
done

# Prefer Microsoft pre-enrolled vars template (.ms) for shim-signed tests.
for vars_candidate in \
    /usr/share/edk2/x64/OVMF_VARS.ms.4m.fd \
    /usr/share/edk2/x64/OVMF_VARS.ms.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.ms.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.ms.fd \
    /usr/share/OVMF/OVMF_VARS.ms.fd \
    "${OVMF_CODE/CODE/VARS}" \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2/x64/OVMF_VARS.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS.fd; do
    if [[ -f "$vars_candidate" ]]; then
        OVMF_VARS="$vars_candidate"
        break
    fi
done

if [[ ! -f "$VHD" ]]; then
    echo "Error: $VHD not found. Build the image first with ./build.sh" >&2
    exit 1
fi

if [[ ! -f "$OVMF_CODE" ]]; then
    echo "Error: Secure Boot OVMF code not found." >&2
    echo "Install edk2-ovmf with Secure Boot firmware files." >&2
    exit 1
fi

if [[ ! -f "$OVMF_VARS" ]]; then
    echo "Error: OVMF VARS template not found for Secure Boot mode." >&2
    exit 1
fi

# Prepare writable OVMF variables store so firmware PCR measurements stay stable
OVMF_VARS_RW="${OVMF_VARS_RW:-out/ovmf-vars-secboot-ms.fd}"
mkdir -p "$(dirname "$OVMF_VARS_RW")"
if [[ ! -f "$OVMF_VARS_RW" ]]; then
    cp "$OVMF_VARS" "$OVMF_VARS_RW"
    echo ":: Initialized writable OVMF vars at ${OVMF_VARS_RW}"
else
    echo ":: Reusing writable OVMF vars at ${OVMF_VARS_RW}"
fi

DATA_DISK_IMG=""
SWTPM_PID=""
TPM_DIR=""
CIDATA_ISO=""
cleanup() {
    if [[ -n "$SWTPM_PID" ]]; then
        kill "$SWTPM_PID" 2>/dev/null || true
        wait "$SWTPM_PID" 2>/dev/null || true
    fi
    [[ -n "$TPM_DIR" ]] && rm -rf "$TPM_DIR"
    [[ -n "$DATA_DISK_IMG" ]] && rm -f "$DATA_DISK_IMG" \
        && echo ":: Removed temporary data disk: ${DATA_DISK_IMG}"
    [[ -n "$CIDATA_ISO" ]]    && rm -f "$CIDATA_ISO" \
        && echo ":: Removed cloud-init seed ISO: ${CIDATA_ISO}"
}
trap cleanup EXIT

TPM_ARGS=()
if [[ "$USE_TPM" -eq 1 ]]; then
    if ! command -v swtpm &>/dev/null; then
        echo "Error: swtpm not found. Install it: pacman -S swtpm" >&2
        exit 1
    fi
    TPM_DIR=$(mktemp -d /tmp/swtpm-XXXXXX)
    TPM_SOCK="$TPM_DIR/swtpm-sock"
    rm -f "$TPM_SOCK"
    swtpm socket \
        --tpmstate dir="$TPM_DIR" \
        --ctrl type=unixio,path="$TPM_SOCK" \
        --tpm2 \
        --log level=0 &
    SWTPM_PID=$!
    sleep 0.5
    TPM_ARGS=(
        -chardev "socket,id=chrtpm,path=$TPM_SOCK"
        -tpmdev emulator,id=tpm0,chardev=chrtpm
        -device tpm-tis,tpmdev=tpm0
    )
    echo ":: vTPM attached (swtpm pid: ${SWTPM_PID}, state: ${TPM_DIR})"
fi

DATA_DISK_ARGS=()
if [[ "$DATA_DISK" -eq 1 ]]; then
    DATA_DISK_IMG=$(mktemp /tmp/data-disk-XXXXXX.raw)
    truncate -s 4G "$DATA_DISK_IMG"
    DATA_DISK_ARGS=(-drive "file=${DATA_DISK_IMG},format=raw,if=virtio")
    echo ":: Attached blank 4GB data disk: ${DATA_DISK_IMG}"
fi

########################################################################
# Cloud-init NoCloud seed ISO
########################################################################
CIDATA_ARGS=()
if [[ "$CLOUD_INIT" -eq 1 ]]; then
    # Need genisoimage or xorriso to create the ISO
    MKISO=""
    if command -v genisoimage &>/dev/null; then
        MKISO=genisoimage
    elif command -v xorriso &>/dev/null; then
        MKISO=xorriso
    else
        echo "Error: genisoimage or xorriso required for --cloud-init" >&2
        echo "  pacman -S cdrtools   # provides genisoimage" >&2
        exit 1
    fi

    CIDATA_DIR=$(mktemp -d /tmp/cidata-XXXXXX)
    CIDATA_ISO=$(mktemp /tmp/cidata-XXXXXX.iso)

    cat > "${CIDATA_DIR}/meta-data" << 'META'
instance-id: test-kvm-01
local-hostname: archlinux-test
META

    cat > "${CIDATA_DIR}/user-data" << 'USERDATA'
#cloud-config
locale: C.UTF-8
users:
  - name: test
    plain_text_passwd: test
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
runcmd:
  - [sh, -c, 'echo cloud-init-runcmd-success > /var/log/cloud-init-test.log']
  - [systemctl, poweroff]
USERDATA

    if [[ "$MKISO" == "genisoimage" ]]; then
        genisoimage -output "$CIDATA_ISO" -volid cidata -joliet -rock \
            "${CIDATA_DIR}/meta-data" "${CIDATA_DIR}/user-data" 2>/dev/null
    else
        xorriso -as genisoimage -output "$CIDATA_ISO" -volid cidata -joliet -rock \
            "${CIDATA_DIR}/meta-data" "${CIDATA_DIR}/user-data" 2>/dev/null
    fi
    rm -rf "$CIDATA_DIR"

    CIDATA_ARGS=(-drive "file=${CIDATA_ISO},format=raw,if=virtio,readonly=on")
    echo ":: Cloud-init seed ISO attached (runcmd will poweroff after data-disk boot)"
fi

########################################################################
# Launch QEMU
########################################################################
REBOOT_ARG=()
if [[ "$NO_REBOOT" -eq 1 ]]; then
    REBOOT_ARG=(-no-reboot)
fi

echo ":: Booting ${VHD} with QEMU/KVM (UEFI)..."
echo ":: Secure Boot firmware: ${OVMF_CODE}"
echo ":: Vars template source: ${OVMF_VARS}"
echo ":: Console on serial — press Ctrl-A X to quit"
if [[ "$NO_REBOOT" -eq 0 ]]; then
    echo ":: Reboots allowed — VM will restart after provisioning"
fi
echo ""

qemu-system-x86_64 \
    -enable-kvm \
    -machine q35,smm=on \
    -m 2048 \
    -cpu host \
    -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,file="${OVMF_VARS_RW}" \
    -drive file="${VHD}",format=vpc,if=virtio \
    ${DATA_DISK_ARGS[@]+"${DATA_DISK_ARGS[@]}"} \
    ${CIDATA_ARGS[@]+"${CIDATA_ARGS[@]}"} \
    ${TPM_ARGS[@]+"${TPM_ARGS[@]}"} \
    ${REBOOT_ARG[@]+"${REBOOT_ARG[@]}"} \
    -serial stdio \
    -display none \
    -net nic,model=virtio \
    -net user
