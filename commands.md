# Commands Log — ROK Infra Learning Lab (Floci + real RKE2 VMs)

A record of the commands that actually worked in each phase, with a one-line note on what each does.
Compute = real RKE2 in Lima/QEMU VMs; "AWS" = Floci emulator in Docker. See `PLAN.md` for the design.
Host: WSL2 (Linux 6.18 microsoft-standard-WSL2), 10 vCPU / ~9.7 GiB RAM, `/dev/kvm` present.

---

## Phase 0 — Prerequisites & VM toolchain

### Step 0.1 — Inventory the host toolchain

```bash
docker --version ; docker compose version ; terraform version ; kubectl version --client ; nproc ; free -h
```

**Result:** Present — Docker 29.8.0, Compose v5.5.1, Terraform v1.16.3, kubectl v1.36.1.
Missing (install just-in-time) — helm, aws CLI, VM tools. Resources: 10 vCPU, 9.7 GiB RAM.
Decision: RAM is tight → run lean (server VM ~3 GB, agent ~2 GB), defer RDS SQL Server (Phase 11).

### Step 0.2 — Install Lima + QEMU (VM toolchain)

```bash
# QEMU + helpers
sudo apt-get update && sudo apt-get install -y qemu-system-x86 qemu-utils unzip

# Lima (latest release binary → /usr/local)
LIMA_VER=$(curl -fsSL https://api.github.com/repos/lima-vm/lima/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
curl -fsSL "https://github.com/lima-vm/lima/releases/download/${LIMA_VER}/lima-${LIMA_VER#v}-Linux-x86_64.tar.gz" | sudo tar -C /usr/local -xzf -

# Confirm
limactl --version ; qemu-system-x86_64 --version | head -1 ; ls -l /dev/kvm
```

**Result:** Lima **2.2.0**, QEMU **10.2.1**, `/dev/kvm` present. VM toolchain ready.
Tool choice: **Lima** over multipass (no snap/systemd daemon dependency; single binary over QEMU/KVM).

### Step 0.3 — Grant KVM hardware access + throwaway VM go/no-go

`/dev/kvm` was `root:kvm` mode `0660` and the user was not in the `kvm` group → QEMU could not
open it (would fall back to slow software emulation). Add the user to the `kvm` group so QEMU gets
hardware acceleration; group change needs a new login session, so activate it now with `newgrp`.

```bash
sudo usermod -aG kvm $USER          # persistent membership (takes effect on next login)
newgrp kvm                          # activate the group in the current shell
# verify QEMU can read+write the KVM device:
id | tr ',' '\n' | grep -i kvm && [ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM readable+writable ✔"
```

**Result:** now shows `991(kvm)` and `KVM readable+writable ✔`. QEMU will use hardware acceleration.

Launch one throwaway VM (2 vCPU / 2 GB / 10 GB) to confirm boot + network before committing to the
VM path. First run downloads an Ubuntu cloud image (~700 MB), then caches it for later VMs.

```bash
limactl start --name=throwaway --vm-type=qemu --cpus=2 --memory=2 --disk=10 --tty=false template://default
limactl shell throwaway -- bash -c 'uname -a; ip -4 addr show | grep inet; ping -c2 8.8.8.8; curl -sSI https://get.rke2.io | head -1'
```

**Result:** VM booted with its **own kernel** `7.0.0-28-generic` (host is `6.18 …microsoft-standard-WSL2`
→ proves separate kernel per node, the whole reason we use VMs), own IP `192.168.5.15/24` on `eth0`
(Lima user-mode NAT), and `curl https://get.rke2.io` returned `HTTP/2 200` (DNS + HTTPS/TCP work).
**Phase 0 = GO.**

**Gotcha:** `ping 8.8.8.8` shows 100% loss inside the VM — this is normal for Lima/QEMU **user-mode
(slirp) networking**, which does not forward ICMP but does forward TCP/UDP (curl 200 proves outbound
is fine). Don't use `ping` to test VM connectivity here; use `curl`/TCP. Later phases needing
routable host↔VM traffic (ALB → NodePort, Phase 5) will use a proper bridged/socket_vmnet network.

Teardown of the throwaway once verified:

```bash
limactl stop throwaway && limactl delete throwaway
```
