#!/usr/bin/env bash
# socat-bridge.sh — the "ALB" for Nimbus.
#
# One socat TCP forward per Traefik entrypoint: a "pretty" port on the WSL host ->
# the matching NodePort on nimbus-agent-1. This mirrors ROK's rok-scaleout/lower-env/alb.tf
# listener->target contract (ALB "pretty" port -> Traefik NodePort entrypoint), with socat
# playing the ALB. See the mapping table in PLAN.md.
#
# Idempotent: kills any socat forwards THIS script previously started (matched by the agent
# IP in the socat command line, so a real ssh session to the agent is never touched), then
# relaunches all of them under nohup so they survive this shell exiting.
#
# Run on the WSL host:   zsh /abs/.../scripts/socat-bridge.sh
# Stop everything:       zsh /abs/.../scripts/socat-bridge.sh stop
#
# NOTE: until Traefik is installed (Phase 5) the agent NodePorts aren't listening yet, so each
# forward will bind its host port and accept() but the forwarded connection will fail — that's
# expected. Phase 5.2 verifies the forwards actually reach Traefik.
set -euo pipefail

AGENT_IP="${AGENT_IP:-192.168.122.21}"
LOG_DIR="/tmp"

# host_port  nodeport  label   (one line per Traefik entrypoint — the PLAN.md ALB table)
FORWARDS="
8080 30001 web
3100 30000 loki
9090 30002 prometheus
9069 30003 argocd
8025 30004 mailpit-ui
1025 30005 mailpit-smtp
"

# Kill only forwards this script launched: socat processes whose target is the agent IP.
# The 'socat ' prefix + 'TCP:AGENT_IP:' target keeps this from matching ssh/other procs.
stop_forwards() {
  pkill -f "socat .*TCP:${AGENT_IP}:" 2>/dev/null || true
}

if [ "${1:-start}" = "stop" ]; then
  stop_forwards
  echo "stopped all Nimbus socat forwards to ${AGENT_IP}"
  exit 0
fi

stop_forwards
sleep 0.3   # let the old listeners release their host ports before rebinding

echo "$FORWARDS" | while read -r host_port node_port label; do
  [ -z "${host_port:-}" ] && continue
  nohup socat "TCP-LISTEN:${host_port},fork,reuseaddr" "TCP:${AGENT_IP}:${node_port}" \
    >"${LOG_DIR}/nimbus-socat-${label}.log" 2>&1 &
done

sleep 0.3
echo "--- Nimbus 'ALB' forwards (host port -> ${AGENT_IP}:NodePort) ---"
echo "$FORWARDS" | while read -r host_port node_port label; do
  [ -z "${host_port:-}" ] && continue
  printf '  %-13s localhost:%-5s -> %s:%s\n' "$label" "$host_port" "$AGENT_IP" "$node_port"
done
echo "--- host ports now listening ---"
ss -ltnp 2>/dev/null | grep -E ':(8080|3100|9090|9069|8025|1025)\b' || echo "(none up yet — check ${LOG_DIR}/nimbus-socat-*.log)"
