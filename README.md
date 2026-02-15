# Archlinux on Azure VM Image

A hardened archlinux VM image for Azure to build with packer and deploy to Azure Trusted Launch VMs incl. Secureboot and vTPM. It contains:
* cloud-init
* systemd-boot + shim
* btrfs
* full-disk-encryption with luks (and luks_unlocker in initramfs to unlock with key from key vault)
* apparmor
* firewalld + tinyproxy to controll egress traffic
* admin user with oath / 2fa
* restic for backs
* no walinuxagent
* linux-hardened + hardening measures

# Build
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

On azure for trusted launch VMs, you need to create a managed image, then a generalized image in a compute gallery with the managed image as source.

# Post Deployment

## SecureBoot
For SecureBoot, you need to launch the VM first with secure boot disabled, then run:
```bash
/usr/local/sbin/setup-secureboot.sh
```
This will enroll the mok key. After rebooting with secure boot enabled, you can enroll the key. If enrollment failed, you can enroll manually with the key being stored under "/efi/mok-manager.crt".

## DataDisk
The root os disk can be small (4GB). You may attach a 2nd data disk (premium v2 ssd) and migrate the btrfs device to the data disk for improved performance.
