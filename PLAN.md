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
        │  Host containers                                          │
        │   ┌───────────┐   ┌──────────────┐  (AWS APIs @ :4566)     │
        │   │  Floci    │   │ host compose │                         │
        │   │  :4566    │   │ registry:2   │                         │
        │   │  ECR/SM/  │   │  :5000 (ECR) │                         │
        │   │  SQS/SNS/ │   │ postgres     │                         │
        │   │  ALB/IAM  │   │  :5432 (P10) │                         │
        │   └─────┬─────┘   └──────────────┘                         │
        │         │ ALB listener forwards to  VM_IP:NodePort         │
        └─────────┼─────────────────────────────────────────────────┘
                  │  (host ↔ VM routing, Phase 5)
        ┌─────────┼───────────────────────┐   ┌───────────────────┐
        │  VM: rok-server                 │   │  VM: rok-agent-1    │
        │  RKE2 server (etcd+control)     │◀──│  RKE2 agent        │
        │  Traefik (NodePort 30080)       │9345 join              │
        │  ArgoCD, External Secrets Op    │   │  workloads         │
        │  frontend/backend/mailer +      │   │  consumer (P10)    │
        │  mailpit sink (P9)              │   │                   │
        └─────────────────────────────────┘   └───────────────────┘
   Pods reach AWS/Postgres at http://<host-ip>:4566 / :5432 (ECR, ESO, SQS/SNS, DB).
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
| SQS + DLQ | **Real** | SNS→SQS consumer queue + DLQ (Phase 10) |
| SNS | **Real** | Producer publishes events; SNS→SQS fan-out (Phase 10) |
| SES | **Not used** — mailpit runs **in-cluster** as a test sink | Frontend → mailer → mailpit (SMTP), no cloud email (Phase 9) |
| ALB (ELBv2) | **Real** — forwards HTTP by path/host to targets | ALB → Traefik NodePort |
| RDS SQL Server | **Not used** — **Postgres via docker-compose** on the host | App DB for the SNS→SQS consumer; creds in Secrets Manager (Phase 10) |
| IAM / KMS / Lambda | Real enough | Use as needed |
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
- 1.1 Write `docker-compose.yml` for Floci: shared network, docker socket mount, persistent storage,
  published port `4566`. (mailpit is NOT here — it's deployed **in-cluster** in Phase 9; Postgres is a
  separate host compose in Phase 10.)
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

### Phase 9 — In-cluster mailpit + a mailer wired to the frontend
mailpit is a **test mail sink deployed in the cluster** (as ROK does in lower envs) — no real email,
no SES, no AWS in the path. The frontend sends a message straight through to mailpit over SMTP.
- 9.1 Deploy mailpit **into the cluster**: a Deployment + Service `mailpit` (SMTP `:1025` ClusterIP,
  web UI `:8025` exposed via a host-less Ingress path / NodePort). Confirm the UI loads.
- 9.2 Add a new **mailer** workload to the `rok-app` chart: a small Node service with
  `POST /api/email {to,subject,body}` that opens an SMTP connection to `mailpit:1025` and sends. SMTP
  host/port come from `development-rok-general-secret` (`Smtp__Host`/`Smtp__Port`) via ESO. Service +
  host-less Ingress (`/api/email`).
- 9.3 Frontend: add a simple send-email form → `fetch("/api/email", …)` → mailer → mailpit. Submit
  from the browser and watch the message land in the mailpit UI.
→ Learn: the ROK in-cluster mailpit test-sink pattern, a frontend→service→mailpit hop, and service
  config pulled from Secrets Manager via ESO — all cloud-email-free.

### Phase 10 — SNS→SQS event pipeline + Postgres (producer/consumer)
A real fan-out: a **producer** publishes events to **SNS**, SNS delivers to an **SQS** queue, and a
**consumer** processes them and writes to **Postgres**. Postgres runs as its own docker-compose (like
the registry), NOT RDS/Floci; every backend service reads its creds from Floci Secrets Manager via ESO.
- 10.1 Stand up **Postgres** via a `postgres/docker-compose.yml` on the host (published on
  `192.168.122.1:5432` — the same host-gateway route pods already use for the registry/Floci). Create
  the app DB + an `events` table.
- 10.2 Terraform: put the Postgres creds in Floci Secrets Manager (`development-rok-db-secret`) and
  create the **SNS topic** + an **SQS queue subscribed to it** (SNS→SQS fan-out).
- 10.3 **Producer:** a frontend action (button/form) → `POST` to a publisher endpoint that publishes
  an event to SNS (through Floci at `http://192.168.122.1:4566`).
- 10.4 **Consumer** workload: long-polls the SNS-subscribed SQS queue, and for each event writes a row
  to Postgres (DB creds from ESO). Uses the map-driven chart's worker shape (no inbound networking).
- 10.5 End-to-end: click in the frontend → SNS → SQS → consumer → row lands in Postgres. Verify with a
  `SELECT`; exercise the DLQ with a poison event.
→ Learn: SNS→SQS fan-out, a genuine producer/consumer split, pod↔Floci runtime API calls, and a
  cloud-agnostic Postgres whose creds live in Secrets Manager.

---

## Verification checkpoints
- Phase 4: `kubectl get nodes` shows server + agent both `Ready`, no host-network crash.
- Phase 6: Traefik, ESO, ArgoCD all `Running`; ArgoCD reachable.
- Phase 8: browser/curl through the Floci ALB returns the frontend, which reaches the backend; a
  secret value visible in a pod originated from Floci Secrets Manager.
- Phase 9: a message sent from the frontend form appears in the in-cluster mailpit UI (no AWS).
- Phase 10: a frontend action publishes to SNS → the SQS consumer writes a row visible in Postgres.

## Cleanup notes (for later)
- `docker compose down -v` in `~/floci-docker` removes Floci + volumes; the `registry:2` and the
  Phase-10 Postgres composes are separate stacks (tear down independently). mailpit is in-cluster
  (`kubectl delete`).
- Delete the VMs with the chosen tool (e.g. `multipass delete --purge rok-server rok-agent-1`).
- `terraform destroy` against Floci (or just drop the Floci volume).
- Everything else is plain files under this directory.
