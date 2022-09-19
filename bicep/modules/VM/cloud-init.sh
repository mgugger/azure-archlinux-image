#cloud-config
package_upgrade: true
runcmd:
  - # Set alternative SSH Port
  - sudo echo "Port 22222" >> /etc/ssh/sshd_config
  - sudo systemctl restart sshd
  - sudo apt update && sudo apt upgrade -y
  - # Install KVM
  - sudo apt install -y git qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils virtinst libvirt-daemon
  - sudo systemctl enable --now libvirtd
  - # Install Packer
  - curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
  - sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
  - sudo apt update
  - sudo apt install -y packer
  - #Install Ansible
  - sudo apt update
  - sudo apt install software-properties-common
  - sudo apt-add-repository --yes --update ppa:ansible/ansible
  - sudo apt install -y ansible
  - ansible-galaxy collection install community.general