#!/bin/bash
set -euo pipefail

if [[ -z "${MOUNT_ROOT:-}" ]]; then
    echo "ERROR: MOUNT_ROOT is not set" >&2
    exit 1
fi

arch-chroot "${MOUNT_ROOT}" bash -c '
    systemctl unmask cloud-init.target cloud-init-local.service cloud-init-network.service cloud-init-main.service cloud-final.service
    systemctl enable sshd
    systemctl enable cloud-init-local.service
    systemctl enable cloud-init-main.service
    systemctl enable cloud-init-network.service
    systemctl enable cloud-final.service
'
