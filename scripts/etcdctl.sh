#!/usr/bin/env bash
# Run etcdctl against the RKE2 embedded etcd. Run ON a server node with sudo.
# RKE2 runs etcd as a static-pod container, so etcdctl lives inside it — this
# wraps `crictl exec` with the right client certs and all 3 member endpoints.
#
# Usage (on a server node):
#   sudo bash etcdctl.sh member list -w table
#   sudo bash etcdctl.sh endpoint status --cluster -w table   # shows IS LEADER / RAFT INDEX
#   sudo bash etcdctl.sh endpoint health --cluster
set -euo pipefail

CRICTL=/var/lib/rancher/rke2/bin/crictl
CRICFG=/var/lib/rancher/rke2/agent/etc/crictl.yaml

TLS=/var/lib/rancher/rke2/server/tls/etcd

EP=https://192.168.122.11:2379,https://192.168.122.12:2379,https://192.168.122.13:2379

# The etcd static pod mounts individual cert FILES (not the whole dir): server-client.{crt,key}
# + server-ca.crt are the ones present inside the container (the apiserver's client.crt is NOT).
# The image is distroless (no sh/ls) — so we exec etcdctl directly, never a shell.
CERT="$TLS/server-client.crt"
KEY="$TLS/server-client.key"
CA="$TLS/server-ca.crt"

CID=$("$CRICTL" --config "$CRICFG" ps -q --name etcd | head -1)
[ -n "$CID" ] || { echo "no running etcd container found on this node" >&2; exit 1; }

"$CRICTL" --config "$CRICFG" exec "$CID" etcdctl \
  --cacert "$CA" --cert "$CERT" --key "$KEY" \
  --endpoints "$EP" "$@"
