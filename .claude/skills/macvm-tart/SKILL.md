---
name: macvm-tart
description: >
  Host-side Tart lifecycle and SSH for the macvm Apple Silicon guest (darwin sandbox, same operator identity as every other host)
  Use when: starting/stopping macvm, SSH from the Mac into the guest, creating the Tart VM from IPSW, sharing Screengrab, or activating the guest nix-darwin config.
---

# macvm Tart

Canonical detail: [`docs/macvm-tart-runbook.md`](../../../docs/macvm-tart-runbook.md).

| Layer | Where | Notes |
|---|---|---|
| Hypervisor + disk | **Host** (`macos`) | Tart + Apple Virtualization; disk under `~/.tart/` never in the flake |
| Guest nix-darwin | Inside VM as **`ismail`** | `darwinConfigurations.macvm` |
| SSH | Host → guest shared net | `nix run .#macvm-tart-ssh` |

`macvm` ≠ `nixvm`. **Do not wipe a healthy guest** (`macvm-tart-doctor` exit 0 → keep).

## Greenfield

1. `nix run .#macvm-tart-create` → IPSW install; Setup Assistant user **`ismail`**; Remote Login on.
2. Guest: Determinate Nix, then **`nix run github:kattakath/nix-config#macvm`**
   (not bare `sudo darwin-rebuild` — sudo keeps `HOME=/Users/ismail` as root and
   home-manager skips the user profile). The app also moves unmanaged
   `/etc/nix/nix.custom.conf` aside for Determinate → nix-darwin handoff.
3. Host: `nix run .#macvm-tart-start` (Screengrab VirtioFS), then SSH.
4. Verify: `nix run .#macvm-tart-doctor`; guest has `~/.nix-profile` after HM.

## Day-to-day

```bash
nix run .#macvm-tart-ensure | doctor | start | stop | ssh | ip
nix run .#macvm-tart-ssh -- nix run --refresh github:kattakath/nix-config#macvm
```

## Xcode CLT

Best-effort `softwareupdate` install runs before Homebrew on activate (never
fails switch). Not required for current cask-only Brewfile. GUI fallback:
`xcode-select --install`.

## Do not

- Put IPSW / Tart disks in git or the Nix store.
- Use the host `#macvm` app to create the VM (guest activate only).
- `sudo darwin-rebuild` without `HOME=/var/root` (half-activates system, skips HM).
