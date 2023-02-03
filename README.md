# Archlinux on Azure VM Image

This repository contains:
* the bicep code to deploy an Ubuntu VM with alternate SSH Port 22222
* the cloud-init script to install required kvm / qemu and packer and ansible dependencies
* an ansible script that builds an archlinux image / vhd for azure with packer and creates a managed image

The archlinux image contains:
* cloud-init
* grub2
* btrfs with multiple volumes for easier snapshotting
* selinux (not enforced, see post deployment steps)
* cockpit for server management 
* firewalld
* The admin user has oath (2fa) with a totp activated and requires username + password + totp for logging in via cockpit
* It will use quad9 dns with DNS over TLS
* pacman-auto-update is enabled to regulary update and reboot the machine
* pacman updates will create btrfs snapshot which can be booted from in the serial console in case an update goes wrong
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
5. From within the git repo, run and replace the storage account variable with the storage account name you want to upload the vhd to:
```bash
packer build \
-var "username=$(whoami)" \
-var "publickey=\"$(cat ~/.ssh/authorized_keys)\"" \
-var "storage_account_name=TODO" \
-var "password=TODO" \
-var "random_seed_for_oath=$(openssl rand -hex 10)" \
azure-archlinux-packer.json
```

# Post Deployment

Use the following runcmd in cloud-init to enforce selinux and optionally start caddy to access the server:

```
#cloud-config
runcmd:
  - restorecon -r / -e /.snapshots
  - sed -i s/^SELINUX=.*$/SELINUX=enforcing/ /etc/selinux/config
  - semanage permissive -a systemd_resolved_t
  - setenforce 1
  - systemctl --now enable firewalld
  - sed -i 's/<domain>/mydomain/g' /etc/caddy/Caddyfile
  - systemctl enable caddy
  - systemctl start caddy
```