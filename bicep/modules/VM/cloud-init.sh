#cloud-config
package_upgrade: true
runcmd:
  - sudo echo "Port 22222" >> /etc/ssh/sshd_config
  - sudo systemctl restart sshd
  - sudo apt update && sudo apt upgrade -y
  - sudo apt install -y git qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils virtinst libvirt-daemon
  - sudo systemctl enable --now libvirtd
  - curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
  - sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
  - sudo apt update
  - sudo apt install -y packer