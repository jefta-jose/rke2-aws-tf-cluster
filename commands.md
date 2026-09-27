# Commands Log — ROCK Infra Learning Lab (Floci + real RKE2 VMs)

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

## Phase 3 — rock-server VM (Ubuntu 24.04 cloud image on virbr0)

### 3.1 Build & boot the VM
Config lives in `vms/rock-server/` (heavily commented): `user-data` + `meta-data` (cloud-init: hostname + SSH key) and `build.sh` (downloads the Ubuntu 24.04 cloud image, builds a `cidata` seed ISO with genisoimage, makes a qcow2 overlay disk, then `virt-install --import`). One idempotent command:
```bash
sudo bash /home/jeffndegwa/rke2-aws-tf-cluster/vms/rock-server/build.sh
```
Result: VM `rock-server` created and booted (2 vCPU / 4 GB / 20 GB). Grab its virbr0 IP and
**save it in a HOST shell variable** so the SSH step already has it — no copy-pasting the raw
`<node-ip>`:


### 3.2 Install the RKE2 server + write config
Derive rock-server's IP into a HOST shell var (cloud-init done → passwordless SSH).
`config.yaml`: token = shared join secret, node-ip pins identity, tls-san so host/agent trust the API cert, kubeconfig readable.
```bash
SERVER_IP=$(virsh -c qemu:///system domifaddr rock-server | awk '/ipv4/ {print $4}' | cut -d/ -f1)
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
ssh ubuntu@"$SERVER_IP"
```

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
Result: after ~4 min (etcd + control plane + Canal CNI pulls), `rock-server` is `Ready` (control-plane,etcd), internal IP node-ip. Its kernel `6.8.0-139-generic` differs from the WSL2 host kernel — proof each node owns its kernel (separate netfilter/conntrack/cgroups), the reason the agent join is clean in VMs.

## Phase 4 — rock-agent-1 VM + clean RKE2 agent join

### 4.1 Build & boot the agent VM
Config in `vms/rock-agent-1/` (mirrors rock-server, hostname `rock-agent-1`, 2 vCPU / 4 GB). Reuses the base image already downloaded. On the HOST:
```bash
sudo bash /home/jeffndegwa/rke2-aws-tf-cluster/vms/rock-agent-1/build.sh
```

Grab the agent's virbr0 IP into a HOST variable, same as the server:


### 4.2 Install + configure the RKE2 agent
Derive both IPs into HOST shell vars (`SERVER_IP` = rock-server's node-ip, `AGENT_IP` = this worker):
```bash
SERVER_IP=$(virsh -c qemu:///system domifaddr rock-server | awk '/ipv4/ {print $4}' | cut -d/ -f1)
AGENT_IP=$(virsh -c qemu:///system domifaddr rock-agent-1 | awk '/ipv4/ {print $4}' | cut -d/ -f1)
echo "SERVER_IP=$SERVER_IP AGENT_IP=$AGENT_IP"
```
Write the agent config by **piping a script into the agent over SSH**, passing `SERVER_IP` as its
argument (no multi-line paste; the agent's own `NODE_IP` is auto-detected inside the VM):
```bash
ssh ubuntu@"$AGENT_IP" "sudo bash -s $SERVER_IP" < /home/jeffndegwa/rke2-aws-tf-cluster/scripts/write-rke2-agent-config.sh
```
`server` uses the **9345 supervisor port** (join endpoint), token must match the server, node-ip pins this worker's identity. Install in agent mode, PINNING the version to match the server (the `stable` channel briefly 404'd — pinning also enforces server/agent version parity):
```bash
ssh ubuntu@"$AGENT_IP"
```

```bash
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE="agent" INSTALL_RKE2_VERSION="v1.36.4+rke2r1" sh -
```

### 4.3 Start the agent + verify from the server
On the agent:
```bash
sudo systemctl enable --now rke2-agent.service
```
On the server: `kubectl get nodes -o wide`.
Result: agent dialed `<server-ip>:6443` HEALTHY→ACTIVE and registered cleanly (no host crash). Was briefly `NotReady` (`cni plugin not initialized`) while Canal finished; a few transient Docker Hub "image not found" pulls self-healed on RKE2 retry. After ~2 min: **both nodes `Ready`** (rock-server control-plane,etcd + rock-agent-1 worker). Phase 4 checkpoint met.
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
Derive rock-server's current virbr0 IP (DHCP — don't hardcode it):
```bash
SERVER_IP=$(virsh -c qemu:///system domifaddr rock-server | awk '/ipv4/ {print $4}' | cut -d/ -f1)
echo "SERVER_IP=$SERVER_IP"
mkdir -p ~/.kube
ssh ubuntu@"$SERVER_IP" 'cat /etc/rancher/rke2/rke2.yaml' | sed "s/127.0.0.1/$SERVER_IP/" > ~/.kube/rock-lab.yaml
chmod 600 ~/.kube/rock-lab.yaml
```

### B. Point THIS shell at the cluster (dies with the session)
```bash
export KUBECONFIG="$HOME/.kube/rock-lab.yaml"
kubectl get nodes -o wide
```
Result: both nodes `Ready` from the host — `rock-server` (control-plane,etcd, 192.168.122.138) and
`rock-agent-1` (worker, 192.168.122.105), both `v1.36.4+rke2r1`, containerd 2.3.4.
Session-only proof: `export` lives only in this shell. New terminal → `KUBECONFIG` unset → `kubectl`
falls back to `~/.kube/config` (which doesn't know this cluster) → can't reach it. To use the lab in a
future terminal, deliberately re-run the `export` line from step B.

> ⚠️ DHCP caveat: if `rock-server`'s IP changes on a later boot, `~/.kube/rock-lab.yaml` points at the
> stale IP. Re-run step A with the new `SERVER_IP` (grab it via `virsh -c qemu:///system domifaddr rock-server`).

## Phase 2 — Terraform the AWS base into Floci

Provider points at Floci (`localhost:4566`, dummy creds, skip flags). Provisions the network,
`development-rock-general-secret`, SQS `email` + `email-dlq` (FIFO), and IAM node role/policies. It also
provisions an ALB → NodePort 30080 target group + a WAFv2 WebACL, but those exist only to mirror ROCK's
infra — the lab does not use them (traffic reaches the cluster via socat, not the ALB; see 8.4/8.5).
```bash
cd /home/jeffndegwa/rke2-aws-tf-cluster/terraform
terraform init
terraform plan
terraform apply
```
Result: applied cleanly against Floci.

## Phase 5 (networking) — wire the compute world to Floci (outbound)

The lab is **two worlds that don't naturally know about each other**, and on real AWS a shared VPC
wires them for free. Locally we hand-wire the **outbound** path (pods → Floci); the inbound path
(user → cluster) uses a socat bridge, not the ALB — see 8.4.
- **AWS world** = Floci, a container on the host's Docker net, serving AWS APIs on `:4566`.
- **compute world** = the RKE2 VMs on libvirt `virbr0` (`192.168.122.0/24`).

### 5.0 Grab live IPs into shell vars (re-run per shell — DHCP drifts)
Node IPs are DHCP and change across boots, so derive them instead of hardcoding. The virbr0 gateway
(`HOST_IP`, what VMs use to reach Floci) is stable but we derive it too. Run on the HOST. (Comments
stripped: interactive zsh doesn't treat
`#` as a comment unless `setopt interactive_comments`, and it would tilde-expand a `~` inside one →
`no such user`.) `HOST_IP` is the stable virbr0 gateway (~192.168.122.1):
```bash
HOST_IP=$(ip -4 addr show virbr0 | awk '/inet / {print $2}' | cut -d/ -f1)
SERVER_IP=$(virsh -c qemu:///system domifaddr rock-server  | awk '/ipv4/ {print $4}' | cut -d/ -f1)
AGENT_IP=$(virsh -c qemu:///system domifaddr rock-agent-1 | awk '/ipv4/ {print $4}' | cut -d/ -f1)
printf 'HOST_IP=%s\nSERVER_IP=%s\nAGENT_IP=%s\n' "$HOST_IP" "$SERVER_IP" "$AGENT_IP"
```

### 5.1 VMs → Floci (outbound) — the road image pulls + ESO secret-sync ride on
Pods must *call* AWS (GetSecretValue via ESO, SQS) and pull images. From a VM the host — and thus
Floci — is the virbr0 gateway `$HOST_IP:4566` (Floci binds `*:4566`, so it's reachable). Prove
the path from inside a node:
```bash
ssh ubuntu@"$SERVER_IP" "curl -sS -o /dev/null -w 'floci http=%{http_code}\n' http://$HOST_IP:4566/ || echo UNREACHABLE"
```
Result: got an HTTP status back → VM→host→Floci path is open.

> The inbound front door (**user → cluster**) does NOT go through Floci's ALB — see 8.4 for why
> (Floci can't route into the libvirt subnet and rewrites the Host header), and how a socat bridge
> stands in for it.

> 5.3 (`/etc/hosts` for the mock Route53) is deferred to Phase 8 — nothing to resolve until a frontend
> ingress host exists.

## Phase 6.1 — expose the bundled Traefik on NodePort 30080

RKE2 ships Traefik as a **DaemonSet** (one pod per node) but its `rke2-traefik` Service defaults to
**ClusterIP** — nothing answers on a node port, so the socat bridge (8.4) would have nothing to
forward to. Customize a
*bundled* chart the RKE2-native way: a **`HelmChartConfig`** named after the chart (`rke2-traefik`,
`kube-system`); the helm-controller deep-merges its `valuesContent` and re-runs the install. Manifest
lives at `k8s/traefik/nodeport.yaml`; apply from the HOST:
```bash
export KUBECONFIG="$HOME/.kube/rock-lab.yaml"
kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/traefik/nodeport.yaml
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


---

## Phase 6.2 — External Secrets Operator → Floci Secrets Manager

Install ESO the RKE2-native way (no `helm` on the host): a **`HelmChart`** CR (`helm.cattle.io/v1`) in
`kube-system` — the bundled helm-controller pulls the chart and installs it in-cluster, same mechanism
that runs Traefik. Chart pinned to `external-secrets 2.11.0` (appVersion v2.11.0). Manifest at
`k8s/external-secrets/helmchart.yaml`; apply from the HOST:
```bash
export KUBECONFIG="$HOME/.kube/rock-lab.yaml"
kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/external-secrets/helmchart.yaml
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

Manifest at `k8s/external-secrets/floci-store.yaml` (two docs): a `floci-aws-creds` Secret holding dummy `test/test`
(safe to commit — only auths to the local mock) and a cluster-scoped `ClusterSecretStore`
`floci-secrets-manager` referencing those creds. This is just the ESO connectivity smoke-test — the
app's real secret sync uses **per-workload `SecretStore`s** rendered by the chart in Phase 8 (with creds
in the app namespace). Apply + confirm the store validates (proves ESO reaches Floci Secrets Manager
via the injected endpoint):
```bash
kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/external-secrets/floci-store.yaml
```

```bash
#give it some few seconds
kubectl get clustersecretstore # -> Valid / READY True
```
Result: store `Valid`/`READY True` — ESO authenticated to Floci and can read Secrets Manager. (Tip for
inspecting a synced Secret's keys later: `kubectl get secret <name> -o go-template='{{range $k,$v :=
.data}}{{$k}}{{"\n"}}{{end}}'` — `-o jsonpath` can't iterate a map's keys.) Phase 6.2 done.

---

## Phase 6.3 — ArgoCD (install via HelmChart CR, expose through Traefik, CLI login)

Same RKE2-native install pattern: an `argo-cd` **`HelmChart`** CR (chart `10.9.2`, appVersion `v3.5.3`)
into an `argocd` namespace. Exposed through the **existing Traefik** (the Phase 6.1 ingress) rather than
port-forward/NodePort. Key values in `k8s/argocd/install/helmchart.yaml`: `server.insecure: true` (argocd-server
serves plain HTTP on 8080 so Traefik routes without gRPC/TLS passthrough) and `server.rootpath: /argocd`
(serve the UI/API under a **sub-path** so a HOST-LESS Ingress can route it — no hostname, no `/etc/hosts`,
reached through the same socat bridge as the app). The chart's own Ingress is **disabled**
(`server.ingress.enabled: false`); our host-less Ingress lives in `k8s/argocd/install/ingress.yaml` (path
`/argocd`, class `traefik`), exactly like mailpit's `/mailpit`. Apply both from the HOST:
```bash
export KUBECONFIG="$HOME/.kube/rock-lab.yaml"
kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/argocd/install/helmchart.yaml
```

```bash
kubectl -n kube-system get job helm-install-argo-cd -w
```

```bash
kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/argocd/install/ingress.yaml
```

```bash
kubectl -n argocd get pods
```

```bash
kubectl -n argocd get ingress
```


### 6.3a — get password for login


```bash
PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo)
```

### 6.3b — open the ArgoCD web UI (no port-forward)

Host-less `/argocd` means the UI rides the **same front door as the app** through Traefik — **no
port-forward, no hosts file**. Two entry points depending on where the browser runs:
- **WSL2 side** (WSLg browser or curl): hit the node directly — `http://$SERVER_IP:30080/argocd`.
- **Windows Chrome:** it can't reach `192.168.122.0/24`, so bring up the **socat bridge** — the lab's
  single front door (§8.4). The helper script (re)starts it against rock-server's current IP:
```bash
bash /home/jeffndegwa/rke2-aws-tf-cluster/scripts/socat-bridge.sh
```
Then browse `http://localhost:30080/argocd` (admin + the initial password). 

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
```

```bash
cd /home/jeffndegwa/rke2-aws-tf-cluster/apps/backend
docker build -t rock-backend:v001 .
docker tag rock-backend:v001  localhost:5000/rock-backend:v001
```

```bash
cd /home/jeffndegwa/rke2-aws-tf-cluster/apps/frontend
docker build -t rock-frontend:v001 .
docker tag rock-frontend:v001  localhost:5000/rock-frontend:v001
```

```bash
docker push localhost:5000/rock-frontend:v001
docker push localhost:5000/rock-backend:v001
```

check images in the repo
```bash
curl -s http://localhost:5000/v2/_catalog
```

check repo can be reached from inside the VMs
```bash
SERVER_IP=$(virsh -c qemu:///system domifaddr rock-server | awk '/ipv4/ {print $4}' | cut -d/ -f1)
ssh ubuntu@"$SERVER_IP" curl -s http://192.168.122.1:5000/v2/_catalog
```

### 7.3 — Point RKE2 nodes at the registry

`vms/registries.yaml` (an `http://` endpoint = plain HTTP, no TLS flags needed) installed to
`/etc/rancher/rke2/registries.yaml` on **every** node, then RKE2 restarted (containerd reads it only at
start). Server restart bounces the control plane ~30–60s; both nodes returned `Ready`.
```bash
SERVER_IP=$(virsh -c qemu:///system domifaddr rock-server | awk '/ipv4/ {print $4}' | cut -d/ -f1)
AGENT_IP=$(virsh -c qemu:///system domifaddr rock-agent-1 | awk '/ipv4/ {print $4}' | cut -d/ -f1)
echo "SERVER_IP=$SERVER_IP AGENT_IP=$AGENT_IP"
```

```bash
for ip in $SERVER_IP $AGENT_IP; do
  scp vms/registries.yaml ubuntu@$ip:/tmp/registries.yaml
  ssh ubuntu@$ip "sudo mkdir -p /etc/rancher/rke2 && sudo mv /tmp/registries.yaml /etc/rancher/rke2/registries.yaml && sudo chown root:root /etc/rancher/rke2/registries.yaml"
done
```

```bash
ssh ubuntu@$SERVER_IP "sudo systemctl restart rke2-server"
```

```bash
ssh ubuntu@$AGENT_IP  "sudo systemctl restart rke2-agent"
```

```bash
kubectl get nodes
```

---

## Phase 8 — GitOps: ArgoCD deploys the workloads (map-driven chart)

### 8.3 — deploy: push, bootstrap the namespace, apply the apps

ArgoCD is pull-based, so push the chart first. Then create the release namespace and the Floci creds
the per-workload SecretStores read (creds live in the SAME namespace — the lab stand-in for ROCK's
IRSA), and apply the two apps that are live now (worker waits for Phase 9).

```bash
# MAKE SURE LATES CHART CHANGES ARE PUSHED TO GITHUB
```

```bash
kubectl create namespace rock-development
kubectl -n rock-development create secret generic floci-aws-creds \
  --from-literal=access-key-id=test --from-literal=secret-access-key=test
kubectl apply -f k8s/argocd/applications/rock-frontend-development.yaml
kubectl apply -f k8s/argocd/applications/rock-backend-development.yaml
```
Verify (ArgoCD auto-syncs in ~30–60s):
```bash
kubectl get pods,svc,ingress,externalsecret,secretstore -n rock-development
curl -s http://localhost:30080/api/hello; echo
```
Result: frontend + backend pods `1/1 Running` in `rock-development`; **images pulled from
`192.168.122.1:5000` by the kubelet (Phase 7 proven via GitOps, no manual pull)**; per-workload
SecretStores `Valid`, ExternalSecrets `SecretSynced`; `rock-backend-secret` carries the synced keys; the
curl (via the socat bridge → Traefik NodePort 30080 → host-less Ingress → ClusterIP → pod) returns the
JSON with the injected `SECRET_MESSAGE`.
**Gotcha:** ArgoCD health stays `Progressing` forever because Traefik doesn't populate
`Ingress.status.loadBalancer` (`LB={}`) and ArgoCD waits on it. Purely cosmetic — traffic works. Fix if
desired: set Traefik `providers.kubernetesIngress.ingressEndpoint` so it writes ingress status.

---

## Phase 9.1 — in-cluster mailpit (test mail sink), the ROCK way

ROCK runs **mailpit** in-cluster as a throwaway mail sink for lower envs — no real email, no SES.
It's installed exactly like ROCK's other add-ons: the upstream `jouve/mailpit` Helm chart + a
**values file** (`k8s/mailpit/values.yaml`, mirroring `rock-scaleout/manifests/values/mailpit_values.yaml`),
into a dedicated `mailhog` namespace. Same chart/image ROCK pins (chart `0.32.5`, image
`axllent/mailpit:v1.29.6`) and the same security-context hardening; the lab drops only ROCK's EBS PVC
(no storageClass here — ephemeral sink) and htpasswd auth (so the Phase-9.2 mailer sends plain SMTP).

```bash
helm repo add jouve https://jouve.github.io/charts
helm repo update
kubectl create namespace mailhog
helm install mailpit jouve/mailpit -n mailhog --version 0.32.5 -f k8s/mailpit/values.yaml
kubectl -n mailhog rollout status deploy/mailpit --timeout=180s
```
Result: one `mailpit` pod **Running** (non-root uid 1001, read-only rootfs, `emptyDir` for data since
persistence is off), and two ClusterIP services — `mailpit-http` (`:8025`, UI) and `mailpit-smtp`
(`:1025`, inbound mail). The mailer will target `mailpit-smtp.mailhog:1025` cross-namespace in 9.2.

### 9.1a — expose the UI host-less on `/mailpit` (reuse `localhost`, no Windows hosts file)

First attempt used a hostname Ingress (`mailpit.rock.local`) like ArgoCD — but Windows Chrome returned
`DNS_PROBE_FINISHED_NXDOMAIN`: the browser can't resolve that name, and WSL2's `/etc/hosts` doesn't help
a **Windows** browser (it reads `C:\Windows\System32\drivers\etc\hosts`). NXDOMAIN is a *resolution*
failure — upstream of socat, which is why the frontend (`localhost:30080`) still worked fine.

Fix (no per-rebuild Windows edit): serve mailpit under a base path and route it host-less.
- `mailpit.webroot: mailpit` in the values file → mailpit serves the UI + assets under `/mailpit`.
- Ingress is **host-less** on `path: /mailpit` (more specific than the frontend's `/`, so no collision).
Both reached through the same socat bridge + Traefik NodePort 30080 as the app.
```bash
kubectl apply -f k8s/mailpit/ingress.yaml
kubectl -n mailhog get pods,svc,ingress
```
Then open **`http://localhost:30080/mailpit`** — the empty mailpit inbox loads in Windows Chrome, no
hosts entry needed. Path: `browser → localhost:30080 (WSL2 mirrored) → socat → VM:30080 → Traefik
(/mailpit prefix) → mailpit-http:8025`.

> **9.1 done.** mailpit is an in-cluster test sink in `mailhog`, UI at `localhost:30080/mailpit`,
> SMTP waiting on `mailpit-smtp.mailhog:1025`. Next (9.2): a `mailer` workload that sends to it.

---

## Phase 9.2 — the `mailer` workload (frontend → SMTP → mailpit)

A new **server workload** in the map-driven chart: `rock-mailer`, a dependency-free Node service
(`apps/mailer/server.js`) exposing `POST /api/email {to,subject,body}`. It opens a raw SMTP
conversation (no auth/TLS) with the in-cluster mailpit sink and sends the message. `SMTP_HOST`/
`SMTP_PORT` are **not hardcoded** — they come from `development-rock-general-secret` via ESO
(`Smtp__Host`/`Smtp__Port`), the same config-from-Secrets-Manager pattern the backend uses.

Chart wiring:
- `workloads.mailer` in `values.yaml` ships `enabled: false` (like worker) so the frontend/backend
  apps stay clean; image + `remoteKey: development-rock-general-secret` in `values-development.yaml`.
- Ingress path `/api/email` — more specific than backend's `/api`, so Traefik routes them apart.
- `secretEnv: {SMTP_HOST: Smtp__Host, SMTP_PORT: Smtp__Port}` — ESO's `dataFrom.extract` pulls every
  key of the general secret into `rock-mailer-secret`; these two become env vars.
- New ArgoCD app `k8s/argocd/applications/rock-mailer-development.yaml` (flips mailer on, disables the rest);
  `mailer.enabled=false` added to the backend/frontend/worker apps for isolation.

**Terraform change:** the general secret's `Smtp__Host` moved `mailpit` → **`mailpit-smtp.mailhog`**
(mailpit now lives in the `mailhog` namespace as service `mailpit-smtp`; cross-namespace DNS).

```bash
cd /home/jeffndegwa/rke2-aws-tf-cluster/apps/mailer
docker build -t rock-mailer:v001 .

docker tag rock-mailer:v001 localhost:5000/rock-mailer:v001
docker push localhost:5000/rock-mailer:v001

kubectl apply -f /home/jeffndegwa/rke2-aws-tf-cluster/k8s/argocd/applications/rock-mailer-development.yaml
```