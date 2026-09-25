#!/usr/bin/env bash
# Write /etc/rancher/rke2/config.yaml for the RKE2 AGENT (worker).
# Runs INSIDE rok-agent-1; auto-detects this VM's virbr0 IP as node-ip.
#   server = https://<server-ip>:9345  (9345 = the supervisor/join port)
#   token  = must match the server's shared secret
#   arg 1  = rok-server's node-ip (pass it from the host shell)
#
# Usage from the HOST ($SERVER_IP already set in the shell):
#   ssh ubuntu@"$AGENT_IP" "sudo bash -s $SERVER_IP" < /home/jeffndegwa/rke2-aws-tf-cluster/scripts/write-rke2-agent-config.sh
set -euo pipefail

SERVER_IP="${1:?pass rok-server's node-ip as the first argument}"
NODE_IP="$(hostname -I | awk '{print $1}')"
mkdir -p /etc/rancher/rke2
tee /etc/rancher/rke2/config.yaml >/dev/null <<EOF
server: https://${SERVER_IP}:9345
token: rok-lab-shared-token
node-ip: ${NODE_IP}
EOF

echo "--- /etc/rancher/rke2/config.yaml ---"
cat /etc/rancher/rke2/config.yaml
