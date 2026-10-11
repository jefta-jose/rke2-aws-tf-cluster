# NUKE — tear the Nimbus lab down to a clean slate

Full teardown of the runtime (VMs, host containers, socat, kubeconfigs). **KEEPS** the Ubuntu base
image and everything in git (PLAN.md, commands.md, scripts/, k8s/, vms/*/). Rebuild with the Phase
1→N commands in `commands.md`.

> Everything we built *inside* the cluster (RKE2, Traefik override, ArgoCD + the fragile cluster
> secret, Prometheus/Loki) lives on the VM disks — destroying the VMs destroys all of it. The git repo
> is untouched, so a rebuild is just re-running the logged commands.

Run on the WSL host.

## 1. Stop the host-side forwarders + kubeconfigs
```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/socat-bridge.sh stop
pkill -f 'socat .*TCP:192.168.122' 2>/dev/null || true
rm -f /tmp/nimbus-kubeconfig.yaml /tmp/nimbus-nlb-kubeconfig.yaml
```

## 2. Destroy + undefine the VMs (and their disks)
```bash
for vm in nimbus-agent-2 nimbus-agent-1 nimbus-server-1; do
  virsh -c qemu:///system destroy  "$vm" 2>/dev/null || true
  virsh -c qemu:///system undefine "$vm" --nvram 2>/dev/null || true
done

sudo rm -f /var/lib/libvirt/images/nimbus-*-seed.iso \
           /var/lib/libvirt/images/nimbus-server-*.qcow2 \
           /var/lib/libvirt/images/nimbus-agent-*.qcow2

virsh -c qemu:///system list --all
```
**KEEP** `/var/lib/libvirt/images/noble-server-cloudimg-amd64.img` (the pristine base — fast rebuilds).

## 3. Host containers (optional — these are light; keep them to skip Phase 1)
```bash
cd /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/registry && docker compose down
```
Append `-v` to `docker compose down` to also wipe the registry volume (drops the pushed images);
omit it to keep them across rebuilds. Host Grafana (Phase 8) only exists once created — tear it down
the same way with `cd ../host-grafana && docker compose down -v`.

## 4. Leave in place (shared / reused by the rebuild)
- libvirt `default` network + the MAC→IP reservations (`vms/net-reservations.sh`).
- The base image (step 2 note).
- Everything in git.

## Partial: drop a worker (3 VMs → 2) WITHOUT a full nuke
Keep `nimbus-server-1` + `nimbus-agent-1`; cleanly remove the second worker `nimbus-agent-2`. Workers
are **not** etcd members, so — unlike removing a server — there is NO etcd `member remove` step: drain
the node, delete it from the API, then destroy the VM. Draining reschedules its pods onto
`nimbus-agent-1` first (preferred pod anti-affinity may then co-locate replicas that used to be spread
— expected once only one worker remains). The final `kubectl get nodes` should show
`nimbus-server-1` + `nimbus-agent-1`.
```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
kubectl drain nimbus-agent-2 --ignore-daemonsets --delete-emptydir-data
kubectl delete node nimbus-agent-2
virsh -c qemu:///system destroy nimbus-agent-2; virsh -c qemu:///system undefine nimbus-agent-2 --nvram
sudo rm -f /var/lib/libvirt/images/nimbus-agent-2.qcow2 /var/lib/libvirt/images/nimbus-agent-2-seed.iso
kubectl get nodes
```
