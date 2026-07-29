---
name: macvm-utm
description: >
  Host-side UTM lifecycle and SSH for the macvm Apple Silicon guest (darwin
  sandbox under the aloshy persona). Use when starting/stopping macvm, SSH from
  the Mac into the guest, creating the UTM VM, fixing duplicate UTM registry
  entries, sharing Screengrab, guest tools/clipboard, activating the guest
  nix-darwin config, or copying login-Keychain secrets (secret / set-secret)
  from macos → macvm.
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
| Keychain secrets | **Separate** per host | macos `ismailkattakath` ≠ macvm `aloshy` |

`macvm` ≠ `nixvm`. **Do not wipe a healthy guest** (`macvm-utm-doctor` exit 0 → keep).

## Greenfield (ordered)

1. `nix run .#macvm-utm-ensure` → UTM GUI: Virtualize macOS, name **`macvm`**, user **`aloshy`**, Shared net, Clipboard Sharing on.
2. In guest (once): `sudo nix run github:kattakath/nix-config#macvm` (password once → NOPASSWD).
3. Host: `nix run .#macvm-utm-share-screengrab` then **restart** guest.
4. Day-to-day activate (prefer **private** `nix-personal` when personal HM modules matter):
   sync clone → guest `~/nix-personal`, then  
   `nix run .#macvm-utm-ssh -- sudo nix run /Users/aloshy/nix-personal#macvm`  
   (guest usually has no GitLab SSH). Fleet-only: `… github:kattakath/nix-config#macvm`
5. Verify: `nix run .#macvm-utm-doctor`
6. Optional tokens: `nix run .#macvm-utm-secret-copy -- KEY` (see below)

## Host apps

```bash
nix run .#macvm-utm-ensure | doctor | start | stop | ssh
nix run .#macvm-utm-share-screengrab
nix run .#macvm-utm-clipboard-on -- --yes
nix run .#macvm-utm-registry-dedupe -- --apply --yes   # duplicate sidebar only
nix run .#macvm-utm-secret-copy -- KEY [KEY…]
nix run .#macvm-utm-secret-copy -- --list | --rm KEY
```

## Guest (declarative `#macvm`)

| Feature | Mechanism |
|---|---|
| SSH | Apple's sshd, keys-only, ALF off, passwordless sudo |
| Clipboard | Pinned spice-vdagent |
| Screengrab | VirtioFS share + symlink heal every 30s |
| Lean | No RAG / MCP / macos login openers |
| Secrets CLI | `secret` (singular) via `programs.keychainSecrets` — same as host |

## Keychain secrets (macos → macvm)

**Trigger phrases:** copy secret to macvm, set CIVITAI_TOKEN on guest, macvm Keychain,
`secret set` over SSH fails, “User interaction is not allowed”.

### Facts

- CLI is **`secret`**, not `secrets`. Shell function + PATH binary; loader at
  `~/.config/secrets/loader.sh`.
- Host and guest Keychains are **isolated**. Copy is explicit.
- **Plain SSH cannot write** (and often cannot read) the guest login Keychain:
  `security: … User interaction is not allowed.` The Keychain is unlocked for
  the **GUI (Aqua) session** only.
- **Always use the flake app** (do not re-invent `launchctl asuser` by hand
  unless debugging the app itself):

```bash
# Host — KEY must already exist on macos
nix run .#macvm-utm-secret-copy -- CIVITAI_TOKEN
nix run .#macvm-utm-secret-copy -- --list
nix run .#macvm-utm-secret-copy -- --rm VAST_CIVITAI_TOKEN
```

### What the app does

1. Host: `secret get KEY` / `security find-generic-password`
2. Base64 stage to guest (no token in `ssh` argv)
3. Guest: `sudo launchctl asuser $(id -u aloshy) sudo -u aloshy` → `set-secret`
4. SHA-256 verify — never prints values

### Requirements

- macvm **running**, **aloshy logged into the GUI**
- Guest activated (`#macvm`) so `set-secret` exists
- Prefer reading secrets in a **GUI Terminal** on the guest if plain SSH `secret get` returns empty

### Do not

- Assume a successful-looking `secret set` over raw SSH actually wrote the Keychain
- Copy secrets the guest does not need (e.g. only `CIVITAI_TOKEN`, not every `VAST_*`)
- Log or echo secret values

## Do not

- Put IPSW/`.img`/`.utm` in git or the Nix store.
- Activate `#macvm` on the host Mac.
- Rotate Screengrab on the guest (host owns aging).
- Expect rebuild/key-recovery to restore the guest disk.
- Expect host Keychain items to appear on macvm without `macvm-utm-secret-copy`.
