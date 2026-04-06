# nomad-worker-setup

HashiCorp Nomad cluster setup for servers and workers, targeting OpenSUSE-based
systems running on bare metal, VMs, or WSL2 on Windows 11.

## Requirements

- OpenSUSE Leap 15.x, Leap 16.x, Tumbleweed, or Slowroll
- Bare metal, VM, or WSL2 (Windows 11 Pro, 22H2 or later recommended)
- `sudo` access on each node

---

## Scripts

### `nomad-setup.sh` — Install and configure Nomad

Installs Nomad, generates mTLS certificates, deploys configuration, and
sets up a systemd service. Detects GPU, CPU, RAM, WSL2, SELinux, and AppArmor
automatically.

**Server (run first):**
```bash
./nomad-setup.sh --server
```

Generates all mTLS certificates in `/etc/nomad.d/tls/`. After running,
copy three files to each worker node (see `tls/README.md`):

```bash
scp /etc/nomad.d/tls/nomad-agent-ca.pem          user@worker:/tmp/tls/
scp /etc/nomad.d/tls/global-client-nomad.pem     user@worker:/tmp/tls/
scp /etc/nomad.d/tls/global-client-nomad-key.pem user@worker:/tmp/tls/
```

**Worker:**
```bash
./nomad-setup.sh --worker --server-ip <IP> --tls-dir /tmp/tls
# or
./nomad-setup.sh --worker --server-host <hostname> --tls-dir /tmp/tls
```

After setup, activate the Nomad CLI environment:
```bash
source /etc/nomad.d/nomad-env.sh
nomad node status
```

---

### `ssh-setup.sh` — Harden and configure sshd

Installs OpenSSH server with:
- ed25519 host key only (RSA/DSA/ECDSA removed)
- Public key authentication only (passwords disabled)
- Strong ciphers, key exchange algorithms and MACs only
- sshd enabled as a systemd service

On usrmerge systems (Tumbleweed, Leap 16+) the script detects vendor defaults
in `/usr/etc/ssh/` and warns about any settings not covered by the new config
before writing the admin override to `/etc/ssh/`.

```bash
./ssh-setup.sh                                        # uses keys/*.pub automatically
./ssh-setup.sh --pubkey "ssh-ed25519 AAAA... user@host"
./ssh-setup.sh --pubkey-file ~/.ssh/id_ed25519.pub
./ssh-setup.sh --port 2222 --user nomad
```

Public keys are safe to commit — place `.pub` files in `keys/` and they will
be added to `authorized_keys` on every node. See `keys/README.md`.

---

### `harden-os.sh` — OS hardening

Hardens the system with:
- System updates and removal of unnecessary packages
- sysctl hardening (ASLR, ptrace restriction, network)
- Core dumps disabled
- PAM: account lockout (5 attempts → 10 min) and password policy
- Login banners
- auditd with rules for identity, SSH, Nomad, cron and kernel modules
- MAC framework: AppArmor or SELinux (see below)
- firewalld (VM and bare metal only — skipped on WSL2)
- FIPS support via `patterns-base-fips` (VM and bare metal only)

**MAC framework selection:**
- WSL2 → AppArmor enabled automatically
- VM / bare metal → prompts to choose AppArmor or SELinux
  - Leap 15.x, Tumbleweed, Slowroll → AppArmor is default
  - Leap 16+, SLES 16+ → SELinux is default
  - If SELinux is unavailable the script explains why and offers AppArmor

```bash
./harden-os.sh
./harden-os.sh --skip-firewalld
./harden-os.sh --skip-mac
./harden-os.sh --skip-fips
```

---

### `wsl-firewall-setup.ps1` — Windows Firewall rules for WSL2

Run on the **Windows host** (PowerShell as Administrator) to open the
necessary ports for Nomad and set up port forwarding to the WSL2 VM.
Detects WSL2 networking mode (`nat`, `mirrored`, `bridged`) automatically
from `.wslconfig`.

```powershell
# Worker node — opens port 4646 only
.\wsl-firewall-setup.ps1 -Mode worker

# Server node — opens ports 4646, 4647, 4648
.\wsl-firewall-setup.ps1 -Mode server

# Older Windows / non-Pro editions
.\wsl-firewall-setup.ps1 -Mode worker -Legacy
```

If multiple WSL2 distros are installed the script prompts you to select one.

---

### `wsl-autostart-setup.ps1` — Auto-start WSL2 and Nomad at logon

Run on the **Windows host** (PowerShell as Administrator) to register a
scheduled task that starts the WSL2 distro (and therefore Nomad via systemd)
automatically at logon.

```powershell
# Basic setup — prompts for distro and memory reclaim mode
.\wsl-autostart-setup.ps1

# Dedicated worker: disable sleep, auto-logon, lock screen after boot
.\wsl-autostart-setup.ps1 -Distro Ubuntu-24.04 -PreventSleep -AutoLogon -LockAfterLogon
```

**Memory reclaim modes (prompted interactively):**
- `gradual` — slowly returns unused RAM, best for dedicated worker nodes
- `dropcache` — aggressively frees RAM when idle, best for gaming PCs that
  also run Nomad

**Note:** `-AutoLogon` configures everything except the password. Set the
password separately using `netplwiz` or
[Sysinternals Autologon](https://learn.microsoft.com/sysinternals/downloads/autologon).

---

## Directory structure

```
nomad-worker-setup/
├── config/                    Nomad HCL templates and systemd service file
│   ├── nomad-server.hcl       Server configuration (mTLS enabled)
│   ├── nomad-client.hcl.tpl   Worker configuration template
│   ├── nomad-env.sh           Shell environment for Nomad CLI with mTLS
│   ├── nomad.service          systemd service unit
│   └── ...                    sysctl, limits, AppArmor, SELinux configs
├── keys/                      SSH public keys (safe to commit, see keys/README.md)
├── tls/                       Staging area for mTLS certificates (gitignored)
├── nomad-setup.sh             Nomad install and configuration
├── ssh-setup.sh               SSH server hardening
├── harden-os.sh               OS hardening
├── wsl-firewall-setup.ps1     Windows Firewall rules (run on Windows host)
└── wsl-autostart-setup.ps1    WSL2 auto-start task (run on Windows host)
```

## Recommended setup order

1. **Each node:** `./harden-os.sh`
2. **Each node:** `./ssh-setup.sh`
3. **Server:** `./nomad-setup.sh --server`
4. Copy TLS certificates to each worker (see `tls/README.md`)
5. **Each worker:** `./nomad-setup.sh --worker --server-ip <IP> --tls-dir tls/`
6. **Windows host (WSL2 only):** `.\wsl-firewall-setup.ps1 -Mode worker/server`
7. **Windows host (WSL2 only):** `.\wsl-autostart-setup.ps1`
