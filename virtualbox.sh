#!/bin/bash
source .secrets

# Create VM
VBoxManage createvm --name "Tumbleweed-Desktop" --ostype "OpenSUSE_64" --register
VBoxManage modifyvm "Tumbleweed-Desktop" \
  --memory 16384 \
  --cpus 4 \
  --nic1 nat \
  --graphicscontroller vmsvga \
  --vram 128 \
  --accelerate3d on

# Create virtual disk
VBoxManage createmedium disk --filename "Tumbleweed.vdi" --size 204800

# Attach storage
VBoxManage storagectl "Tumbleweed-Desktop" --name "SATA Controller" --add sata
VBoxManage storageattach "Tumbleweed-Desktop" \
  --storagectl "SATA Controller" \
  --port 0 \
  --device 0 \
  --type hdd \
  --medium "Tumbleweed.vdi"

# Configure installation media
VBoxManage storagectl "Tumbleweed-Desktop" --name "IDE Controller" --add ide
VBoxManage storageattach "Tumbleweed-Desktop" \
  --storagectl "IDE Controller" \
  --port 0 \
  --device 0 \
  --type dvddrive \
  --medium tumbleweed.iso

# Enable nested virtualization (if needed)
VBoxManage modifyvm "Tumbleweed-Desktop" --nested-hw-virt on

# Start VM
VBoxManage startvm "Tumbleweed-Desktop" --type gui