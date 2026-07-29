# macvm + Tart runbook (Apple Virtualization, no UTM)

Two layers — do not conflate:

| Layer | Owner | Notes |
|---|---|---|
| **Hypervisor + disk** | **Tart** on the **macos** host | Apple **Virtualization.framework**; disk under `~/.tart/vms/` — **never** in this flake / Nix store |
| **Guest nix-darwin** | `darwinConfigurations.macvm` | Activate as **`aloshy`** (same persona as the UTM path) |

**UTM is optional.** The UTM control plane (`nix run .#macvm-utm-*`) remains for the existing guest. This path is a **parallel** host backend: same guest flake, IPSW-driven create, CLI-only lifecycle.

`nix run .#nixvm` is still a different product (throwaway NixOS/QEMU). **macvm ≠ nixvm.**

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

Optional baseline (automation-friendly): passwordless sudo for `aloshy`, auto-login off if you prefer a locked sandbox.

### 3. First guest activation (console or SSH)

Inside the guest as **`aloshy`**, with Determinate Nix installed:

```bash
sudo nix run github:kattakath/nix-config#macvm
```

That lands Apple’s `sshd` (keys-only), passwordless sudo, Screengrab symlink agent, lean Homebrew — same as the UTM guest path.

### 4. Day-to-day (host)

```bash
nix run .#macvm-tart-start
nix run .#macvm-tart-ip
nix run .#macvm-tart-ssh -- uname -a
nix run .#macvm-tart-ssh -- sudo nix run --refresh github:kattakath/nix-config#macvm
nix run .#macvm-tart-stop
nix run .#macvm-tart-doctor
```

### Screengrab share

`macvm-tart-start` always attaches:

```text
--dir=Screengrab:$HOME/Pictures/Screengrab
```

Guest path matches the UTM VirtioFS layout already used by `hosts/macvm.nix`:

`/Volumes/My Shared Files/Screengrab` → `~/Pictures/Screengrab` (symlink).

Restart the VM after host path changes.

### Clipboard

Tart enables clipboard sharing by default (disable with `tart run --no-clipboard` if you start by hand). Full fidelity on macOS guests may need [tart-guest-agent](https://github.com/cirruslabs/tart-guest-agent); the UTM guest’s spice-vdagent is UTM-specific and is **not** required for Tart SSH/activate.

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

## vs UTM

| | Tart (`macvm-tart-*`) | UTM (`macvm-utm-*`) |
|---|---|---|
| Hypervisor | Apple Virtualization | Apple Virtualization |
| Create | CLI + IPSW (`latest` or path) | GUI once |
| Disk location | `~/.tart/vms/` | UTM sandbox `…/macvm.utm` |
| Host apps | `macvm-tart-*` | `macvm-utm-*` |
| Guest flake | `#macvm` / `aloshy` | same |

Do **not** run both backends against the same guest identity at once unless you know which disk you are booting.

## Optional: registry base image instead of IPSW

For a preinstalled macOS (still need `aloshy` + SSH + Nix):

```bash
# Example only — image tags change; pick a current sequoia/tahoe base from tart.run
tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest macvm
nix run .#macvm-tart-start
```

Prefer **IPSW create** when you want a clean install owned by you (no third-party base credentials).

## What not to do

- Put IPSW or Tart disks in the Nix store or this git repo.
- Expect `nix run .#macvm` on the **host** to create the VM — that app activates the **guest** config inside the VM.
- Confuse with `nix run .#nixvm` (Linux XFCE build-vm).
