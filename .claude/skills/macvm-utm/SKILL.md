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

`macvm` ≠ `nixvm` (NixOS/QEMU throwaway).

## Host (run on macos)

```bash
nix run .#macvm-utm-ensure              # ready (0) or open UTM + create steps (2)
nix run .#macvm-utm-doctor              # package, share, spice, clipboard, Screengrab
nix run .#macvm-utm-start
nix run .#macvm-utm-ssh                 # aloshy + operator id_ed25519
nix run .#macvm-utm-share-screengrab    # register host Screengrab R/W (restart guest after)
nix run .#macvm-utm-clipboard-on -- --yes
nix run .#macvm-utm-registry-dedupe -- --apply --yes   # only if duplicate sidebar rows
```

Create is **GUI once** (`utmctl` cannot create macOS AVF guests). Name VM `macvm`;
login user `aloshy`. Enable **Virtualization → Clipboard Sharing** (or clipboard-on).

## Activate guest (prefer host-driven over SSH)

After `aloshy` has passwordless sudo (`hosts/macvm.nix`), **do not ask the user to
type in the guest** — run from the host:

```bash
nix run .#macvm-utm-start   # if needed
nix run .#macvm-utm-ssh -- sudo nix run --refresh github:kattakath/nix-config#macvm
```

First bootstrap only (or if `sudo -n` fails): password once in-guest so NOPASSWD lands.

## Guest features (declarative in `#macvm`)

| Feature | Mechanism |
|---|---|
| SSH | Apple's `com.openssh.sshd`, keys-only, ALF off |
| Guest tools / clipboard | Pinned spice-vdagent pkg + launchd |
| Screengrab | Symlink `~/Pictures/Screengrab` → VirtioFS; heal agent every 30s |
| No RAG/MCP/login openers | Host-gated lean sandbox |

Diagnose: `nix run .#macvm-utm-doctor`; guest `readlink ~/Pictures/Screengrab`,
`launchctl print system/com.openssh.sshd`, `pkgutil --pkg-info com.redhat.spice.vdagent`.

## Do not

- Put IPSW/`.img`/`.utm` in git or the Nix store.
- Activate `#macvm` on the host Mac (wrong persona/paths).
- Run file-rotation on the guest (host owns Screengrab aging).
- Expect key-recovery / rebuild to restore the guest disk — recreate + re-activate.
