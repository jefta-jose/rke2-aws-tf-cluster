# Nimbus — RKE2 learning lab (modeled on ROK): 3-server etcd HA + observability + the cert-expiry incident

> **Naming:** our lab is **Nimbus**; everything we create is prefixed `nimbus-*`. "ROK" / "rok-scaleout"
> references throughout are pointers to the *real* platform we study at
> `/home/jeffndegwa/TheRokInfrastructure` — read-only study sources, not names we reuse.

## Context & goal
The v1 lab proved the hard part: **real RKE2 in libvirt/QEMU VMs on WSL2 works**, and the agent-join
that crashed in Docker is clean when each node owns its kernel. We keep that foundation (libvirt +
QEMU + a socat bridge) and rebuild around three new learning goals:

1. **Real etcd HA** — 3 RKE2 server nodes so there is an actual quorum, a leader, and elections to
   watch (v1 had one server, so etcd was invisible — see the git history discussion).
2. **The ROK ingress shape, faithfully** — `socat` plays the part of the AWS **ALB**, and **Traefik**
   is configured with the same **named-entrypoint-per-service** pattern as the real
   `rok-scaleout/manifests/values/traefik_values.yml`. The ALB→Traefik contract from
   `rok-scaleout/lower-env/alb.tf` becomes socat(host "pretty" port) → Traefik NodePort.
3. **Observability like ROK** — **Prometheus + Loki in-cluster**, and **Grafana running OUTSIDE the
   cluster on the WSL2 host**, reading metrics/logs *through the socat "ALB"* — exactly how ROK's
   `chief` cluster Grafana reads lower-env over the ALB (that is why `alb.tf` opens 9090/3100 only to
   the chief Grafana CIDRs).

Then, once it all works, we **simulate the 1-year certificate-expiry incident** (30 Sep–1 Oct 2026)
and fix it with the real runbook — including the **etcd split-brain** a single-server lab can never show.

**Scope decisions for this rebuild (locked):**
- **No Floci / Terraform / AWS half, no External Secrets Operator.** We keep only a host-local
  `registry:2` as the image source, and use plain Kubernetes `Secret`s. (v1's Floci/Terraform/ESO
  work stays in git history if we ever want it back.)
- **Workloads: a frontend + 3 small "metrics-first" services**, each exposing Prometheus `/metrics`,
  so Grafana has real dashboards to show.
- Same working style and folder-structure *style* as v1 — **not** ROK's folder layout.

## How we work (unchanged from v1)
- **You run every command; I never do.** For each step I explain *what* and *why*, hand you the exact
  command(s), you run them and paste output, I interpret, we move on. One numbered step at a time.
- **`commands.md` grows as we go and logs only what WORKED** — real command + one-line note + real
  result. Failed attempts aren't logged (except a short gotcha note worth keeping).
- Everything lives in `/home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/`.
  (The directory name is now a slight misnomer — no AWS/TF — rename later if you like; keeping it
  preserves git history.)

## Resource budget — WSL2 is `memory=12GB, swap=4GB, processors=10, nestedVirtualization=true`
RAM is the hard limit; vCPU overcommits fine. The plan: **lean, dedicated etcd/control-plane servers;
one bigger agent that carries every workload.**

| VM | Role | vCPU | RAM | Notes |
|---|---|---|---|---|
| `nimbus-server-1` | etcd + control-plane (cluster-init) | 2 | 2 GB | tainted `CriticalAddonsOnly=true:NoExecute` |
| `nimbus-server-2` | etcd + control-plane (join) | 2 | 2 GB | tainted |
| `nimbus-server-3` | etcd + control-plane (join) | 2 | 2 GB | tainted |
| `nimbus-agent-1` | workloads | 2 | 3.5 GB | Traefik, ArgoCD, Prometheus, Loki, mailpit, apps |
| **VMs total** | | **8** | **9.5 GB** | |
| Host headroom | WSL2 + registry:2 + host Grafana + socat | 2 | ~2.5 GB | |

**Why taint the servers** (ROK does *not* taint its big EC2 control-planes): at 2 GB a server can't
safely host Prometheus next to etcd without risking an OOM that would wreck the very etcd lesson we're
here for. Tainting keeps all workloads on the agent and the control plane healthy. We note this as a
deliberate lab adaptation. Prometheus still *scrapes* the servers over the network — pods don't need
to run there.

> If 2 GB servers prove too tight once everything's up, the fallback is **1 server + ROK-style
> no-taint** (loses the etcd-HA lesson) or dropping Loki. We'll measure before deciding.

## The mental model
```
WSL2 host (12 GB / 10 vCPU / 4 GB swap)
┌──────────────────────────────────────────────────────────────────────┐
│  OUTSIDE the cluster (host-side)                                       │
│    registry:2 :5000              Grafana :3000                         │
│       ▲ image pulls                 │ reads Prometheus + Loki          │
│       │                             ▼                                  │
│    socat = "the ALB"   host:9090→30002 (Prometheus)                    │
│                        host:3100→30000 (Loki)                          │
│                        host:9069→30003 (ArgoCD)                        │
│                        host:8080→30001 (web / apps)                    │
│                        host:8025→30004 (mailpit UI)                    │
└──────┬───────────────────────────────────────────────┬───────────────┘
       │ libvirt default net (host = 192.168.122.1)     │ forwards to agent NodePorts
  ┌──────┴──────┐ ┌─────────────┐ ┌─────────────┐  ┌──────┴──────────────┐
  │nimbus-server│ │nimbus-server│ │nimbus-server│  │    nimbus-agent-1    │
  │     -1      │◀▶│    -2      │◀▶│    -3      │  │  Traefik (entrypts), │
  │  etcd+cp    │ │  etcd+cp    │ │  etcd+cp    │  │  ArgoCD, Prometheus, │
  │  2 GB       │ │  2 GB       │ │  2 GB       │  │  Loki, mailpit, apps │
  │  tainted    │ │  tainted    │ │  tainted    │  │  3.5 GB              │
  └─────────────┘ └─────────────┘ └─────────────┘  └─────────────────────┘
        etcd quorum = 2 of 3           VMs pull images from 192.168.122.1:5000
```

## The ALB → Traefik mapping (our socat ⇄ rok's `alb.tf` + `traefik_values.yml`)
ROK's ALB listens on a "pretty" port and forwards to a **Traefik NodePort entrypoint**; Traefik
declares one named entrypoint per service. We copy that shape exactly, with socat as the ALB.

| Service | ROK ALB listener | Traefik entrypoint | NodePort | Our socat (host → agent) |
|---|---|---|---|---|
| apps / web | 443 | `web` | 30001 | `localhost:8080` → `:30001` |
| Loki | 3100 | `loki` | 30000 | `localhost:3100` → `:30000` |
| Prometheus | 9090 | `prometheus` | 30002 | `localhost:9090` → `:30002` |
| ArgoCD | 9069 | `argocd` | 30003 | `localhost:9069` → `:30003` |
| mailpit UI | 8025 | `mailpit` | 30004 | `localhost:8025` → `:30004` |
| mailpit SMTP | 1025 | `mailpit-smtp` | 30005 | `localhost:1025` → `:30005` (optional) |

(We use host `8080` for web instead of 80/443 so socat needn't bind a privileged port; the rest keep
ROK's own numbers. `nodePort` values are the same ones in `traefik_values.yml`.)

## Target folder structure (our style, extended)
```
PLAN.md  NUKE.md  commands.md  virsh.md  .gitignore
registry/
  docker-compose.yml                     # registry:2 (host, :5000) — our ECR stand-in
host-grafana/
  docker-compose.yml                     # Grafana on the host (:3000)
  provisioning/datasources/*.yml         # Prometheus=localhost:9090, Loki=localhost:3100 (via socat)
  provisioning/dashboards/*.json
scripts/
  socat-bridge.sh                        # multi-port "ALB" (table above)
  write-rke2-server-config.sh            # server-1 = cluster-init; server-2/3 = join; taint
  write-rke2-agent-config.sh
vms/
  registries.yaml                        # nodes pull from 192.168.122.1:5000
  nimbus-server-1/  nimbus-server-2/  nimbus-server-3/  nimbus-agent-1/   # each: build.sh, meta-data, user-data
k8s/
  traefik/        helmchart.yaml + traefik-values.yaml (mirror of traefik_values.yml) + entrypoints
  argocd/         install/ (helmchart, ingressroute) + applications/ (app-of-apps)
  monitoring/     prometheus-values.yaml, loki-values.yaml, ingressroutes (prometheus/loki entrypoints)
  mailpit/        values.yaml + ingressroute
charts/
  nimbus-app/     frontend + service-a/b/c (Deployments, Services, IngressRoutes, scrape config)
apps/
  frontend/  service-a/  service-b/  service-c/   # each with Dockerfile; services expose /metrics
```

---

## Phases

### Phase 0 — Tear down v1 & confirm the host budget
- 0.1 Tear down the v1 lab with the existing **`NUKE.md`** (VMs, Floci, socat, kubeconfig). **KEEP** the
  Ubuntu base image `/var/lib/libvirt/images/noble-server-cloudimg-amd64.img`.
- 0.2 Confirm `~/.wslconfig` is `memory=12GB / swap=4GB / processors=10 / nestedVirtualization=true`
  and that it's applied (`nproc`, `free -h` inside WSL). Confirm `/dev/kvm`, `virsh`, `qemu-img`,
  `genisoimage`, `kubectl`, `helm`, `docker` present.
- 0.3 Reorganize the repo to the structure above (git-rm `terraform/`, `k8s/external-secrets/`;
  rename `nimbus-*`/`rok-*`→`nimbus-*`). We'll do this as we build each phase, not all at once.
- 0.4 Rewrite `NUKE.md` for the new topology (3 servers + 1 agent, registry + host-Grafana composes,
  no Floci) — done at the end once names/ports are final.
→ Learn: clean slate; the exact resource envelope we're fitting into.

### Phase 1 — Host-local registry (our ECR stand-in)
- 1.1 `registry/docker-compose.yml`: `registry:2` on `:5000`, persistent volume.
- 1.2 `docker compose up -d`; verify a test push/pull to `localhost:5000`.
→ Learn: the registry the nodes + ArgoCD pull from, reachable at `192.168.122.1:5000` from VMs.

### Phase 2 — Three RKE2 server VMs (real etcd quorum)
- 2.1 `vms/nimbus-server-1/build.sh` (clone of v1's, 2 vCPU / 2 GB). Boot it.
- 2.2 Install RKE2 server on `nimbus-server-1` with **`cluster-init: true`**, shared `token`, `tls-san`
  (all three server IPs + `nimbus-server` + host), `node-taint: CriticalAddonsOnly=true:NoExecute`.
- 2.3 Boot `nimbus-server-2` and `nimbus-server-3`; install RKE2 server with `server:
  https://<server-1-ip>:9345`, same token, same taint, unique `node-ip`/`node-name`.
- 2.4 Pull kubeconfig to the host (point it at a server IP); `kubectl get nodes` → **3 `control-plane,etcd`
  Ready**.
- 2.5 **Inspect etcd** (this is the lesson v1 skipped): `rke2 etcd-snapshot save`, then via `crictl` +
  `etcdctl` — `member list -w table`, `endpoint status --cluster -w table` (see IS LEADER / RAFT INDEX),
  `endpoint health --cluster`.
→ Learn: embedded etcd, `cluster-init` vs join, the 9345 registration port, quorum = 2 of 3, who's leader.

### Phase 3 — RKE2 agent VM (the workload node) + registry trust
- 3.1 `vms/nimbus-agent-1/build.sh` (2 vCPU / 3.5 GB). Boot and join as agent
  (`server: https://<server-1-ip>:9345`, token, unique node-ip/name). `kubectl get nodes` → **4 nodes**
  (3 cp + 1 worker Ready).
- 3.2 `vms/registries.yaml` on every node → mirror/endpoint `http://192.168.122.1:5000` (insecure OK on
  the lab net). Confirm a node can pull a test image.
→ Learn: agent join at scale, scheduling onto the one untainted node, pulling from the host registry.

### Phase 4 — Networking: socat = the ALB
- 4.1 Rewrite `scripts/socat-bridge.sh` into the **multi-port "ALB"** from the mapping table (one
  `socat` forward per entrypoint, all pointed at the agent IP's NodePorts). `nohup`, idempotent restart.
- 4.2 `/etc/hosts` only if a host-based route needs it (most ingress is path-based / host-less).
→ Learn: the ALB listener→target contract, now as host-port→NodePort forwards.

### Phase 5 — Traefik (the ALB-shaped ingress)
- 5.1 `k8s/traefik/`: install Traefik via Helm with `traefik-values.yaml` **mirroring**
  `rok-scaleout/manifests/values/traefik_values.yml` — named entrypoints `web`(30001), `loki`(30000),
  `prometheus`(30002), `argocd`(30003), `mailpit`(30004)/`mailpit-smtp`(30005); `metrics.prometheus`
  enabled; access logs; dashboard. Service type NodePort.
- 5.2 Confirm each entrypoint's NodePort is listening and the socat forwards reach Traefik.
→ Learn: multi-entrypoint Traefik, NodePort-per-service, the exact ROK ingress config.

### Phase 6 — ArgoCD (GitOps)
- 6.1 `k8s/argocd/install/`: install ArgoCD; expose the UI/API through the Traefik `argocd` entrypoint
  (IngressRoute → 30003 → socat `localhost:9069`). Log in via CLI; extract the admin password.
- 6.2 `k8s/argocd/applications/`: an **app-of-apps** that will own the monitoring stack, mailpit, and
  `nimbus-app`.
- 6.3 **Cluster credential — the fragile 1-year path first (on purpose).** Instead of letting ArgoCD
  use its automatic in-cluster credential, register the target cluster as an *external* cluster the way
  ROK does — through a stable API endpoint, using the **admin client cert (`certData`) copied from the
  kubeconfig**. That cert is a 1-year leaf, so this is the setup that breaks in Phase 11. To make the
  endpoint ROK-shaped, add a socat forward for the API (`localhost:6443 → <server-ip>:6443`) mimicking
  ROK's dedicated control-plane NLB, and `argocd cluster add` against that. Confirm the cluster secret's
  `config` holds `tlsClientConfig.certData` (not a `bearerToken`), and note its expiry date — we'll
  watch it die, then fix it properly in Phase 11.
→ Learn: the ROK GitOps entrypoint and app-of-apps layout, and *why* an ArgoCD cluster credential built
  from the admin cert is a time bomb — the exact thing we fix in Phase 11 by moving to a ServiceAccount.

### Phase 7 — Observability in-cluster: Prometheus + Loki
- 7.1 `k8s/monitoring/prometheus-values.yaml`: Prometheus (kube-prometheus-stack or prometheus-community,
  **tuned tiny**: short retention, low memory limits). Scrape kube/node/Traefik + our apps.
- 7.2 `k8s/monitoring/loki-values.yaml`: Loki single-binary (filesystem, tiny) + a log collector
  (Alloy/Promtail) DaemonSet.
- 7.3 Expose Prometheus via the Traefik `prometheus` entrypoint (30002) and Loki via `loki` (30000)
  with IngressRoutes — these *are* ROK's ALB `9090`/`3100` listeners.
→ Learn: in-cluster metrics + logs, surfaced through the ALB shape exactly like ROK.

### Phase 8 — Grafana OUTSIDE the cluster (on the WSL2 host)
- 8.1 `host-grafana/docker-compose.yml`: Grafana on `:3000`, provisioned datasources
  **Prometheus = `http://localhost:9090`** and **Loki = `http://localhost:3100`** — i.e. *through the
  socat ALB*, never touching the cluster directly.
- 8.2 Provision a few dashboards: cluster/node health, **etcd**, Traefik, and our app metrics.
→ Learn: the ROK `chief`→ALB→metrics pattern — Grafana reading a cluster it doesn't live in.

### Phase 9 — Apps: frontend + metrics-first trio, via ArgoCD + registry
- 9.1 Build `apps/frontend` + `apps/service-a|b|c` (each exposes `/metrics`: request counter + latency
  histogram). `docker build`, tag `localhost:5000/...`, push.
- 9.2 `charts/nimbus-app`: Deployments + Services + Traefik IngressRoutes on the `web` entrypoint +
  scrape annotations/ServiceMonitors so Prometheus picks them up. Frontend calls the 3 services.
- 9.3 ArgoCD `Application`s (under the app-of-apps) sync; pods pull from the host registry; hit the
  frontend through `localhost:8080` (web) → Traefik → services; watch metrics land in Prometheus and
  **light up the host Grafana**.
- 9.4 (Optional carry-over) mailpit in-cluster, exposed via the `mailpit` entrypoint.
→ Learn: the full GitOps → ingress → metrics → external-Grafana loop, end to end.

### Phase 10 — Read the data plane: Canal/Calico, Services, Endpoints, EndpointSlices
RKE2's default CNI is **Canal = Calico (NetworkPolicy) + Flannel (VXLAN pod network)**, installed
automatically — so Calico is already here, running as the `rke2-canal` DaemonSet. With the apps from
Phase 9 giving us multi-replica Services, this is the moment to *read* how traffic actually finds a pod.
Pure `kubectl get` — no changes.
- 10.1 **The CNI itself**: `kubectl -n kube-system get pods -o wide | grep -E 'canal|coredns'` (one
  `rke2-canal` pod per node + CoreDNS), `kubectl -n kube-system get ds rke2-canal`, and the kube-proxy
  pods. See that networking is per-node DaemonSets — these are the same canal pods whose CNI token
  expires in Phase 11.
- 10.2 **Service → Endpoints**: pick a service with 3 replicas; `kubectl get svc <s>`,
  `kubectl get endpoints <s>` — the Endpoints list holds exactly the ready pod IPs. Scale the Deployment
  up/down and re-run to watch the Endpoints set track pod readiness live.
- 10.3 **EndpointSlices** (the modern replacement for Endpoints): `kubectl get endpointslices`,
  then `kubectl get endpointslice -l kubernetes.io/service-name=<s> -o yaml` — the same addresses sliced
  up, each with `conditions.ready`, `nodeName`, and a `targetRef` back to its pod.
- 10.4 **How it's wired**: trace the chain — Service (stable ClusterIP) → EndpointSlice (pod IPs) →
  **kube-proxy** programs that into each node's iptables → Canal/Flannel VXLAN carries the packet to the
  pod's node. This is exactly the chain that silently freezes in Phase 11 when kube-proxy's cert expires.
→ Learn: Calico/Canal ships with RKE2; and the real path a request takes — Service, Endpoints,
  EndpointSlices, kube-proxy, CNI — all by reading it with `kubectl get`.

### Phase 11 — Day-2: simulate the certificate-expiry incident (the payoff)
Recreate the 30 Sep–1 Oct 2026 outage in the lab. With **3 servers** we can finally reproduce the
**etcd split-brain**, not just the single-node cert break.
- 11.1 **Baseline**: on every VM, inspect leaf cert expiry
  (`openssl x509 -enddate` over the `tls/`, `tls/etcd/`, `agent/*.crt` files — use `sudo sh -c` for the
  glob), decode the Calico CNI token `exp` in `/etc/cni/net.d/calico-kubeconfig`, note the kubeconfig
  cert date. Take a fresh etcd snapshot.
- 11.2 **Trigger expiry without waiting a year** — the one lab-safe method is a **clock jump**: stop
  RKE2 on *all* nodes, disable `systemd-timesyncd`, set the date **+400 days** on every VM, then start
  RKE2. (Jump with the cluster stopped so etcd/raft never runs across the discontinuity.)
- 11.3 **Observe the real symptoms** in our cluster: `kubectl` → "must be logged in"; nodes `NotReady`;
  the **silent kube-proxy** `Unauthorized` (node `Ready` but Service routing frozen — now you'll see the
  Endpoints/EndpointSlices from Phase 10 stop updating); canal `FailedKillPod ... Unauthorized`;
  **the expired etcd leader blocking renewed members**; ArgoCD `ComparisonError`.
- 11.4 **Fix with the runbook, scaled to the lab**: snapshot → rotate control-plane **one at a time,
  leader first, keep 2/3 quorum** (`systemctl stop rke2-server` → `rke2-killall.sh` →
  `rke2 certificate rotate` → `systemctl start rke2-server`) → **then** `systemctl restart rke2-agent`
  → delete stale canal pods → refresh the host kubeconfig.
- 11.5 **Fix ArgoCD the right way — switch cluster credential cert → ServiceAccount.** Rotating the
  node certs does *not* heal ArgoCD: its cluster secret still holds the now-expired admin `certData`
  (Phase 6.3), so apps stay `ComparisonError`. Replace that `certData` config with the **long-lived
  `kube-system/argocd-manager` ServiceAccount bearer token** (`argocd cluster add` already created the
  SA + ClusterRoleBinding), set `config` to `{bearerToken, tlsClientConfig:{caData}}`, restart the
  application-controller, and watch apps leave `Unknown`. (If apps are `automated`, pause auto-sync
  first, review the diff, then restore — same caution as the runbook.) That token doesn't expire, so
  this never recurs.
- 11.6 **Verify**: all certs ~1 year out, nodes Ready, etcd healthy with a leader, every kube-proxy
  `Unauthorized` count 0, Endpoints/EndpointSlices updating again, apps Synced, host Grafana still
  reading through the ALB, and the ArgoCD cluster secret now using `bearerToken` (no cert to expire).
→ Learn: the incident first-hand — *including* the etcd leader/quorum failure a 1-server lab can't show,
  and the cert→ServiceAccount switch that makes ArgoCD's cluster credential permanent.

---

## Verification checkpoints
- Phase 2: `kubectl get nodes` → 3 `control-plane,etcd` Ready; `etcdctl endpoint status` shows one leader.
- Phase 3: 4 nodes Ready; a pod schedules only onto `nimbus-agent-1`; a test image pulls from the host registry.
- Phase 5: each Traefik entrypoint NodePort is listening; socat forwards reach it.
- Phase 8: host Grafana shows live cluster + etcd metrics, pulled through `localhost:9090`/`:3100`.
- Phase 9: frontend reachable at `localhost:8080`, calls the 3 services, and their `/metrics` appear in
  Grafana.
- Phase 10: `kubectl get` shows the `rke2-canal` DaemonSet per node, and a Service's EndpointSlices
  listing exactly its ready pod IPs (and tracking a scale up/down).
- Phase 11: expiry reproduced (all documented symptoms seen), then fully recovered via the runbook.

## Cleanup
Rewritten in `NUKE.md` at the end: `virsh destroy/undefine` the 4 VMs (VMs first, libvirt `default`
network last); `docker compose down -v` for `registry/` and `host-grafana/`; `pkill -f socat`; remove
the host kubeconfig. **KEEP** the Ubuntu base image for fast rebuilds.
