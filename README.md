This repository contains:
* the code to deploy an Ubuntu VM with alternate Port 22222
* the cloud-init script to install required kvm and packer and ansible dependencies
* an ansible script that builds an archlinux image / vhd for azure with packer and uploads it to a storage account

This can be used to easily create an archlinux image to use with azure VMs.

# Steps
1. Deploy the bicep file with ./deploy.azcli
2. SSH into the VM with ssh @HOST -p22222
3. Add your user to the kvm and libvirt group with ```sudo gpasswd -a $USER kvm && sudo gpasswd -a $USER libvirt```
4. Run ````packer build -var "username=$(whoami)" -var "publickey=$(cat ~/.ssh/authorized_keys)" -var "storage_account_name=TODO" archlinux-packer.json```
