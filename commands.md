# Commands Log — Nimbus RKE2 learning lab (1 server + 2 workers, observability + cert-expiry incident)

Logs **only what WORKED**: the real command + a one-line note + the real result.
Failed attempts are not logged (except a short "gotcha" note worth keeping).
See `PLAN.md` for the phase-by-phase design.

**Topology — 1 control-plane/etcd server + 2 worker nodes (3 VMs).** The second worker exists to make
**pod anti-affinity** real (Phase 9) — you need ≥2 workers to watch replicas land on distinct hosts.
etcd is a **single member** (quorum 1, no HA / elections / split-brain); the cert-expiry incident
(Phase 12) still applies. Sizing stays under the RAM ceiling that once hung the host:

| VM | role | vCPU | RAM | disk |
|---|---|---|---|---|
| `nimbus-server-1` | control-plane + etcd (cluster-init), tainted | 3 | 3072 MB | 20 GB |
| `nimbus-agent-1` | worker | 4 | 3584 MB | 30 GB |
| `nimbus-agent-2` | worker | 4 | 3584 MB | 30 GB |

Totals **11 vCPU / 10 GB RAM** on the measured 16 GB / 20 vCPU WSL2 host → ~6 GB headroom (~62% RAM).
vCPU overcommits safely; RAM is the only hard limit, so this stays well clear of a hang.

---

## `k8s/` layout (one folder per kind of thing)

```
k8s/
├── bootstrap/      applied ONCE by hand with kubectl; not GitOps-managed
│   ├── root.yaml       the app-of-apps root (Application `nimbus-root`)
│   ├── argocd/         ArgoCD customizations (cmd-params, server Service, UI Ingress)
│   └── traefik/        HelmChartConfig that reshapes RKE2's packaged Traefik
├── applications/   ArgoCD Application CRs, one flat file per app — `nimbus-root` watches this dir
└── ingress/        every Traefik Ingress (frontend, prometheus, loki, ...), synced by the `ingress` app
```

Rule of thumb: `bootstrap/` is what you apply yourself; everything else is synced by ArgoCD from git.

> **Migration note (pending until you push):** the running `nimbus-root` was applied by hand and still
> points at the old `k8s/argocd/applications/children` path. After `git push`, re-apply the root once:
> `kubectl apply -f k8s/bootstrap/root.yaml`. The old `monitoring-ingress` + `apps-ingress` apps are
> replaced by a single `ingress` app, so the three Ingresses are deleted and recreated — expect
> `localhost:8080` / `:9090` / `:3100` to return 404 for a few seconds to a minute, then recover.

---

## Phase 0 — clean slate (2026-10-07)

Host already bare: no lab VMs (`virsh list --all` empty), no `~/.kube/config`, libvirt
`default` net active, Ubuntu base image kept at
`/var/lib/libvirt/images/noble-server-cloudimg-amd64.img`. WSL2 budget measured at
**16 GB RAM / 20 vCPU / 4 GB swap**, `/dev/kvm` present (PLAN assumed 12 GB — more headroom).
Repo wiped down to `PLAN.md` and rebuilt from scratch from here.

Toolchain present: `virsh` 12.0.0, `qemu-img` 10.2.1, `genisoimage`, `kubectl`, `helm`,
`docker` 29.8.2, `socat`. `cloud-localds` is **absent** — not needed; we build the cloud-init
seed ISO with `genisoimage`.

---

## Phase 1 — host-local registry (our ECR stand-in)

```bash
cd registry && docker compose up -d

curl -s http://localhost:5000/v2/
```

---

## Phase 2 — the RKE2 server VM (single control-plane + embedded etcd)

### 2.1 — build + boot the server VM (generic builder)

Fixed MAC→IP reservations on the libvirt `default` net (run once):

```bash

zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/net-reservations.sh

```

Build one VM from a qcow2 overlay of the kept base image + a NoCloud seed ISO. Usage:
`make-vm.sh <name> <ip> <mac> <vcpus> <ram_mb> <disk_gb>` (prompts sudo for the images dir). The server
runs at 3072 MB (2048 leaves no room for the CNI → NotReady; see 2.2); the two workers at 3584 MB.

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/make-vm.sh nimbus-server-1 192.168.122.11 52:54:00:a1:b1:11 3 3072 20

virsh -c qemu:///system net-dhcp-leases default

ssh -o StrictHostKeyChecking=accept-new ubuntu@192.168.122.11 'hostname; ip -4 -br a; nproc'
```

Result: `nimbus-server-1` running, lease `192.168.122.11`, SSH key login works. NIC is **`ens2`**
(not enp1s0) — DHCP reservations sidestep NIC-name guessing. Gotchas worth keeping:
- **Run `make-vm.sh` with its shebang (`vms/make-vm.sh ...`), not `zsh make-vm.sh`** — it's a bash
  script; under zsh `BASH_SOURCE` was unset so the VM dir resolved to CWD. (Script now uses `$0`.)
- `--osinfo generic` warning is harmless (libosinfo has no noble entry); VM runs fine.

### 2.2 — install RKE2 server on server-1 (cluster-init)

Copy the config generator to the VM once, then do the whole chain in ONE ssh session:

```bash
scp scripts/write-rke2-server-config.sh ubuntu@192.168.122.11:/tmp/

ssh ubuntu@192.168.122.11

```

At the `ubuntu@nimbus-server-1` prompt — config (cluster-init = no join IP) → install → start → kubectl:

```bash
sudo bash /tmp/write-rke2-server-config.sh nimbus-server-1 192.168.122.11

curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=v1.36.5+rke2r1 sh -

sudo systemctl enable --now rke2-server.service

sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl

mkdir -p ~/.kube && sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config \
  && sudo chown ubuntu:ubuntu ~/.kube/config && chmod 600 ~/.kube/config

kubectl get nodes -o wide
```

Result: `nimbus-server-1` **Ready**, roles `control-plane,etcd`. First etcd member live.

**Two design decisions this phase forced (already in the recipe above — not extra steps):**
1. **The server runs at 3072 MB, not 2048** (set in 2.1). On 2 GB the four core static pods request
   **1920Mi** (apiserver 1Gi, etcd 512Mi, controller-manager 256Mi, kube-proxy 128Mi) = 97% of the
   node → canal can't schedule → `cni plugin not initialized` → `NotReady`. *(If a VM was already
   built at 2 GB, bump in place without reinstalling: `virsh -c qemu:///system shutdown <n>`; wait
   for `shut off`; `virsh ... setmaxmem <n> 3072M --config`; `virsh ... setmem <n> 3072M --config`;
   `virsh ... start <n>`.)*
2. **The server is NOT tainted at bootstrap.** `CriticalAddonsOnly=true:NoExecute` on a node still
   bringing up its own CNI blocks the one-shot `helm-install-*` jobs (they don't tolerate it) → no
   canal → `NotReady`. The taint is removed from `write-rke2-server-config.sh`; we taint the server
   via `kubectl` AFTER the workers exist (Phase 3).

The version pin matters: the `stable` channel API lookup 404'd (`using stable as release` →
`releases/download/stable/...` 404), so `INSTALL_RKE2_VERSION=v1.36.5+rke2r1` is pinned explicitly.
The `curl | sh` install is only a ~65 MB tarball fetch+unpack (seconds); the real time is the
component **image pulls at first `systemctl start`**.

### 2.5 — inspect etcd (single member)

```bash
ssh ubuntu@192.168.122.11

sudo rke2 etcd-snapshot save --name phase2-baseline

sudo rke2 etcd-snapshot list
```

etcd runs as a **distroless** static-pod container (no `sh`/`ls`, only `etcd`/`etcdctl`), and RKE2
mounts the certs as **individual files** — so `scripts/etcdctl.sh` execs `etcdctl` directly with the
files that are actually in the container: `server-ca.crt` + `server-client.{crt,key}` (NOT the
host-only `client.crt`, which belongs to the apiserver and isn't mounted into etcd).

```bash
scp /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/etcdctl.sh ubuntu@192.168.122.11:/tmp/

ssh ubuntu@192.168.122.11

sudo bash /tmp/etcdctl.sh member list -w table
sudo bash /tmp/etcdctl.sh endpoint status --cluster -w table
sudo bash /tmp/etcdctl.sh endpoint health --cluster

```

Expect **1 voting member** (`nimbus-server-1`, `IS LEARNER=false`) → **quorum = 1**: the single member
is its own leader, with no elections or split-brain to reason about (the workers are not etcd members).
Gotcha: the hardened-etcd image has no shell — never `crictl exec ... sh`; call `etcdctl` directly.

---

## Phase 3 — the two worker (agent) nodes + taint

Build and join the workers **one at a time** (build → join → verify before the next). Each is
3584 MB / 30 GB; the stack spreads across the two instead of piling onto one. The install uses
`INSTALL_RKE2_TYPE=agent` (agent service, no control plane).

### 3.1 — build + join nimbus-agent-1

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/make-vm.sh nimbus-agent-1 192.168.122.21 52:54:00:a1:b1:21 4 3584 30

scp /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/write-rke2-agent-config.sh ubuntu@192.168.122.21:/tmp/
scp /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/registries.yaml ubuntu@192.168.122.21:/tmp/
ssh ubuntu@192.168.122.21
sudo bash /tmp/write-rke2-agent-config.sh nimbus-agent-1 192.168.122.21 192.168.122.11
# Trust the host-local registry over plain HTTP (ECR stand-in) BEFORE first start, so containerd
# generates certs.d/192.168.122.1:5000/hosts.toml with the http mirror at startup (no restart).
sudo install -D -o root -g root -m 0644 /tmp/registries.yaml /etc/rancher/rke2/registries.yaml
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE=agent INSTALL_RKE2_VERSION=v1.36.5+rke2r1 sh -
sudo systemctl enable --now rke2-agent.service
```

Expect 2 nodes Ready (1 `control-plane,etcd` + 1 worker) once you can see the cluster (kubeconfig step).

> **Registry trust (why this line matters).** Without `/etc/rancher/rke2/registries.yaml`, containerd
> has no mirror for `192.168.122.1:5000` and defaults to **HTTPS** → `http: server gave HTTP response
> to HTTPS client` when pulling `192.168.122.1:5000/nimbus/*`. containerd 2.x does **not** inline the
> mirror in `config.toml`; RKE2 writes it to `certs.d/192.168.122.1:5000/hosts.toml`. If the agent is
> already running when you add the file, run `sudo systemctl restart rke2-agent` to regenerate it.
> Verify: `sudo cat /var/lib/rancher/rke2/agent/etc/containerd/certs.d/192.168.122.1:5000/hosts.toml`
> shows a `[host."http://192.168.122.1:5000/v2"]` block with `capabilities = ["pull", "resolve"]`.

### 3.2 — build + join nimbus-agent-2

The identical join recipe with agent-2's name / IP / MAC:

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/make-vm.sh nimbus-agent-2 192.168.122.22 52:54:00:a1:b1:22 4 3584 30

scp /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/write-rke2-agent-config.sh ubuntu@192.168.122.22:/tmp/
scp /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/registries.yaml ubuntu@192.168.122.22:/tmp/
ssh ubuntu@192.168.122.22
sudo bash /tmp/write-rke2-agent-config.sh nimbus-agent-2 192.168.122.22 192.168.122.11
# same registry-trust step as agent-1 (see the note under 3.1)
sudo install -D -o root -g root -m 0644 /tmp/registries.yaml /etc/rancher/rke2/registries.yaml
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE=agent INSTALL_RKE2_VERSION=v1.36.5+rke2r1 sh -
sudo systemctl enable --now rke2-agent.service
```

### Host (WSL) kubectl — session-only (not persisted)

```bash
scp ubuntu@192.168.122.11:.kube/config /tmp/nimbus-kubeconfig.yaml
sed -i 's#https://127.0.0.1:6443#https://192.168.122.11:6443#' /tmp/nimbus-kubeconfig.yaml
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
kubectl get nodes -o wide
```

Expect **3 nodes Ready** — 1 `control-plane,etcd` + 2 workers (`nimbus-agent-1`/`-2`, role `<none>`).
The agents have no API/kubeconfig of their own. The `127.0.0.1`→server-IP rewrite is required because
the node kubeconfig only works on-node; the server IP is valid because it's in `tls-san`.

### 3.3 — taint the server LAST (ordering matters)

Only after **both** workers are Ready, taint `nimbus-server-1` so no workloads land on the
control-plane/etcd node:

Run the following in a second terminal before you apply the taint, because events are only retained ~1h and you want to catch them live:
```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
kubectl get events -A --watch --field-selector reason=TaintManagerEviction
```

```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/taint-servers.sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

The order is the whole point: `CriticalAddonsOnly=true:NoExecute` applied at bootstrap (while a node is
still bringing up its CNI) blocks the one-shot `helm-install-*` jobs — they don't tolerate the taint —
so canal never installs and the node is `NotReady`. Applied here, at steady state with both workers
already catching workloads, **canal** (DaemonSet, blanket tolerations) and **kube-proxy** (static pod)
are not evicted, networking stays intact, and the taint lives in the node object in etcd (survives
reboots). **CoreDNS stays on the server by design** (RKE2 gives it a `CriticalAddonsOnly` toleration for
DNS HA); only its `autoscaler` moves to a worker — visible proof the taint took. The taint's real job is
keeping heavy add-ons (Traefik/Prometheus/Loki/apps) on the workers.

---

## Phase 4 — networking: socat = the ALB

### 4.1 — bring up the multi-port "ALB"

One `socat` forward per Traefik entrypoint: a "pretty" host port -> the matching NodePort on
`nimbus-agent-1` (192.168.122.21) — an AWS ALB listener->target contract, socat as the ALB. NodePorts
are published on **every** node by kube-proxy, so these forwards reach the Traefik pod even when the
scheduler places it on `nimbus-agent-2` — no change is needed for the second worker.

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/socat-bridge.sh
```
The start is idempotent; tear the forwards down with `zsh .../socat-bridge.sh stop`.

Result: all six host ports LISTEN (`8080`/web->30001, `3100`/loki->30000, `9090`/prometheus->30002,
`9069`/argocd->30003, `8025`/mailpit-ui->30004, `1025`/mailpit-smtp->30005; plus `3000`/grafana->30006,
which `socat-bridge.sh` also forwards for the in-cluster Grafana of Phase 8). Notes:
- The forwards bind `0.0.0.0` and accept connections now, but can't *complete* a connection until
  Traefik publishes those NodePorts (Phase 5) — expected. Phase 5.2 verifies they reach Traefik.
- Idempotent restart matches `socat .*TCP:192.168.122.21:` so a re-run kills only this script's
  forwards, never an open ssh session to the agent. Per-service logs at `/tmp/nimbus-socat-*.log`.

### 4.2 — /etc/hosts

Skipped: Traefik routing here is path-based / host-less (IngressRoutes keyed on entrypoint + path,
not Host headers), so no hosts entry is needed. Revisit if a host-based route appears.

---

## Phase 5 — Traefik (the ALB-shaped ingress)

RKE2 v1.36 **ships Traefik** as a packaged, helm-controller-managed chart (`rke2-traefik` +
`rke2-traefik-crd` in kube-system) — image `rancher/hardened-traefik:v3.7.13`, chart = upstream
Traefik Helm **v40.1.0** renamed. Out of the box it's a ClusterIP service with only `web`(80)/
`websecure`(443). So Phase 5 is *reshaping the Traefik RKE2 already runs* into our ALB-shaped config —
the RKE2-native equivalent of a standalone `helm upgrade traefik -f <values>.yml`.

### 5.1 — override the packaged chart with a HelmChartConfig

RKE2's helm-controller watches for a `HelmChartConfig` of the SAME name/namespace as a packaged
chart and re-runs the install with its `valuesContent` deep-merged over the chart defaults. Our values
set named entrypoints, a NodePort service, metrics, JSON access logs, and the dashboard — minus any
app-specific entrypoints or plugins we don't need. File: `k8s/bootstrap/traefik/helmchartconfig.yaml`.
The entrypoints are `web`(30001), `loki`(30000), `prometheus`(30002), `argocd`(30003), `mailpit`(30004),
`mailpit-smtp`(30005) and `grafana`(30006, port 3000 — used by Phase 8). All of Traefik is applied here, so
Phase 8 does not touch Traefik or socat.

```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml

kubectl apply -f /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/k8s/bootstrap/traefik/helmchartconfig.yaml

kubectl -n kube-system get pods -l job-name=helm-install-rke2-traefik -w
```

**Gotcha that cost one failed install — chart v40 moved the service type.** Older Traefik values set
`service.type: NodePort`; in Traefik chart v40 the type lives at **`service.spec.type`**. The old key
silently no-ops, so the Service stayed ClusterIP while the per-entrypoint `nodePort`s applied → helm
install failed: `spec.ports[*].nodePort: Forbidden ... when type is 'ClusterIP'`. The helm-install job
then crash-looped under `FAILURE_POLICY: reinstall`. Fix = `service.spec.type: NodePort`; re-apply
changes the configHash → fresh job uninstalls the failed release and reinstalls clean.
(Chart internals were read by decoding the `chart-content-rke2-traefik` ConfigMap:
`.data["rke2-traefik.tgz.base64"] | base64 -d | gunzip | tar x` → `values.yaml`.)

Also note: do **not** set `globalArguments` in the override — Helm *replaces* lists (no merge), so it
would wipe the chart's own default flags. We route with IngressRoute CRDs, so the single
`ingressendpoint.ip` flag (for the kubernetesIngress provider) isn't needed.

---

## Phase 6 — ArgoCD (GitOps)

### 6.1 — install ArgoCD + expose via the Traefik `argocd` entrypoint

RKE2 ships nothing for ArgoCD, so we install upstream, **pinned to v2.12.3**. That pinned
`install.yaml` is the stock upstream manifest; we apply it from the pinned URL rather than vendoring
the 1.2 MB blob, then layer three small customizations (`k8s/bootstrap/argocd/`):

```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
cd /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=360s

kubectl apply -f k8s/bootstrap/argocd/argocd-cmd-params-cm.yaml
kubectl apply -f k8s/bootstrap/argocd/argocd-server-service.yaml
kubectl apply -f k8s/bootstrap/argocd/06_argocd-ingress.yaml
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
```

Why these three:
- **`server.insecure: "true"`** — the socat ALB is a dumb plain-TCP forward (no TLS), so argocd-server
  must serve plain HTTP on :8080. This mirrors the usual AWS setup, where the ALB terminates HTTPS and
  forwards plain HTTP to the Traefik argocd nodePort.
- **argocd-server Service port 9069 → targetPort 8080** — the remap so the Traefik `argocd`
  entrypoint (Service port 9069) reaches it.
- **Ingress on entrypoint `argocd`** — rather than the deprecated `kubernetes.io/ingress.class` annotation,
  we use the modern **`spec.ingressClassName: traefik`** field (clears the kubectl deprecation
  warning; Traefik is also the default class). The `traefik.ingress.kubernetes.io/router.entrypoints:
  argocd` annotation is what actually binds it to the entrypoint.

### get the password and access it over the web

```bash
PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d); echo "$PW"
```

Result: UI returns 200 over plain HTTP through socat→Traefik `argocd`→argocd-server; CLI login works.
Gotchas: use **`--plaintext --grpc-web`** (plain HTTP + gRPC-over-HTTP/1.1 through Traefik). The v3.5
CLI still prints a one-time TLS cert warning (`valid for *.traefik.default, not localhost`) before
falling through to plaintext — **cosmetic**, answer `y`; the path is plain HTTP end to end. (CLI v3.5
vs server v2.12 skew is fine for login/cluster-add.)

### 6.2 — app-of-apps (DEFERRED to Phase 7/9)

ArgoCD syncs from a **Git repo**; the project is now a git repo pushed to
`git@github.com:jefta-jose/rke2-aws-tf-cluster.git` (branch `main`). The app-of-apps + Applications
are created when we have workloads to put in them (monitoring in Phase 7, apps in Phase 9), deployed to
the **in-cluster** cluster. ArgoCD manages the cluster it runs on via its default in-cluster
ServiceAccount, so Applications target `https://kubernetes.default.svc`; no external cluster is registered.

---

## Phase 7 — observability in-cluster (GitOps via ArgoCD app-of-apps)

Route chosen: **GitOps**. ArgoCD (public repo, no creds) owns monitoring via an app-of-apps. The
workers are small, so Prometheus/Loki are tuned tiny.

### 7.0 — app-of-apps root (the deferred 6.2)

`k8s/bootstrap/root.yaml` = Application `nimbus-root`: watches `k8s/applications/` in git
(recurse), destination in-cluster/argocd (where Application CRs must live), automated+prune+selfHeal.
Bootstrap ONCE by hand; self-managing after (commit a child manifest -> ArgoCD creates the app).

```bash
git add k8s/ && git commit -m "..." && git push
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
kubectl apply -f k8s/bootstrap/root.yaml
argocd app get nimbus-root
```

(The `metadata.finalizers: resources-finalizer.argocd.argoproj.io` warning is cosmetic — it's
ArgoCD's standard cascade-delete finalizer; newer k8s just wants a `/path` suffix.)

The monitoring stack is **three** child apps: the Prometheus chart (7.1), the Loki chart (7.2), and a
shared ingress-glue app (7.3). The two chart apps render **only workloads**; their Traefik Ingresses
are plain manifests owned by the ingress app, so all the "expose it" wiring is in one place.

### 7.1 — Prometheus child app (tiny)

`k8s/applications/prometheus.yaml` = Application: chart
`prometheus-community/prometheus` **29.36.0** (Prometheus v3.15.0), destination **in-cluster**
(`https://kubernetes.default.svc`), ns `monitoring`. Values: alertmanager + pushgateway off; server
emptyDir + 6h retention (RKE2 has no default StorageClass); node-exporter `tolerations: [{operator:
Exists}]` so it also runs on the tainted server; default scrape config kept (honors
`prometheus.io/scrape` annotations — no ServiceMonitor needed). No Ingress in the chart — see 7.3.

Result: `monitoring` has `prometheus-server` (2/2: server + config-reload), `kube-state-metrics`, and
`node-exporter` on **all 3 nodes**. Once 7.3 is synced, reachable through the ALB
(`curl localhost:9090/-/healthy` -> `Prometheus Server is Healthy.`), all active targets up
(`curl -s localhost:9090/api/v1/targets?state=active`).

### 7.2 — Loki child app (tiny)

`k8s/applications/loki.yaml` = Application: chart `grafana/loki-stack` **2.10.3**
(Loki 2.9.3 single-binary + Promtail DaemonSet), destination **in-cluster**, ns `monitoring`. Values:
Loki filesystem storage, persistence off (emptyDir); Promtail DaemonSet with a blanket toleration so it
also ships logs from the tainted server (we want etcd/kube-proxy/canal errors visible in Phase 12); the
chart's bundled Grafana + Prometheus subcharts **off** (Grafana is on the host in Phase 8; Prometheus is
its own app). The deprecated `loki-stack` chart is chosen on purpose — it's "single-binary Loki +
collector" with almost no knobs, vs the current `grafana/loki` chart that needs memcached/gateway/canary
disabled to fit a tiny node. No Ingress in the chart — see 7.3.

Result: `monitoring` gains `loki-0` plus a `loki-promtail` pod per node. Once 7.3 is synced, reachable
through the ALB (`curl localhost:3100/ready` -> `ready`).

### 7.3 — ingress child app (the shared ingress glue)

`k8s/applications/ingress.yaml` = a **directory** Application (`ingress`) syncing every
plain manifest under `k8s/ingress/` (each sets its own namespace). Currently `prometheus.yaml`
(Ingress -> entrypoint `prometheus` -> `prometheus-server:80`), `loki.yaml` (Ingress -> entrypoint
`loki` -> `loki:3100`) and `frontend.yaml` (entrypoint `web` -> `frontend:8080`). Convention: chart apps render workloads; each service's host-less Traefik
Ingress is a plain manifest here, one pattern for all (annotation
`traefik.ingress.kubernetes.io/router.entrypoints: <name>` + `ingressClassName: traefik`). Add a
service's entrypoint later by dropping its Ingress YAML into that directory — this app picks it up.

Workflow (all three): edit the manifest -> `git add k8s/ && git commit && git push` ->
`argocd app get <app> --refresh`. ArgoCD reads GitHub, not your working tree.

Gotchas:
- **kube-state-metrics `Failed to contact API server for /livez: got 0`** warnings + a few early
  restarts (exit 2) are a benign, over-sensitive self-check (short-timeout API ping via kube-proxy to a
  loaded server); it settles, and Prometheus (same node) scrapes the API fine. Only relax its probe if
  restarts recur under load.
- A brief startup blip (Prometheus' first scrape pass) can momentarily disrupt argocd/9069 +
  prometheus/9090 through the ALB; it self-recovers. Watch for it when adding more load.
- We deliberately keep each Ingress OUT of its chart. Prometheus' chart would carry it via
  `extraManifests`, whose items must be STRINGS (rendered through `tpl`; a YAML map errors with
  `wrong type for value; expected string; got map`) — keeping ingresses as plain manifests in
  `k8s/ingress/` sidesteps that and puts all the glue in one place.

---

## Phase 8 — Grafana in-cluster, managed by ArgoCD (POC of the real Rok setup)

> **STATUS: written, NOT YET RUN.** Mark each step with its real result once you run it (this file logs
> only what worked).

Grafana runs **in the cluster**, deployed by ArgoCD the way the real Rok Grafana is (chart
`grafana/grafana` **8.10.1** = Grafana 11.5.2, release `grafana`, **namespace `grafana`**). The old host
docker-compose Grafana (`host-grafana/`) is removed. Deliberate differences from real Rok: persistence off
(emptyDir; real = `ebs-sc` PVC), no Azure AD/SMTP, datasources provisioned in values (real = UI), Traefik
host-less Ingress (real = nginx + cert-manager TLS).

**Prerequisite (already done in Phases 4-5, nothing to run here):** the Traefik `grafana` entrypoint
(NodePort 30006) is applied and socat forwards `localhost:3000` -> 30006. Phase 8 is just the same
GitOps flow as Phase 7: create the namespace + Secret by hand, push, let ArgoCD sync.

### 8.1 — create the namespace + admin Secret by hand (never in git)

The repo is public, so credentials never go in a manifest — same idea as the real `grafana-secret`.
Do this BEFORE the push so the pod finds its Secret on first start:

```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml

kubectl create namespace grafana
kubectl -n grafana create secret generic grafana \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 18)"
```

### 8.2 — push to git; ArgoCD syncs

`k8s/applications/grafana.yaml` (the Application) and `k8s/ingress/grafana.yaml` (the Ingress, picked up
by the existing `ingress` app) are the only new manifests. ArgoCD reads GitHub, not your working tree:

```bash
git add -A && git commit -m "grafana via argocd" && git push
argocd app get grafana --refresh
kubectl -n grafana get pods
```

### 8.3 — log in and verify

```bash
kubectl -n grafana get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
curl -s -o /dev/null -w "grafana: %{http_code}\n" http://localhost:3000/api/health --max-time 5
```

Open `http://localhost:3000` (user `admin`, password from the command above). Under Connections ->
Data sources, **Prometheus** (default) and **Loki** should test green — they point at the in-cluster
Services `prometheus-server.monitoring.svc:80` and `loki.monitoring.svc:3100`, not the socat ports.

Key points:
- State is `emptyDir`: a pod restart resets anything created only in the UI. That is intentional — the
  next step tracks a dashboard + alert rule in git so they survive.
- Add dashboards/alerts later via git (deferred step); nothing is clicked together by hand.

---

## Phase 9 — app pods: resource management + pod (anti-)affinity (learning)

The three-VM topology exists for this phase. We give the Phase 9 trio a worked example on
**`service-a`** (scaled to `replicas: 2`) plus a tiny **`cache`** Deployment, to learn three scheduling
controls. All of it is config layered into `charts/nimbus-app` and synced through ArgoCD.

### 9.a — Resource requests & limits

`requests` are the scheduling floor the kube-scheduler reserves on a node; a **CPU request does not cap
CPU** (it only guarantees a share under contention). `limits.memory` is a hard cap — a container that
exceeds it is **OOMKilled** and restarted. We leave CPU uncapped (a CPU limit throttles rather than
kills, and throttling is easy to misdiagnose). Tiny-lab starting values (a production-scale service uses
`cpu 250m / mem 1Gi` requests and a `6Gi` memory limit for a heavy report generator):

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi
```

### 9.b — Pod anti-affinity (why there are two workers)

Spread the two `service-a` replicas onto different workers. **Preferred**, not required, so a rollout
can never wedge:

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app: service-a
```

`preferred` is best-effort: with 2 workers and 2 replicas they split one-per-worker, but a third
replica (or a surge-heavy rollout under `maxSurge`) is still allowed to co-locate rather than stall.
**Required** (`requiredDuringSchedulingIgnoredDuringExecution`) would instead leave any replica beyond
the node count stuck `Pending` — fine for strict separation, dangerous for rollouts on a 2-worker
cluster.

Scope note: this is **same-namespace** separation (all `service-a` replicas share one namespace).
Separating two *namespaces* — e.g. `development` vs `staging` — is different:
`topologySpreadConstraints` only count pods in the pod's own namespace, so cross-environment separation
needs pod anti-affinity with an explicit `namespaces:` list or a `namespaceSelector:`. We demo only the
same-namespace case here; the cross-namespace variant is described in `note.txt`.

### 9.c — Pod affinity (co-locate the cache)

Pull the `cache` pod onto whichever worker runs `service-a`:

```yaml
affinity:
  podAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app: service-a
```

(`nodeAffinity` is the cousin that pins to a specific node by label — the inverse of the
`CriticalAddonsOnly` taint on the server, which *repels* pods instead.)

### 9.d — The Helm caveat: values alone do nothing

Adding `resources` / `affinity` to a values file has no effect unless the shared chart **template**
renders them into the PodSpec. The Deployment template must carry something like:

```yaml
spec:
  template:
    spec:
      {{- with .Values.serviceA.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: service-a
          {{- with .Values.serviceA.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

So each change touches **both** `charts/nimbus-app` values and its Deployment template. Render before
deploying to confirm the fields actually land:

```bash
helm template charts/nimbus-app | kubectl apply --dry-run=client -f -
```

### 9.e — Verify placement

```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
kubectl -n nimbus get pods -o wide -l app=service-a
kubectl describe node nimbus-agent-1 | sed -n '/Allocated resources/,/Events/p'
kubectl top pod -n nimbus
kubectl -n nimbus scale deploy/service-a --replicas=3
kubectl -n nimbus get pods -o wide -l app=service-a
kubectl -n nimbus get pod -l app=cache -o wide
```

Expect the two `service-a` replicas on **different** workers; the `cache` pod on the **same** worker as
a `service-a` replica; and the third replica (after scale-up) co-located on one of the two workers —
`preferred` allows it, whereas `required` would leave it `Pending`. To see a memory limit bite, drive
the app past its `limits.memory` and watch the container go `OOMKilled` with a rising restart count:

```bash
kubectl -n nimbus get pod -l app=service-a -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
```

---

## Phase 10 — manage Grafana via git (dashboards + alert rules as code)

> **STATUS: in progress.** 10.1 is done. 10.2/10.3 are written but NOT YET RUN — fill in each real
> result once it works (this file logs only what worked).

Idea: the Grafana chart can run **sidecar containers** that watch Kubernetes for ConfigMaps carrying a
label and load them into Grafana. So: file in git -> ArgoCD syncs a labelled ConfigMap -> sidecar sees it ->
Grafana loads it. Delete the file and it disappears. This is how the real Rok Grafana (UI-only today,
nothing in git) could be put under version control.

Baseline before changing anything (done): `grafana` app healthy, pod `1/1`, a single container `grafana`,
`localhost:3000/api/health` -> `200`. (`argocd` CLI needed a fresh `argocd login localhost:9069 ... --plaintext
--grpc-web` — its old token was stale.)

### 10.1 — enable the dashboard + alert sidecars

`k8s/applications/grafana.yaml` gained a `sidecar:` block under `valuesObject`:
- `sidecar.dashboards`: watches ConfigMaps labelled `grafana_dashboard: "1"` in ALL namespaces; the folder
  comes from the annotation `grafana_folder`.
- `sidecar.alerts`: watches ConfigMaps labelled `grafana_alert: "1"` in ALL namespaces; after writing a file
  it calls Grafana's `/api/admin/provisioning/alerting/reload` using the admin Secret from Phase 8.

```bash
git add -A && git commit -m "grafana: enable dashboard + alert sidecars" && git push
argocd app get grafana --refresh
kubectl -n grafana get pods -w
kubectl -n grafana get pod -l app.kubernetes.io/name=grafana -o jsonpath='{range .items[0].spec.containers[*]}{.name}{"\n"}{end}'
```

Result: the pod was replaced by a rolling update (`grafana-56f5d857b4-…`), `3/3` Running, 0 restarts,
containers `grafana-sc-alerts`, `grafana-sc-dashboard`, `grafana`. (The chart also adds a ClusterRole so the
sidecars can read ConfigMaps in ALL namespaces.) Gotcha: `argocd` CLI needs a fresh login first, and the
change reaches Grafana in two hops (root app syncs the changed Application, then `grafana` re-renders).

### 10.2 + 10.3 — a node-health dashboard, an alert rule and a Teams contact point, all from git

> NOT YET RUN.

New files: `k8s/grafana/` and `k8s/applications/grafana-content.yaml`:
- `kustomization.yaml` — a `configMapGenerator` wraps two files into ConfigMaps in namespace `grafana`:
  `dashboards/nimbus-node-health.json` (label `grafana_dashboard: "1"`, annotation `grafana_folder: Nimbus`)
  and `alerting/nimbus-alerting.yaml` (label `grafana_alert: "1"`). Hash suffixes off = stable names.
- `alerting/nimbus-alerting.yaml` — contact point `nimbus-teams` (type `teams`, url `dummy-webhook-url`) and
  rule group `Nimbus Node Health` / rule **Node not Ready**: query `kube_node_status_condition{condition="Ready",status="true"}`
  -> Reduce(last) -> Threshold `< 1`, `for 2m`, noData/execErr = Alerting, routed to `nimbus-teams`. No
  `or vector(0)`: a missing metric must show as No data, not as healthy.
- `grafana-content.yaml` — Application syncing `k8s/grafana/` (ServerSideApply for big dashboard JSON).
- `k8s/applications/grafana.yaml` — datasources now have fixed uids `prometheus` / `loki` (this rolls the
  Grafana pod once), so the JSON/YAML in git can reference them.

Preview what ArgoCD will apply (read-only): `kubectl kustomize k8s/grafana`

```bash
git add -A && git commit -m "grafana content from git: node-health dashboard + alert + teams contact point" && git push
argocd app get nimbus-root --refresh | head -12
argocd app get grafana --refresh | head -12
argocd app get grafana-content --refresh | head -12
kubectl -n grafana get cm -l grafana_dashboard=1
kubectl -n grafana get cm -l grafana_alert=1
kubectl -n grafana logs deploy/grafana -c grafana-sc-alerts --tail=20
```

Verify in the UI (`http://localhost:3000`): Dashboards -> folder **Nimbus** -> "Nimbus - Node Health";
Alerting -> Alert rules -> **Node not Ready** (state Normal, 3 nodes); Alerting -> Contact points ->
**nimbus-teams** (provisioned, read-only).
