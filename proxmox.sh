#!/bin/bash
# Read secrets
source .secrets

# Create VM (adjust parameters as needed)
qm create 1000 \
  --name "Tumbleweed-Desktop" \
  --cores 4 \
  --memory 16384 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:200 \
  --ostype l26 \
  --bios ovmf \
  --efidisk0 local-lvm:1 \
  --boot c \
  --bootdisk scsi0 \
  --agent 1

# Add GPU passthrough (if needed)
qm set 1000 --hostpci0 01:00.0,pcie=1,rombar=0

# Install using cloud-init
qm set 1000 \
  --ide2 local-lvm:cloudinit \
  --sshkeys ~/.ssh/id_rsa.pub \
  --ipconfig0 ip=${network.static_ip},gw=${network.gateway} \
  --nameserver "${network.dns_servers}"

# Download OpenSUSE Tumbleweed image
wget https://download.opensuse.org/tumbleweed/iso/openSUSE-Tumbleweed-NET-x86_64-Current.iso -O /var/lib/vz/template/iso/tumbleweed.iso

# Attach ISO and start installation
qm set 1000 --cdrom local:iso/tumbleweed.iso
qm start 1000

### Inside the VM after installation
#zypper addrepo https://download.nvidia.com/opensuse/tumbleweed NVIDIA
#zypper refresh
#zypper install nvidia-driver-G06 nvidia-driver-G06-kmp-default