# Commands Log — ROK Infra Learning Lab (Floci + real RKE2 VMs)

> Clean slate — 2026-09-24. Logs only commands that actually worked, written step-by-step as we go.
> See `PLAN.md` for the full design.

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
SSH in from the HOST using the variable from 3.1 (cloud-init done → passwordless).
`config.yaml`: token = shared join secret, node-ip pins identity, tls-san so host/agent trust the API cert, kubeconfig readable.
```bash
# ssh ubuntu@"$SERVER_IP"
virsh -c qemu:///system domifaddr rok-server
```
Then, **inside the rok-server VM**, paste this whole block. `NODE_IP` is auto-detected from
the VM's own interface, and `tee` writes the file atomically (no dropped last line like nano/
here-doc paste), then `cat` prints it back so you can eyeball all 6 lines:
```bash
NODE_IP="$(hostname -I | awk '{print $1}')"        # this VM's virbr0 IP, auto-detected
sudo mkdir -p /etc/rancher/rke2
sudo tee /etc/rancher/rke2/config.yaml >/dev/null <<EOF
token: rok-lab-shared-token
node-ip: ${NODE_IP}
tls-san:
  - ${NODE_IP}
  - rok-server
write-kubeconfig-mode: "0644"
EOF
sudo cat /etc/rancher/rke2/config.yaml             # verify: 6 lines, real IP substituted
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
SSH into the agent from the HOST using the variable from 4.1:
```bash
# ssh ubuntu@"$AGENT_IP"
virsh -c qemu:///system domifaddr rok-agent-1
```
Then, **inside the rok-agent-1 VM**, paste this block. The only value to fill is `SERVER_IP`
— the rok-server `<node-ip>` you echoed in 3.1; this agent's own `NODE_IP` is auto-detected:
```bash
SERVER_IP="<server-ip>"                            # <-- rok-server's <node-ip> from step 3.1
NODE_IP="$(hostname -I | awk '{print $1}')"        # this agent's own virbr0 IP, auto-detected
sudo mkdir -p /etc/rancher/rke2
sudo tee /etc/rancher/rke2/config.yaml >/dev/null <<EOF
server: https://${SERVER_IP}:9345
token: rok-lab-shared-token
node-ip: ${NODE_IP}
EOF
sudo cat /etc/rancher/rke2/config.yaml             # verify: 3 lines, real IPs substituted
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

---

## Full nuke — tear the whole lab down to a bare host

Wipes VMs, disks, base image, the `default` network, and reverses the Phase 0 host prep.
**Everything runs on the HOST** (not inside a VM). Exit any SSH sessions first.

> ⚠️ The step order below is load-bearing: **VMs are destroyed FIRST, the network LAST.**
> `net-destroy default` while a VM is still running rebuilds `virbr0` empty and leaves the
> VM's tap dangling → `ssh: No route to host` + an empty `net-dhcp-leases`. Purging libvirt
> while domains are still defined orphans their qcow2/ISO files. Follow the steps in order.

```bash
for vm in rok-server rok-agent-1; do
  virsh -c qemu:///system destroy "$vm" 2>/dev/null || true
  virsh -c qemu:///system undefine "$vm" || true
done

virsh -c qemu:///system list --all

# sudo rm -f /var/lib/libvirt/images/rok-server.qcow2  /var/lib/libvirt/images/rok-server-seed.iso \
#            /var/lib/libvirt/images/rok-agent-1.qcow2 /var/lib/libvirt/images/rok-agent-1-seed.iso \
#            /var/lib/libvirt/images/noble-server-cloudimg-amd64.img

sudo virsh -c qemu:///system net-destroy default
sudo virsh -c qemu:///system net-undefine default

sudo gpasswd -d jeffndegwa libvirt
sudo gpasswd -d jeffndegwa kvm
sudo systemctl disable --now libvirtd
sudo apt-get purge -y libvirt-daemon-system libvirt-clients virtinst qemu-utils genisoimage
sudo apt-get autoremove -y
```

> Not part of the cluster recreate loop: **Floci** stays up as-is, and **Terraform** state is already
> empty (we `terraform destroy`'d it this session). Re-applying Terraform is a separate step for later.

# Autostart the VMs on WSL2 launch

```bash
virsh -c qemu:///system autostart rok-server
virsh -c qemu:///system autostart rok-agent-1
```