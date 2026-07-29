# macvm + UTM runbook

Host-side lifecycle for the **macvm** Apple Silicon guest under UTM, plus
in-guest activation of `darwinConfigurations.macvm`.

## Two layers (do not conflate)

| Layer | Who owns it | How |
|---|---|---|
| **Hypervisor + disk** | UTM on the **macos** host | Multi-GB `macvm.utm` under UTM’s sandbox — **not** in this flake |
| **Guest nix-darwin config** | This repo (`#macvm`) | Activate **inside** the VM as user **`aloshy`** |

`nix run .#nixvm` is a different product: throwaway NixOS/QEMU, fully materialised
by the flake. **macvm is not nixvm.**

## Prerequisites (host)

- `macos` activated so the **`utm`** Homebrew cask is present (`hosts/macos.nix`).
- Run glue apps on the **host** Mac (not inside the guest).

## Host-side flake apps

```bash
nix run .#macvm-utm-ensure              # 0 if ready; else open UTM + create steps (exit 2)
nix run .#macvm-utm-doctor              # health: UTM, package, single registry entry
nix run .#macvm-utm-list                # utmctl list
nix run .#macvm-utm-open                # open UTM.app
nix run .#macvm-utm-start               # start the registered macvm
nix run .#macvm-utm-stop                # stop it
nix run .#macvm-utm-registry-dedupe     # dry-run de-dupe of UTM prefs
nix run .#macvm-utm-registry-dedupe -- --apply --yes   # fix double-sidebar ghosts
nix run .#macvm-utm-create-print        # one-time UTM GUI create steps
nix run .#macvm-utm-bootstrap-print     # print in-guest checklist
nix run .#macvm-utm-ssh                 # SSH as aloshy (discovers guest IP)
nix run .#macvm-utm-ssh -- --ip 192.168.64.4
```

Env overrides (optional):

| Variable | Default |
|---|---|
| `MACVM_UTM_PATH` | `~/Library/Containers/com.utmapp.UTM/Data/Documents/macvm.utm` |
| `MACVM_UTM_DOCS` | parent Documents directory |

**Never** put IPSWs or `.img` files in the Nix store or this git tree.

## First-time create (GUI — Phase 2 conclusion)

**`utmctl` has no create** for Apple Virtualization macOS guests. Unattended
scaffold of a bootable guest is **not viable** without shipping IPSW/disk into
the store (explicit non-goal). Permanent create path:

1. `nix run .#macvm-utm-ensure` — if missing, opens UTM and prints steps
   (or `nix run .#macvm-utm-create-print`).
2. UTM → **Virtualize** → **macOS** (Apple Virtualization).
3. Name the VM **`macvm`** (must match hostname / glue name).
4. Finish install; create login account **`aloshy`** (matches flake identity).
5. On the host: `nix run .#macvm-utm-doctor` / `nix run .#macvm-utm-ensure`
   (expect exit 0, one match, package present).

## In-guest activation

```bash
# First time (Determinate Nix installed, before darwin-rebuild is on PATH):
sudo nix run github:kattakath/nix-config#macvm

# Thereafter:
sudo darwin-rebuild switch --flake .#macvm
# or: sudo nix run github:kattakath/nix-config#macvm
```

Guest must be logged in as **`aloshy`**. Wrong login user → wrong home paths.

## SSH from host → macvm

UTM **Shared** networking puts the guest on the host’s `bridge100` subnet
(typically `192.168.64.0/24`; host is often `192.168.64.1`).

1. **Guest** (already in `#macvm` config): `services.openssh.enable = true` and
   the operator ed25519 public key in `users.users.aloshy.openssh.authorizedKeys`.
   Re-activate inside the guest after that lands on the flake you pin.
2. **Host**:
   ```bash
   nix run .#macvm-utm-start          # if stopped
   nix run .#macvm-utm-ssh            # discovers :22 on the shared net
   # or: ssh -i ~/.ssh/id_ed25519 aloshy@192.168.64.4
   ```

Keys-only (no password). If connection times out: guest Remote Login not up yet
(re-activate), wrong IP (`arp -an | grep 192.168.64`), or VM stopped.

## Registry duplicates

UTM can list the same package twice if prefs grow ghost entries. Symptoms: two
`macvm` rows in the sidebar, same disk.

```bash
nix run .#macvm-utm-registry-dedupe              # see KEEP vs DROP
nix run .#macvm-utm-registry-dedupe -- --apply --yes
```

Keeps the entry whose UUID matches `macvm.utm/config.plist`. Backs up prefs under
`~/Library/Application Support/utm-registry-backup-*/`. **Does not delete** the disk.

## Mac rebuild / key recovery

A wiped Mac gets an **empty** UTM library (container recreated). Recreate the
guest (GUI) then re-activate inside as above. See
[`docs/mac-key-recovery-runbook.md`](mac-key-recovery-runbook.md). Optional
external backup of the `.utm` bundle is operator-owned — not part of the key kit.

## Implementation

- Package kit: `packages/macvm-utm.nix`
- Guest host profile: `hosts/macvm.nix`
- Apps wired in `flake.nix` (`apps.aarch64-darwin.macvm-utm-*`)
