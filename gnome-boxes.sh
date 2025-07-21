#!/bin/bash
source .secrets

# Create virtual disk
qemu-img create -f qcow2 tumbleweed.qcow2 200G

# Install with virt-install
virt-install \
  --name Tumbleweed-Desktop \
  --memory 16384 \
  --vcpus 4 \
  --disk tumbleweed.qcow2 \
  --cdrom openSUSE-Tumbleweed-NET-x86_64-Current.iso \
  --network bridge=virbr0 \
  --graphics spice \
  --os-variant opensuse-tumbleweed \
  --boot uefi