#!/usr/bin/env bash
set -euo pipefail

# Create an Azure managed image from a VHD in blob storage.
# Required env vars: AZURE_STORAGE_ACCOUNT, AZURE_RESOURCE_GROUP

AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:?Set AZURE_STORAGE_ACCOUNT (e.g. mdgcorpvmimages)}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:?Set AZURE_RESOURCE_GROUP}"
IMAGE_NAME="${IMAGE_NAME:-archlinux}"
CONTAINER_NAME="archlinux"
BLOB_NAME="archlinux.vhd"

SOURCE_VHD="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${BLOB_NAME}"

az image create \
    --source "${SOURCE_VHD}" \
    --name "${IMAGE_NAME}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --os-type linux \
    --hyper-v-generation V2 \
    --os-disk-caching ReadOnly

echo "Managed image '${IMAGE_NAME}' created in resource group '${AZURE_RESOURCE_GROUP}'."
