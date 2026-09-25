#!/usr/bin/env bash
# ============================================================================
# build.sh — create and boot the rok-server VM on libvirt/KVM.
#
# THE BIG PICTURE: a "cloud image" is a pre-installed Ubuntu disk that expects
# cloud-init to configure it on first boot. So to make a working VM we need
# three things on disk, then we hand them to libvirt:
#   1. the base cloud image           (the OS)
#   2. a seed CD-ROM (user-data/meta-data)  (the config: hostname + SSH key)
#   3. a writable disk for THIS VM    (so we don't dirty the shared base image)
# Then `virt-install --import` defines the VM and powers it on.
#
# Run with:  sudo bash vms/rok-server/build.sh
# It is IDEMPOTENT — re-running skips anything already done, so it's safe.
# ============================================================================

# 'set -e' stop on first error; '-u' error on unset vars; 'pipefail' so a
# failure anywhere in a pipe fails the whole line. Standard safety belt.
set -euo pipefail

# Figure out the folder this script lives in, so we can find user-data/meta-data
# next to it no matter where you run the script from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# libvirt's standard image store (root-owned). Keeping all VM disks here avoids
# permission/AppArmor problems that happen if QEMU tries to read from /home.
IMG_DIR="/var/lib/libvirt/images"

BASE="${IMG_DIR}/noble-server-cloudimg-amd64.img"   # the shared, read-only OS image
SEED="${IMG_DIR}/rok-server-seed.iso"               # the cloud-init config CD-ROM
URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

DISK="${IMG_DIR}/rok-server.qcow2"                  # this VM's own writable disk

VCPUS=2          # 2 virtual CPUs  (RKE2 server wants ~2)
MEM_MB=4096      # 4 GB RAM
DISK_SIZE=20G    # grow the VM's root disk to 20 GB (the base image is tiny)

echo "==> 1/4 Base Ubuntu 24.04 cloud image"
# Download the OS image once. It's the same base for every node, so we reuse it.
if [[ -f "$BASE" ]]; then
  echo "    already present: $BASE"
else
  echo "    downloading $URL"
  # -o BASE -> where to download the file
  # URL -> where to download the file
  wget -q --show-progress -O "$BASE" "$URL"
fi

echo "==> 2/4 cloud-init seed ISO (hostname + SSH key)"
# Package user-data + meta-data into a tiny ISO labelled "cidata". cloud-init
# inside the VM looks for a CD-ROM with exactly that label and reads its config.
# We 'cd' into the script dir first so the files land at the ISO root with their
# exact names (cloud-init requires files named literally user-data / meta-data).
( cd "$SCRIPT_DIR" && genisoimage -quiet -output "$SEED" -volid cidata -joliet -rock user-data meta-data )
echo "    wrote $SEED"

echo "==> 3/4 VM overlay disk (${DISK_SIZE}, backed by base image)"
# Create a "copy-on-write overlay": a new disk that USES the base image as its
# read-only backing file and records only this VM's changes on top. Fast, tiny,
# and it keeps the shared base image pristine so other nodes can reuse it.
if [[ -f "$DISK" ]]; then
  echo "    already present: $DISK"
else
  qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$DISK" "$DISK_SIZE"
fi

echo "==> 4/4 Define & boot the VM"
# If a VM named rok-server already exists, don't try to create it again.
if virsh -c qemu:///system dominfo rok-server >/dev/null 2>&1; then
  echo "    domain rok-server already exists — skipping virt-install"
else
  # virt-install registers the VM with libvirt and powers it on. What each flag
  # below does (NOTE: a trailing '\' just continues the command onto the next
  # line — it must be the LAST character on its line, so these notes live here):
  #   --virt-type kvm ............ use hardware KVM acceleration (fast)
  #   --memory / --vcpus ......... RAM (MB) and CPU count for the VM
  #   --cpu host-passthrough ..... expose the real host CPU features to the guest
  #   --os-variant ubuntu24.04 ... let libvirt tune devices/defaults for this OS
  #   --import ................... boot the disk we built; do NOT run an installer
  #   --disk ...qcow2... ......... the writable overlay = the VM's main disk
  #   --disk ...seed...,cdrom .... the cloud-init seed ISO as a CD-ROM
  #   --network network=default . attach to virbr0 -> VM gets a 192.168.122.x IP
  #   --graphics none ............ headless, no GUI display
  #   --console pty,serial ....... provide a serial console we can attach to later
  #   --noautoconsole ............ don't attach the console now; return to the shell
  virt-install \
    --connect qemu:///system \
    --name rok-server \
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
# The VM needs a few seconds to boot and ask virbr0's DHCP for an IP. This may
# be blank on the first try (still booting) — re-run domifaddr to see it.
sleep 5
virsh -c qemu:///system domifaddr rok-server || true
