# macvm + Tart runbook (Apple Virtualization)

Two layers — do not conflate:

| Layer | Owner | Notes |
|---|---|---|
| **Hypervisor + disk** | **Tart** on the **macos** host | Apple **Virtualization.framework**; disk under `~/.tart/vms/` — **never** in this flake / Nix store |
| **Guest nix-darwin** | `darwinConfigurations.macvm` | Activate as **`aloshy`** |

`nix run .#nixvm` is a different product (throwaway NixOS/QEMU). **macvm ≠ nixvm.**

**Do not wipe a healthy guest.** If `nix run .#macvm-tart-doctor` exits 0, keep the disk and only re-activate when config changes.

## Prerequisites (host)

- `macos` activated; flake packages build `tart` (unfree, from nixpkgs).
- Operator SSH key at `~/.ssh/id_ed25519` (authorized on the guest after `#macvm` activate).
- Run all `macvm-tart-*` apps on the **host**, not in the guest.

## Greenfield path (ordered)

### 1. Create from Apple IPSW

```bash
# Latest supported restore image from Apple (large download; cached by Tart)
nix run .#macvm-tart-create

# Or a local/official IPSW path/URL
nix run .#macvm-tart-create -- --ipsw=/path/to/UniversalMac_….ipsw
```

Defaults: 80 GB disk, 4 CPUs, 8 GB RAM (`MACVM_TART_DISK_GB` / `_CPUS` / `_MEMORY_MB` override).

Disk appears under `~/.tart/vms/macvm` — not in git, not in the store.

### 2. First boot + Setup Assistant

```bash
nix run .#macvm-tart-start
```

Complete macOS setup in the Tart window. Create login user **`aloshy`** (must match the flake identity). Enable **Remote Login (SSH)** in System Settings → General → Sharing.

### 3. First guest activation

Inside the guest as **`aloshy`**, with Determinate Nix installed:

```bash
sudo nix run github:kattakath/nix-config#macvm
```

That lands Apple’s `sshd` (keys-only, operator pubkey via nix-darwin), passwordless sudo, Screengrab symlink agent, lean Homebrew.

### 4. Day-to-day (host)

```bash
nix run .#macvm-tart-start
nix run .#macvm-tart-ip
nix run .#macvm-tart-ssh -- uname -a
nix run .#macvm-tart-ssh -- sudo nix run --refresh github:kattakath/nix-config#macvm
nix run .#macvm-tart-stop
nix run .#macvm-tart-doctor
```

Private home modules (path-sync, not guest GitLab SSH):

```bash
# From private flake checkout on host:
#   tar -C ~/path/to/nix-personal -cf - . | \
#     nix run .#macvm-tart-ssh -- 'mkdir -p ~/nix-personal && tar -C ~/nix-personal -xf -'
#   nix run .#macvm-tart-ssh -- sudo nix run /Users/aloshy/nix-personal#macvm
```

## Screengrab share

`macvm-tart-start` always attaches:

```text
--dir=Screengrab:$HOME/Pictures/Screengrab
```

Guest: `/Volumes/My Shared Files/Screengrab` → `~/Pictures/Screengrab` (symlink via `hosts/macvm.nix`). Restart the VM after host path changes.

## Clipboard

Tart enables clipboard sharing by default. Full fidelity on macOS guests may need [tart-guest-agent](https://github.com/cirruslabs/tart-guest-agent).

## Commands

| App | Role |
|---|---|
| `macvm-tart-create` | `tart create --from-ipsw=…` + `tart set` CPU/RAM |
| `macvm-tart-ensure` | Exit 0 if VM exists, else print create help (exit 2) |
| `macvm-tart-start` | Detached `tart run` + Screengrab dir share |
| `macvm-tart-stop` | `tart stop macvm` |
| `macvm-tart-ip` | `tart ip macvm` |
| `macvm-tart-ssh` | SSH as `aloshy` with operator key |
| `macvm-tart-list` | `tart list` |
| `macvm-tart-doctor` | Quick health check |
| `macvm-tart-bootstrap-print` | In-guest checklist |

## Optional: registry base image instead of IPSW

```bash
tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest macvm
nix run .#macvm-tart-start
```

Prefer **IPSW create** for a clean install owned by you.

## What not to do

- Put IPSW or Tart disks in the Nix store or this git repo.
- Expect `nix run .#macvm` on the **host** to create the VM — that app activates the **guest** config inside the VM.
- Confuse with `nix run .#nixvm` (Linux XFCE build-vm).

## Source map

| Piece | Path |
|---|---|
| Host toolkit | `packages/macvm-tart.nix` |
| Guest profile | `hosts/macvm.nix` |
| Agent skill | `.claude/skills/macvm-tart/SKILL.md` |
