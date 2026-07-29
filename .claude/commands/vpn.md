---
description: Operate WireGuard via the fleet vpn CLI (list/status/switch/down)
---

Use the **wireguard-vpn** skill and `docs/wireguard-vpn.md`.

Default actions when the user is vague:

1. `vpn doctor` then `vpn list` / `vpn status`
2. Prefer `vpn switch <NAME>` to change full-tunnel endpoint
3. Never print private keys

The `vpn` CLI is **macvm-only** — macos manages WireGuard through the
`WireGuard.app` GUI (no CLI). On macvm, run through
`nix run .#macvm-utm-ssh -- bash -lc 'vpn …'` after activate (or
`/opt/homebrew/bin/vpn` if PATH is thin).
