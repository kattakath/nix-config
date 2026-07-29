---
name: macvm-tart
description: >
  Host-side Tart lifecycle and SSH for the macvm Apple Silicon guest (darwin sandbox under the aloshy persona)
  Use when: starting/stopping macvm, SSH from the Mac into the guest, creating the Tart VM from IPSW, sharing Screengrab, or activating the guest nix-darwin config.
---

# macvm Tart

Canonical detail: [`docs/macvm-tart-runbook.md`](../../../docs/macvm-tart-runbook.md).

| Layer | Where | Notes |
|---|---|---|
| Hypervisor + disk | **Host** (`macos`) | Tart + Apple Virtualization; disk under `~/.tart/` never in the flake |
| Guest nix-darwin | Inside VM as **`aloshy`** | `darwinConfigurations.macvm` |
| SSH | Host → guest shared net | `nix run .#macvm-tart-ssh` |

`macvm` ≠ `nixvm`. **Do not wipe a healthy guest** (`macvm-tart-doctor` exit 0 → keep).

## Greenfield

1. `nix run .#macvm-tart-create` → IPSW install; Setup Assistant user **`aloshy`**; Remote Login on.
2. Guest: Determinate Nix, then `sudo nix run github:kattakath/nix-config#macvm`.
3. Host: `nix run .#macvm-tart-start` (Screengrab VirtioFS), then SSH.
4. Verify: `nix run .#macvm-tart-doctor`.

## Day-to-day

```bash
nix run .#macvm-tart-ensure | doctor | start | stop | ssh | ip
nix run .#macvm-tart-ssh -- sudo nix run --refresh github:kattakath/nix-config#macvm
```

## Do not

- Put IPSW / Tart disks in git or the Nix store.
- Use the host `#macvm` app to create the VM (guest activate only).
