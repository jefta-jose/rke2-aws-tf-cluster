#!/usr/bin/env bash
# Write /etc/rancher/rke2/config.yaml for a Nimbus RKE2 *server* node (PLAN Phase 2).
# Run ON the VM with sudo, BEFORE installing/starting rke2-server.
#
# Usage (on the VM):
#   sudo bash write-rke2-server-config.sh <node-name> <node-ip> [join-target-ip]
#     - no join-target-ip  -> cluster-init (the FIRST server; starts embedded etcd)
#     - with join-target-ip -> join an existing cluster at https://<join-target-ip>:9345
#
# The shared cluster secret is TOKEN (same on every server & agent). Override by
# exporting TOKEN=... before running; the default below is fine for this lab.
set -euo pipefail

NODE_NAME=${1:?node-name}
NODE_IP=${2:?node-ip}
JOIN_IP=${3:-}
TOKEN=${TOKEN:-nimbus-etcd-ha-lab-token-2026}

install -d -m 0755 /etc/rancher/rke2

{
  echo "token: ${TOKEN}"
  echo "node-name: ${NODE_NAME}"
  echo "node-ip: ${NODE_IP}"
  echo "# every server/agent must trust these names/IPs in the API server cert:"
  echo "tls-san:"
  echo "  - 192.168.122.11"
  echo "  - 192.168.122.12"
  echo "  - 192.168.122.13"
  echo "  - 192.168.122.1       # WSL2 host (for the socat API proxy added in Phase 6)"
  echo "  - nimbus-server-1"
  echo "  - nimbus-server-2"
  echo "  - nimbus-server-3"
  echo "  - nimbus-server       # generic alias"
  echo "# NOTE: servers are NOT tainted here. CriticalAddonsOnly=true:NoExecute on a node that"
  echo "# is still bootstrapping blocks the one-shot helm-install jobs (canal/coredns), so the"
  echo "# CNI never installs and the node stays NotReady. We apply the taint to ALL servers with"
  echo "# kubectl AFTER the cluster is healthy and nimbus-agent-1 exists (see scripts/taint-servers.sh)."
  if [ -z "$JOIN_IP" ]; then
    echo "cluster-init: true    # first server: bootstrap embedded etcd"
  else
    echo "server: https://${JOIN_IP}:9345   # join the cluster started by the first server"
  fi
} > /etc/rancher/rke2/config.yaml

echo "wrote /etc/rancher/rke2/config.yaml:"
echo "--------------------------------------"
cat /etc/rancher/rke2/config.yaml
