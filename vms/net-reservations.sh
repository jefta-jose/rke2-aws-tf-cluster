#!/usr/bin/env bash
# Reserve (or, with `clean`, remove) fixed IPs for the Nimbus VMs on the libvirt `default`
# network (PLAN Phase 2/3). Each VM boots with a fixed MAC and DHCPs; dnsmasq hands it the
# reserved IP below.
#   - add (default): idempotent, skips any reservation already present.
#   - clean/delete : removes EVERY nimbus-* reservation currently on the net, including stale
#                    ones from older topologies (e.g. nimbus-server-2/3). Used by NUKE.md.
#
#   VM               MAC                  IP
#   nimbus-server-1  52:54:00:a1:b1:11    192.168.122.11
#   nimbus-agent-1   52:54:00:a1:b1:21    192.168.122.21
#   nimbus-agent-2   52:54:00:a1:b1:22    192.168.122.22
#
# Reserve (default):   zsh vms/net-reservations.sh
# Fresh network slate: zsh vms/net-reservations.sh clean
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

if [ "${1:-add}" = "clean" ] || [ "${1:-add}" = "delete" ]; then
  echo "removing all nimbus-* DHCP reservations on net '$NET'..."
  hosts="$(virsh -c "$URI" net-dumpxml "$NET" \
             | grep -oE "<host [^>]*name='nimbus-[^']*'[^>]*/>" || true)"
  if [ -n "$hosts" ]; then
    printf '%s\n' "$hosts" | while IFS= read -r host; do
      if virsh -c "$URI" net-update "$NET" delete ip-dhcp-host "$host" --live --config; then
        echo "  - removed: $host"
      else
        echo "  ! failed to remove: $host"
      fi
    done
  else
    echo "  (no nimbus-* reservations found)"
  fi
  echo "---- remaining reservations ----"
  virsh -c "$URI" net-dumpxml "$NET" | grep "host mac" || echo "  (none)"
  exit 0
fi

add_res 52:54:00:a1:b1:11 nimbus-server-1 192.168.122.11
add_res 52:54:00:a1:b1:21 nimbus-agent-1  192.168.122.21
add_res 52:54:00:a1:b1:22 nimbus-agent-2  192.168.122.22

echo "---- current reservations ----"
virsh -c "$URI" net-dumpxml "$NET" | grep "host mac" || true
