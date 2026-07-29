# macvm + UTM runbook

Two layers — do not conflate:

| Layer | Owner | Notes |
|---|---|---|
| **Hypervisor + disk** | UTM on the **macos** host | `macvm.utm` under UTM’s sandbox — **never** in this flake / Nix store |
| **Guest nix-darwin** | `darwinConfigurations.macvm` | Activate **inside** the VM as **`aloshy`** |

`nix run .#nixvm` is a different product (throwaway NixOS/QEMU). **macvm ≠ nixvm.**

## Prerequisites (host)

- `macos` activated (`utm` cask from `hosts/macos.nix`).
- Run `macvm-utm-*` apps on the **host**, not in the guest.

## Host apps

```bash
nix run .#macvm-utm-ensure              # 0 if ready; else open UTM + create steps (exit 2)
nix run .#macvm-utm-doctor              # UTM, share, spice, clipboard, Screengrab probe
nix run .#macvm-utm-list                # utmctl list
nix run .#macvm-utm-open                # open UTM.app
nix run .#macvm-utm-start | stop
nix run .#macvm-utm-registry-dedupe     # dry-run; add -- --apply --yes to write
nix run .#macvm-utm-create-print        # one-time GUI create checklist
nix run .#macvm-utm-bootstrap-print     # in-guest activate checklist
nix run .#macvm-utm-ssh                 # SSH as aloshy (discovers guest IP)
nix run .#macvm-utm-ssh -- --ip 192.168.64.4
nix run .#macvm-utm-share-screengrab    # host ~/Pictures/Screengrab → guest VirtioFS R/W
nix run .#macvm-utm-clipboard-on -- --yes   # Virtualization.ClipboardSharing=true
```

| Variable | Default |
|---|---|
| `MACVM_UTM_PATH` | `~/Library/Containers/com.utmapp.UTM/Data/Documents/macvm.utm` |
| `MACVM_UTM_DOCS` | parent Documents directory |
| `MACVM_SSH_IP` | (auto-discover on `192.168.64.0/24`) |
| `MACVM_SSH_IDENTITY` | `~/.ssh/id_ed25519` |

**Never** put IPSWs or `.img` files in the Nix store or this git tree.

## First-time create (GUI, once)

`utmctl` cannot create Apple Virtualization macOS guests. Create path is UTM UI only:

1. `nix run .#macvm-utm-ensure` (opens UTM + prints steps if missing).
2. UTM → **Virtualize** → **macOS**. Name the VM exactly **`macvm`**.
3. Finish install; login account **`aloshy`** (matches flake identity).
4. UTM VM settings: **Virtualization → Enable Clipboard Sharing** (macOS 15+).
5. Host: `nix run .#macvm-utm-doctor` (one match, package present).
6. Activate guest (declaratively installs UTM Guest Tools / spice-vdagent).

Network: **Shared** (host `bridge100`, typically `192.168.64.0/24`).

## Shared Screengrab (host ↔ guest, R/W)

**Single path (atomic with macos):** `~/Pictures/Screengrab` on the host
(`modules/darwin/core.nix` — `screencapture.location` + hourly file-rotation).

| Layer | What |
|---|---|
| Host UTM share | `nix run .#macvm-utm-share-screengrab` → Registry `SharedDirectories` (R/W bookmark) |
| Guest automount | `/Volumes/My Shared Files/Screengrab` (Apple VirtioFS) |
| Guest home path | `~/Pictures/Screengrab` → symlink to that automount (`hosts/macvm.nix`) |
| Rotation | **macos only** (must not trash host files from the guest) |

After (re)registering the share, **restart the macvm guest** so VirtioFS attaches.
Guest agent `nix-screengrab-share` re-heals the symlink every 30s (boot race /
remount); dangling symlinks are removed until the share is up so captures don’t
vanish. Verify: `nix run .#macvm-utm-doctor` (symlink + R/W + clipboard).

## UTM Guest Tools (clipboard)

macOS guests need **spice-vdagent** for host↔guest clipboard (requires **macOS 15+**
on both sides and UTM **Virtualization → Enable Clipboard Sharing**).

| Layer | How |
|---|---|
| Host UTM setting | `Virtualization.ClipboardSharing` in `macvm.utm` — set in UI, or `nix run .#macvm-utm-clipboard-on -- --yes` |
| Guest package + launchd | `darwinConfigurations.macvm` activation installs pinned [utmapp/vd_agent](https://github.com/utmapp/vd_agent/releases) pkg and loads jobs |
| Verify | `nix run .#macvm-utm-doctor` (pkg, channel, host→guest paste probe) |

No need for the UTM toolbar “Install Guest Tools” CD once the guest has been
activated. First install may still prompt once in the guest GUI to allow
**spice-vdagent** / **spice-vdagentd** (Gatekeeper). Shared folders use
`mount_virtiofs` ([docs](https://docs.getutm.app/guest-support/macos/)), not spice-webdav.

## In-guest activation

Guest must be logged in as **`aloshy`**. Prefer driving activation **from the host**
over SSH (passwordless sudo for `aloshy` is set on this sandbox):

```bash
# From the host Mac (after guest is started and has been activated at least once
# with a password, so NOPASSWD is on disk):
nix run .#macvm-utm-ssh -- sudo nix run --refresh github:kattakath/nix-config#macvm
# or, with a local checkout on the guest:
nix run .#macvm-utm-ssh -- sudo darwin-rebuild switch --flake /path/to/nix-config#macvm
```

First-time / bootstrap (console or SSH with a password still required until
`security.sudo.extraConfig` lands):

```bash
sudo nix run github:kattakath/nix-config#macvm
```

## SSH (host → guest)

**Single path on the guest:** Apple’s sshd via `services.openssh.enable` (keys-only;
operator ed25519 in `users.users.aloshy.openssh.authorizedKeys` — same key as
nixpi/nixvm). Application Firewall is forced **off** on macvm so UTM Shared is
not blocked (core.nix turns ALF on for the real Mac).

```bash
nix run .#macvm-utm-start          # if stopped
nix run .#macvm-utm-ssh            # discovers :22 on the shared net
# or: ssh -i ~/.ssh/id_ed25519 aloshy@192.168.64.N
```

If it times out: guest not activated / not started, wrong IP
(`arp -an | grep 192.168.64`), or `launchctl print system/com.openssh.sshd` empty
inside the guest (re-activate).

## Registry duplicates

Two sidebar `macvm` rows, same disk → ghost UTM prefs:

```bash
nix run .#macvm-utm-registry-dedupe
nix run .#macvm-utm-registry-dedupe -- --apply --yes
```

Keeps the UUID matching `macvm.utm/config.plist`. Prefs backup under
`~/Library/Application Support/utm-registry-backup-*/`. Does **not** delete the disk.

## Mac rebuild / key recovery

A wiped Mac gets an empty UTM library. Recreate the guest (GUI) then re-activate
inside. See [`mac-key-recovery-runbook.md`](mac-key-recovery-runbook.md). Optional
`.utm` backup is operator-owned — not part of the key kit.

## Source map

| Concern | Path |
|---|---|
| Guest profile | `hosts/macvm.nix` |
| Host toolkit | `packages/macvm-utm.nix` |
| Flake apps / `#macvm` activate | `flake.nix` |
| Host `ssh macvm` stub | `modules/shared/home.nix` |
| Agent skill | `.claude/skills/macvm-utm/SKILL.md` |
