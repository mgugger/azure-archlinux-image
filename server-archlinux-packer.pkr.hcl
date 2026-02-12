packer {
  required_plugins {
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1"
    }
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

variable "password" {
  type = string
  sensitive = true
  validation {
    condition     = length(var.password) > 0
    error_message = "The password length cannot be empty."
  }
}

variable "luks_passphrase" {
  type = string
  sensitive = true
  validation {
    condition     = length(var.luks_passphrase) > 0
    error_message = "The luks_passphrase length cannot be empty."
  }
}

variable "random_seed_for_oath" {
  type = string
  sensitive = true
  validation {
    condition     = length(var.random_seed_for_oath) > 0
    error_message = "The random_seed_for_oath length cannot be empty."
  }
}

variable "resource_group_for_image" {
  type = string
  validation {
    condition     = length(var.resource_group_for_image) > 0
    error_message = "The resource_group_for_image length cannot be empty."
  }
}

variable "ssh_authorized_keys_base64" {
  type = string
  sensitive = true
  validation {
    condition     = length(var.ssh_authorized_keys_base64) > 0
    error_message = "The ssh_authorized_keys_base64 length cannot be empty."
  }
}

variable "storage_account_name" {
  type = string
  validation {
    condition     = length(var.storage_account_name) > 0
    error_message = "The storage_account_name length cannot be empty."
  }
}

variable "username" {
  type = string
  validation {
    condition     = length(var.username) > 0
    error_message = "The username length cannot be empty."
  }
}


source "qemu" "azure_archlinux" {
  accelerator      = "kvm"
  boot_command     = ["<enter><wait60>", "curl -sfSLO http://{{ .HTTPIP }}:{{ .HTTPPort }}/packer.sh<enter><wait>", "chmod +x *.sh<enter>", "./packer.sh<enter>"]
  boot_wait        = "20s"
  cpus             = 6
  disk_cache       = "unsafe"
  disk_compression = true
  disk_discard     = "unmap"
  disk_size        = "4000M"
  efi_boot         = true
  efi_firmware_code = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  efi_firmware_vars = "/tmp/OVMF_VARS_4M.fd"
  format           = "raw"
  headless         = false
  http_directory   = "http"
  iso_checksum     = "none"
  iso_url          = "https://mirror.anquan.cl/archlinux/iso/latest/archlinux-x86_64.iso"
  memory           = 2048
  output_directory = "./packer_output/qemu"
  shutdown_command = "sudo systemctl poweroff"
  ssh_password     = "root"
  ssh_timeout      = "20m"
  ssh_username     = "root"
}

build {
  sources = ["source.qemu.azure_archlinux"]

  provisioner "ansible" {
    user            = "root"
    ansible_env_vars = [
      "ANSIBLE_REMOTE_TMP=/tmp/.ansible/tmp",
      "ANSIBLE_SHELL_EXECUTABLE=/bin/bash",
      "ANSIBLE_SCP_IF_SSH=true",
      "ANSIBLE_SCP_EXTRA_ARGS=-O"
    ]
    extra_arguments = [
      "--extra-vars", "username=${var.username}",
      "--extra-vars", "luks_passphrase=${var.luks_passphrase}",
      "--extra-vars", "password=${var.password}",
      "--extra-vars", "ssh_authorized_keys_base64=${var.ssh_authorized_keys_base64}",
      "--extra-vars", "random_seed=${var.random_seed_for_oath}"
    ]
    playbook_file   = "playbooks/1_archlinux-server-install-playbook.yml"
  }

  post-processor "shell-local" {
    inline = ["set -e; qemu-img convert -f raw -O vpc -o subformat=fixed,force_size ./packer_output/qemu/packer-azure_archlinux ./packer_output/archlinux.vhd", "azcopy login --login-type=MSI", "azcopy copy ./packer_output/archlinux.vhd https://${var.storage_account_name}.blob.core.windows.net/archlinux/", "az login --identity", "az image create --source https://${var.storage_account_name}.blob.core.windows.net/archlinux/archlinux.vhd --name archlinux -g ${var.resource_group_for_image} --os-type linux --hyper-v-generation V2 --os-disk-caching ReadOnly", "echo \"random seed is: ${var.random_seed_for_oath} and base32 $(oathtool -v --totp -d 6 ${var.random_seed_for_oath} | grep '^Base32 secret:' | sed 's/^.*: //')\"", "echo \"QR Code for oath otp is\"", "qrencode -t UTF8 \"otpauth://totp/Archlinux:${var.username}@archlinux?secret=$(oathtool -v --totp -d 6 ${var.random_seed_for_oath} | grep \"^Base32 secret:\" | cut -d \" \" -f3)&issuer=${var.username}\"", "if [ -f /tmp/secureboot-cert.pem ]; then echo \"Secure Boot certificate (PEM):\"; cat /tmp/secureboot-cert.pem; echo \"Secure Boot certificate (PEM, base64): $(base64 -w0 /tmp/secureboot-cert.pem)\"; else echo \"Secure Boot certificate not found (missing /tmp/secureboot-cert.pem)\"; fi", "rm -rf packer_output/"]
  }
}