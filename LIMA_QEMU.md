# Phase 0 — Virtualization, KVM, Lima/QEMU, and Linux Groups

---

## 1. EC2 intuition 
> "Virtualization is how we get EC2 instances — it's one piece of hardware, and when we request an
> EC2 we get a slice of it."

Yes. That's exactly it. One big physical server in an AWS data center runs many customers' EC2
instances at once. Each instance *thinks* it's a whole computer — it has its own CPU, RAM, disk,
kernel, network card — but really it's a **software-defined slice** of the one physical machine.
The thing that carves up the real hardware into these convincing illusions is called a
**hypervisor**.

```
        ONE physical server (real CPU, RAM, disk, NIC)
        ┌───────────────────────────────────────────────┐
        │                 Hypervisor                      │  ← carves the hardware into slices
        │   ┌─────────┐   ┌─────────┐   ┌─────────┐        │
        │   │  VM  A  │   │  VM  B  │   │  VM  C  │        │  ← each VM: own kernel, own OS,
        │   │ own OS  │   │ own OS  │   │ own OS  │        │     own fake CPU/RAM/disk/NIC
        │   └─────────┘   └─────────┘   └─────────┘        │
        └───────────────────────────────────────────────┘
```

A **VM (virtual machine)** = one of those slices. On AWS the hypervisor is Amazon's own (Nitro).
On *our* laptop, we're playing the role of AWS: **we** run a hypervisor and **we** carve out VMs.
That's the whole point of Phase 0 — proving our WSL2 host can be a mini-AWS for compute.

### The one distinction that matters: VM vs container

The old crash happened because we used **containers** instead of VMs. The difference:

| | **Container** (Docker) | **Virtual Machine** (what we're doing now) |
|---|---|---|
| Shares the host **kernel**? | **Yes** — all containers use the host's one Linux kernel | **No** — each VM boots its *own* kernel |
| Isolation | Processes fenced off, but same kernel underneath | A whole separate computer |
| Networking internals | Shares host's **one** netfilter/iptables/conntrack | Its **own** networking stack |
| Weight | Light, fast | Heavier (boots a real OS) |

The RKE2 crash: two RKE2 nodes as containers both tried to reprogram the host's **single** shared
kernel networking (iptables/conntrack) at once → they collided → host networking died. VMs fix this
because each VM has its **own** kernel and its own networking tables — nothing to collide over. When
we saw the throwaway VM report kernel `7.0.0-28-generic` while our WSL2 host is `6.18-microsoft`,
that different kernel version was the **proof** the VM is truly separate. That single line is the
reason this whole approach works.

---

## 2. The hypervisor stack we installed: KVM + QEMU + Lima

We didn't install "a hypervisor" — we installed three cooperating layers. Here's who does what:

- **KVM** (Kernel-based Virtual Machine) — a feature *built into the Linux kernel* that lets a VM's
  virtual CPU run directly on the real CPU at full speed, using hardware support baked into modern
  Intel/AMD chips. This is the "hardware acceleration." Without it, VMs still work but the CPU has
  to be *emulated* in software → painfully slow. KVM is exposed to programs as a special file:
  **`/dev/kvm`**. (More on that file in §3 — it's the reason for the whole "group" saga.)

- **QEMU** — the actual machine emulator. It fakes all the *other* hardware a VM needs that KVM
  doesn't do: the virtual disk, the virtual network card, the BIOS, etc. QEMU + KVM together =
  a fast, complete virtual computer. (You saw `qemu-system-x86_64 --version` → QEMU 10.2.1.)

- **Lima** — a friendly manager *on top of* QEMU. Raw QEMU commands are enormous and fiddly. Lima
  wraps them: it downloads a ready-made Ubuntu image, boots it under QEMU, sets up SSH, and gives us
  simple verbs like `limactl start` / `limactl shell`. Think of Lima as the "control panel," QEMU as
  the "engine," KVM as the "turbocharger." (You saw `limactl --version` → Lima 2.2.0.)

```
   You  →  limactl (Lima)  →  QEMU  →  /dev/kvm  →  real CPU
           (control panel)   (engine)  (turbo)     (hardware)
```

We chose Lima over an alternative called **multipass** because Lima is a single self-contained
binary that doesn't need extra background daemons (`snap`/systemd) — simpler on WSL2.

---

## 3. Why the "group" saga happened — Linux permissions in 5 minutes

To use the KVM turbocharger, QEMU has to open the file **`/dev/kvm`**. In Linux, *everything*
including hardware is represented as a file, and every file has an owner and permissions. This is
where the commands you'd never run before come in. Let's decode them.

### `ls -l /dev/kvm` → who is allowed to touch the KVM device
```
crw-rw---- 1 root kvm 10, 232 ... /dev/kvm
│└──┬──┘     │    │
│   │        │    └─ group owner:  "kvm"
│   │        └────── user  owner:  "root"
│   └───────────── permissions: owner(rw-) group(rw-) everyone-else(---)
└─ "c" = character device (a piece of hardware, not a normal file)
```
Read this as three permission slots:
- **owner `root`**: `rw-` → can read+write
- **group `kvm`**: `rw-` → can read+write
- **everyone else**: `---` → *nothing*

So: unless you are `root`, the **only** way to touch `/dev/kvm` is to be a **member of the `kvm`
group**. You weren't → QEMU would have been locked out of hardware acceleration.

### What a Linux "group" is
A **group** is just a named bucket of users, used to grant shared access to things. Instead of
giving every individual user permission to the KVM device, Linux gives the *group* `kvm` permission,
and then you get access by *being put into that group*. Same idea as an IAM group in AWS granting a
policy to everyone in it.

### `id | tr ',' '\n' | grep -i kvm` → am I in that group?
- `id` prints your user ID and **all the groups you belong to** (a long comma-separated line).
- `tr ',' '\n'` = "translate": swaps every comma for a newline, so each group lands on its own line
  (just makes it readable/greppable).
- `grep -i kvm` = filter to only lines containing "kvm" (`-i` = case-insensitive).

First run: printed nothing for kvm → **not a member** → no access. That's the "NOT in kvm group".

### `[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "..."` → the actual access test
Those square brackets are Linux's **test** command. `-r file` asks "can *I* read this?", `-w` asks
"can I write it?". `&&` means "and only if the previous succeeded." So the whole line means:
"if I can read AND write /dev/kvm, print the ✔, otherwise print the failure message." A direct,
honest check of reality rather than guessing.

### The fix: `sudo usermod -aG kvm $USER`
- `sudo` = run this as the superuser (`root`) — modifying group membership is an admin action.
- `usermod` = "modify a user account."
- `-aG kvm` = **a**dd me to the **G**roup `kvm` (the `-a` = *append*; without it you'd get kicked
  out of your other groups — a classic footgun).
- `$USER` = a shell variable holding your username, so we don't hardcode it.

### `newgrp kvm` — why we needed it immediately
Group membership is normally read **once, at login**. So right after `usermod`, your *current*
terminal still doesn't know you're in `kvm` — you'd have to fully log out and back in. `newgrp kvm`
is the shortcut: it starts a fresh shell that **re-reads your groups now**, so `kvm` takes effect in
this session without logging out. After that, the same read/write test printed **`991(kvm)`** and
**`KVM readable+writable ✔`** — turbocharger unlocked.

> Takeaway: the entire "group" detour was one thing — *earning permission to use the CPU's
> virtualization feature* by joining the group that owns `/dev/kvm`.

---

## 4. Launching and inspecting the throwaway VM

### `limactl start --name=throwaway --vm-type=qemu --cpus=2 --memory=2 --disk=10 --tty=false template://default`
Told Lima: build a VM named `throwaway`, run it on QEMU, give it 2 virtual CPUs, 2 GB RAM, a 10 GB
virtual disk, don't ask me interactive questions (`--tty=false`), and base it on Lima's default
Ubuntu image (`template://default`). On first run it **downloaded** that Ubuntu cloud image (~700 MB)
— a pre-baked disk file — then booted it. This is precisely the AWS moment: "give me an instance of
this size from this image." Our `template://default` is the equivalent of an EC2 **AMI**.

### `limactl shell throwaway -- bash -c '...'`
`limactl shell` drops you *inside* the running VM (like `ssh` into an EC2 box). Everything after it
ran **in the VM, not on your host**. What each probe told us:
- `uname -a` → the VM's kernel: `7.0.0-28-generic` — **different from the host** = truly separate machine. ✅
- `ip -4 addr show` → the VM's own IP `192.168.5.15/24` on `eth0` — its own virtual network card. ✅
- `curl -sSI https://get.rke2.io | head -1` → `HTTP/2 200` — the VM can resolve DNS and reach the
  internet over HTTPS, *and* specifically reach the RKE2 installer we'll use in Phase 3. ✅

### The `ping` "failure" that isn't a failure
`ping -c2 8.8.8.8` reported 100% packet loss — yet `curl` to a website worked. Both can be true.
`ping` uses a protocol called **ICMP**; Lima/QEMU's default **user-mode ("slirp") networking**
gives the VM outbound internet by quietly translating its **TCP/UDP** traffic (web, SSH, package
installs — the things we actually need) but it **does not carry ICMP**. So `ping` looks dead while
real traffic flows fine. **Lesson: on these VMs, test connectivity with `curl`/TCP, never `ping`.**
Later, when we need the host and VMs to talk to each other directly (ALB → NodePort in Phase 5),
we'll switch to a more capable network mode — but for "can the VM reach the world," this passed.

---

## 5. One-paragraph summary

We proved our WSL2 laptop can act like AWS's compute side: it can run a **hypervisor** (KVM in the
kernel + QEMU emulating the rest, driven by **Lima**) that boots a **virtual machine** — a slice of
the real hardware with its **own kernel** and network stack. Getting there meant unlocking the CPU's
virtualization feature by joining the Linux **`kvm` group** that owns the `/dev/kvm` device. The
throwaway VM booted with its own kernel and reached the internet, so the VM path is viable — and
because each VM has its own kernel, the multi-node RKE2 networking crash that killed the
container-based attempt cannot happen here. **Phase 0 = GO.**
