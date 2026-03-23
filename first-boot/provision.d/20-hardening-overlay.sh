#!/bin/bash
set -euo pipefail

if [[ -z "${MOUNT_ROOT:-}" ]]; then
    echo "ERROR: MOUNT_ROOT is not set" >&2
    exit 1
fi

OVERLAY_DIR="/usr/local/share/provision-overlay"
if [[ -d "${OVERLAY_DIR}" ]]; then
    cp -a "${OVERLAY_DIR}/." "${MOUNT_ROOT}/"
else
    echo "WARNING: overlay directory ${OVERLAY_DIR} not found; skipping hardening overlay"
fi

grep -q '^\* hard core 0$' "${MOUNT_ROOT}/etc/security/limits.conf" 2>/dev/null || \
    echo '* hard core 0' >> "${MOUNT_ROOT}/etc/security/limits.conf"
