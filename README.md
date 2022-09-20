This repository contains:
* the code to deploy an Ubuntu VM with alternate Port 22222
* the cloud-init script to install required kvm and packer and ansible dependencies
* an ansible script that builds an archlinux image / vhd for azure with packer and uploads it to a storage account

This can be used to easily create an archlinux image to use with azure VMs.

# Steps
1. Deploy the bicep file with ./deploy.azcli
2. SSH into the VM with ssh @HOST -p22222
3. Add your user to the kvm and libvirtd group with ```sudo gpasswd -a $USER kvm && sudo gpasswd -a $USER libvirtd```
4. Run ````packer build archlinux-packer.json```
