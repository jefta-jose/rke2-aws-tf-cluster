#!/usr/bin/env bash
# Taint the Nimbus server so NO workloads land on the 3 GB control-plane/etcd node
# (PLAN lab-adaptation). Run ONLY after nimbus-agent-1 exists to catch the workloads.
# Run on the WSL host with KUBECONFIG set (or on a server node).
#
# Why not at bootstrap: CriticalAddonsOnly=true:NoExecute on a node still bringing up its
# CNI blocks the one-shot helm-install jobs. Applied now (steady state) it's safe: canal is a
# DaemonSet with blanket tolerations and kube-proxy is a static pod — neither is evicted; any
# other add-on that doesn't tolerate it simply reschedules onto the agent.
#
# Applied via kubectl, the taint lives in the node object in etcd and survives reboots
# (unlike a register-time node-taint, which only applies at first registration).
set -euo pipefail

for n in nimbus-server-1; do
  kubectl taint node "$n" CriticalAddonsOnly=true:NoExecute --overwrite
done

echo "--- taints now ---"
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
