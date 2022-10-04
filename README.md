# Archlinux on Azure VM Image

This repository contains:
* the bicep code to deploy an Ubuntu VM with alternate SSH Port 22222
* the cloud-init script to install required kvm / qemu and packer and ansible dependencies
* an ansible script that builds an archlinux image / vhd for azure with packer and uploads it to a storage account
* The archlinux image contains cloud-init, selinux (not enforced), cockpit and firewalld installed
* The admin user has oath (2fa) with a totp activated and requires username + password + totp for logging in
* By default it will use quad9 dns
* By default has pacman-auto-update enabled

# Steps
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
archlinux-packer.json
```