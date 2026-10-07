#!/usr/bin/env bash
# socat-bridge.sh — the WSL-host TCP forwarders that stand in for ROK's two AWS load balancers.
#
# ROK fronts the cluster with TWO load balancers; we reproduce both with socat on the host:
#   1. the "ALB"  -> a "pretty" host port per Traefik entrypoint, forwarded to nimbus-agent-1's
#                    NodePorts (rok-scaleout/lower-env/alb.tf listener->target). See PLAN.md.
#   2. the control-plane "NLB" -> the kube-apiserver, forwarded to a server node, so there is ONE
#                    stable API endpoint (https://192.168.122.1:6444) that is reachable from both the
#                    host AND in-cluster pods, and TLS-valid (192.168.122.1 is in tls-san).
#                    ArgoCD registers the target cluster against this endpoint (PLAN Phase 6.3).
#                    Host port is 6444, NOT 6443: the WSL host already runs its OWN kube-apiserver on
#                    6443 (a local Docker/Rancher Desktop k8s). The cert SAN matches the IP, not the
#                    port, so https://192.168.122.1:6444 still verifies.
#
# Idempotent: kills any socat forwards THIS script previously started (matched by our target IPs in
# the socat command line, so a real ssh session to a VM is never touched), then relaunches all under
# nohup so they survive this shell exiting.
#
# Run on the WSL host:   zsh /abs/.../scripts/socat-bridge.sh
# Stop everything:       zsh /abs/.../scripts/socat-bridge.sh stop
#
# NOTE: ALB forwards accept() even before Traefik publishes a NodePort (connection then fails) — that
# is expected until the relevant backend exists.
set -euo pipefail

AGENT_IP="${AGENT_IP:-192.168.122.21}"      # ALB target: the workload node
APISERVER_IP="${APISERVER_IP:-192.168.122.11}"  # NLB target: a control-plane node (server-1)
LOG_DIR="/tmp"

# host_port  target_ip  target_port  label
# --- ALB (-> agent NodePorts, PLAN.md table) ---           --- control-plane NLB (-> server :6443) ---
FORWARDS="
8080 ${AGENT_IP} 30001 web
3100 ${AGENT_IP} 30000 loki
9090 ${AGENT_IP} 30002 prometheus
9069 ${AGENT_IP} 30003 argocd
8025 ${AGENT_IP} 30004 mailpit-ui
1025 ${AGENT_IP} 30005 mailpit-smtp
6444 ${APISERVER_IP} 6443 kube-api
"

# Kill only forwards this script launched: socat processes whose target is one of our VM IPs.
# The 'socat ' prefix + 'TCP:<ip>:' target keeps this from matching ssh or other processes.
stop_forwards() {
  for ip in "$AGENT_IP" "$APISERVER_IP"; do
    pkill -f "socat .*TCP:${ip}:" 2>/dev/null || true
  done
}

if [ "${1:-start}" = "stop" ]; then
  stop_forwards
  echo "stopped all Nimbus socat forwards (ALB -> ${AGENT_IP}, NLB -> ${APISERVER_IP})"
  exit 0
fi

stop_forwards
sleep 0.3   # let old listeners release their host ports before rebinding

echo "$FORWARDS" | while read -r host_port target_ip target_port label; do
  [ -z "${host_port:-}" ] && continue
  nohup socat "TCP-LISTEN:${host_port},fork,reuseaddr" "TCP:${target_ip}:${target_port}" \
    >"${LOG_DIR}/nimbus-socat-${label}.log" 2>&1 &
done

sleep 0.3
echo "--- Nimbus host forwarders ---"
echo "$FORWARDS" | while read -r host_port target_ip target_port label; do
  [ -z "${host_port:-}" ] && continue
  role="ALB"; [ "$target_ip" = "$APISERVER_IP" ] && role="NLB"
  printf '  [%s] %-13s localhost:%-5s -> %s:%s\n' "$role" "$label" "$host_port" "$target_ip" "$target_port"
done
echo "--- host ports now listening ---"
ss -ltnp 2>/dev/null | grep -E ':(8080|3100|9090|9069|8025|1025|6444)\b' || echo "(none up yet — check ${LOG_DIR}/nimbus-socat-*.log)"
