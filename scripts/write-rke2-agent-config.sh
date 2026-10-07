#!/usr/bin/env bash
# Write /etc/rancher/rke2/config.yaml for a Nimbus RKE2 *agent* (worker) node (PLAN Phase 3).
# Run ON the VM with sudo, BEFORE installing/starting rke2-agent.
#
# Usage (on the VM):
#   sudo bash write-rke2-agent-config.sh <node-name> <node-ip> <server-ip>
#
# An agent only needs to find a server (9345) and present the shared token. No tls-san
# (it serves no API), no taint (this is the one node that CARRIES workloads), no cluster-init.
set -euo pipefail

NODE_NAME=${1:?node-name}
NODE_IP=${2:?node-ip}
SERVER_IP=${3:?server-ip}
TOKEN=${TOKEN:-nimbus-etcd-ha-lab-token-2026}

install -d -m 0755 /etc/rancher/rke2

{
  echo "server: https://${SERVER_IP}:9345"
  echo "token: ${TOKEN}"
  echo "node-name: ${NODE_NAME}"
  echo "node-ip: ${NODE_IP}"
} > /etc/rancher/rke2/config.yaml

echo "wrote /etc/rancher/rke2/config.yaml:"
echo "--------------------------------------"
cat /etc/rancher/rke2/config.yaml
