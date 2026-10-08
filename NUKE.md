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
pkill -f 'socat .*TCP:192.168.122' 2>/dev/null || true     # belt-and-braces
rm -f /tmp/nimbus-kubeconfig.yaml /tmp/nimbus-nlb-kubeconfig.yaml
```

## 2. Destroy + undefine the VMs (and their disks)
```bash
for vm in nimbus-agent-1 nimbus-server-3 nimbus-server-2 nimbus-server-1; do
  virsh -c qemu:///system destroy  "$vm" 2>/dev/null || true     # power off (ignore if already off)
  virsh -c qemu:///system undefine "$vm" --nvram 2>/dev/null || true
done

# remove the per-VM overlay disks + cloud-init seed ISOs (sudo: root-owned dir)
sudo rm -f /var/lib/libvirt/images/nimbus-*-seed.iso \
           /var/lib/libvirt/images/nimbus-server-*.qcow2 \
           /var/lib/libvirt/images/nimbus-agent-*.qcow2

virsh -c qemu:///system list --all        # confirm no nimbus-* domains remain
```
**KEEP** `/var/lib/libvirt/images/noble-server-cloudimg-amd64.img` (the pristine base — fast rebuilds).

## 3. Host containers (optional — these are light; keep them to skip Phase 1)
```bash
# registry:2 (Phase 1). Drop -v to keep the pushed images across rebuilds.
cd /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/registry && docker compose down       # add -v to wipe the volume
# host Grafana (Phase 8) — only exists once created:
# cd ../host-grafana && docker compose down -v
```

## 4. Leave in place (shared / reused by the rebuild)
- libvirt `default` network + the MAC→IP reservations (`vms/net-reservations.sh`).
- The base image (step 2 note).
- Everything in git.

## Partial: downsize 3-server → 1-server WITHOUT a full nuke
Keep `nimbus-server-1` + `nimbus-agent-1`; cleanly remove the other two servers (etcd membership
must be removed, not just the VM, or quorum math breaks):
```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
for n in nimbus-server-3 nimbus-server-2; do           # 3->2 then 2->1 (one at a time)
  ssh ubuntu@<that-node-ip> 'sudo systemctl stop rke2-server'   # stop it first
  # remove its etcd member from a HEALTHY node (server-1):
  #   sudo bash scripts/etcdctl.sh member list            # find the member ID
  #   sudo bash scripts/etcdctl.sh member remove <ID>
  kubectl delete node "$n"
  virsh -c qemu:///system destroy "$n"; virsh -c qemu:///system undefine "$n" --nvram
  sudo rm -f /var/lib/libvirt/images/$n.qcow2 /var/lib/libvirt/images/$n-seed.iso
done
kubectl get nodes      # expect: nimbus-server-1 + nimbus-agent-1
```
