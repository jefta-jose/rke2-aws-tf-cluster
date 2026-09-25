# Recreate the ROK Infra as a Learning Lab (Floci + real RKE2 VMs)

## Context & goal
The real "TheRok" platform (studied in `/home/jeffndegwa/TheRokInfrastructure`) is a hub-and-spoke
**RKE2 + Rancher + ArgoCD** Kubernetes platform on AWS, with an ALB → Traefik(NodePort) ingress
path, RDS SQL Server, Secrets Manager → External Secrets Operator, SQS/SES email workers, ECR image
registry, WAF, and a frontend + .NET APIs deployed via GitOps.

We are building a **shrunk, local, learning version** of that world so we understand every moving
part hands-on — the same way the materialized-views lab worked. We do **not** match it 1:1; we
recreate the *shapes and mechanisms* small enough to read by eye.

**Two halves, wired on one Docker network + a VM network:**
- **The "AWS" half = Floci** (a local AWS emulator on `localhost:4566`) running in Docker on the WSL2
  host. Provides ECR, Secrets Manager, SQS, SES, ALB (ELBv2), RDS SQL Server, WAF, IAM — provisioned
  by **Terraform** (mirroring `rok-scaleout`'s Terraform).
- **The "compute" half = real RKE2 in lightweight VMs.** One RKE2 **server** VM + one RKE2 **agent**
  VM (optionally a second agent). Real systemd, real containerd, real agent-join on port **9345**.

## Why VMs (and why this fixes the old crash)
Previously RKE2 was run as Docker containers and *"server fine, agent joins → complete crash."*
Root cause (confirmed by research): RKE2 nodes each assume they **own their kernel**. Two nodes as
containers on one WSL2 host share **one** netfilter/iptables table, **one** conntrack table, **one**
cgroup tree. When the agent's second kube-proxy + second Canal/VXLAN instance reprogram that shared
kernel, they collide with the server's rules and take down host networking. RKE2-in-Docker is
unsupported, undocumented, and triples the fragility on WSL2 (nested containers + no-systemd + WSL2
kernel gaps).

**VMs give each node its own kernel** → separate netfilter/conntrack/cgroups → the agent join is
clean. WSL2 nested virtualization is available here (`/dev/kvm` present), so this is viable. Phase 0
confirms the toolchain before we commit.

## The mental model (how the halves connect)
```
        WSL2 host (Ubuntu)
        ┌─────────────────────────────────────────────────────────┐
        │  Docker network  "roklab"                                 │
        │   ┌───────────┐   ┌──────────┐                            │
        │   │  Floci    │   │ mailpit  │   (AWS APIs @ :4566)        │
        │   │  :4566    │   │ :8025 UI │                            │
        │   │  ECR/SM/  │   │ :1025    │                            │
        │   │  SQS/SES/ │   └──────────┘                            │
        │   │  ALB/RDS/ │                                           │
        │   │  WAF/IAM  │                                           │
        │   └─────┬─────┘                                           │
        │         │ ALB listener forwards to  VM_IP:NodePort         │
        └─────────┼─────────────────────────────────────────────────┘
                  │  (host ↔ VM routing, Phase 5)
        ┌─────────┼───────────────────────┐   ┌───────────────────┐
        │  VM: rok-server                 │   │  VM: rok-agent-1    │
        │  RKE2 server (etcd+control)     │◀──│  RKE2 agent        │
        │  Traefik (NodePort 30080)       │9345 join              │
        │  ArgoCD, External Secrets Op    │   │  workloads         │
        │  frontend + backend pods        │   │                   │
        └─────────────────────────────────┘   └───────────────────┘
   Pods reach AWS at http://<host-ip>:4566 (ECR pulls, ESO GetSecretValue).
```

## How we work (same as the materialized-views lab)
- **You run every command; I never do.** For each step I explain *what* and *why*, hand you the exact
  command(s), you run them and paste output, I interpret, we move on.
- **One numbered step at a time** (1.1, 1.2, …).
- **`commands.md` grows as we go and logs only what WORKED** — the real command + a one-line note +
  the real result. No pre-written dumps; failed attempts aren't logged (except a short gotcha note if
  it's a lesson worth keeping).
- Everything lives in `/home/jeffndegwa/rke2-aws-tf-cluster/`.

## Floci capability map (what's real vs what we substitute) — from research
| ROK piece | Floci support | Lab approach |
|---|---|---|
| ECR | **Real** `registry:2`, docker push/pull | Use as the real image registry |
| Secrets Manager | **Real** storage, GetSecretValue | External Secrets Operator syncs from it |
| SQS + DLQ | **Real** | Email-worker queue + DLQ |
| SES | Emulated + **SMTP relay to mailpit** | SES → mailpit, like ROK lower envs |
| ALB (ELBv2) | **Real** — forwards HTTP by path/host to targets | ALB → Traefik NodePort |
| RDS SQL Server | **Real** `mssql/server:2022` container | Backend DB (optional phase) |
| IAM / KMS / Lambda / SNS | Real enough | Use as needed |
| WAFv2 | **Mock** (config-only, no filtering) | IaC in Terraform; real filtering = Traefik middleware (optional) |
| Route53 | **Mock** (no DNS resolution) | Use `/etc/hosts` / Docker DNS |
| EKS | Real but single-node **k3s**, not RKE2 | Not used — we run real RKE2 in VMs |
| ECS | **Real** Fargate-style containers (no real ALB/CloudMap) | "service that interacts with ECS" phase |

---

## Phases

### Phase 0 — Prerequisites & VM toolchain go/no-go
Confirm the host can do everything before we build.
- 0.1 Verify Docker, Terraform, kubectl, helm, aws CLI versions (install what's missing).
- 0.2 Confirm virtualization: `/dev/kvm` present (done ✔), pick VM tool — **multipass** (simplest) or
  Lima/QEMU. Launch a throwaway VM and confirm it boots and has network.
- 0.3 Decide resource budget (server VM ~2 vCPU/4 GB, agent ~2 vCPU/2–4 GB, Floci + SQL Server ~2 GB).
→ Learn: what the lab needs and that the VM path is viable here.

### Phase 1 — Floci up (the local AWS)
- 1.1 Write `docker-compose.yml` for Floci: shared network `roklab`, docker socket mount,
  `FLOCI_HOSTNAME=floci`, persistent storage, published ports (4566, RDS proxy 7001–7099), SES→mailpit
  env, plus a `mailpit` service.
- 1.2 `docker compose up -d`; verify `aws --endpoint-url=http://localhost:4566 sts get-caller-identity`.
- 1.3 Open the Floci web console (`/_floci/ui`) and mailpit UI.
→ Learn: Floci = AWS on localhost; the wire protocol is real.

### Phase 2 — Terraform the AWS base (mirror rok-scaleout)
- 2.1 Terraform provider block pointed at Floci (dummy creds, skip flags, per-service endpoints).
- 2.2 Create: ECR repos (frontend, backend), Secrets Manager secret (`development-rok-general-secret`
  shape), SQS queue + DLQ, IAM role/policy, WAFv2 (IaC only), ALB + target group + listener rules
  (target left empty until the cluster exists).
- 2.3 `terraform apply`; inspect resources in the Floci console.
→ Learn: the exact Terraform ROK uses, applied locally against Floci.

### Phase 3 — Real RKE2 server VM
- 3.1 Launch `rok-server` VM.
- 3.2 Install RKE2 server (`curl -sfL https://get.rke2.io | sh -`), write `config.yaml`
  (`node-ip`, `tls-san`, `write-kubeconfig-mode`, token), enable + start `rke2-server`.
- 3.3 Pull kubeconfig to the host, `kubectl get nodes` → 1 node Ready.
→ Learn: real RKE2 server bootstrap, etcd, the node token, tls-san.

### Phase 4 — Real RKE2 agent join (the crash lesson, done right)
- 4.1 Launch `rok-agent-1` VM.
- 4.2 Install RKE2 agent, `config.yaml` → `server: https://<server-ip>:9345`, `token`, unique
  `node-name`/`node-ip`; start `rke2-agent`.
- 4.3 `kubectl get nodes` → 2 nodes Ready. Inspect why it's clean now: separate kernels, separate
  netfilter/conntrack/cgroups, unique node identity, correct 9345 registration.
→ Learn: the real agent-join, node-ip, and *exactly why* this crashed in Docker but not in VMs.

### Phase 5 — Networking: cluster ↔ Floci, and ALB → NodePort
- 5.1 Make the VMs reach Floci at `http://<host-ip>:4566` (ECR pulls, ESO). Confirm from inside a VM.
- 5.2 Reserve Traefik NodePort (e.g. 30080). Register the VM IP + NodePort as the Floci ALB target
  group target; confirm the ALB listener forwards to it (once Traefik is up in Phase 6).
- 5.3 Handle DNS with `/etc/hosts` entries (Route53 is mock).
→ Learn: node IP, NodePort, and the ALB→ingress hop that ROK's ALB→Traefik does.

### Phase 6 — Platform add-ons via Helm (ROK bootstrap order)
Following ROK's `setup-env.md` order:
- 6.1 Traefik (ingress controller, NodePort service on 30080) + a middleware.
- 6.2 External Secrets Operator; `ClusterSecretStore` → Floci Secrets Manager (`http://<host-ip>:4566`).
- 6.3 ArgoCD; expose it; log in via CLI.
→ Learn: the RKE2 platform bootstrap sequence ROK runs.

### Phase 7 — ECR image flow
- 7.1 Build a tiny **frontend** (static/nginx) and **backend** (Node/HTTP) image.
- 7.2 `docker login` to Floci ECR, tag, push. Configure the RKE2 nodes to pull from Floci ECR
  (`registries.yaml` / imagePullSecret).
→ Learn: ECR as the registry ArgoCD/RKE2 pulls from, the exact image URIs.

### Phase 8 — GitOps: ArgoCD deploys frontend + backend
- 8.1 Write Helm charts mirroring `therok_v2` (infra: ExternalSecret + Ingress) and
  `therok_deployment` (Deployments + NodePort Services).
- 8.2 ArgoCD `Application`(s) pointed at the chart(s); sync; pods come up pulling from Floci ECR;
  secrets arrive via ESO from Floci Secrets Manager.
- 8.3 Hit the app end-to-end **through the Floci ALB** → Traefik → frontend/backend.
→ Learn: the whole ROK GitOps loop, ingress routing, secret injection — end to end.

### Phase 9 — mailpit + SES + an SQS worker
- 9.1 Wire Floci SES → mailpit (done in compose); verify a test SES send lands in mailpit.
- 9.2 Give the backend an endpoint that enqueues to SQS; deploy a small worker that reads SQS and
  sends via SES → watch it appear in mailpit; exercise the DLQ.
→ Learn: ROK's email-worker + mailpit + SQS/DLQ pattern.

### Phase 10 — A service that interacts with ECS
- 10.1 Run an ECS (Fargate-style) service on Floci (real container, published port) — e.g. a small
  API the cluster backend calls, or an SQS consumer.
- 10.2 Have the in-cluster backend interact with it; note Floci ECS limits (no real ALB/CloudMap →
  reach it by published port).
→ Learn: ECS real container execution and where the emulation stops.

### Phase 11 (optional) — RDS SQL Server + WAF middleware
- 11.1 Create a Floci RDS SQL Server instance via Terraform; point the backend at it; run a query.
- 11.2 Add real request filtering as a Traefik/Coraza middleware to stand in for WAF behavior.
→ Learn: RDS SQL Server round-trip; why Floci WAF is IaC-only and how to get real filtering.

---

## Verification checkpoints
- Phase 4: `kubectl get nodes` shows server + agent both `Ready`, no host-network crash.
- Phase 6: Traefik, ESO, ArgoCD all `Running`; ArgoCD reachable.
- Phase 8: browser/curl through the Floci ALB returns the frontend, which reaches the backend; a
  secret value visible in a pod originated from Floci Secrets Manager.
- Phase 9: a message enqueued to SQS results in an email visible in mailpit.

## Cleanup notes (for later)
- `docker compose down -v` removes Floci + mailpit + volumes.
- Delete the VMs with the chosen tool (e.g. `multipass delete --purge rok-server rok-agent-1`).
- `terraform destroy` against Floci (or just drop the Floci volume).
- Everything else is plain files under this directory.
