#!/usr/bin/env bash
# Write /etc/rancher/rke2/config.yaml for the RKE2 SERVER.
# Runs INSIDE rok-server; auto-detects this VM's virbr0 IP as node-ip.
#   token          = shared join secret (agent must match)
#   node-ip        = pins this node's identity
#   tls-san        = names/IPs the API cert must be valid for (host + agent trust)
#   write-kubeconfig-mode 0644 = kubeconfig world-readable (host can `cat` it over SSH)
#
# Usage from the HOST (no multi-line paste — the file carries the indentation):
#   ssh ubuntu@"$SERVER_IP" 'sudo bash -s' < /home/jeffndegwa/rke2-aws-tf-cluster/scripts/write-rke2-server-config.sh
set -euo pipefail

NODE_IP="$(hostname -I | awk '{print $1}')"
mkdir -p /etc/rancher/rke2
tee /etc/rancher/rke2/config.yaml >/dev/null <<EOF
token: rok-lab-shared-token
node-ip: ${NODE_IP}
tls-san:
  - ${NODE_IP}
  - rok-server
write-kubeconfig-mode: "0644"
EOF

echo "--- /etc/rancher/rke2/config.yaml ---"
cat /etc/rancher/rke2/config.yaml
