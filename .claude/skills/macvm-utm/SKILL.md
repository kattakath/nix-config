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

## Guest (run inside VM as aloshy)

```bash
sudo nix run github:kattakath/nix-config#macvm
# later: sudo darwin-rebuild switch --flake .#macvm
```

SSH is Apple’s sshd (`services.openssh` in `hosts/macvm.nix`): keys-only, ALF off.
Diagnose: `launchctl print system/com.openssh.sshd`, `lsof -iTCP:22 -sTCP:LISTEN`.

## Do not

- Put IPSW/`.img`/`.utm` in git or the Nix store.
- Activate `#macvm` on the host Mac (wrong persona/paths).
- Expect key-recovery / rebuild to restore the guest disk — recreate + re-activate.
