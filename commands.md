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

### 6.2a — ClusterSecretStore + a synced ExternalSecret

Manifest at `k8s/eso-floci-store.yaml` (three docs): a `floci-aws-creds` Secret holding dummy `test/test`
(safe to commit — only auths to the local mock), a cluster-scoped `ClusterSecretStore`
`floci-secrets-manager` referencing those creds, and a verification `ExternalSecret` that `extract`s all
keys of `development-rok-general-secret` into a k8s Secret `rok-general-secret` in `default`. Apply +
verify:
```bash
kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/eso-floci-store.yaml
kubectl get clustersecretstore floci-secrets-manager
kubectl -n default get externalsecret rok-general-secret
kubectl -n default get secret rok-general-secret -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```
**Gotcha:** to list a Secret's *keys*, use `-o go-template` with `{{range $k,$v := .data}}` — kubectl
`-o jsonpath` cannot iterate a map's keys (`{range $k,$v := .data}` is go-template syntax, silently
prints nothing under jsonpath). Result: store `Valid`/`READY True`, ExternalSecret `SecretSynced`/`True`,
target secret carries `ConnectionStrings__Default`, `Smtp__Host`, `Smtp__Port`; decoding `Smtp__Host`
→ `mailpit`, proving the value round-tripped Floci Secrets Manager → ESO → k8s Secret. Phase 6.2 done.

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

## Phase 8 — GitOps: ArgoCD deploys frontend + backend

### 8.1 / 8.2 — the `rok-app` Helm chart (`charts/rok-app`)

One small chart mirroring ROK's split: **compute** (`therok_deployment`) = frontend + backend
Deployments + **ClusterIP** Services; **infra** (`therok_v2`) = `ExternalSecret` + Traefik `Ingress`.
Notes:
- App Services are **ClusterIP**, not NodePort — the only NodePort in the path is Traefik's `30080`
  (Phase 6). Path: `ALB :80 → Traefik NodePort 30080 → Ingress → ClusterIP svc`.
- `imagePullSecrets` kept as an (empty) value to mirror ROK's `aws-registry`, but our registry is open.
- Backend gets `SECRET_MESSAGE` from k8s Secret `rok-general-secret` via `secretKeyRef`.
- Added `SECRET_MESSAGE` to the Floci secret in `terraform/main.tf` (`development_secret`) + `terraform
  apply`. Verify: `aws --endpoint-url=http://localhost:4566 secretsmanager get-secret-value
  --secret-id development-rok-general-secret --query SecretString --output text` shows all 4 keys.
- **ESO ownership split** to avoid a duplicate `ExternalSecret`: `k8s/eso-floci-store.yaml` now holds
  only the bootstrap (creds Secret + `ClusterSecretStore`); the app `ExternalSecret` lives in the chart.
```bash
helm lint charts/rok-app
helm template rok-app charts/rok-app   # renders: 2 Deploys, 2 Svcs, Ingress, ExternalSecret
```
Result: lint clean, render shows correct image refs, backend `env: SECRET_MESSAGE`, Ingress
(`/api`→backend, `/`→frontend, host `rok.local`), and the `ExternalSecret`.