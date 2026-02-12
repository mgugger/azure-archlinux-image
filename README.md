# Archlinux on Azure VM Image

This repository contains:
* Bicep code to deploy an Ubuntu builder VM with alternate SSH port 22222
* Cloud-init to install required KVM/QEMU, Packer, and Ansible dependencies
* Ansible playbooks that build an Arch Linux image / VHD for Azure and create a managed image

The Arch Linux image contains:
* cloud-init
* systemd-boot
* btrfs
* apparmor
* cockpit for server management 
* firewalld
* The admin user has oath (2fa) with a totp activated and requires username + password + totp for logging in via cockpit
* It will use quad9 dns with DNS over TLS
* pacman-auto-update is enabled to regularly update and reboot the machine
* pac-snap / pacman updates will create btrfs snapshots 
* All outgoing traffic must pass through tinyproxy on localhost to enable domain filtering
* For backup, restic with systemd jobs is preinstalled
* Azure Agents are removed
* some other hardening measures

# Image Creation Steps
1. Deploy the bicep file with ./deploy.azcli
2. SSH into the VM with 
```bash
ssh username@HOST -p22222
```
3. Add your user to the kvm and libvirt group with 
```bash
sudo gpasswd -a $(whoami) kvm && sudo gpasswd -a $(whoami) libvirt && sudo reboot now
```
4. Clone this git repository on the VM
5. From within the git repo, run and replace the storage account variable with the storage account name you want to upload the VHD to:
```bash
packer build \
-var "username=$(whoami)" \
-var "ssh_authorized_keys_base64=$(cat ~/.ssh/id_rsa.pub | base64 -w0)" \
-var "storage_account_name=TODO" \
-var "password=TODO" \
-var "random_seed_for_oath=TODO" \
-var "resource_group_for_image=mdgcorp_storage" \
-var "luks_passphrase=TODO" \
server-archlinux-packer.pkr.hcl
```

# Post Deployment

Use the following runcmd in cloud-init to enable firewalld and optionally start Caddy to access the server:

```
#cloud-config
runcmd:
  - systemctl --now enable firewalld
  - sed -i 's/<domain>/mydomain/g' /etc/caddy/Caddyfile
  - systemctl enable caddy
  - systemctl start caddy
```

# Inputs / Outputs

## Packer variables (server image)

| Variable | Description |
| --- | --- |
| username | Admin user created in the image and used for SSH/Cockpit. |
| password | Password for the admin user (also required for TOTP login). |
| luks_passphrase | LUKS passphrase used to encrypt the root volume. |
| random_seed_for_oath | Seed used to generate the TOTP secret. |
| ssh_authorized_keys_base64 | Base64-encoded SSH authorized keys for the admin user. |
| storage_account_name | Storage account name used to upload the VHD. |
| resource_group_for_image | Resource group where the managed image is created. |

## Packer variables (minimal image)

| Variable | Description |
| --- | --- |
| username | Admin user created in the image. |
| password | Password for the admin user. |
| luks_passphrase | LUKS passphrase used to encrypt the root volume. |
| random_seed_for_oath | Seed used to generate the TOTP secret. |
| ssh_authorized_keys_base64 | Base64-encoded SSH authorized keys for the admin user. |

## Build outputs

| Output | Description |
| --- | --- |
| packer_output/archlinux.vhd | Local VHD produced by Packer before upload. |
| Azure Storage container | VHD uploaded to the `archlinux` container. |
| Managed image | Azure image named `archlinux` created in the target resource group. |
| Bicep output `hostname` | FQDN of the builder VM public IP. |