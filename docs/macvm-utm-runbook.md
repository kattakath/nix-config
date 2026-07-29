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
nix run .#macvm-utm-ssh -- sudo nix run --refresh github:kattakath/nix-config#macvm
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
