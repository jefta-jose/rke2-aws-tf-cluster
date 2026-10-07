#!/usr/bin/env bash
# Generic Nimbus VM builder (PLAN Phase 2/3).
# Builds one VM from the kept Ubuntu 24.04 cloud image using a qcow2 overlay
# (base stays pristine) + a NoCloud cloud-init seed ISO, then virt-install --import.
#
# Usage:
#   vms/make-vm.sh <name> <ip> <mac> <vcpus> <ram_mb> <disk_gb>
# Example:
#   vms/make-vm.sh nimbus-server-1 192.168.122.11 52:54:00:a1:b1:11 2 2048 20
#
# Notes:
# - You must be in the `libvirt` group (virsh talks to qemu:///system without sudo).
# - sudo is used ONLY to write the overlay + seed ISO into /var/lib/libvirt/images
#   (root-owned). libvirt re-owns the disk to the qemu user at domain start.
# - IP comes from the DHCP reservation (vms/net-reservations.sh) matching <mac>.
set -euo pipefail

NAME=${1:?name}      ; IP=${2:?ip}        ; MAC=${3:?mac}
VCPUS=${4:?vcpus}    ; RAM_MB=${5:?ram_mb}; DISK_GB=${6:?disk_gb}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # $0 works under bash and zsh (BASH_SOURCE does not)
VMDIR="$SCRIPT_DIR/$NAME"
IMG_DIR=/var/lib/libvirt/images
BASE="$IMG_DIR/noble-server-cloudimg-amd64.img"
DISK="$IMG_DIR/$NAME.qcow2"
SEED="$IMG_DIR/$NAME-seed.iso"
PUBKEY_FILE="${PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
PUBKEY="$(cat "$PUBKEY_FILE")"

[ -f "$BASE" ] || { echo "base image missing: $BASE" >&2; exit 1; }
mkdir -p "$VMDIR"

# ---- cloud-init: meta-data + user-data (written into the repo for inspection) ----
cat > "$VMDIR/meta-data" <<EOF
instance-id: $NAME
local-hostname: $NAME
EOF

cat > "$VMDIR/user-data" <<EOF
#cloud-config
hostname: $NAME
users:
  - name: ubuntu
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - $PUBKEY
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - {name: ubuntu, password: ubuntu, type: text}
EOF

# ---- disk overlay backed by the pristine base (grown to DISK_GB) ----
BASE_FMT="$(sudo qemu-img info "$BASE" | awk -F': ' '/file format/{print $2}')"
sudo qemu-img create -f qcow2 -F "$BASE_FMT" -b "$BASE" "$DISK" "${DISK_GB}G" >/dev/null
echo "overlay: $DISK (${DISK_GB}G, backing $BASE_FMT)"

# ---- NoCloud seed ISO (volume label MUST be cidata); files at ISO root ----
( cd "$VMDIR" && sudo genisoimage -quiet -output "$SEED" -volid cidata -joliet -rock user-data meta-data )
echo "seed:    $SEED"

# ---- define + start the domain ----
virt-install \
  --connect qemu:///system \
  --name "$NAME" \
  --memory "$RAM_MB" \
  --vcpus "$VCPUS" \
  --cpu host-passthrough \
  --import \
  --disk path="$DISK",format=qcow2,bus=virtio \
  --disk path="$SEED",device=cdrom \
  --network network=default,mac="$MAC",model=virtio \
  --osinfo detect=on,require=off \
  --graphics none \
  --noautoconsole

echo "started $NAME — expected IP $IP (reserved for $MAC). Give cloud-init ~30-60s."
