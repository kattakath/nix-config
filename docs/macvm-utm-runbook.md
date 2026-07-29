# macvm + UTM runbook

Two layers — do not conflate:

| Layer | Owner | Notes |
|---|---|---|
| **Hypervisor + disk** | UTM on the **macos** host | `macvm.utm` under UTM’s sandbox — **never** in this flake / Nix store |
| **Guest nix-darwin** | `darwinConfigurations.macvm` | Activate as **`aloshy`** (prefer host-driven SSH after first bootstrap) |

`nix run .#nixvm` is a different product (throwaway NixOS/QEMU). **macvm ≠ nixvm.**

**Do not wipe a healthy guest.** If `nix run .#macvm-utm-doctor` exits 0 (share, spice, clipboard, Screengrab), keep the disk and only re-activate when config changes. Rebuild only for corruption, wrong login persona, or a deliberate greenfield test (see [Optional full rebuild](#optional-full-rebuild)).

## Prerequisites (host)

- `macos` activated (`utm` cask from `hosts/macos.nix`).
- Operator SSH key at `~/.ssh/id_ed25519` (same public key as nixpi/nixvm).
- Run all `macvm-utm-*` apps on the **host**, not in the guest.

## Greenfield path (ordered)

Use this for a **new** guest or after an intentional wipe. Order matters.

### 1. Create the VM (GUI once)

`utmctl` cannot create Apple Virtualization macOS guests.

```bash
nix run .#macvm-utm-ensure    # opens UTM + prints steps if missing
# or: nix run .#macvm-utm-create-print
```

In UTM:

1. **+** → **Virtualize** → **macOS** (Apple Virtualization).
2. Name exactly **`macvm`**.
3. Network: **Shared** (host `bridge100` ≈ `192.168.64.0/24`).
4. Finish install; create login user **`aloshy`** (must match flake identity).
5. VM settings → **Virtualization → Enable Clipboard Sharing** (macOS 15+ both sides),  
   or later: `nix run .#macvm-utm-clipboard-on -- --yes` (quit UTM first / `--yes` auto-quits).

```bash
nix run .#macvm-utm-doctor    # expect: one match, package present, clipboard on
```

### 2. First guest activation (console, once)

Inside the guest as **`aloshy`**, with Determinate Nix installed:

```bash
sudo nix run github:kattakath/nix-config#macvm
```

Enter the password **once**. That lands:

- SSH (Apple’s `com.openssh.sshd`, keys-only, ALF off)
- Passwordless sudo for `aloshy` (host-driven activates thereafter)
- Pinned **spice-vdagent** guest tools + launchd
- Screengrab symlink agent (heals when VirtioFS appears)
- Lean Homebrew / no MCP / no host login openers

Allow **spice-vdagent** / **spice-vdagentd** if Gatekeeper prompts (once).

### 3. Host: share Screengrab + start guest

```bash
nix run .#macvm-utm-share-screengrab    # Registry SharedDirectories R/W bookmark
nix run .#macvm-utm-stop                # if already running — re-attach VirtioFS
nix run .#macvm-utm-start
```

**Atomic path:** host `~/Pictures/Screengrab` (macos screencapture + 24h rotation only)  
↔ guest `/Volumes/My Shared Files/Screengrab` ↔ guest `~/Pictures/Screengrab` (symlink).

### 4. Day-to-day activate / SSH (host-driven)

```bash
# Fleet-only (public engine, no private HM modules)
nix run .#macvm-utm-ssh -- sudo nix run --refresh github:kattakath/nix-config#macvm

# With private personal modules (GitLab nix-personal — preferred for day-to-day)
nix run .#macvm-utm-ssh -- sudo nix run --refresh \
  'git+ssh://git@gitlab.com/ismailkattakath/nix-personal#macvm'

nix run .#macvm-utm-ssh                 # interactive shell as aloshy
nix run .#macvm-utm-doctor              # health: UTM + spice + clipboard + Screengrab
```

## Host apps (reference)

```bash
nix run .#macvm-utm-ensure
nix run .#macvm-utm-doctor
nix run .#macvm-utm-list | open | start | stop
nix run .#macvm-utm-registry-dedupe              # dry-run; -- --apply --yes to write
nix run .#macvm-utm-create-print | bootstrap-print
nix run .#macvm-utm-ssh [-- --ip 192.168.64.N]
nix run .#macvm-utm-share-screengrab
nix run .#macvm-utm-clipboard-on -- --yes
nix run .#macvm-utm-secret-copy -- KEY [KEY…]   # host Keychain → guest (aloshy)
nix run .#macvm-utm-secret-copy -- --list
nix run .#macvm-utm-secret-copy -- --rm KEY
```

| Variable | Default |
|---|---|
| `MACVM_UTM_PATH` | `~/Library/Containers/com.utmapp.UTM/Data/Documents/macvm.utm` |
| `MACVM_UTM_DOCS` | parent Documents directory |
| `MACVM_HOST_SCREENGRAB` | `$HOME/Pictures/Screengrab` |
| `MACVM_SSH_IP` | auto on `192.168.64.0/24` |
| `MACVM_SSH_IDENTITY` | `~/.ssh/id_ed25519` |

**Never** put IPSWs or `.img` / `.utm` into the Nix store or this git tree.

## Shared Screengrab (detail)

| Layer | What |
|---|---|
| Host path | `~/Pictures/Screengrab` — `screencapture.location` + rotation (**macos only**) |
| UTM share | `macvm-utm-share-screengrab` → Registry `SharedDirectories` (`ReadOnly=false`) |
| Guest automount | `/Volumes/My Shared Files/Screengrab` |
| Guest home | `~/Pictures/Screengrab` → symlink; agent re-heals every 30s |

Restart the guest after (re)registering the share so VirtioFS attaches.

## Guest tools / clipboard (detail)

| Layer | How |
|---|---|
| Host | Clipboard Sharing on (UI or `macvm-utm-clipboard-on`) |
| Guest | `#macvm` activation installs pinned [utmapp/vd_agent](https://github.com/utmapp/vd_agent/releases) spice-vdagent |
| Verify | `macvm-utm-doctor` host→guest paste probe |

No need for the UTM toolbar “Install Guest Tools” CD after a successful activate.

## SSH (detail)

Single path: Apple’s sshd via `services.openssh` (keys-only; operator ed25519). ALF forced off on macvm. Diagnose: guest `launchctl print system/com.openssh.sshd`, host `arp -an | grep 192.168.64`.

## WireGuard configs (private; no autostart)

Both **macos** and **macvm** install `wireguard-tools` (CLI). Official
`WireGuard.app` is **macos-only** (`masApps` — macvm has no Apple ID).

Interface configs (`*.conf` with private keys) are **not** in this public flake
(Nix would put them in the world-readable store). Instead:

| Path | Role |
|---|---|
| `~/.local/share/wireguard-configs/*.conf` | Operator plant (outside git) |
| `~/.config/wireguard/*.conf` | Synced at HM activation (`local.wireguardConfigs`, mode 600) |

```bash
# Plant once (host example), then activate so HM copies into ~/.config/wireguard
mkdir -p ~/.local/share/wireguard-configs
cp ~/Downloads/{BANGKOK,BANGLORE,DUBAI,JAKARTA,MANILA}.conf ~/.local/share/wireguard-configs/
chmod 600 ~/.local/share/wireguard-configs/*.conf

# macvm: copy the same files into aloshy's source dir, then re-activate #macvm
# (or use a private composition flake — docs/private-home-modules.md)

# Bring a tunnel up ONLY when you want it (not on login):
sudo wg-quick up ~/.config/wireguard/BANGKOK.conf
sudo wg-quick down ~/.config/wireguard/BANGKOK.conf
```

**Privacy options** (pick one; never commit plaintext keys to the public tree):

1. **Operator plant dir** (what this module uses) — confs only on disk, gitignored /
   never in the flake. Sync host → macvm with `scp` / `macvm-utm-ssh` when they change.
2. **Private GitLab flake** — owns a thin HM module or re-exports `#macos`/`#macvm`
   via `lib.mkDarwin { extraHomeModules = … }` (`docs/private-home-modules.md`).
   Still: prefer activation `cp` from outside the store, not `home.file.source = ./secret.conf`
   (that copies secrets into `/nix/store`).
3. **agenix** — ciphertext in a repo is OK; host-decrypt at activation is a policy
   choice (this fleet currently avoids host-decrypted secrets).

## Keychain secrets (host ↔ guest)

Both **macos** and **macvm** install `programs.keychainSecrets` (`secret` / `set-secret` /
`remove-secret` from the [nix-keychain-secrets](https://github.com/ismailkattakath/nix-keychain-secrets)
flake). The command name is **`secret`** (singular) — there is no `secrets` CLI.

| Host | Persona / Keychain | Notes |
|---|---|---|
| `macos` | `ismailkattakath` login Keychain | Operator’s tokens (Civitai, Vast, GH, …) |
| `macvm` | `aloshy` login Keychain | **Separate** store — nothing is shared automatically |

### Why plain SSH cannot `secret set`

macOS blocks Keychain **writes** (and often **reads**) from an SSH session with:

```text
security: … User interaction is not allowed.
```

even when the guest GUI user is logged in. The login Keychain is unlocked for the
**Aqua session**, not for arbitrary SSH TTYs.

### Correct path (codified)

```bash
# On the host Mac — copy one or more KEY names that already exist on macos:
nix run .#macvm-utm-secret-copy -- CIVITAI_TOKEN

nix run .#macvm-utm-secret-copy -- --list          # guest index (names only)
nix run .#macvm-utm-secret-copy -- --rm OLD_KEY    # guest only
```

What the app does (agents: do **not** invent a shorter path):

1. Read `KEY` from the **host** Keychain (`secret get` / `security find-generic-password`).
2. Base64-stage the value to the guest (no plaintext in `ssh` argv).
3. On the guest: `sudo launchctl asuser $(id -u aloshy) sudo -u aloshy … set-secret`
   so `security` runs inside aloshy’s Aqua session.
4. Verify with SHA-256 length match — **never** prints secret values.

Requirements: macvm **running**, **aloshy logged into the GUI**, guest activated
(`#macvm` so `secret` / `set-secret` exist).

### In-guest use (after copy)

In a **GUI Terminal** on macvm (or any session that loads `~/.config/secrets/loader.sh`):

```bash
secret ls
secret get CIVITAI_TOKEN   # may still fail over plain SSH; prefer GUI Terminal
```

### Do not

- Expect host Keychain items to appear on macvm without an explicit copy.
- Run `secret set` over raw `macvm-utm-ssh` and assume it worked (index may update
  while the Keychain write fails).
- Put token values in git, flake apps’ source, or shell history when avoidable.

## Registry duplicates

Two sidebar `macvm` rows, same disk:

```bash
nix run .#macvm-utm-registry-dedupe
nix run .#macvm-utm-registry-dedupe -- --apply --yes
```

Backs up prefs under `~/Library/Application Support/utm-registry-backup-*/`. Does **not** delete the disk.

## Optional full rebuild

Only if the guest is corrupt, wrong persona, or you are validating greenfield:

```bash
# Host — destructive
nix run .#macvm-utm-stop
# UTM UI: remove VM "macvm", or delete the package directory under
#   ~/Library/Containers/com.utmapp.UTM/Data/Documents/macvm.utm
# Optional: nix run .#macvm-utm-registry-dedupe -- --apply --yes
```

Then follow [Greenfield path](#greenfield-path-ordered) from step 1.

## Mac rebuild / key recovery

A wiped Mac gets an empty UTM library. Recreate via greenfield. See
[`mac-key-recovery-runbook.md`](mac-key-recovery-runbook.md). Optional `.utm`
backup is operator-owned — not part of the key kit.

## Source map

| Concern | Path |
|---|---|
| Guest profile | `hosts/macvm.nix` |
| Host toolkit | `packages/macvm-utm.nix` |
| Flake apps / `#macvm` | `flake.nix` |
| Host `ssh macvm` stub | `modules/shared/home.nix` |
| Agent skill | `.claude/skills/macvm-utm/SKILL.md` |
