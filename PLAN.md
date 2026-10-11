# Nimbus — RKE2 learning lab: single-server control plane + two worker nodes + observability + the cert-expiry incident

> **Naming:** our lab is **Nimbus**; everything we create is prefixed `nimbus-*`.

The lab is **1 server + 2 workers (3 VMs)**. The second worker exists to teach **pod anti-affinity** —
spreading replicas across distinct worker nodes needs ≥2 workers (Phase 9).

## Context & goal
Real RKE2 in libvirt/QEMU VMs on WSL2, where the agent-join that crashes under Docker is clean because
each node owns its kernel. On that foundation (libvirt + QEMU + a socat bridge) we build three learning
goals:

1. **Embedded etcd (single member).** The one server runs RKE2 with `cluster-init`, so etcd is a
   1-member cluster — quorum 1, no leader elections or split-brain. We still *inspect* it (member list,
   endpoint status/health). The cert-expiry incident (goal below) applies fully to the single node.
2. **An AWS-ALB-shaped ingress** — `socat` plays the part of the AWS **ALB**, and **Traefik** is
   configured with a **named-entrypoint-per-service** pattern. The ALB→Traefik contract is
   socat(host "pretty" port) → Traefik NodePort.
3. **Observability** — **Prometheus + Loki in-cluster**, and **Grafana running OUTSIDE the
   cluster on the WSL2 host**, reading metrics/logs *through the socat "ALB"* — the pattern where an
   external Grafana reads a cluster over the ALB (which is why the ALB only needs to expose 9090/3100
   to the Grafana host).

Then, once it all works, we **simulate the 1-year certificate-expiry incident** (30 Sep–1 Oct 2026)
and fix it with the real runbook.

**Scope decisions for this rebuild (locked):**
- **No Floci / Terraform / AWS half, no External Secrets Operator.** We keep only a host-local
  `registry:2` as the image source, and use plain Kubernetes `Secret`s. (v1's Floci/Terraform/ESO
  work stays in git history if we ever want it back.)
- **Workloads: a frontend + 3 small "metrics-first" services**, each exposing Prometheus `/metrics`,
  so Grafana has real dashboards to show.
- Same working style and folder-structure *style* as v1 — our own layout.

## How we work (unchanged from v1)
- **You run every command; I never do.** For each step I explain *what* and *why*, hand you the exact
  command(s), you run them and paste output, I interpret, we move on. One numbered step at a time.
- **`commands.md` grows as we go and logs only what WORKED** — real command + one-line note + real
  result. Failed attempts aren't logged (except a short gotcha note worth keeping).
- Everything lives in `/home/jeffndegwa/vibe-learning/rke2-aws-tf-cluster/`.
  (The directory name is now a slight misnomer — no AWS/TF — rename later if you like; keeping it
  preserves git history.)

## Resource budget — WSL2 measured at `memory=16GB, swap=4GB, processors=20, nestedVirtualization=true`
RAM is the hard limit; vCPU overcommits fine. The plan: **one lean control-plane server + two workers
that split the workload** — two workers so Phase 9 can demonstrate **pod anti-affinity** across distinct
nodes.

| VM | Role | vCPU | RAM | Notes |
|---|---|---|---|---|
| `nimbus-server-1` | etcd + control-plane (cluster-init) | 3 | 3 GB (3072 MB) | tainted `CriticalAddonsOnly=true:NoExecute` (late) |
| `nimbus-agent-1` | worker | 4 | 3.5 GB (3584 MB) | Traefik / ArgoCD / Prometheus / Loki / apps — split with agent-2 |
| `nimbus-agent-2` | worker | 4 | 3.5 GB (3584 MB) | second worker: enables pod anti-affinity (Phase 9) |
| **VMs total** | | **11** | **10 GB** | 3072 + 3584 + 3584 = 10240 MB |
| Host headroom | WSL2 + registry:2 + host Grafana + socat | — | ~6 GB | |

**Why this won't hang:** RAM is the hard limit, and 10 GB is **~62% of 16 GB** — comfortably within
budget with ~6 GB to spare. vCPU overcommits safely, so CPU stays generous (11 vCPU on 20). Splitting
the stack across two workers keeps each at ~3 GB of real need; **3584 MB** adds a cushion for ArgoCD
sync spikes while keeping total VM RAM at a safe 10 GB. (3 GB server: at 2 GB the four core static pods
request ~1920Mi and canal can't schedule → `NotReady`; see commands.md Phase 2. If pressure shows,
workers can drop to 3072 MB.)

**Why still taint the single server:** keep every
workload on the two workers so the control plane / etcd stays healthy and predictable. Prometheus still
*scrapes* the server over the network — pods don't need to run there. (Applied via kubectl **after both
workers (agent-1 AND agent-2) exist and are Ready**; tainting at bootstrap blocks the helm-install jobs
→ no CNI → NotReady.)

## The mental model
```
WSL2 host (16 GB / 20 vCPU / 4 GB swap)
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
│    socat = "the NLB"   host:6444→server:6443 (kube-apiserver, ArgoCD)  │
│    (NodePorts answer on EVERY node via kube-proxy, so socat → agent-1   │
│     reaches Traefik even if the scheduler puts the pod on agent-2)      │
└──────┬───────────────────────────────────────────────┬───────────────┘
       │ libvirt default net (host = 192.168.122.1)     │ forwards to a worker's NodePorts
  ┌──────┴──────────────┐        ┌──────────────────────┴──────────────────────┐
  │   nimbus-server-1    │        │              workers (split the stack)        │
  │   etcd + cp          │        │  ┌──────────────────┐  ┌──────────────────┐  │
  │   (cluster-init)     │◀──────▶│  │  nimbus-agent-1  │  │  nimbus-agent-2  │  │
  │   3 GB, tainted      │ default│  │  3.5 GB worker   │  │  3.5 GB worker   │  │
  │   etcd = 1 member    │  net   │  │  Traefik/ArgoCD/ │  │  Prometheus/Loki/│  │
  │                      │        │  │  apps (spread)   │  │  apps (spread)   │  │
  └─────────────────────┘        │  └──────────────────┘  └──────────────────┘  │
   (no HA — single member)       │   pod anti-affinity spreads replicas across    │
                                 │   both workers (Phase 9)                       │
                                 └───────────────────────────────────────────────┘
          VMs pull images from 192.168.122.1:5000
```

## The ALB → Traefik mapping (socat ⇄ Traefik entrypoints)
The ALB listens on a "pretty" port and forwards to a **Traefik NodePort entrypoint**; Traefik
declares one named entrypoint per service. socat plays the ALB.

| Service | ALB listener | Traefik entrypoint | NodePort | Our socat (host → agent) |
|---|---|---|---|---|
| apps / web | 443 | `web` | 30001 | `localhost:8080` → `:30001` |
| Loki | 3100 | `loki` | 30000 | `localhost:3100` → `:30000` |
| Prometheus | 9090 | `prometheus` | 30002 | `localhost:9090` → `:30002` |
| ArgoCD | 9069 | `argocd` | 30003 | `localhost:9069` → `:30003` |
| mailpit UI | 8025 | `mailpit` | 30004 | `localhost:8025` → `:30004` |
| mailpit SMTP | 1025 | `mailpit-smtp` | 30005 | `localhost:1025` → `:30005` (optional) |

(We use host `8080` for web instead of 80/443 so socat needn't bind a privileged port; the rest keep
the entrypoint's chosen numbers.)

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
  write-rke2-server-config.sh            # server-1 = cluster-init (single server, no join)
  write-rke2-agent-config.sh             # agent-1 + agent-2 join the server
  taint-servers.sh                       # taint nimbus-server-1 AFTER both workers are Ready
vms/
  registries.yaml                        # nodes pull from 192.168.122.1:5000
  nimbus-server-1/  nimbus-agent-1/  nimbus-agent-2/   # each: meta-data, user-data (made by make-vm.sh)
k8s/
  traefik/        helmchart.yaml + traefik-values.yaml + entrypoints
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
- 0.2 Confirm `~/.wslconfig` is `memory=16GB / swap=4GB / processors=20 / nestedVirtualization=true`
  and that it's applied (`nproc`, `free -h` inside WSL). Confirm `/dev/kvm`, `virsh`, `qemu-img`,
  `genisoimage`, `kubectl`, `helm`, `docker` present.
- 0.3 Reorganize the repo to the structure above (git-rm `terraform/`, `k8s/external-secrets/`;
  keep the `nimbus-*` prefix). We'll do this as we build each phase, not all at once.
- 0.4 `NUKE.md` written for the 1-server + 2-worker topology (registry + host-Grafana composes, no Floci).
→ Learn: clean slate; the exact resource envelope we're fitting into.

### Phase 1 — Host-local registry (our ECR stand-in)
- 1.1 `registry/docker-compose.yml`: `registry:2` on `:5000`, persistent volume.
- 1.2 `docker compose up -d`; verify a test push/pull to `localhost:5000`.
→ Learn: the registry the nodes + ArgoCD pull from, reachable at `192.168.122.1:5000` from VMs.

### Phase 2 — The RKE2 server VM (single control-plane + embedded etcd)
- 2.1 `vms/make-vm.sh nimbus-server-1 192.168.122.11 52:54:00:a1:b1:11 3 3072 20`. Boot it.
- 2.2 Install RKE2 server on `nimbus-server-1` with **`cluster-init: true`**, shared `token`, `tls-san`
  (server IP + `192.168.122.1` host + `nimbus-server`). **No join steps** — it's the only server.
- 2.4 Pull kubeconfig to the host (point it at the server IP); `kubectl get nodes` → **1 `control-plane,etcd`
  Ready** (the taint is applied in Phase 3, after **both workers** exist).
- 2.5 **Inspect etcd** (single member): `rke2 etcd-snapshot save`, then via `scripts/etcdctl.sh` —
  `member list -w table`, `endpoint status -w table`, `endpoint health`. One voting member, quorum 1.
→ Learn: embedded etcd, `cluster-init`, the 9345 registration port, the kubeconfig TLS-SAN rewrite.

### Phase 3 — RKE2 worker VMs (the workload nodes) + registry trust + taint
Build and join the two workers **one at a time** — fully verify each before starting the next:
- 3.1 `vms/make-vm.sh nimbus-agent-1 192.168.122.21 52:54:00:a1:b1:21 4 3584 30`. Boot and join as agent
  (`server: https://<server-1-ip>:9345`, token, unique node-ip/name). `kubectl get nodes` → **2 nodes**
  (1 cp + 1 worker Ready).
- 3.2 `vms/make-vm.sh nimbus-agent-2 192.168.122.22 52:54:00:a1:b1:22 4 3584 30`. Join the same way.
  `kubectl get nodes` → **3 nodes** (1 `control-plane,etcd` + 2 workers Ready).
- 3.3 `vms/registries.yaml` on every node → mirror/endpoint `http://192.168.122.1:5000` (insecure OK on
  the lab net). Confirm a node can pull a test image.
- 3.4 **Now taint the server** (`scripts/taint-servers.sh` → `CriticalAddonsOnly=true:NoExecute` on
  nimbus-server-1) — **only after both workers are Ready**, so the one-shot helm-install jobs have
  already run and evicted/rescheduled add-ons have the two workers to land on. Verify workloads sit only
  on agent-1/agent-2.
→ Learn: agent join, scheduling onto the untainted workers, pulling from the host registry, and the
  **taint-ordering rule** — taint *after* the workers exist and are Ready, never at bootstrap (a
  bootstrap taint blocks the helm-install jobs → no CNI → NotReady).

### Phase 4 — Networking: socat = the ALB
- 4.1 Rewrite `scripts/socat-bridge.sh` into the **multi-port "ALB"** from the mapping table (one
  `socat` forward per entrypoint, all pointed at the agent IP's NodePorts). `nohup`, idempotent restart.
- 4.2 `/etc/hosts` only if a host-based route needs it (most ingress is path-based / host-less).
→ Learn: the ALB listener→target contract, now as host-port→NodePort forwards.

### Phase 5 — Traefik (the ALB-shaped ingress)
- 5.1 `k8s/traefik/`: install Traefik via Helm with a `traefik-values.yaml` that declares named
  entrypoints `web`(30001), `loki`(30000),
  `prometheus`(30002), `argocd`(30003), `mailpit`(30004)/`mailpit-smtp`(30005); `metrics.prometheus`
  enabled; access logs; dashboard. Service type NodePort.
- 5.2 Confirm each entrypoint's NodePort is listening and the socat forwards reach Traefik.
→ Learn: multi-entrypoint Traefik, NodePort-per-service, the ALB-shaped ingress config.

### Phase 6 — ArgoCD (GitOps)
- 6.1 `k8s/argocd/install/`: install ArgoCD; expose the UI/API through the Traefik `argocd` entrypoint
  (IngressRoute → 30003 → socat `localhost:9069`). Log in via CLI; extract the admin password.
- 6.2 `k8s/argocd/applications/`: an **app-of-apps** that will own the monitoring stack, mailpit, and
  `nimbus-app`.
- 6.3 **Cluster credential — the fragile 1-year path first (on purpose).** Instead of letting ArgoCD
  use its automatic in-cluster credential, register the target cluster as an *external* cluster
  through a stable API endpoint, using the **admin client cert (`certData`) copied from the
  kubeconfig**. That cert is a 1-year leaf, so this is the setup that breaks in Phase 11. To give the
  endpoint a stable address, add a socat forward for the API (`localhost:6443 → <server-ip>:6443`)
  standing in for a dedicated control-plane **NLB**, and `argocd cluster add` against that. Confirm the
  cluster secret's `config` holds `tlsClientConfig.certData` (not a `bearerToken`), and note its expiry
  date — we'll watch it die, then fix it properly in Phase 11.
→ Learn: the GitOps entrypoint and app-of-apps layout, and *why* an ArgoCD cluster credential built
  from the admin cert is a time bomb — the exact thing we fix in Phase 11 by moving to a ServiceAccount.

### Phase 7 — Observability in-cluster: Prometheus + Loki
- 7.1 `k8s/monitoring/prometheus-values.yaml`: Prometheus (kube-prometheus-stack or prometheus-community,
  **tuned tiny**: short retention, low memory limits). Scrape kube/node/Traefik + our apps.
- 7.2 `k8s/monitoring/loki-values.yaml`: Loki single-binary (filesystem, tiny) + a log collector
  (Alloy/Promtail) DaemonSet.
- 7.3 Expose Prometheus via the Traefik `prometheus` entrypoint (30002) and Loki via `loki` (30000)
  with IngressRoutes — these *are* the ALB `9090`/`3100` listeners.
→ Learn: in-cluster metrics + logs, surfaced through the ALB shape.

### Phase 8 — Grafana OUTSIDE the cluster (on the WSL2 host)
- 8.1 `host-grafana/docker-compose.yml`: Grafana on `:3000`, provisioned datasources
  **Prometheus = `http://localhost:9090`** and **Loki = `http://localhost:3100`** — i.e. *through the
  socat ALB*, never touching the cluster directly.
- 8.2 Provision a few dashboards: cluster/node health, **etcd**, Traefik, and our app metrics.
→ Learn: the external-Grafana→ALB→metrics pattern — Grafana reading a cluster it doesn't live in.

### Phase 9 — Apps: frontend + metrics-first trio, via ArgoCD + registry — and scheduling control
- 9.1 Build `apps/frontend` + `apps/service-a|b|c` (each exposes `/metrics`: request counter + latency
  histogram). `docker build`, tag `localhost:5000/...`, push.
- 9.2 `charts/nimbus-app`: Deployments + Services + Traefik IngressRoutes on the `web` entrypoint +
  scrape annotations/ServiceMonitors so Prometheus picks them up. Frontend calls the 3 services.
- 9.3 ArgoCD `Application`s (under the app-of-apps) sync; pods pull from the host registry; hit the
  frontend through `localhost:8080` (web) → Traefik → services; watch metrics land in Prometheus and
  **light up the host Grafana**.
- 9.4 (Optional carry-over) mailpit in-cluster, exposed via the `mailpit` entrypoint.

Then use `service-a` as the exemplar for three scheduling-control lessons (this is the payoff of running
two workers):

- **9.5 Resource management (requests, limits, OOMKill).** Give `service-a`
  `requests: {cpu: 100m, memory: 128Mi}` and `limits: {memory: 256Mi}`.
  - `requests` are the **scheduling floor** + the pod's reservation — the scheduler only places the pod
    where that much is free, and `kubectl describe node` counts it under *Allocated*. A **cpu request
    does NOT cap CPU**; it's a weight/floor only.
  - `limits.memory` is a **hard cap**: exceed it and the container is **OOMKilled** and restarted.
  - We set **no cpu limit** on purpose (a cpu limit *throttles* rather than kills; for a bursty metrics
    app that hurts more than it helps). *(A production-scale service might use `cpu: 250m /
    memory: 1Gi` requests and a `6Gi` memory limit above a ~5.3 GiB report-gen peak — same idea,
    bigger numbers.)*
  - Verify: `kubectl describe node <worker>` (Allocated requests rise), `kubectl top pod`, then push the
    app past 256Mi and watch `kubectl get pod` flip to `OOMKilled` + a restart.

- **9.6 Pod anti-affinity (why two workers).** Scale `service-a` to `replicas: 2` and add preferred pod
  anti-affinity so the replicas avoid sharing a node:
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
  - `preferred` = best-effort: the scheduler **strongly prefers** a node with no matching pod but will
    still co-locate if it must. A `required…` rule is hard — with 3 replicas on 2 workers (or during a
    `maxSurge` rollout that briefly needs more pods than nodes) it leaves the extra pod **Pending**,
    stalling the rollout. Preferred keeps rollouts unblocked; it just doesn't *guarantee* separation.
  - **Namespaces matter** (the lesson in `note.txt`): a `topologySpreadConstraint` counts only pods
    in the **pod's own namespace** by default, so it can't separate two *environments* in different
    namespaces (`development` vs `staging`). Cross-namespace separation needs
    `podAntiAffinity` with an explicit `namespaces:` list or `namespaceSelector:`. Our lab is single-ns,
    so we demo same-ns anti-affinity across the two workers and only **note** the cross-ns variant.
  - Verify: `kubectl get pods -o wide` → the two `service-a` replicas on **two different workers**
    (agent-1 and agent-2). Scale to 3 → the 3rd **co-locates** (preferred allows it); under `required`
    it would sit `Pending`.

- **9.7 Pod affinity (co-location).** Add a tiny `cache` Deployment with preferred **pod affinity**
  toward `service-a` (same `topologyKey: kubernetes.io/hostname`, `labelSelector app: service-a`) so the
  cache lands on the **same** worker as a service-a replica (locality). (`nodeAffinity` is the cousin
  that pins to a *node* by label — the inverse of the server's repelling taint.)
  - Verify: `kubectl get pods -o wide` → `cache` shares a worker with a `service-a` replica.

- **9.8 The Helm wiring that makes 9.5–9.7 real.** `resources`/`affinity` in a values file do **nothing**
  unless the shared chart template renders them into the PodSpec. The `charts/nimbus-app` Deployment
  template must include, e.g.:
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
  So each change touches **both** the `charts/nimbus-app` values **and** the Deployment template.
  Validate the rendered output (`helm template …` or `kubectl get deploy service-a -o yaml`) **before**
  deploy, then let ArgoCD sync and confirm placement with `kubectl get pods -o wide`.

→ Learn: the full GitOps → ingress → metrics → external-Grafana loop, **plus** how requests/limits drive
  scheduling + OOM behavior and how pod (anti-)affinity controls placement across the two workers.

### Phase 10 — Read the data plane: Canal/Calico, Services, Endpoints, EndpointSlices
RKE2's default CNI is **Canal = Calico (NetworkPolicy) + Flannel (VXLAN pod network)**, installed
automatically — so Calico is already here, running as the `rke2-canal` DaemonSet. With the apps from
Phase 9 giving us multi-replica Services, this is the moment to *read* how traffic actually finds a pod.
Pure `kubectl get` — no changes.
- 10.1 **The CNI itself**: `kubectl -n kube-system get pods -o wide | grep -E 'canal|coredns'` (one
  `rke2-canal` pod per node — **3 now** — + CoreDNS), `kubectl -n kube-system get ds rke2-canal`, and the
  kube-proxy pods. See that networking is per-node DaemonSets — these are the same canal pods whose CNI
  token expires in Phase 11.
- 10.2 **Service → Endpoints**: pick a multi-replica service (e.g. `service-a` scaled to 2–3);
  `kubectl get svc <s>`,
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
Recreate the 30 Sep–1 Oct 2026 outage in the lab: the node cert break, the silent kube-proxy, and the
ArgoCD cluster-cred expiry.
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
  ArgoCD `ComparisonError`.
- 11.4 **Fix with the runbook, scaled to the lab**: snapshot → rotate the single control-plane
  (`systemctl stop rke2-server` → `rke2-killall.sh` → `rke2 certificate rotate` →
  `systemctl start rke2-server`) → **then** `systemctl restart rke2-agent` **on both workers** → delete
  stale canal pods → refresh the host kubeconfig. (With one server there's a brief full control-plane
  outage during the rotate — expected.)
- 11.5 **Fix ArgoCD the right way — switch cluster credential cert → ServiceAccount.** Rotating the
  node certs does *not* heal ArgoCD: its cluster secret still holds the now-expired admin `certData`
  (Phase 6.3), so apps stay `ComparisonError`. Replace that `certData` config with the **long-lived
  `kube-system/argocd-manager` ServiceAccount bearer token** (`argocd cluster add` already created the
  SA + ClusterRoleBinding), set `config` to `{bearerToken, tlsClientConfig:{caData}}`, restart the
  application-controller, and watch apps leave `Unknown`. (If apps are `automated`, pause auto-sync
  first, review the diff, then restore — same caution as the runbook.) That token doesn't expire, so
  this never recurs.
- 11.6 **Verify**: all certs ~1 year out, all three nodes Ready, etcd healthy, every kube-proxy
  `Unauthorized` count 0, Endpoints/EndpointSlices updating again, apps Synced, host Grafana still
  reading through the ALB, and the ArgoCD cluster secret now using `bearerToken` (no cert to expire).
→ Learn: the incident first-hand on a single node, and the cert→ServiceAccount switch that makes
  ArgoCD's cluster credential permanent.

---

## Verification checkpoints
- Phase 2: `kubectl get nodes` → 1 `control-plane,etcd` Ready; `etcdctl member list` shows 1 member.
- Phase 3: 3 nodes Ready (1 cp + 2 workers); pods schedule only onto the workers (`nimbus-agent-1`/`nimbus-agent-2`); a test image pulls from the host registry.
- Phase 5: each Traefik entrypoint NodePort is listening; socat forwards reach it.
- Phase 8: host Grafana shows live cluster + etcd metrics, pulled through `localhost:9090`/`:3100`.
- Phase 9: frontend reachable at `localhost:8080`, calls the 3 services, and their `/metrics` appear in
  Grafana; `service-a`'s 2 replicas land on **different workers** (anti-affinity); its resource requests
  show under `kubectl describe node`; breaching the memory limit yields `OOMKilled`; the `cache` pod
  co-locates with a `service-a` replica (affinity).
- Phase 10: `kubectl get` shows the `rke2-canal` DaemonSet per node, and a Service's EndpointSlices
  listing exactly its ready pod IPs (and tracking a scale up/down).
- Phase 11: expiry reproduced (all documented symptoms seen), then fully recovered via the runbook.

## Cleanup
See **`NUKE.md`**: stop socat + remove host kubeconfigs; `virsh destroy/undefine` the 3 VMs and their
disks; `docker compose down` for `registry/` (and `host-grafana/` once it exists). **KEEP** the Ubuntu
base image for fast rebuilds. (NUKE.md also has a "drop a worker" partial section for removing
`nimbus-agent-2` without a full teardown.)
