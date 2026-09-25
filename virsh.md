`virsh` is basically the **command-line tool you use to talk to libvirt and manage VMs**.

Think of the architecture like this:

```text
                 YOU
                  │
                  │ virsh commands
                  ▼
              ┌─────────┐
              │ libvirt │
              └────┬────┘
                   │
                   ▼
              ┌─────────┐
              │  QEMU   │
              │  + KVM  │
              └────┬────┘
                   │
                   ▼
                VM
```

### What is each one?

**KVM**

Provides the Linux kernel's hardware virtualization capability.

```text
KVM = makes the CPU able to efficiently run virtual machines
```

**QEMU**

Actually emulates/provides the virtual hardware:

```text
virtual CPU
virtual disk
virtual NIC
virtual CD-ROM
```

**libvirt**

Provides a management layer around virtualization.

It keeps track of things like:

```text
VM name
CPU
RAM
disks
network
VM state
```

**virsh**

Is the CLI client for libvirt.

So when you type:

```bash
virsh list
```

you're basically saying:

> "Hey libvirt, show me the VMs."

---

## For example

Your script has:

```bash
virsh -c qemu:///system dominfo rok-server
```

Break that down:

```text
virsh
 │
 ├── -c qemu:///system
 │       │
 │       └── connect to the system libvirt instance
 │
 └── dominfo rok-server
         │
         └── give me information about this VM
```

`domain` is libvirt's terminology for a VM.

So:

```text
domain = VM
```

---

### Other commands you'll probably use

See VMs:

```bash
virsh list --all
```

Start:

```bash
virsh start rok-server
```

Stop gracefully:

```bash
virsh shutdown rok-server
```

Force stop:

```bash
virsh destroy rok-server
```

See information:

```bash
virsh dominfo rok-server
```

See the VM's IP:

```bash
virsh domifaddr rok-server
```

Connect to its console:

```bash
virsh console rok-server
```

---