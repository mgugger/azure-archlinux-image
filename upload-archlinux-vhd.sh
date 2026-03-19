#!/usr/bin/env bash
set -euo pipefail

# Upload out/archlinux.vhd to the "archlinux" container in Azure Blob Storage.
# Required env var: AZURE_STORAGE_ACCOUNT

AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:?Set AZURE_STORAGE_ACCOUNT (e.g. mdgcorpvmimages)}"
CONTAINER_NAME="archlinux"
SOURCE_VHD="out/archlinux.vhd"
BLOB_NAME="archlinux.vhd"

if [[ ! -f "${SOURCE_VHD}" ]]; then
    echo "Error: ${SOURCE_VHD} not found. Build the image first." >&2
    exit 1
fi

az storage blob upload \
    --account-name "${AZURE_STORAGE_ACCOUNT}" \
    --container-name "${CONTAINER_NAME}" \
    --name "${BLOB_NAME}" \
    --file "${SOURCE_VHD}" \
    --type page \
    --overwrite \
    --auth-mode key

echo "Upload complete: https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${BLOB_NAME}"
