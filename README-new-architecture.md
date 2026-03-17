# Archlinux on Azure — Squashfs + vTPM Architecture

A hardened Arch Linux image for Azure Trusted Launch VMs with:
* **Squashfs fallback root** — minimal boot image, no Packer required
* **vTPM disk encryption** — LUKS2 sealed to vTPM (PCR 7+11), replaces luks_unlocker
* **Auto-provisioning** — raw data disk is encrypted and installed on first boot
* systemd-boot + UKI + Secure Boot
* BTRFS with subvolumes + zstd compression
* cloud-init, AppArmor, linux-hardened
* No walinuxagent

## Architecture

```
Boot VHD (~1.5GB)                     Data Disk (attached in Azure)
┌─────────────────────┐               ┌──────────────────────────┐
│ ESP: UKI + loader   │               │ LUKS2 (vTPM-sealed)      │
│ Root: squashfs.sfs  │  ──detects──▶ │  └─ BTRFS                │
│       /var/log      │               │     ├─ @      (root)     │
│       /var/cache    │               │     ├─ @home             │
└─────────────────────┘               │     ├─ @log              │
                                      │     ├─ @cache            │
                                      │     └─ @srv              │
                                      └──────────────────────────┘
```

### Boot Flow

1. **UKI boots** → initramfs runs `arch-root-discover` hook
2. **Data disk with LUKS found** → vTPM unseals key → mount BTRFS subvols → boot into data disk root
3. **Raw/unformatted data disk found** → boot into squashfs + overlayfs → `provision-data-disk.service` runs:
   - LUKS2 format + `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+11`
   - BTRFS with subvolumes
   - System install from squashfs + `pacman -Syu`
   - Regenerate UKI for data-disk root
   - Reboot
4. **No data disk** → boot into squashfs maintenance environment (SSH available via cloud-init)

## Build (replaces Packer)

Build directly on an Arch Linux host — no QEMU/Packer needed:

```bash
# Install build dependencies
pacman -S arch-install-scripts squashfs-tools dosfstools btrfs-progs \
    qemu-img mkinitcpio systemd-ukify sbsigntools azure-cli

# Build the VHD image
sudo KEY_VAULT_NAME=<your-key-vault-name> ./build.sh

# Build and upload to Azure
sudo AZURE_STORAGE_ACCOUNT=mystorageacct \
     AZURE_STORAGE_CONTAINER=vhds \
  KEY_VAULT_NAME=<your-key-vault-name> \
     ./build.sh --upload
```

Output: `out/azure-archlinux.vhd`

Then create the Azure managed image:
```bash
az image create --resource-group <rg> --name azure-archlinux \
  --os-type Linux --hyper-v-generation V2 \
  --source https://<storage>.blob.core.windows.net/vhds/azure-archlinux.vhd
```

## Deployment

Deploy with the existing Bicep templates:
```bash
az deployment group create \
  --resource-group <rg> \
  --template-file bicep/main.bicep \
  --parameters baseName=myvm pubkeydata="$(cat ~/.ssh/id_rsa.pub)" \
               vm_admin_name=$(whoami) local_public_ip=$(curl -s ifconfig.me)
```

### Post-Deployment

1. **Set VM tag and Key Vault permissions** before first provisioning reboot:
  - VM tag: `KeyVaultName=<your-key-vault-name>`
  - Grant VM managed identity `secrets/get` on that Key Vault
2. **Attach a data disk** (Premium SSD v2 recommended) to the VM
3. **Reboot** — the first-boot service will automatically:
   - Encrypt the data disk with LUKS2 + vTPM
   - Install the full system
  - Fetch Secure Boot private key from Key Vault into encrypted root
   - Reboot into the data disk root
4. **Secure Boot** — after first successful boot, enable Secure Boot and run:
   ```bash
   /usr/local/sbin/setup-secureboot.sh
   ```

### Secure Boot Private Key Flow

* Build time: key is generated, used for signing UKI/systemd-boot, uploaded to Key Vault, then shredded from the build workspace
* Boot disk image: only the public certificate is included
* Provisioning: private key is fetched via managed identity and stored on encrypted data disk only
* Runtime updates: `/usr/local/bin/secure-boot-resign` uses local encrypted key and can recover it from Key Vault if missing

### Recovery / Maintenance

If the data disk is removed or fails, the VM boots into the squashfs maintenance environment with SSH access via cloud-init credentials.

## Repository Structure

```
build.sh                          # Build script (replaces Packer)
packages.conf                     # Package lists for squashfs + full install
initcpio/
  hooks/arch-root-discover        # Initramfs: detect data disk + vTPM unlock
  hooks/squashfs-overlay           # Initramfs: squashfs + overlayfs mount
  install/arch-root-discover       # Initramfs: install hook
  install/squashfs-overlay         # Initramfs: install hook
first-boot/
  provision-data-disk.sh           # First-boot: encrypt, format, install
  provision-data-disk.service      # systemd unit for provisioning
bicep/                             # Azure infrastructure (unchanged)
playbooks/                         # Ansible playbooks (optional, for customization)
```

## Key Differences from Previous Architecture

| Aspect | Old (Packer + luks_unlocker) | New (squashfs + vTPM) |
|--------|------------------------------|------------------------|
| Build tool | Packer + QEMU/KVM | Native Arch (`pacstrap` + `mksquashfs`) |
| Image size | 4GB (full LUKS root) | ~1.5GB (squashfs + ESP) |
| Encryption unlock | `luks_unlocker` binary (Azure KeyVault) | `systemd-cryptenroll` (vTPM, PCR 7+11) |
| Root filesystem | LUKS on OS disk | LUKS on data disk, squashfs fallback |
| Recovery | Fallback initramfs with passphrase | Squashfs maintenance environment |
| First boot | Manual data disk migration | Automatic provisioning |
| External deps | GitHub binary download | Azure Key Vault (for Secure Boot private key storage) |
