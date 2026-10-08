#!/usr/bin/env bash
# Reserve fixed IPs for the Nimbus VMs on the libvirt `default` network (PLAN Phase 2/3).
# Each VM boots with a fixed MAC and DHCPs; dnsmasq hands it the reserved IP below.
# Idempotent: skips any reservation already present. Run once before building VMs.
#
#   VM               MAC                  IP
#   nimbus-server-1  52:54:00:a1:b1:11    192.168.122.11
#   nimbus-agent-1   52:54:00:a1:b1:21    192.168.122.21
set -euo pipefail
URI=qemu:///system
NET=default

add_res() {
  local mac=$1 name=$2 ip=$3
  if virsh -c "$URI" net-dumpxml "$NET" | grep -q "ip='$ip'"; then
    echo "  = $name already reserved ($ip)"
  else
    virsh -c "$URI" net-update "$NET" add ip-dhcp-host \
      "<host mac='$mac' name='$name' ip='$ip'/>" --live --config
    echo "  + reserved $name -> $ip"
  fi
}

add_res 52:54:00:a1:b1:11 nimbus-server-1 192.168.122.11
add_res 52:54:00:a1:b1:21 nimbus-agent-1  192.168.122.21

echo "---- current reservations ----"
virsh -c "$URI" net-dumpxml "$NET" | grep "host mac" || true
