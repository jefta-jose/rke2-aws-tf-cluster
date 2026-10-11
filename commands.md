# Commands Log — Nimbus RKE2 learning lab (1 server + 2 workers, observability + cert-expiry incident)

Logs **only what WORKED**: the real command + a one-line note + the real result.
Failed attempts are not logged (except a short "gotcha" note worth keeping).
See `PLAN.md` for the phase-by-phase design.

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

## Phase 2 — three RKE2 server VMs (real etcd quorum)

### 2.1 — build + boot the VMs (generic builder)

Fixed MAC→IP reservations on the libvirt `default` net (run once):

```bash

zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/net-reservations.sh

```

Build one VM from a qcow2 overlay of the kept base image + a NoCloud seed ISO. Usage:
`make-vm.sh <name> <ip> <mac> <vcpus> <ram_mb> <disk_gb>` (prompts sudo for the images dir). Servers
run at 3072 MB (2048 leaves no room for the CNI → NotReady; see 2.2); the agent at 3584 MB.

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/make-vm.sh nimbus-server-1 192.168.122.11 52:54:00:a1:b1:11 2 3072 20

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
1. **Servers run at 3072 MB, not 2048** (set in 2.1). On 2 GB the four core static pods request
   **1920Mi** (apiserver 1Gi, etcd 512Mi, controller-manager 256Mi, kube-proxy 128Mi) = 97% of the
   node → canal can't schedule → `cni plugin not initialized` → `NotReady`. *(If a VM was already
   built at 2 GB, bump in place without reinstalling: `virsh -c qemu:///system shutdown <n>`; wait
   for `shut off`; `virsh ... setmaxmem <n> 3072M --config`; `virsh ... setmem <n> 3072M --config`;
   `virsh ... start <n>`.)*
2. **Servers are NOT tainted at bootstrap.** `CriticalAddonsOnly=true:NoExecute` on a node still
   bringing up its own CNI blocks the one-shot `helm-install-*` jobs (they don't tolerate it) → no
   canal → `NotReady`. The taint is removed from `write-rke2-server-config.sh`; we taint all servers
   via `kubectl` AFTER the agent exists (Phase 3).

### 2.3 — join additional servers (one at a time)

Build one server VM (host side):

```bash

zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/make-vm.sh nimbus-server-2 192.168.122.12 52:54:00:a1:b1:12 2 3072 20

```

Then the join, in ONE ssh session (the 3rd arg to the config script = the first server's IP):

```bash
scp /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/write-rke2-server-config.sh ubuntu@192.168.122.12:/tmp/

ssh ubuntu@192.168.122.12

sudo bash /tmp/write-rke2-server-config.sh nimbus-server-2 192.168.122.12 192.168.122.11

curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=v1.36.5+rke2r1 sh -

sudo systemctl enable --now rke2-server.service

sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl

mkdir -p ~/.kube && sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config \
  && sudo chown ubuntu:ubuntu ~/.kube/config && chmod 600 ~/.kube/config

kubectl get nodes -o wide
```

Result: `nimbus-server-2` joined, **2 `control-plane,etcd` nodes Ready** (~3m30s to Ready). Notes:
- **Pin `INSTALL_RKE2_VERSION`** — the `stable` channel API lookup 404'd (`using stable as release`
  → `releases/download/stable/...` 404). Pinning skips the lookup and matches server-1's version.
- The `curl | sh` install is only a ~65 MB tarball fetch+unpack (seconds); the real time is the
  component **image pulls at first `systemctl start`** (each VM pulls independently — no shared cache).
- server-3 joins identically: `nimbus-server-3 192.168.122.13 ... 192.168.122.11`.

### 2.5 — inspect the etcd quorum

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

Result: 3 voting members (`IS LEARNER=false`), **quorum = 2 of 3**. Leader was `nimbus-server-2`
(leadership is elected and moves — it shifted off server-1 when we rebooted it for the RAM bump).
All members on the same `RAFT TERM` (7) and identical `RAFT INDEX` (21358) = fully in sync. `IN USE`
7.1 MB on all three; server-1's larger `DB SIZE` is just un-defragged free space (cosmetic).
Gotcha: the hardened-etcd image has no shell — never `crictl exec ... sh`; call `etcdctl` directly.

---

## Phase 3 — the agent (workload) node + registry trust

### 3.1 — build + join nimbus-agent-1

Bigger box: 3584 MB / 40 GB (carries every workload + all images). Build (host side):

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/make-vm.sh nimbus-agent-1 192.168.122.21 52:54:00:a1:b1:21 2 3584 40
```

Join in ONE ssh session — install uses `INSTALL_RKE2_TYPE=agent` (agent service, no control plane):

```bash
scp /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/write-rke2-agent-config.sh ubuntu@192.168.122.21:/tmp/
ssh ubuntu@192.168.122.21
sudo bash /tmp/write-rke2-agent-config.sh nimbus-agent-1 192.168.122.21 192.168.122.11
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

Result: **4 nodes Ready** — 3 `control-plane,etcd` + `nimbus-agent-1` (role `<none>`, worker).
The agent has no API/kubeconfig of its own. The `127.0.0.1`→server-IP rewrite is required because
the node's kubeconfig only works on-node; the server IP is valid because it's in `tls-san`.

### 3.2 — taint the servers (now safe: the agent exists to catch workloads)

```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/taint-servers.sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

Result: `CriticalAddonsOnly=true:NoExecute` on the 3 servers (persists in etcd, survives reboots).
`NoExecute` evicts non-tolerating pods immediately — but **canal** (DaemonSet, blanket tolerations)
and **kube-proxy** (static pod) are not evicted, so networking is intact. **CoreDNS stays on the
servers by design** (RKE2 gives it a `CriticalAddonsOnly` toleration for DNS HA); only its
`autoscaler` (no toleration) moved to the agent — visible proof the taint took. The taint's real job
is keeping heavy add-ons (Traefik/Prometheus/Loki/apps) on the agent.

---

## Phase 4 — networking: socat = the ALB

### 4.1 — bring up the multi-port "ALB"

One `socat` forward per Traefik entrypoint: a "pretty" host port -> the matching NodePort on
`nimbus-agent-1` (192.168.122.21) — an AWS ALB listener->target contract, socat as the ALB.

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/socat-bridge.sh
```
The start is idempotent; tear the forwards down with `zsh .../socat-bridge.sh stop`.

Result: all six host ports LISTEN (`8080`/web->30001, `3100`/loki->30000, `9090`/prometheus->30002,
`9069`/argocd->30003, `8025`/mailpit-ui->30004, `1025`/mailpit-smtp->30005). Notes:
- The forwards bind `0.0.0.0` and accept connections now, but can't *complete* a connection until
  Traefik publishes those NodePorts (Phase 5) — expected. Phase 5.2 verifies they reach Traefik.
- Idempotent restart matches `socat .*TCP:192.168.122.21:` so a re-run kills only this script's
  forwards, never an open ssh session to the agent. Per-service logs at `/tmp/nimbus-socat-*.log`.
- The ArgoCD API forward (`localhost:6443 -> <server-ip>:6443`, the control-plane NLB) is a
  *server*-targeted forward and comes in Phase 6.3 — not in this script yet.

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
app-specific entrypoints or plugins we don't need. File: `k8s/traefik/helmchartconfig.yaml`.

```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml

kubectl apply -f /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/k8s/traefik/helmchartconfig.yaml

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

### 5.2 — verify

```bash
kubectl -n kube-system get svc rke2-traefik -o jsonpath='{.spec.type}{"\n"}{range .spec.ports[*]}{.name}{"\t"}{.port}{"\t->node:"}{.nodePort}{"\n"}{end}'
kubectl -n kube-system get pod -l app.kubernetes.io/name=rke2-traefik -o wide
for p in 8080 3100 9090 9069 8025; do echo -n "localhost:$p -> "; curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:$p/" --max-time 4; done
```

Result: Service **NodePort**; entrypoints `web`->30001, `loki`->30000, `prometheus`->30002,
`argocd`->30003, `mailpit`->30004, `mailpit-smtp`->30005 (websecure got an auto 31906 — harmless).
Traefik pod on **nimbus-agent-1** (the server taint pushed it to the one untainted node — exactly
where the socat ALB points). All five curls returned **404** = Traefik answering through the full
chain `localhost:<port>` → socat → agent NodePort → kube-proxy → Traefik pod. (404 = no IngressRoute
matches yet; backends come in Phases 6–9.)

---

## Phase 6 — ArgoCD (GitOps)

### 6.1 — install ArgoCD + expose via the Traefik `argocd` entrypoint

RKE2 ships nothing for ArgoCD, so we install upstream, **pinned to v2.12.3**. That pinned
`install.yaml` is the stock upstream manifest; we apply it from the pinned URL rather than vendoring
the 1.2 MB blob, then layer three small customizations (`k8s/argocd/install/`):

```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
cd /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.12.3/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=360s

kubectl apply -f k8s/argocd/install/argocd-cmd-params-cm.yaml
kubectl apply -f k8s/argocd/install/argocd-server-service.yaml
kubectl apply -f k8s/argocd/install/06_argocd-ingress.yaml
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

Verify + log in through the ALB:

```bash
kubectl -n argocd get svc argocd-server -o jsonpath='{range .spec.ports[*]}{.name}{" "}{.port}{" -> "}{.targetPort}{"\n"}{end}'
curl -s -o /dev/null -w "argocd via ALB: %{http_code}\n" http://localhost:9069/ --max-time 5

PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d); echo "$PW"
argocd login localhost:9069 --username admin --password "$PW" --plaintext --grpc-web
argocd account get-user-info
```

Result: UI returns 200 over plain HTTP through socat→Traefik `argocd`→argocd-server; CLI login works.
Gotchas: use **`--plaintext --grpc-web`** (plain HTTP + gRPC-over-HTTP/1.1 through Traefik). The v3.5
CLI still prints a one-time TLS cert warning (`valid for *.traefik.default, not localhost`) before
falling through to plaintext — **cosmetic**, answer `y`; the path is plain HTTP end to end. (CLI v3.5
vs server v2.12 skew is fine for login/cluster-add.)

### 6.2 — app-of-apps (DEFERRED to Phase 7/9)

ArgoCD syncs from a **Git repo**; the project is now a git repo pushed to
`git@github.com:jefta-jose/rke2-aws-tf-cluster.git` (branch `main`). The app-of-apps + Applications
are created when we have workloads to put in them (monitoring in Phase 7, apps in Phase 9), targeting
the **external `nimbus` cluster** (see 6.3) so the fragile credential is actually exercised.

### 6.3 — register the cluster the FRAGILE way (the Phase 11 time bomb)

The control-plane "NLB": the WSL host already runs its OWN kube-apiserver on `:6443` (a local
Docker/Rancher Desktop k8s), so our stable API endpoint uses host port **6444** → server-1:6443,
added to `scripts/socat-bridge.sh`. Endpoint `https://192.168.122.1:6444` is reachable from host AND
in-cluster pods (gateway IP), and TLS-valid (`192.168.122.1` is in `tls-san`).

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/socat-bridge.sh

export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)
curl -s -o /dev/null -w "%{http_code}\n" --cacert <(printf '%s' "$CA") https://192.168.122.1:6444/livez --max-time 5

cp /tmp/nimbus-kubeconfig.yaml /tmp/nimbus-nlb-kubeconfig.yaml
sed -i 's#https://192.168.122.11:6443#https://192.168.122.1:6444#' /tmp/nimbus-nlb-kubeconfig.yaml
KUBECONFIG=/tmp/nimbus-nlb-kubeconfig.yaml argocd cluster add "$(KUBECONFIG=/tmp/nimbus-nlb-kubeconfig.yaml kubectl config current-context)" --name nimbus --yes
```

`argocd cluster add` creates in `kube-system`: SA `argocd-manager`, ClusterRole/Binding
`argocd-manager-role[-binding]`, and secret **`argocd-manager-long-lived-token`** (a non-expiring SA
token — this is the Phase 11.5 FIX, kept ready). It stores the cluster with that bearer token.

**Then convert the credential to the admin client cert** — the deliberate 1-year time bomb. A real
production cluster secret uses `tlsClientConfig.certData` (admin leaf), which is what expires in the incident.

```bash
SEC=$(kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster -o jsonpath='{.items[0].metadata.name}')
CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
CERT=$(kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}')
KEY=$(kubectl config view --raw -o jsonpath='{.users[0].user.client-key-data}')
PATCH=$(CA="$CA" CERT="$CERT" KEY="$KEY" python3 -c '
import os, json
config = json.dumps({"tlsClientConfig": {"caData": os.environ["CA"], "certData": os.environ["CERT"], "keyData": os.environ["KEY"]}})
print(json.dumps({"stringData": {"config": config}}))')
kubectl -n argocd patch secret "$SEC" --type merge -p "$PATCH"
kubectl -n argocd rollout restart statefulset argocd-application-controller

kubectl -n argocd get secret "$SEC" -o jsonpath='{.data.config}' | base64 -d | python3 -m json.tool
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -noout -subject -enddate
```

Result: cluster secret `config` now has `tlsClientConfig.{caData,certData,keyData}`, no `bearerToken`.
**Admin cert `O=system:masters, CN=system:admin`, `notAfter = Oct 7 2027`** = the fuse (Phase 11's
+400-day jump blows past it). `argocd cluster list` shows both `nimbus` (6444) and `in-cluster` as
`Unknown` = "no applications / not monitored" — **normal**, not an error; ArgoCD only health-checks a
cluster once an Application targets it. The credential is valid *now*; it dies in Phase 11, and 11.5
reverts `config` to the `argocd-manager-long-lived-token` (which never expires).

**Carry-forward:** Phase 9 Applications must set `destination.server: https://192.168.122.1:6444`
(the `nimbus` external cluster), NOT `in-cluster`, or the time bomb never bites.

---

## Phase 7 — observability in-cluster (GitOps via ArgoCD app-of-apps)

Route chosen: **GitOps**. ArgoCD (public repo, no creds) owns monitoring via an app-of-apps. The agent
had ~2.2 GB free, so Prometheus/Loki are tuned tiny.

### 7.0 — app-of-apps root (the deferred 6.2)

`k8s/argocd/applications/root.yaml` = Application `nimbus-root`: watches `.../children/` in git
(recurse), destination in-cluster/argocd (where Application CRs must live), automated+prune+selfHeal.
Bootstrap ONCE by hand; self-managing after (commit a child manifest -> ArgoCD creates the app).

```bash
git add k8s/ && git commit -m "..." && git push
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
kubectl apply -f k8s/argocd/applications/root.yaml
argocd app get nimbus-root
```

(The `metadata.finalizers: resources-finalizer.argocd.argoproj.io` warning is cosmetic — it's
ArgoCD's standard cascade-delete finalizer; newer k8s just wants a `/path` suffix.)

### 7.1 — Prometheus child app (tiny)

`k8s/argocd/applications/children/prometheus.yaml` = Application: chart
`prometheus-community/prometheus` **29.36.0** (Prometheus v3.15.0), destination the **nimbus** external
cluster (6444), ns `monitoring`. Values: alertmanager + pushgateway off; server emptyDir + 6h retention
(RKE2 has no default StorageClass); node-exporter `tolerations: [{operator: Exists}]` so it runs on the
tainted servers too; host-less Ingress on the Traefik `prometheus` entrypoint via `extraManifests`.

Workflow: edit child manifest -> `git push` -> `argocd app get prometheus --refresh`.

Result: `monitoring` has `prometheus-server` (2/2: server + config-reload), `kube-state-metrics`,
and `node-exporter` on **all 4 nodes**. Reachable through the ALB (`curl localhost:9090/-/healthy` ->
`Prometheus Server is Healthy.`), **20/20 active targets up**
(`curl -s localhost:9090/api/v1/targets?state=active`).

Gotchas:
- **`extraManifests` items must be STRINGS**, not YAML maps — the chart renders each via `tpl`. A map
  gives `wrong type for value; expected string; got map`. Use a `|` block scalar.
- **kube-state-metrics `Failed to contact API server for /livez: got 0`** warnings + a few early
  restarts (exit 2) are a benign, over-sensitive self-check (short-timeout API ping via kube-proxy to a
  loaded server); it stops restarting once things settle, and Prometheus (same node) scrapes the API
  fine (20/20 up). Only relax its probe if restarts recur under load.
- A brief startup blip (Prometheus' first scrape pass) momentarily disrupted argocd/9069 + prometheus/
  9090 through the ALB; it self-recovered. Watch for it when adding more load.

---

## SCOPE CHANGE — retopology to 3 VMs: 1 server + 2 workers (2026-10-11)

The interim "1 server + 1 agent" plan is superseded. We now build **1 control-plane/etcd server +
2 worker (agent) nodes = 3 VMs**. The second worker exists for one reason: to make **pod anti-affinity**
real — you need ≥2 worker nodes to watch replicas land on distinct hosts (the Phase 9 learning goal
below). etcd is still a **single member** (quorum 1, no HA / elections / split-brain); the cert-expiry
incident still applies.

**Everything above (Phases 0–7) is the historical 4-VM build — kept as the recipe we reuse.** This
section is the authoritative **current build** (the commands to run; no results logged until a step
actually runs). Sizing is deliberately kept under the RAM ceiling that once hung the host:

| VM | role | vCPU | RAM | disk |
|---|---|---|---|---|
| `nimbus-server-1` | control-plane + etcd (cluster-init), tainted | 3 | 3072 MB | 20 GB |
| `nimbus-agent-1` | worker | 4 | 3584 MB | 30 GB |
| `nimbus-agent-2` | worker | 4 | 3584 MB | 30 GB |

Totals **11 vCPU / 10 GB RAM** on the measured 16 GB / 20 vCPU WSL2 host → ~6 GB headroom (~62% RAM,
vs the ~79% that hung the host at the old 4-VM sizing). vCPU overcommits safely; RAM is the only hard
limit, so this stays well clear of a hang. The stack now spreads across the two workers instead of
piling onto one.

### Build order (one VM at a time — build + join + verify before the next)

Reserve the fixed IPs first (now including agent-2):

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/net-reservations.sh
```

**server-1** (control-plane + etcd, cluster-init). Build, then install in one ssh session (Phase 2.2 recipe):

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/make-vm.sh nimbus-server-1 192.168.122.11 52:54:00:a1:b1:11 3 3072 20

scp /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/write-rke2-server-config.sh ubuntu@192.168.122.11:/tmp/
ssh ubuntu@192.168.122.11
```

On the VM:

```bash
sudo bash /tmp/write-rke2-server-config.sh nimbus-server-1 192.168.122.11
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=v1.36.5+rke2r1 sh -
sudo systemctl enable --now rke2-server.service
sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
mkdir -p ~/.kube && sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config \
  && sudo chown ubuntu:ubuntu ~/.kube/config && chmod 600 ~/.kube/config
kubectl get nodes -o wide
```

Expect 1 node `control-plane,etcd` Ready before moving on.

**agent-1** (worker). Build, then join with `INSTALL_RKE2_TYPE=agent` (Phase 3.1 recipe):

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/make-vm.sh nimbus-agent-1 192.168.122.21 52:54:00:a1:b1:21 4 3584 30

scp /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/write-rke2-agent-config.sh ubuntu@192.168.122.21:/tmp/
ssh ubuntu@192.168.122.21
sudo bash /tmp/write-rke2-agent-config.sh nimbus-agent-1 192.168.122.21 192.168.122.11
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE=agent INSTALL_RKE2_VERSION=v1.36.5+rke2r1 sh -
sudo systemctl enable --now rke2-agent.service
```

Expect 2 nodes Ready (1 `control-plane,etcd` + 1 worker).

**agent-2** (second worker) — the identical join recipe with agent-2's name / IP / MAC:

```bash
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/vms/make-vm.sh nimbus-agent-2 192.168.122.22 52:54:00:a1:b1:22 4 3584 30

scp /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/write-rke2-agent-config.sh ubuntu@192.168.122.22:/tmp/
ssh ubuntu@192.168.122.22
sudo bash /tmp/write-rke2-agent-config.sh nimbus-agent-2 192.168.122.22 192.168.122.11
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE=agent INSTALL_RKE2_VERSION=v1.36.5+rke2r1 sh -
sudo systemctl enable --now rke2-agent.service
```

Expect **3 nodes Ready** — 1 `control-plane,etcd` + 2 workers.

**Host (WSL) kubectl** — session-only, pointed at server-1:

```bash
scp ubuntu@192.168.122.11:.kube/config /tmp/nimbus-kubeconfig.yaml
sed -i 's#https://127.0.0.1:6443#https://192.168.122.11:6443#' /tmp/nimbus-kubeconfig.yaml
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
kubectl get nodes -o wide
```

### Taint the server LAST (ordering matters)

Only after **both** workers are Ready, taint `nimbus-server-1` so no workloads land on the
control-plane/etcd node:

```bash
export KUBECONFIG=/tmp/nimbus-kubeconfig.yaml
zsh /home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/scripts/taint-servers.sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

The order is the whole point: `CriticalAddonsOnly=true:NoExecute` applied at bootstrap (while a node is
still bringing up its CNI) blocks the one-shot `helm-install-*` jobs — they don't tolerate the taint —
so canal never installs and the node is `NotReady`. Applied here, at steady state with both workers
already catching workloads, canal (DaemonSet, blanket tolerations) and kube-proxy (static pod) are not
evicted, networking stays intact, and the taint lives in the node object in etcd (survives reboots).

### Ingress still points at agent-1 — fine with two workers

`scripts/socat-bridge.sh` keeps forwarding host ports to `nimbus-agent-1` (192.168.122.21). NodePorts
are published on **every** node by kube-proxy, so `localhost:<port>` → socat → `agent-1:<nodePort>`
reaches the Traefik pod even when the scheduler places Traefik on agent-2. No socat change is needed
for the second worker.

### GitOps stack re-syncs unchanged

Once the cluster + ArgoCD + the app-of-apps `root` are back (Phases 5–7 above, unchanged), the Traefik
HelmChartConfig override, the ArgoCD fragile cluster cert (6.3), and the Prometheus/Loki children
re-sync themselves from git — the `k8s/` manifests already live in the repo. `registry:2` is left
running across nukes (its pushed images persist).

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
