---
name: macvm-utm
description: >
  Host-side UTM lifecycle and SSH for the macvm Apple Silicon guest (darwin
  sandbox under the aloshy persona). Use when starting/stopping macvm, SSH from
  the Mac into the guest, creating the UTM VM, fixing duplicate UTM registry
  entries, or activating the guest nix-darwin config.
---

# macvm UTM

Canonical detail: [`docs/macvm-utm-runbook.md`](../../../docs/macvm-utm-runbook.md).

## Boundaries

| Layer | Where | What |
|---|---|---|
| Hypervisor + disk | **Host** (`macos`) | UTM; `macvm.utm` never in the flake |
| Guest OS config | **Inside VM** as `aloshy` | `darwinConfigurations.macvm` |
| SSH | Host → guest Shared net | `nix run .#macvm-utm-ssh` |

`macvm` ≠ `nixvm` (NixOS/QEMU throwaway).

## Host (run on macos)

```bash
nix run .#macvm-utm-ensure     # ready (0) or open UTM + create steps (2)
nix run .#macvm-utm-doctor
nix run .#macvm-utm-start
nix run .#macvm-utm-ssh        # aloshy + operator id_ed25519; discovers 192.168.64.x
nix run .#macvm-utm-registry-dedupe -- --apply --yes   # only if duplicate sidebar rows
```

Create is **GUI once** (`utmctl` cannot create macOS AVF guests). Name VM `macvm`;
login user `aloshy`.

## Activate guest (prefer host-driven over SSH)

After `aloshy` has passwordless sudo (set in `hosts/macvm.nix`), **do not ask the
user to type in the guest** — run from the host:

```bash
nix run .#macvm-utm-start   # if needed
nix run .#macvm-utm-ssh -- sudo nix run --refresh github:kattakath/nix-config#macvm
```

First bootstrap only (or if `sudo -n` fails): user must enter the password once
in-guest so NOPASSWD lands; then host-driven activation is enough.

SSH is Apple’s sshd: keys-only, ALF off.
Diagnose: `launchctl print system/com.openssh.sshd`, `lsof -iTCP:22 -sTCP:LISTEN`.

## Do not

- Put IPSW/`.img`/`.utm` in git or the Nix store.
- Activate `#macvm` on the host Mac (wrong persona/paths).
- Expect key-recovery / rebuild to restore the guest disk — recreate + re-activate.
