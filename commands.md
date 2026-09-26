# Commands Log — ROK Infra Learning Lab (Floci + real RKE2 VMs)

> Clean slate — 2026-09-24. Logs only commands that actually worked, written step-by-step as we go.
> See `PLAN.md` for the full design.

## Conventions (paste-safety standard)

Interactive zsh mangles pasted **multi-line indented** text (lost indentation, duplicated lines) and
tilde-expands `~` inside would-be comments. So this log never asks you to paste fragile blocks:

- **Indented YAML manifest** → a file under `k8s/`, applied with a one-line `kubectl apply -f <path>`.
- **Heredocs / loops / anything indented or using `\` line-continuation** → a file under `scripts/`,
  executed: `bash <path>` on the HOST, or `ssh ubuntu@$IP 'sudo bash -s' < <path>` to run it IN a VM.
- **Multi-line inside a code block is allowed only** when every line is an *independent single-line
  command* (no indentation, no `\`, no heredoc, no `#` comments) — those paste cleanly.

## Phase 0 — VM toolchain (libvirt/KVM) on the WSL2 host

### 1.1 Install the VM toolchain
```bash
sudo apt-get update && sudo apt-get install -y libvirt-daemon-system libvirt-clients virtinst qemu-utils genisoimage
```
Installs libvirt + qemu deps. Gives each RKE2 node its own kernel (separate netfilter/conntrack/cgroups) — the reason we don't run RKE2 nodes as Docker containers on WSL2.
Result: installed OK (libvirt-daemon 12.0.0, lvm2 storage driver configured). `dm-event.service ... not starting it` on WSL2 is informational, not an error.

### 1.2 Re-add user to libvirt/kvm groups
```bash
sudo usermod -aG libvirt,kvm jeffndegwa
```
Lets you drive libvirt without sudo after a re-login. Until then, use `sudo virsh -c qemu:///system ...` (no `sg`/`newgrp` installed here).

### 1.3 Enable + start libvirtd
```bash
sudo systemctl enable --now libvirtd
```
Enabled and started; created the libvirtd service + socket symlinks.

### 1.4 Redefine + start the default network (virbr0, 192.168.122.0/24)
Reinstalling the packages did NOT restore `default` (teardown had undefined it). Redefine from the shipped template, then autostart + start. Run as separate short lines (long one-liners get wrapped/split by the terminal on paste):
```bash
sudo virsh -c qemu:///system net-define /usr/share/libvirt/networks/default.xml
sudo virsh -c qemu:///system net-autostart default
sudo virsh -c qemu:///system net-start default
sudo virsh -c qemu:///system net-list --all
```
Result: `default   active   yes   yes`. Each VM gets a distinct routable IP on virbr0 (full L2 between nodes + DHCP), which is why libvirt (not Lima) is the VM layer.

## Phase 3 — rok-server VM (Ubuntu 24.04 cloud image on virbr0)

### 3.1 Build & boot the VM
Config lives in `vms/rok-server/` (heavily commented): `user-data` + `meta-data` (cloud-init: hostname + SSH key) and `build.sh` (downloads the Ubuntu 24.04 cloud image, builds a `cidata` seed ISO with genisoimage, makes a qcow2 overlay disk, then `virt-install --import`). One idempotent command:
```bash
sudo bash /home/jeffndegwa/rke2-aws-tf-cluster/vms/rok-server/build.sh
```
Result: VM `rok-server` created and booted (2 vCPU / 4 GB / 20 GB). Grab its virbr0 IP and
**save it in a HOST shell variable** so the SSH step already has it — no copy-pasting the raw
`<node-ip>`:


### 3.2 Install the RKE2 server + write config
Derive rok-server's IP into a HOST shell var (cloud-init done → passwordless SSH).
`config.yaml`: token = shared join secret, node-ip pins identity, tls-san so host/agent trust the API cert, kubeconfig readable.
```bash
SERVER_IP=$(virsh -c qemu:///system domifaddr rok-server | awk '/ipv4/ {print $4}' | cut -d/ -f1)
echo "SERVER_IP=$SERVER_IP"
```
Write the config by **piping a script into the VM over SSH** (no multi-line paste — the file carries
the indentation; see Conventions). The script auto-detects `NODE_IP` inside the VM and `cat`s the
result back so you can eyeball all 6 lines. From the HOST:
```bash
ssh ubuntu@"$SERVER_IP" 'sudo bash -s' < /home/jeffndegwa/rke2-aws-tf-cluster/scripts/write-rke2-server-config.sh
```
Install RKE2 (server is the default flavour — no `INSTALL_RKE2_TYPE`). PIN the version so server/agent match and the `stable` channel can't 404 on us:
```bash
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION="v1.36.4+rke2r1" sh -
```
Result: installed v1.36.4+rke2r1.

### 3.3 Start the server + verify
```bash
sudo systemctl enable --now rke2-server.service
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
kubectl get nodes -o wide
```
Result: after ~4 min (etcd + control plane + Canal CNI pulls), `rok-server` is `Ready` (control-plane,etcd), internal IP node-ip. Its kernel `6.8.0-139-generic` differs from the WSL2 host kernel — proof each node owns its kernel (separate netfilter/conntrack/cgroups), the reason the agent join is clean in VMs.

## Phase 4 — rok-agent-1 VM + clean RKE2 agent join

### 4.1 Build & boot the agent VM
Config in `vms/rok-agent-1/` (mirrors rok-server, hostname `rok-agent-1`, 2 vCPU / 4 GB). Reuses the base image already downloaded. On the HOST:
```bash
sudo bash /home/jeffndegwa/rke2-aws-tf-cluster/vms/rok-agent-1/build.sh
```

Grab the agent's virbr0 IP into a HOST variable, same as the server:


### 4.2 Install + configure the RKE2 agent
Derive both IPs into HOST shell vars (`SERVER_IP` = rok-server's node-ip, `AGENT_IP` = this worker):
```bash
SERVER_IP=$(virsh -c qemu:///system domifaddr rok-server | awk '/ipv4/ {print $4}' | cut -d/ -f1)
AGENT_IP=$(virsh -c qemu:///system domifaddr rok-agent-1 | awk '/ipv4/ {print $4}' | cut -d/ -f1)
echo "SERVER_IP=$SERVER_IP AGENT_IP=$AGENT_IP"
```
Write the agent config by **piping a script into the agent over SSH**, passing `SERVER_IP` as its
argument (no multi-line paste; the agent's own `NODE_IP` is auto-detected inside the VM):
```bash
ssh ubuntu@"$AGENT_IP" "sudo bash -s $SERVER_IP" < /home/jeffndegwa/rke2-aws-tf-cluster/scripts/write-rke2-agent-config.sh
```
`server` uses the **9345 supervisor port** (join endpoint), token must match the server, node-ip pins this worker's identity. Install in agent mode, PINNING the version to match the server (the `stable` channel briefly 404'd — pinning also enforces server/agent version parity):
```bash
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE="agent" INSTALL_RKE2_VERSION="v1.36.4+rke2r1" sh -
```

### 4.3 Start the agent + verify from the server
On the agent:
```bash
sudo systemctl enable --now rke2-agent.service
```
On the server: `kubectl get nodes -o wide`.
Result: agent dialed `<server-ip>:6443` HEALTHY→ACTIVE and registered cleanly (no host crash). Was briefly `NotReady` (`cni plugin not initialized`) while Canal finished; a few transient Docker Hub "image not found" pulls self-healed on RKE2 retry. After ~2 min: **both nodes `Ready`** (rok-server control-plane,etcd + rok-agent-1 worker). Phase 4 checkpoint met.
Note for Phase 6: this RKE2 build ships **Traefik** (`rke2-traefik` pod) as the bundled ingress, not ingress-nginx — may cover part of Phase 6.1. Confirm later.

## Host access — drive the cluster from the HOST (session-only kubeconfig)
(Out-of-band convenience, not a PLAN phase — the real Phase 5 is the networking section below.)

Goal: run `kubectl` from the WSL2 host without SSHing into the server, but **only** in the terminal
where we opt in — a fresh terminal must NOT reach the cluster. The trick: store the kubeconfig at a
**non-default path** (`kubectl` auto-loads only `~/.kube/config`) and point at it with a `KUBECONFIG`
export that lives only for the current shell. No rc-file edits → nothing leaks into new terminals.

Prereqs already met on the host: `kubectl v1.36.1` at `/usr/local/bin/kubectl` (matches the cluster).

### A. Grab the kubeconfig onto the host
`rke2.yaml` ships with `server: https://127.0.0.1:6443`; rewrite `127.0.0.1` → the server's virbr0 IP
so the host can reach the API. The cert already trusts that IP (it's in the Phase 3 `tls-san`), so no
TLS complaints. `write-kubeconfig-mode: "0644"` (Phase 3) makes the file world-readable → plain `cat`
over SSH works, no `sudo` password prompt.
Derive rok-server's current virbr0 IP (DHCP — don't hardcode it):
```bash
SERVER_IP=$(virsh -c qemu:///system domifaddr rok-server | awk '/ipv4/ {print $4}' | cut -d/ -f1)
echo "SERVER_IP=$SERVER_IP"
mkdir -p ~/.kube
ssh ubuntu@"$SERVER_IP" 'cat /etc/rancher/rke2/rke2.yaml' | sed "s/127.0.0.1/$SERVER_IP/" > ~/.kube/rok-lab.yaml
chmod 600 ~/.kube/rok-lab.yaml
```

### B. Point THIS shell at the cluster (dies with the session)
```bash
export KUBECONFIG="$HOME/.kube/rok-lab.yaml"
kubectl get nodes -o wide
```
Result: both nodes `Ready` from the host — `rok-server` (control-plane,etcd, 192.168.122.138) and
`rok-agent-1` (worker, 192.168.122.105), both `v1.36.4+rke2r1`, containerd 2.3.4.
Session-only proof: `export` lives only in this shell. New terminal → `KUBECONFIG` unset → `kubectl`
falls back to `~/.kube/config` (which doesn't know this cluster) → can't reach it. To use the lab in a
future terminal, deliberately re-run the `export` line from step B.

> ⚠️ DHCP caveat: if `rok-server`'s IP changes on a later boot, `~/.kube/rok-lab.yaml` points at the
> stale IP. Re-run step A with the new `SERVER_IP` (grab it via `virsh -c qemu:///system domifaddr rok-server`).

## Phase 2 — Terraform the AWS base into Floci

Provider points at Floci (`localhost:4566`, dummy creds, skip flags). Provisions network + 2 ECR repos,
`development-rok-general-secret`, SQS `email` + `email-dlq` (FIFO), IAM node role/policies, ALB → NodePort
30080 target group, and the WAFv2 WebACL.
```bash
cd /home/jeffndegwa/rke2-aws-tf-cluster/terraform
terraform init
terraform plan
terraform apply
```
Result: applied cleanly against Floci.

## Phase 5 (networking) — wire the two halves: VMs → Floci, and ALB → Traefik NodePort

The lab is **two worlds that don't naturally know about each other**, and on real AWS a shared VPC
wires them for free. Locally we hand-wire the two directions of traffic:
- **AWS world** = Floci, a container on the host's Docker net, serving AWS APIs on `:4566`.
- **compute world** = the RKE2 VMs on libvirt `virbr0` (`192.168.122.0/24`).

### 5.0 Grab live IPs into shell vars (re-run per shell — DHCP drifts)
Node IPs are DHCP and change across boots, so derive them instead of hardcoding. The virbr0 gateway
(`HOST_IP`, what VMs use to reach Floci) is stable but we derive it too; the target-group ARN comes
straight from Terraform output. Run on the HOST. (Comments stripped: interactive zsh doesn't treat
`#` as a comment unless `setopt interactive_comments`, and it would tilde-expand a `~` inside one →
`no such user`.) `HOST_IP` is the stable virbr0 gateway (~192.168.122.1):
```bash
HOST_IP=$(ip -4 addr show virbr0 | awk '/inet / {print $2}' | cut -d/ -f1)
SERVER_IP=$(virsh -c qemu:///system domifaddr rok-server  | awk '/ipv4/ {print $4}' | cut -d/ -f1)
AGENT_IP=$(virsh -c qemu:///system domifaddr rok-agent-1 | awk '/ipv4/ {print $4}' | cut -d/ -f1)
TG_ARN=$(terraform -chdir=/home/jeffndegwa/rke2-aws-tf-cluster/terraform output -raw alb_target_group_arn)
printf 'HOST_IP=%s\nSERVER_IP=%s\nAGENT_IP=%s\nTG_ARN=%s\n' "$HOST_IP" "$SERVER_IP" "$AGENT_IP" "$TG_ARN"
```

### 5.1 VMs → Floci (outbound) — the road ECR pulls + ESO secret-sync ride on
Pods must *call* AWS (pull from ECR, GetSecretValue via ESO, SQS). From a VM the host — and thus
Floci — is the virbr0 gateway `$HOST_IP:4566` (Floci binds `*:4566`, so it's reachable). Prove
the path from inside a node:
```bash
ssh ubuntu@"$SERVER_IP" "curl -sS -o /dev/null -w 'floci http=%{http_code}\n' http://$HOST_IP:4566/ || echo UNREACHABLE"
```
Result: got an HTTP status back → VM→host→Floci path is open. (Note for Phase 7: the ECR output URLs
say `localhost:4566`, which from a VM means the VM itself — nodes will need containerd pointed at
`$HOST_IP:4566` instead.)

### 5.2 Floci ALB → VMs (inbound) — the front door for user traffic
Real ROK flow: **user → ALB → Traefik (NodePort) → pod**. The ALB needs to know where its backends
are. Register both node IPs on NodePort `30080` into the `target_type = "ip"` target group. Uses the
vars from 5.0. On the HOST:
```bash
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=http://localhost:4566 --region us-east-1 elbv2 register-targets --target-group-arn "$TG_ARN" --targets Id=$SERVER_IP,Port=30080 Id=$AGENT_IP,Port=30080
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=http://localhost:4566 --region us-east-1 elbv2 describe-target-health --target-group-arn "$TG_ARN"
```
Result: both targets registered, `State: initial / Elb.RegistrationInProgress`. They read `unhealthy`
because **nothing listens on 30080 yet** — Traefik doesn't exist until Phase 6. That's the correct
state now; when Phase 6 brings Traefik up on NodePort 30080 the health check passes → targets go
`healthy`, confirming the ALB→cluster hop end-to-end.

> 5.3 (`/etc/hosts` for the mock Route53) is deferred to Phase 8 — nothing to resolve until a frontend
> ingress host exists.

## Phase 6.1 — expose the bundled Traefik on NodePort 30080

RKE2 ships Traefik as a **DaemonSet** (one pod per node) but its `rke2-traefik` Service defaults to
**ClusterIP** — nothing answers on a node port, so the ALB targets stay `unhealthy`. Customize a
*bundled* chart the RKE2-native way: a **`HelmChartConfig`** named after the chart (`rke2-traefik`,
`kube-system`); the helm-controller deep-merges its `valuesContent` and re-runs the install. Manifest
lives at `k8s/rke2-traefik-nodeport.yaml`; apply from the HOST:
```bash
export KUBECONFIG="$HOME/.kube/rok-lab.yaml"
kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/rke2-traefik-nodeport.yaml
```
Verify (single-line jsonpath):
```bash
kubectl -n kube-system get svc rke2-traefik -o jsonpath='type={.spec.type}{"\n"}{range .spec.ports[*]}{.name}={.nodePort}{"\n"}{end}'
```
**Gotcha (cost one cycle):** this hardened chart reads the service type at `service.spec.type`, NOT
`service.type`. Setting `service.type` was silently ignored while `ports.web.nodePort` was honored →
an illegal ClusterIP-with-nodePort, and the helm-install job crash-looped with
`spec.ports[0].nodePort: Forbidden: may not be used when type is 'ClusterIP'`. Found by extracting the
embedded chart (`kubectl get helmchart rke2-traefik -o jsonpath='{.spec.chartContent}' | base64 -d`)
and reading its `values.yaml`. Fixed manifest uses `service.spec.type: NodePort`.
Result: `type=NodePort`, `web=30080` (websecure got an ephemeral 32287). Traefik answers on
`$SERVER_IP:30080` with `404` (up, no route yet).

### 6.1a — why the ALB targets DON'T go healthy yet (corrects the Phase 5.2 prediction)

The Phase 5.2 note predicted "Traefik up on 30080 → targets go healthy." **Wrong.** The target group's
health check is `HTTP GET /` with **matcher `200`** (interval 30s, healthy threshold 3), but a
route-less Traefik answers `/` with **`404`**. `404 ≠ 200`, so Floci correctly holds both targets
`unhealthy` — Traefik being up is necessary but not sufficient. Verify the mismatch (single line each):
```bash
aws --endpoint-url=http://localhost:4566 --region us-east-1 elbv2 describe-target-groups --target-group-arns "$TG_ARN" --query 'TargetGroups[0].{path:HealthCheckPath,matcher:Matcher.HttpCode,proto:HealthCheckProtocol,port:HealthCheckPort}' --output table
aws --endpoint-url=http://localhost:4566 --region us-east-1 elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[].{ip:Target.Id,state:TargetHealth.State}' --output table
```
Decision: **do NOT force it** (no matcher-relaxing, no drift). The targets flip to `healthy` on their
own at **Phase 8**, when ArgoCD deploys the app and its Ingress serves `/` with `200`. Caveat for then:
the ALB health check hits `GET /` with no app Host header, so the app's Ingress must answer `/` via a
path/catch-all route, not only a host-based route — else Traefik keeps 404-ing the health check.

### 6.1b — Floci recovery (it died on WSL2 shutdown)

Floci is a docker-compose stack; a WSL2 shutdown left all three containers `Exited (255)` and nothing on
`:4566`. State survived the restart (target group, ALB, both ECR repos, full Terraform state all intact).
Start the ECR-backing registry FIRST (hybrid-mode gotcha), then Floci:
```bash
docker start floci-ecr-registry floci-docker-floci-1 floci-docker-floci-ui-1
curl -sS -o /dev/null -w 'floci http=%{http_code}\n' http://localhost:4566/ && aws --endpoint-url=http://localhost:4566 --region us-east-1 sts get-caller-identity
```

---

## Phase 6.2 — External Secrets Operator → Floci Secrets Manager

Install ESO the RKE2-native way (no `helm` on the host): a **`HelmChart`** CR (`helm.cattle.io/v1`) in
`kube-system` — the bundled helm-controller pulls the chart and installs it in-cluster, same mechanism
that runs Traefik. Chart pinned to `external-secrets 2.11.0` (appVersion v2.11.0). Manifest at
`k8s/eso-helmchart.yaml`; apply from the HOST:
```bash
export KUBECONFIG="$HOME/.kube/rok-lab.yaml"
kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/eso-helmchart.yaml
```
Watch the install Job, then confirm pods + CRDs:
```bash
kubectl -n kube-system get job helm-install-external-secrets -w
kubectl -n external-secrets get pods
kubectl get crd | grep external-secrets.io
```
**Gotcha (the whole trick):** ESO's AWS provider talks to *real* AWS by default. Point it at Floci by
injecting the SDK endpoint env into the controller via the chart's `extraEnv` (baked into the manifest):
`AWS_ENDPOINT_URL` + `AWS_ENDPOINT_URL_SECRETS_MANAGER = http://192.168.122.1:4566` (the stable virbr0
gateway — what pods use to reach Floci), plus `AWS_REGION=us-east-1`. aws-sdk-go-v2 honors these, so no
per-store endpoint field is needed. Result: job `Complete 1/1` in ~25s; controller, webhook,
cert-controller all `Running`; CRDs installed (only `external-secrets.io/v1` is served — `v1beta1` is
retired in the 2.x line).

### 6.2a — ClusterSecretStore smoke-test (ESO ⇄ Floci connectivity)

Manifest at `k8s/eso-floci-store.yaml` (two docs): a `floci-aws-creds` Secret holding dummy `test/test`
(safe to commit — only auths to the local mock) and a cluster-scoped `ClusterSecretStore`
`floci-secrets-manager` referencing those creds. This is just the ESO connectivity smoke-test — the
app's real secret sync uses **per-workload `SecretStore`s** rendered by the chart in Phase 8 (with creds
in the app namespace). Apply + confirm the store validates (proves ESO reaches Floci Secrets Manager
via the injected endpoint):
```bash
kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/eso-floci-store.yaml
kubectl get clustersecretstore floci-secrets-manager   # -> Valid / READY True
```
Result: store `Valid`/`READY True` — ESO authenticated to Floci and can read Secrets Manager. (Tip for
inspecting a synced Secret's keys later: `kubectl get secret <name> -o go-template='{{range $k,$v :=
.data}}{{$k}}{{"\n"}}{{end}}'` — `-o jsonpath` can't iterate a map's keys.) Phase 6.2 done.

---

## Phase 6.3 — ArgoCD (install via HelmChart CR, expose through Traefik, CLI login)

Same RKE2-native install pattern: an `argo-cd` **`HelmChart`** CR (chart `10.9.2`, appVersion `v3.5.3`)
into an `argocd` namespace. Exposed through the **existing Traefik** (the Phase 6.1 ingress) rather than
port-forward/NodePort. Key values baked into `k8s/argocd-helmchart.yaml`: `configs.params.server.insecure:
true` (argocd-server serves plain HTTP on 8080 so Traefik routes without gRPC/TLS passthrough) and a
chart-generated Ingress (`server.ingress.enabled`, `ingressClassName: traefik`, `hostname:
argocd.rok.local`, `path: /`, `tls: false`). Apply from the HOST:
```bash
export KUBECONFIG="$HOME/.kube/rok-lab.yaml"
kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/argocd-helmchart.yaml
kubectl -n kube-system get job helm-install-argo-cd -w
kubectl -n argocd get pods
kubectl -n argocd get ingress
```
7 pods `Running` (server, repo-server, application-controller statefulset, redis, dex, applicationset,
notifications); Ingress `argo-cd-argocd-server` class `traefik`, host `argocd.rok.local`. Prove Traefik
routes to it (Host header, no hosts file yet) — expect `200`:
```bash
curl -sS -o /dev/null -w 'http=%{http_code}\n' -H 'Host: argocd.rok.local' http://$SERVER_IP:30080/
```

### 6.3a — access + CLI login

Resolve the host to the server node (this is the deferred 5.3 `/etc/hosts` step, brought forward for
ArgoCD; **DHCP-drifts — redo after reboot**), pull the initial admin password, install the CLI, log in:
```bash
echo "$SERVER_IP argocd.rok.local" | sudo tee -a /etc/hosts
PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo)
curl -L -# -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/v3.5.3/argocd-linux-amd64
sudo install -m 555 /tmp/argocd /usr/local/bin/argocd && argocd version --client
argocd login argocd.rok.local:30080 --username admin --password $PW --plaintext --grpc-web
```
Result: `'admin:login' logged in successfully`. The **web UI is the same server** as the CLI (not a
CLI-only install). **Gotchas:** (1) a silent `curl -sSL` of the ~155 MB CLI produced a *corrupt*
binary that **segfaulted** on `argocd version` — re-download with a progress bar (`-L -#`) and verify
`argocd version --client` before trusting it. (2) `argocd login` warns the server cert is for
`*.traefik.default`, not `argocd.rok.local` (Traefik's default self-signed cert) — answer `y`; cosmetic,
login still succeeds. Pin the CLI to the server version (`v3.5.3`) to avoid client/server skew.

### 6.3b — open the ArgoCD web UI from Windows Chrome (WSL2 networking)

The `/etc/hosts` entry and the node IP `192.168.122.138` live on the **WSL2 Linux side / libvirt net**.
A Linux (WSLg) browser can hit `http://argocd.rok.local:30080` directly, but **Windows Chrome cannot** —
Windows has no route into `192.168.122.0/24` and doesn't read WSL2's `/etc/hosts`. Easiest browser path
is a port-forward, which Windows reaches via WSL2's mirrored `localhost` (local port is arbitrary — use
any free one; `6060` below because `8080` was busy):
```bash
export KUBECONFIG="$HOME/.kube/rok-lab.yaml"
kubectl -n argocd port-forward svc/argo-cd-argocd-server 6060:80
```
Leave it running, then open `http://localhost:6060` in Windows Chrome (admin + the initial password).
Trade-off: this **bypasses Traefik** (hits the Service directly) and only lives while the command runs.
To reach it through the *real* Traefik route from Windows instead: run a forwarder on the WSL2 host
(`socat TCP-LISTEN:30080,fork,reuseaddr TCP:192.168.122.138:30080`) + add a *Windows* hosts entry
`127.0.0.1 argocd.rok.local`, then browse `http://argocd.rok.local:30080`.

> **Phase 6 checkpoint met** (PLAN.md): Traefik, ESO, and ArgoCD all `Running`; ArgoCD reachable + CLI
> login works. Next: Phase 7 (ECR image flow) → Phase 8 (ArgoCD deploys frontend/backend; the app Ingress
> serving `/` with `200` is what finally flips the ALB targets `healthy`, per 6.1a).

---

## Full nuke — tear the whole lab down to a bare host

Wipes VMs, disks, base image, the `default` network, and reverses the Phase 0 host prep.
**Everything runs on the HOST** (not inside a VM). Exit any SSH sessions first.

> ⚠️ The step order below is load-bearing: **VMs are destroyed FIRST, the network LAST.**
> `net-destroy default` while a VM is still running rebuilds `virbr0` empty and leaves the
> VM's tap dangling → `ssh: No route to host` + an empty `net-dhcp-leases`. Purging libvirt
> while domains are still defined orphans their qcow2/ISO files. Follow the steps in order.

The whole sequence (for-loop + ordered teardown) lives in a script so nothing multi-line is pasted.
Disk/base-image deletion is left commented inside — uncomment to reclaim space. Run on the HOST:
```bash
bash /home/jeffndegwa/rke2-aws-tf-cluster/scripts/nuke-lab.sh
```

> Not part of the cluster recreate loop: **Floci** stays up as-is, and **Terraform** state is already
> empty (we `terraform destroy`'d it this session). Re-applying Terraform is a separate step for later.

# Autostart the VMs on WSL2 launch

```bash
virsh -c qemu:///system autostart rok-server
virsh -c qemu:///system autostart rok-agent-1
```

---

## Phase 7 gotcha — Floci ECR does NOT work with the Docker Desktop engine (abandoned)

Floci serves ECR at `<acct>.dkr.ecr.<region>.localhost:4566` and routes by the **Host header**, relying
on the RFC 6761 rule that `*.localhost` resolves to `127.0.0.1` (loopback → Docker auto-insecure/HTTP).
That works on native Linux docker, but **Docker Desktop's engine resolves registry hostnames via the
Windows host, not any WSL `/etc/hosts`** — so `docker login/push` to the FQDN fails with
`dial tcp: lookup ... : no such host`, and `localhost:4566/v2/` 404s (no path routing).

Things that did NOT fix it: Ubuntu `/etc/hosts`, the `docker-desktop` distro's `/etc/hosts`. The only
thing that would is the **Windows** hosts file (`C:\Windows\System32\drivers\etc\hosts`) — not worth it.

**Decision:** drop ECR from Terraform; deliver the frontend/backend images to the RKE2 nodes without
Floci ECR. App images built in `apps/frontend` + `apps/backend` (kept).

### 7.2 — Local `registry:2` on the host (replaces ECR)

A plain registry container on the host at `:5000`. **Push from the host via `localhost:5000`**
(loopback → Docker Desktop auto-trusts it as HTTP, no daemon config), **nodes pull via the virbr0
gateway `192.168.122.1:5000`** — same container, same stored repos, host part is just addressing.
```bash
docker run -d --restart unless-stopped --name lab-registry \
  -p 5000:5000 -v lab-registry-data:/var/lib/registry registry:2
docker tag <frontend-image-id> localhost:5000/rok-frontend:v1
docker tag <backend-image-id>  localhost:5000/rok-backend:v1
docker push localhost:5000/rok-frontend:v1
docker push localhost:5000/rok-backend:v1
```
Result: `curl -s http://localhost:5000/v2/_catalog` → `{"repositories":["rok-backend","rok-frontend"]}`,
and the **same catalog is reachable from inside a node**:
`ssh ubuntu@192.168.122.138 "curl -s http://192.168.122.1:5000/v2/_catalog"` → same JSON. Confirms the
gateway-IP publish works exactly like Floci's `:4566`. Image refs everywhere else use
`192.168.122.1:5000/rok-{frontend,backend}:v1`.

### 7.3 — Point RKE2 nodes at the registry

`vms/registries.yaml` (an `http://` endpoint = plain HTTP, no TLS flags needed) installed to
`/etc/rancher/rke2/registries.yaml` on **every** node, then RKE2 restarted (containerd reads it only at
start). Server restart bounces the control plane ~30–60s; both nodes returned `Ready`.
```bash
for ip in $SERVER_IP $AGENT_IP; do
  scp vms/registries.yaml ubuntu@$ip:/tmp/registries.yaml
  ssh ubuntu@$ip "sudo mkdir -p /etc/rancher/rke2 && sudo mv /tmp/registries.yaml /etc/rancher/rke2/registries.yaml && sudo chown root:root $_"
done
ssh ubuntu@$SERVER_IP "sudo systemctl restart rke2-server"
ssh ubuntu@$AGENT_IP  "sudo systemctl restart rke2-agent"
kubectl get nodes   # both back to Ready
```
That's all that's required — `registries.yaml` is what lets containerd reach the registry; the kubelet
(driven by ArgoCD in Phase 8) does the actual image pulls at deploy time, so **no manual pull needed**.
(One-off sanity check if ever debugging an `ImagePullBackOff`:
`ssh ubuntu@$ip "sudo /var/lib/rancher/rke2/bin/crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock pull 192.168.122.1:5000/rok-frontend:v1"`.)

> **Phase 7 checkpoint met:** local registry replaces ECR; both RKE2 nodes pull
> `192.168.122.1:5000/rok-{frontend,backend}:v1`. Next: Phase 8 (ArgoCD deploys the Helm charts;
> Deployments reference those image refs; ESO injects `SECRET_MESSAGE`; reach it via ALB → Traefik).

---

## Phase 8 — GitOps: ArgoCD deploys the workloads (map-driven chart)

### 8.1 — the `rok-app` chart (`charts/rok-app/`, map-driven)

Refactored to mirror the real `becklar_messaging_workloads` chart: a single `workloads:` map that the
templates `range` over, so adding a workload = a values entry (no new template files). Full walkthrough
in `charts/rok-app/README.md`. Layout:
```
charts/rok-app/
  Chart.yaml
  values.yaml                # shape: workloads{frontend,backend,worker} + secretStoreAuth
  values-development.yaml     # per-env overlay: image repos (local registry) + Secrets Manager remoteKeys
  README.md                  # how it works + how to add a workload/environment
  templates/
    _helpers.tpl             # shared labels (rok-app.labels)
    deployments.yaml         # Deployment per enabled workload                (sync-wave 0)
    services.yaml            # ClusterIP Service per workload w/ service.enabled
    ingress.yaml             # host-less Ingress PER workload w/ ingress.enabled
    external-secrets.yaml    # ExternalSecret per workload that has a secretName (sync-wave -1)
    secret-stores.yaml       # namespaced SecretStore per such workload         (sync-wave -2)
```
Key points:
- **Workloads:** `frontend` (nginx — Service+Ingress `/`, no secret), `backend` (node API —
  Service+Ingress `/api`, secret → `SECRET_MESSAGE`), `worker` (SQS consumer — no Service/Ingress,
  ships `enabled: false` until Phase 9).
- **Sync waves** order the ESO chain so dependencies exist first: SecretStore `-2` → ExternalSecret
  `-1` → Deployment `0`.
- **Per-workload `SecretStore`** (namespaced), not one ClusterSecretStore. Real ROK's store has NO auth
  (IRSA). Floci has no IAM, so `secretStoreAuth.enabled: true` renders an `auth.secretRef` → a
  `floci-aws-creds` Secret **in the release namespace** (bootstrapped in 8.3, never in git).
- **Host-less Ingress**, one per workload (`rok-frontend` `/`, `rok-backend` `/api`) so the
  one-app-per-workload model doesn't collide on a shared Ingress name; Traefik merges the path rules.
  Host-less because Floci's ALB rewrites the `Host` header (8.4).
- Backend's secret contents come from Floci `development-rok-general-secret` (`externalSecret.remoteKey`
  in values-development.yaml), which carries `SECRET_MESSAGE`. That key was added to `terraform/main.tf`
  (`development_secret`) + `terraform apply`; verify: `aws --endpoint-url=http://localhost:4566
  secretsmanager get-secret-value --secret-id development-rok-general-secret --query SecretString
  --output text`.
```bash
helm lint charts/rok-app -f charts/rok-app/values-development.yaml
helm template rok-backend charts/rok-app -f charts/rok-app/values-development.yaml \
  --set workloads.frontend.enabled=false --set workloads.worker.enabled=false
```
Result: lint clean. Backend render → Service + Deployment (`secretKeyRef SECRET_MESSAGE`, image
`192.168.122.1:5000/rok-backend:v1`), Ingress `/api`, ExternalSecret (wave -1), SecretStore (wave -2)
with the Floci `auth.secretRef` block. Frontend render → Service+Deployment+Ingress `/` and **zero**
secret machinery.

### 8.2 — ArgoCD Applications (one per workload, `k8s/argocd/`)

Mirrors becklar's per-workload apps: each `Application` points at the **same** chart but enables only
its own workload via `helm.parameters` (the others `=false`), reads `values-development.yaml`, and
deploys to namespace `rok-development`.
```
k8s/argocd/rok-frontend-development.yaml   # enables frontend only
k8s/argocd/rok-backend-development.yaml    # enables backend only
k8s/argocd/rok-worker-development.yaml     # enables worker only — applied in Phase 9
```

### 8.3 — deploy: push, bootstrap the namespace, apply the apps

ArgoCD is pull-based, so push the chart first. Then create the release namespace and the Floci creds
the per-workload SecretStores read (creds live in the SAME namespace — the lab stand-in for ROK's
IRSA), and apply the two apps that are live now (worker waits for Phase 9).
```bash
git add -A charts/ k8s/argocd apps/ terraform/main.tf commands.md
git commit -m "..." && git push origin main
kubectl create namespace rok-development
kubectl -n rok-development create secret generic floci-aws-creds \
  --from-literal=access-key-id=test --from-literal=secret-access-key=test
kubectl apply -f k8s/argocd/rok-frontend-development.yaml
kubectl apply -f k8s/argocd/rok-backend-development.yaml
```
Verify (ArgoCD auto-syncs in ~30–60s):
```bash
kubectl get pods,svc,ingress,externalsecret,secretstore -n rok-development
curl -s http://localhost:30080/api/hello; echo
```
Result: frontend + backend pods `1/1 Running` in `rok-development`; **images pulled from
`192.168.122.1:5000` by the kubelet (Phase 7 proven via GitOps, no manual pull)**; per-workload
SecretStores `Valid`, ExternalSecrets `SecretSynced`; `rok-backend-secret` carries the synced keys; the
curl (via the socat bridge → Traefik NodePort 30080 → host-less Ingress → ClusterIP → pod) returns the
JSON with the injected `SECRET_MESSAGE`.
**Gotcha:** ArgoCD health stays `Progressing` forever because Traefik doesn't populate
`Ingress.status.loadBalancer` (`LB={}`) and ArgoCD waits on it. Purely cosmetic — traffic works. Fix if
desired: set Traefik `providers.kubernetesIngress.ingressEndpoint` so it writes ingress status.

### 8.4 — the last hop: reach the app through the Floci ALB

Path we're completing: `ALB :80 → Traefik NodePort 30080 → Ingress → pod`. Two Floci/Docker-Desktop
topology facts force workarounds (none exist against real AWS):

1. **Floci can't route into libvirt.** Floci runs in Docker Desktop's own VM; it has no route to the
   RKE2 VMs' `192.168.122.0/24`, so an ALB target of `192.168.122.138:30080` health-checks as
   `Target.Timeout`. But Floci *can* reach the host via `host.docker.internal` = `192.168.65.254`
   (WSL2 mirrored networking). So bridge the host into libvirt and point the target at the host.
2. **Floci's LB rewrites the Host header** to the LB's own DNS name before forwarding, so a host-scoped
   Ingress rule never matches → Traefik 404. Fix: path-based (host-less) Ingress (done in this commit).
```bash
# (a) host bridge: host:30080 -> VM:30080  (the WSL2 host CAN route to virbr0).
#     Deliberately NOT a service — re-run this (and steps b,c) on each cluster rebuild.
#     nohup so it survives closing this terminal; `pkill -f 'socat.*30080'` to stop it.
nohup socat TCP-LISTEN:30080,fork,reuseaddr TCP:192.168.122.138:30080 >/dev/null 2>&1 &

# (b) re-point the ALB target at the address Floci can reach (drop the unreachable VM IPs)
TG=$(terraform output -raw alb_target_group_arn)
ALB=$(terraform output -raw alb_dns_name)
AWS="aws --endpoint-url=http://localhost:4566 --region us-east-1"    # note: inline, zsh won't split it
$AWS elbv2 deregister-targets --target-group-arn "$TG" --targets Id=192.168.122.138,Port=30080
$AWS elbv2 deregister-targets --target-group-arn "$TG" --targets Id=192.168.122.105,Port=30080
$AWS elbv2 register-targets   --target-group-arn "$TG" --targets Id=192.168.65.254,Port=30080

# (c) health-check accepts 404: Traefik returns 404 for a host-less probe = "Traefik is alive"
#     (JSON form required — the shorthand parser splits 200,404 into a list)
$AWS elbv2 modify-target-group --target-group-arn "$TG" --matcher '{"HttpCode":"200,404"}'
$AWS elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].{S:TargetHealth.State,T:Target.Id}' --output table   # -> healthy
```
Result: target `192.168.65.254:30080` = **healthy**. Verify the whole chain end-to-end through the ALB.
Floci publishes only `4566` to the host and its edge port routes the LB DNS to *S3* (host-based bucket
parsing), so the LB data-plane is reached from **inside Floci's network** (a busybox sharing its netns):
```bash
docker run --rm --network container:floci-docker-floci-1 busybox \
  wget -qO- -T6 "http://$ALB/api/hello"   # no Host header needed — Ingress is host-less (Floci rewrites Host anyway)
# {"message":"hello from the ROK-lab backend","host":"rok-backend-...","secret":"injected from Floci
#  Secrets Manager via ESO","time":"..."}   <- full path: ALB -> bridge -> Traefik -> backend -> ESO secret
```

> **Phase 8 checkpoint met:** GitOps (ArgoCD) deploys the chart from git; images pull from the local
> registry; ESO injects the secret; and the app is reachable through the **full ROK path** ALB → Traefik
> → pod. The `socat` bridge + host-target + host-less Ingress are Floci-topology accommodations, not part
> of the real AWS design (real ALB routes into the VPC and preserves the Host header).

### 8.5 — Access the app locally + the full request trace

The `socat` bridge (§8.4a) also doubles as the **local browser entry point**: it listens on the WSL2
host's `localhost:30080`, so — with the host-less Ingress — a plain request routes straight through.
```bash
curl -s http://localhost:30080/          | head -c 120   # frontend HTML (no Host header needed)
curl -s http://localhost:30080/api/hello                 # backend JSON with the ESO secret
# then open in the browser (Windows browser works too, via WSL2 mirrored localhost):
#   http://localhost:30080/
```
**What actually happens on `GET http://localhost:30080/`:**
```
Browser/curl (Windows or WSL2)  GET http://localhost:30080/
  │  localhost = WSL2 host (Windows reaches it via WSL2 mirrored networking)
  ▼
[1] socat @ WSL2 host 0.0.0.0:30080  ──splice TCP──▶ 192.168.122.138:30080
  │  host routes via its virbr0 gateway NIC (192.168.122.1) into the libvirt subnet.
  │  (bridge exists only because Floci can't reach libvirt — NOT part of real ROK)
  ▼
[2] rok-server VM :30080  = Traefik NodePort  (kube-proxy listens on :30080 every node)
  ▼
[3] Traefik pod — Ingress is HOST-LESS / path-based:  /api→rok-backend:8080, /→rok-frontend:80
  │  path "/" → rok-frontend
  ▼
[4] Service rok-frontend (ClusterIP :80) ──kube-proxy──▶ [5] rok-frontend pod (nginx) → index.html
  ▲
  │  page JS runs fetch("/api/hello") — same origin, repeats [1]→[3] with path "/api"
  ▼
[3'] Traefik "/api" → rok-backend:8080 → [6] rok-backend pod (node) → JSON
  │  SECRET_MESSAGE env ← k8s Secret rok-backend-secret ← ESO ← Floci Secrets Manager
  ▼
  {"message":"…","host":"rok-backend-…","secret":"injected from Floci Secrets Manager via ESO", …}
```
**This local path deliberately skips the ALB** — for a human at a browser, `host → socat → Traefik
NodePort` is the direct route; the ALB (§8.4) is validated separately. Real ROK equivalent:
`client → DNS → real ALB (in the VPC) → Traefik NodePort → same Ingress → Service → pod` (no socat; the
ALB reaches the nodes natively because it lives in the same network).

> **Phase 8 done.** Local browser access works; the full ROK request path is understood hop-by-hop.
---

## Phase 9.1 — in-cluster mailpit (test mail sink), the ROK way

ROK runs **mailpit** in-cluster as a throwaway mail sink for lower envs — no real email, no SES.
It's installed exactly like ROK's other add-ons: the upstream `jouve/mailpit` Helm chart + a
**values file** (`k8s/mailpit-values.yaml`, mirroring `rok-scaleout/manifests/values/mailpit_values.yaml`),
into a dedicated `mailhog` namespace. Same chart/image ROK pins (chart `0.32.5`, image
`axllent/mailpit:v1.29.6`) and the same security-context hardening; the lab drops only ROK's EBS PVC
(no storageClass here — ephemeral sink) and htpasswd auth (so the Phase-9.2 mailer sends plain SMTP).

```bash
helm repo add jouve https://jouve.github.io/charts
helm repo update
kubectl create namespace mailhog
helm install mailpit jouve/mailpit -n mailhog --version 0.32.5 -f k8s/mailpit-values.yaml
kubectl -n mailhog rollout status deploy/mailpit --timeout=180s
```
Result: one `mailpit` pod **Running** (non-root uid 1001, read-only rootfs, `emptyDir` for data since
persistence is off), and two ClusterIP services — `mailpit-http` (`:8025`, UI) and `mailpit-smtp`
(`:1025`, inbound mail). The mailer will target `mailpit-smtp.mailhog:1025` cross-namespace in 9.2.

### 9.1a — expose the UI host-less on `/mailpit` (reuse `localhost`, no Windows hosts file)

First attempt used a hostname Ingress (`mailpit.rok.local`) like ArgoCD — but Windows Chrome returned
`DNS_PROBE_FINISHED_NXDOMAIN`: the browser can't resolve that name, and WSL2's `/etc/hosts` doesn't help
a **Windows** browser (it reads `C:\Windows\System32\drivers\etc\hosts`). NXDOMAIN is a *resolution*
failure — upstream of socat, which is why the frontend (`localhost:30080`) still worked fine.

Fix (no per-rebuild Windows edit): serve mailpit under a base path and route it host-less.
- `mailpit.webroot: mailpit` in the values file → mailpit serves the UI + assets under `/mailpit`.
- Ingress is **host-less** on `path: /mailpit` (more specific than the frontend's `/`, so no collision).
Both reached through the same socat bridge + Traefik NodePort 30080 as the app.
```bash
kubectl apply -f k8s/mailpit-ingress.yaml
kubectl -n mailhog get pods,svc,ingress
```
Then open **`http://localhost:30080/mailpit`** — the empty mailpit inbox loads in Windows Chrome, no
hosts entry needed. Path: `browser → localhost:30080 (WSL2 mirrored) → socat → VM:30080 → Traefik
(/mailpit prefix) → mailpit-http:8025`.

> **9.1 done.** mailpit is an in-cluster test sink in `mailhog`, UI at `localhost:30080/mailpit`,
> SMTP waiting on `mailpit-smtp.mailhog:1025`. Next (9.2): a `mailer` workload that sends to it.
