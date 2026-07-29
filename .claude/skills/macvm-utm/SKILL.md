---
name: macvm-utm
description: >
  Host-side UTM lifecycle and SSH for the macvm Apple Silicon guest (darwin
  sandbox under the aloshy persona). Use when starting/stopping macvm, SSH from
  the Mac into the guest, creating the UTM VM, fixing duplicate UTM registry
  entries, sharing Screengrab, guest tools/clipboard, or activating the guest
  nix-darwin config.
---

# macvm UTM

Canonical detail: [`docs/macvm-utm-runbook.md`](../../../docs/macvm-utm-runbook.md).

## Boundaries

| Layer | Where | What |
|---|---|---|
| Hypervisor + disk | **Host** (`macos`) | UTM; `macvm.utm` never in the flake |
| Guest OS config | **Inside VM** as `aloshy` | `darwinConfigurations.macvm` |
| SSH | Host → guest Shared net | `nix run .#macvm-utm-ssh` |
| Screengrab | Host path shared R/W | `~/Pictures/Screengrab` ↔ guest symlink |

`macvm` ≠ `nixvm`. **Do not wipe a healthy guest** (`macvm-utm-doctor` exit 0 → keep).

## Greenfield (ordered)

1. `nix run .#macvm-utm-ensure` → UTM GUI: Virtualize macOS, name **`macvm`**, user **`aloshy`**, Shared net, Clipboard Sharing on.
2. In guest (once): `sudo nix run github:kattakath/nix-config#macvm` (password once → NOPASSWD).
3. Host: `nix run .#macvm-utm-share-screengrab` then **restart** guest.
4. Day-to-day: `nix run .#macvm-utm-ssh -- sudo nix run --refresh github:kattakath/nix-config#macvm`
5. Verify: `nix run .#macvm-utm-doctor`

## Host apps

```bash
nix run .#macvm-utm-ensure | doctor | start | stop | ssh
nix run .#macvm-utm-share-screengrab
nix run .#macvm-utm-clipboard-on -- --yes
nix run .#macvm-utm-registry-dedupe -- --apply --yes   # duplicate sidebar only
```

## Guest (declarative `#macvm`)

| Feature | Mechanism |
|---|---|
| SSH | Apple's sshd, keys-only, ALF off, passwordless sudo |
| Clipboard | Pinned spice-vdagent |
| Screengrab | VirtioFS share + symlink heal every 30s |
| Lean | No RAG / MCP / macos login openers |

## Do not

- Put IPSW/`.img`/`.utm` in git or the Nix store.
- Activate `#macvm` on the host Mac.
- Rotate Screengrab on the guest (host owns aging).
- Expect rebuild/key-recovery to restore the guest disk.
