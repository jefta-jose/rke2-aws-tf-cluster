# rok-app — map-driven workloads chart

One Helm chart that renders **all** the lab's Kubernetes workloads from a single
`workloads:` map. Adding a workload means adding a map entry — no new template files.
Modeled on the real `becklar_messaging_workloads` chart.

## Mental model

```
values.yaml            workloads:              templates/ (range over the map)
  frontend  ───┐         frontend: {...}   ┌── deployments.yaml    → Deployment  per workload
  backend   ───┼──▶      backend:  {...} ──┼── services.yaml       → Service     (if service.enabled)
  worker    ───┘         worker:   {...}   ├── ingress.yaml        → Ingress     (if ingress.enabled)
                                           ├── external-secrets.yaml → ExternalSecret (if secretName set)
                                           └── secret-stores.yaml  → SecretStore  (if secretName set)
```

Each template loops (`range $component, $workload := .Values.workloads`) and emits its
resource **only** for workloads where the relevant switch is on. So a workload is fully
described by its data — a static frontend (no secret, has a Service+Ingress), an API
backend (secret + Service + Ingress), or a worker (secret only, no inbound networking).

## Sync waves (ordering)

ArgoCD applies resources in wave order so dependencies exist first:

| Wave | Resource        | Why                                             |
|------|-----------------|-------------------------------------------------|
| `-2` | SecretStore     | ESO needs the store before it can sync a secret |
| `-1` | ExternalSecret  | creates the k8s Secret the pod mounts           |
| `0`  | Deployment      | starts last, once its Secret exists             |

Services/Ingresses have no wave (order-independent).

## Files

| File | Purpose |
|------|---------|
| `Chart.yaml` | chart metadata + version |
| `values.yaml` | **shape** — every workload's structure and defaults (env-agnostic) |
| `values-development.yaml` | **per-env overlay** — image repositories + Secrets Manager `remoteKey` only |
| `templates/_helpers.tpl` | shared labels (`rok-app.labels`) |
| `templates/deployments.yaml` | one Deployment per enabled workload |
| `templates/services.yaml` | ClusterIP Service per workload with `service.enabled` |
| `templates/ingress.yaml` | one host-less Ingress **per** workload with `ingress.enabled` |
| `templates/external-secrets.yaml` | ExternalSecret per workload that declares a `secretName` |
| `templates/secret-stores.yaml` | SecretStore per such workload (+ lab-only auth block) |

## Secrets: lab vs. real ROK

Real ROK's SecretStore has **no `auth` block** — the ESO controller authenticates to AWS
through the node's IAM role (IRSA), secretless. Floci has no IAM identity, so
`secretStoreAuth.enabled: true` renders an `auth.secretRef` pointing at a `floci-aws-creds`
Secret **in the release namespace** (bootstrapped by hand, never in git). Set
`secretStoreAuth.enabled: false` and it renders the real-ROK (IRSA) shape.

The Secret's *contents* come from AWS/Floci Secrets Manager: `externalSecret.remoteKey` is
the Secrets Manager key, `dataFrom.extract` pulls all its keys into the k8s Secret, and
`secretEnv` maps chosen keys into container env vars.

## ArgoCD: one Application per workload

`k8s/argocd/rok-<workload>-development.yaml` — each Application points at **this same chart**
but enables only its own workload via `helm.parameters` (`workloads.X.enabled=false` for the
others). So each app owns exactly one workload's resources, in namespace `rok-development`.
This mirrors becklar's per-workload apps and keeps blast radius small (sync/rollback one
workload at a time).

## How to add a new workload

1. **Add an entry** under `workloads:` in `values.yaml` (copy the closest existing one):
   - server? give it `service` + `ingress` blocks.
   - needs a secret? give it `secretName`, `secretStore`, `externalSecret`, `secretEnv`.
   - worker? set `service.enabled: false`, `ingress.enabled: false`.
2. **Add its per-env bits** in `values-development.yaml`: `image.repository`, `image.tag`,
   and (if it has a secret) `externalSecret.remoteKey`.
3. **Build + push its image** to `192.168.122.1:5000/<name>:<tag>` (Phase 7 flow).
4. **Create its Secrets Manager secret** in Floci if it needs one (matching `remoteKey`).
5. **Add an ArgoCD Application** in `k8s/argocd/` (copy an existing one; enable only the new
   workload) and `kubectl apply -f` it.

No template changes required for any of the above.

## How to add a new environment (e.g. production)

Create `values-production.yaml` (same shape as `values-development.yaml`, prod image repos +
`remoteKey`s) and a matching set of `k8s/argocd/rok-<workload>-production.yaml` Applications
that reference `values-production.yaml` and a `rok-production` namespace.

## Lab-specific notes

- **Images** come from the local registry `192.168.122.1:5000` (Phase 7), not ECR.
- **Ingress is host-less** because Floci's ALB rewrites the `Host` header (Phase 8.4);
  Traefik routes purely by path. Real ROK keys Ingress on a hostname.
- Reaching the app locally: `http://localhost:30080/` via the `socat` bridge (Phase 8.5).
