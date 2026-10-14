#!/usr/bin/env bash
# Pre-push sanity check for k8s/grafana/ (PLAN Phase 10). Read-only; run it before every `git push`.
#   zsh/bash scripts/check-grafana-content.sh
# Catches the mistakes that otherwise fail SILENTLY in Grafana:
#   1. a file in dashboards/ or alerting/ that kustomization.yaml does not list (never deployed)
#   2. broken JSON/YAML
#   3. duplicate dashboard uids / alert-rule uids (one silently overwrites the other)
#   4. a rule routed to a contact point that no file defines
#   5. kustomize can't build
set -euo pipefail
cd "$(dirname "$0")/../k8s/grafana"
kubectl kustomize . >/dev/null && echo "ok  kustomize builds"
python3 - <<'PY'
import glob, json, sys, yaml
err = []
kust = open("kustomization.yaml").read()
files = sorted(glob.glob("dashboards/*.json") + glob.glob("alerting/*.yaml"))
for f in files:
    if f not in kust: err.append(f"{f} is not listed in kustomization.yaml (would be ignored)")
dash_uids, rule_uids, contacts, receivers = {}, {}, set(), []
for f in files:
    try:
        d = json.load(open(f)) if f.endswith(".json") else yaml.safe_load(open(f))
    except Exception as e:
        err.append(f"{f}: does not parse: {e}"); continue
    if f.endswith(".json"):
        u = d.get("uid"); dash_uids.setdefault(u, []).append(f)
        if not u: err.append(f"{f}: dashboard has no uid")
    else:
        for cp in d.get("contactPoints", []) or []: contacts.add(cp["name"])
        for g in d.get("groups", []) or []:
            for r in g.get("rules", []) or []:
                rule_uids.setdefault(r["uid"], []).append(f)
                receivers.append((f, r["title"], (r.get("notification_settings") or {}).get("receiver")))
for kind, m in (("dashboard", dash_uids), ("alert rule", rule_uids)):
    for u, fs in m.items():
        if len(fs) > 1: err.append(f"duplicate {kind} uid {u!r} in {fs}")
for f, t, rc in receivers:
    if rc not in contacts: err.append(f"{f}: rule {t!r} routes to unknown contact point {rc!r}")
print(f"ok  {len(files)} files parsed; {len(dash_uids)} dashboards, {len(rule_uids)} rules, contact points: {sorted(contacts)}")
if err:
    print("\n".join("FAIL " + e for e in err)); sys.exit(1)
print("ok  no listing / uid / receiver problems")
PY
