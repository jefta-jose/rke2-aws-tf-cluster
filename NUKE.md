# NUKE.md — full teardown runbook (ROK Infra Learning Lab)


## 2. Terraform / Floci — destroy the AWS base

Destroys everything Terraform provisioned into Floci: `development-rok-general-secret`,
SQS `email` + `email-dlq`, IAM node role/policies, the ALB + NodePort 30080 target group, and the WAFv2
WebACL. (No ECR repos — Terraform provisions none; images ship via the host-local `registry:2`.)

**Full reset:** instead of a graceful `destroy`, you can wipe Floci's entire state
by dropping its data. Floci persists to a bind mount (`./data`) under the compose project, so bringing
the stack down and deleting that directory nukes all Floci resources at once (also wipes the ECR
backing store). Do this only when you don't care about a clean per-resource destroy:

```bash
docker compose -f /home/jeffndegwa/floci-docker/docker-compose.yaml down
sudo rm -rf /home/jeffndegwa/floci-docker/data
docker volume rm floci-ecr-registry-data
```
---

## 3. Docker (host) — Floci stack + local registry

Only after step 2. Brings down the Floci compose stack (`floci` + `floci-ui`), removes the separate ECR
backing container, and removes the `registry:2` image registry plus its data volume.

```bash
docker compose -f /home/jeffndegwa/floci-docker/docker-compose.yaml down
docker rm -f floci-ecr-registry
docker rm -f lab-registry
docker volume rm lab-registry-data
```

- `docker compose ... down` stops+removes `floci-docker-floci-1` and `floci-docker-floci-ui-1` (started
  per `/home/jeffndegwa/floci-docker/docker-compose.yaml`).
- `floci-ecr-registry` is a standalone container (the hybrid-mode ECR backing store), not in the compose
  file — remove it directly.
  drop it in step 2.
- `lab-registry` is the `registry:2` container started in Phase 7.2
  (`docker run ... -v lab-registry-data:/var/lib/registry registry:2`); removing `lab-registry-data`
  discards the pushed images (`rok-frontend`, `rok-backend`, `rok-mailer`). You'll re-push them from
  `apps/*` on rebuild (Phase 7.2 / 9.2 / 9.3).

> Leave the unrelated observability containers (grafana, prometheus, cadvisor, node-exporter) alone —
> they're not part of this lab's teardown.

---

## 4. VMs — destroy rok-server + rok-agent-1

Destroys (force-stops) then undefines both RKE2 nodes.

> **Order:** VMs FIRST, the libvirt `default` network LAST

```bash
virsh -c qemu:///system destroy rok-server
virsh -c qemu:///system undefine rok-server
virsh -c qemu:///system destroy rok-agent-1
virsh -c qemu:///system undefine rok-agent-1
virsh -c qemu:///system list --all
```

### ⚠️ KEEP the Ubuntu base image (do NOT delete it)

**Leave the downloaded Ubuntu 24.04 cloud image in place** so re-provisioning is fast (no multi-hundred-MB
re-download). The base image is:

```
/var/lib/libvirt/images/noble-server-cloudimg-amd64.img   <-- KEEP THIS
```

`vms/*/build.sh` reuses it to build each VM's overlay disk. If you want to reclaim a little space you may
delete the **per-VM overlays / seed ISOs** (they're rebuilt in seconds from the kept base image), but this
is optional and NOT required for a rebuild:

```bash
sudo rm -f /var/lib/libvirt/images/rok-server.qcow2 /var/lib/libvirt/images/rok-server-seed.iso
sudo rm -f /var/lib/libvirt/images/rok-agent-1.qcow2 /var/lib/libvirt/images/rok-agent-1-seed.iso
```

---

## 5. Host bits — bridge, /etc/hosts, kubeconfig

### 5.1 Kill the socat bridge

The `socat` forwarder (WSL2 host `localhost:30080` → VM `:30080`) runs under `nohup`. Stop it:

```bash
pkill -f 'socat.*30080'
```

### 5.2 Remove the /etc/hosts entries the lab added

Phase 6.3a appended `<IP> argocd.rok.local`. There may also be a **stale `mailpit.rok.local`** line from
the first mailpit attempt (9.1a) before it switched to host-less `/mailpit`. Remove both (they carry
now-stale DHCP IPs anyway):

```bash
sudo sed -i '/argocd\.rok\.local/d' /etc/hosts
sudo sed -i '/mailpit\.rok\.local/d' /etc/hosts
```

### 5.3 Kubeconfig

The session-only kubeconfig lives at:

```bash
rm -f /home/jeffndegwa/.kube/rok-lab.yaml
```