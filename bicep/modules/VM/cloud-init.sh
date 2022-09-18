#cloud-config
package_upgrade: true
runcmd:
  - sudo echo "Port 22222" >> /etc/ssh/sshd_config
  - sudo systemctl restart sshd
  - sudo apt update && sudo apt upgrade -y
  - sudo apt install -y git qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils virtinst libvirt-daemon
  - sudo systemctl enable --now libvirtd