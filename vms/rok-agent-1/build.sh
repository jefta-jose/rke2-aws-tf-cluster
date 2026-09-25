#!/usr/bin/env bash
# ============================================================================
# build.sh — create and boot the rok-agent-1 VM (the RKE2 worker node).
#
# This is the SAME recipe as vms/rok-server/build.sh (read that file for the
# full "three things on disk" explanation). Differences:
#   - reuses the base cloud image already downloaded for rok-server
#   - its own seed ISO + overlay disk + VM name (rok-agent-1)
#   - slightly less RAM (a worker needs less than the control plane)
#
# Run with:  sudo bash vms/rok-agent-1/build.sh
# Idempotent — safe to re-run.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="/var/lib/libvirt/images"
BASE="${IMG_DIR}/noble-server-cloudimg-amd64.img"   # shared OS image (from rok-server build)
SEED="${IMG_DIR}/rok-agent-1-seed.iso"               # this VM's cloud-init CD-ROM
URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

DISK="${IMG_DIR}/rok-agent-1.qcow2"                  # this VM's own writable disk

VCPUS=2
MEM_MB=4096      # 4 GB — a worker node needs less than the control plane
DISK_SIZE=20G

echo "==> 1/4 Base Ubuntu 24.04 cloud image"
if [[ -f "$BASE" ]]; then
  echo "    reusing existing base image: $BASE"
else
  echo "    downloading $URL"
  wget -q --show-progress -O "$BASE" "$URL"
fi

echo "==> 2/4 cloud-init seed ISO (hostname + SSH key)"
( cd "$SCRIPT_DIR" && genisoimage -quiet -output "$SEED" -volid cidata -joliet -rock user-data meta-data )
echo "    wrote $SEED"

echo "==> 3/4 VM overlay disk (${DISK_SIZE}, backed by base image)"
if [[ -f "$DISK" ]]; then
  echo "    already present: $DISK"
else
  qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$DISK" "$DISK_SIZE"
fi

echo "==> 4/4 Define & boot the VM"
if virsh -c qemu:///system dominfo rok-agent-1 >/dev/null 2>&1; then
  echo "    domain rok-agent-1 already exists — skipping virt-install"
else
  # Same flags as rok-server (see that build.sh for what each one means).
  virt-install \
    --connect qemu:///system \
    --name rok-agent-1 \
    --virt-type kvm \
    --memory "$MEM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --os-variant ubuntu24.04 \
    --import \
    --disk "path=${DISK},format=qcow2,bus=virtio" \
    --disk "path=${SEED},device=cdrom" \
    --network network=default,model=virtio \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole
fi

echo "==> Done. Waiting a moment for DHCP lease..."
sleep 5
virsh -c qemu:///system domifaddr rok-agent-1 || true
