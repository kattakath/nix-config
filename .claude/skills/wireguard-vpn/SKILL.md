---
name: wireguard-vpn
description: >
  Operate WireGuard tunnels on macvm with the fleet vpn CLI (list, status, up,
  down, switch, restart, doctor). Use when the user asks to connect VPN, switch
  endpoint (BANGKOK/DUBAI/…), disconnect, or diagnose WireGuard. NOTE: macos has
  NO vpn CLI — it uses the WireGuard.app GUI only; this skill is macvm-scoped.
---

# WireGuard VPN operator

Canonical docs: [`docs/wireguard-vpn.md`](../../../docs/wireguard-vpn.md).

## Rules

- **Never** print private keys or full conf bodies.
- Prefer **`vpn switch NAME`** for full-tunnel confs (`AllowedIPs = 0.0.0.0/0`).
- Conf files live outside git; plant `~/.local/share/wireguard-configs`, activate
  to sync `~/.config/wireguard`.
- Do not start tunnels at login unless the user explicitly asks.
- **macos has no CLI**: it manages WireGuard via `WireGuard.app` (GUI) only — no
  `wireguard-tools`, no `vpn`. All CLI commands below are **macvm-only**. (On
  macos even `nix run .#vpn` is inert: it finds no `wg`/`wg-quick` and refuses.)

## Commands

```bash
vpn doctor
vpn list
vpn status
vpn switch BANGKOK    # atomic: down others → up
vpn up BANGKOK        # fails if another managed tunnel is up
vpn down BANGKOK
vpn down              # all managed
vpn restart DUBAI

# Without PATH (before activate):
nix run .#vpn -- status
```

On **macvm** via host SSH:

```bash
nix run .#macvm-utm-ssh -- /opt/homebrew/bin/vpn status
# after darwin activate, vpn is on PATH in login shells:
nix run .#macvm-utm-ssh -- bash -lc 'vpn list'
```

## Endpoints (operator plant)

Typical names: `BANGKOK`, `BANGLORE`, `DUBAI`, `JAKARTA`, `MANILA` — actual
files under conf dir; use `vpn list`.

## Failure modes

| Symptom | Action |
|---|---|
| `wg not found` | Activate host (wireguard-tools brew) |
| `no conf for X` | Plant source dir + re-activate HM |
| `other tunnel(s) active` | `vpn switch X` |
| no handshake | `vpn status`; check network/endpoint; `vpn restart X` |
