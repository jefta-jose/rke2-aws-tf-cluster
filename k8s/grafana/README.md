# Grafana content in git — how to maintain it

Everything here reaches Grafana as: **file in git → ArgoCD (`grafana-content` app) → labelled ConfigMap →
Grafana sidecar → Grafana**. Nobody edits Grafana by hand; the UI shows these objects as *provisioned*
(read-only). If you change something in the UI it is not saved to git and the next sync reverts/blocks it.

```
kustomization.yaml          the LIST of what gets deployed (one ConfigMap per file)
dashboards/*.json           one dashboard per file        -> label grafana_dashboard, folder from annotation
alerting/contact-points.yaml   WHERE alerts go (shared by all rules)
alerting/<topic>.yaml       one rule GROUP per file (node-health, client-cert-expiry, ...)
```

## Every change, same loop
1. Edit / add files.  2. `bash scripts/check-grafana-content.sh` (catches unlisted files, bad YAML/JSON,
duplicate uids, rules routed to unknown contact points).  3. `git add -A && git commit && git push`.
4. `argocd app get grafana-content --refresh`; then look in Grafana (sidecar log:
`kubectl -n grafana logs deploy/grafana -c grafana-sc-alerts --tail=20`).

## Recipes
| I want to… | Do |
|---|---|
| **Add a dashboard** | Build/export it in Grafana, save JSON to `dashboards/<name>.json`, give it a **unique `uid`**, datasource `{"type":"prometheus","uid":"prometheus"}`; add a `configMapGenerator` entry (copy an existing one). |
| **Add a rule to an existing group** | Append to that file's `rules:`; give it a **new unique `uid`**. No kustomization change. |
| **Add a new rule group** | New `alerting/<topic>.yaml` + a `configMapGenerator` entry with label `grafana_alert: "1"`. |
| **Change a threshold / query / repeat interval** | Edit the value in the rule, push. Same `uid` = same rule, updated in place. |
| **Change where alerts go** | Edit only `contact-points.yaml`. Rules keep pointing at the name `nimbus-teams`. |
| **Use a real Teams webhook** | NEVER commit it (public repo). Create the contact point by hand in the UI or via a Secret-backed mount; keep git on the placeholder. |
| **Delete a rule/dashboard** | Delete it from the file (or the whole file + its kustomization entry). ArgoCD prunes; Grafana drops it. |
| **Rename a rule** | Change `title` freely. Never change `uid` unless you want a delete + create (loses its state history). |

## Gotchas (each one has bitten somebody)
- **A file not listed in `kustomization.yaml` is silently ignored.** The check script fails on this.
- **`uid` is the identity.** Duplicate uids → one silently overwrites the other. Don't reuse them.
- **Don't delete a contact point that rules still use** — Grafana refuses and provisioning errors. Move rules
  first (or in the same commit; ArgoCD creates new objects before pruning old ones).
- **Alert PromQL:** no `> 0` filter and no `or vector(0)` inside the query. Return a number (0 = healthy) and
  let the Grafana Threshold decide, so a vanished metric is real *No data*, not "healthy".
- **Prometheus `le` labels** are exact strings (`7.776e+06`, `2.592e+06`, `604800.0`). A near-miss matches
  nothing and the rule never fires. Check against `/api/v1/query` first.
- **ConfigMap limit 1 MiB** (hence one ConfigMap per file) and ArgoCD's client-side apply annotation limit
  256 KB (hence `ServerSideApply=true` on the app). Very large dashboards: slim down the JSON.
- **Dashboard JSON from the UI export** contains `"id"` and a `__inputs` block when "export for sharing" is
  used; use *Export → Export as JSON* (not "for sharing externally"), set `id` to null, keep a fixed `uid`.
- **Reload lag:** ArgoCD polls git ~every 3 min (use `--refresh`); the sidecar then reloads alerting within a
  few seconds.
