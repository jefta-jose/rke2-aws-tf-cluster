#!/usr/bin/env bash
# Full nuke — tear the whole lab down to a bare host. Run on the HOST.
# Exit any SSH sessions into the VMs first.
#
# ORDER IS LOAD-BEARING: VMs are destroyed FIRST, the network LAST.
#   net-destroy default while a VM still runs rebuilds virbr0 empty and leaves the VM's
#   tap dangling -> "ssh: No route to host" + empty net-dhcp-leases. Purging libvirt while
#   domains are still defined orphans their qcow2/ISO files.
#
# Usage:  bash /home/jeffndegwa/rke2-aws-tf-cluster/scripts/nuke-lab.sh
set -uo pipefail

# 1) VMs first
for vm in rok-server rok-agent-1; do
  virsh -c qemu:///system destroy "$vm" 2>/dev/null || true
  virsh -c qemu:///system undefine "$vm" || true
done
virsh -c qemu:///system list --all

# 2) (optional) delete disks + base image — uncomment to reclaim space
# sudo rm -f /var/lib/libvirt/images/rok-server.qcow2  /var/lib/libvirt/images/rok-server-seed.iso \
#            /var/lib/libvirt/images/rok-agent-1.qcow2 /var/lib/libvirt/images/rok-agent-1-seed.iso \
#            /var/lib/libvirt/images/noble-server-cloudimg-amd64.img

# 3) network LAST
sudo virsh -c qemu:///system net-destroy default
sudo virsh -c qemu:///system net-undefine default

# 4) reverse the Phase 0 host prep
sudo gpasswd -d jeffndegwa libvirt
sudo gpasswd -d jeffndegwa kvm
sudo systemctl disable --now libvirtd
sudo apt-get purge -y libvirt-daemon-system libvirt-clients virtinst qemu-utils genisoimage
sudo apt-get autoremove -y
