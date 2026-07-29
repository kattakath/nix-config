# WireGuard VPN operator

Professional, **atomic / idempotent / graceful** control of WireGuard tunnels —
the CLI operator runs on **macvm only**. **macos manages WireGuard through the
GUI (`WireGuard.app`) exclusively**: no `wireguard-tools`, no `vpn` CLI, so no
shell can bring a tunnel up (a botched tunnel = no-internet on the sole client
Mac). Both hosts sync confs for use; private keys never enter git or the store.

## Pieces

| Piece | Role | Host |
|---|---|---|
| `wireguard-tools` (Homebrew) | `wg` / `wg-quick` (+ wireguard-go) | **macvm only** |
| **`vpn`** CLI | Operator: list / status / up / down / switch / restart / doctor | **macvm only** |
| `local.wireguardConfigs` | HM activation: plant dir → `~/.config/wireguard` (mode 600, **no** autostart) | macos + macvm |
| Official `WireGuard.app` | GUI — import a synced conf, connect manually | **macos only** (`masApps`) — the ONLY interface there |

Plant directory (outside git):

```text
~/.local/share/wireguard-configs/*.conf   # you maintain
~/.config/wireguard/*.conf                # synced on activate
```

Private composition: activate via `gitlab.com/ismailkattakath/nix-personal` when
you want personal HM modules; plant dirs are the same. See
`docs/private-home-modules.md`.

## Install / activate

The `vpn` CLI is **macvm-only**. After activating macvm (`darwin-rebuild` /
private flake):

```bash
vpn doctor    # or: nix run .#vpn -- doctor
```

`vpn` is on PATH (macvm `home.packages`) and as `nix run .#vpn -- …`. On **macos**
there is no `vpn` CLI (GUI-only); even `nix run .#vpn` is inert there — it finds no
`wg`/`wg-quick` and refuses.

## Commands

| Command | Behavior |
|---|---|
| `vpn list` | Conf names + up/down |
| `vpn status` | Active tunnels (private keys redacted) |
| `vpn doctor` | Tools, dirs, inventory |
| `vpn up NAME` | Bring up; **idempotent** if already up; **refuses** if another managed tunnel is up |
| `vpn down [NAME]` | Down one, or all managed if no name; idempotent if already down |
| `vpn switch NAME` | **Atomic**: down all managed → settle → up NAME (primary for full-tunnel confs) |
| `vpn restart NAME` | Down then up under one lock |

`NAME` may be `BANGKOK`, `BANGKOK.conf`, or a path.

### Guarantees

- **Atomic**: `switch` / `up` / `down` take a process lock (`/tmp/vpn-operator.lock.d`).
- **Idempotent**: repeated `up` / `down` of the same state is a no-op success.
- **Graceful**: waits for handshake (default 15s, `VPN_HANDSHAKE_WAIT`); full-tunnel
  conflict must use `switch` (avoids dual default routes).
- **Professional**: never prints private keys; clear stderr messages.

## Examples

```bash
vpn list
vpn switch BANGKOK          # only one full-tunnel endpoint at a time
vpn status
curl -4 https://api.ipify.org && echo
vpn switch DUBAI
vpn down                    # all managed
```

## Env

| Variable | Default |
|---|---|
| `VPN_CONFIG_DIR` | `~/.config/wireguard` |
| `VPN_SOURCE_DIR` | `~/.local/share/wireguard-configs` |
| `VPN_HANDSHAKE_WAIT` | `15` |
| `WG` / `WG_QUICK` | auto-detect Homebrew |

## Agent skill

`.claude/skills/wireguard-vpn/SKILL.md` — use when the operator asks to connect VPN,
switch endpoint, or diagnose tunnels.

## Source

| Path | What |
|---|---|
| `packages/vpn.nix` | CLI (installed on macvm only — `modules/shared/home.nix` gates it `!isMacosHost`) |
| `modules/shared/wireguard-configs.nix` | conf sync (copy-only, both hosts) |
| `hosts/macvm.nix` | brew `wireguard-tools` (macvm's CLI) |
| `hosts/macos.nix` | `masApps.WireGuard` GUI only — no `wireguard-tools`, no `vpn` |
