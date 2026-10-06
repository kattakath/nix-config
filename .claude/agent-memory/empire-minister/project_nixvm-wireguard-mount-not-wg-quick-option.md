---
name: project-nixvm-wireguard-mount-not-wg-quick-option
description: networking.wg-quick.interfaces is REJECTED for nixvm — not for autostart or private keys (it solves both) but because this repo is PUBLIC and the option re-derives peer topology into git. Confs stay opaque files.
metadata:
  type: project
---

`networking.wg-quick.interfaces` is **rejected** as the way to give `nixvm` the operator's
WireGuard confs. Do not re-propose it.

**Why:** the two objections usually raised against it do **not** hold — the pinned nixpkgs'
`nixos/modules/services/networking/wg-quick.nix` has an `autostart` toggle (`:53`) and a
`privateKeyFile` escape hatch (`:88`), so neither "nothing may autostart" nor "the confs hold
private keys" disqualifies it. The real disqualifier: using it means re-expressing each conf
as Nix **attributes** (`publicKey`, `endpoint`, `allowedIPs`), and **kattakath/nix-config is
public**, so the operator's VPN peer topology would be in git history permanently. The private
overlay flake that could once have hidden such values was retired 2026-09-15.

The same argument kills `environment.etc."wireguard/…"` — it symlinks a world-readable
`/nix/store` path.

**How to apply:** confs reach a guest as **opaque files via a mount**, never parsed, evaluated
or re-emitted by Nix. Implementation: one read-only 9p `sharedDirectories` entry at the guest's
`/etc/wireguard` (so `wg-quick up <name>` resolves a bare name), sourced from
`"$HOME"/.local/share/wireguard-configs` — the same operator-maintained directory
`modules/home/wireguard-configs.nix` syncs from on darwin, keeping one source of truth.
7 confs there as of 2026-10-06.

Posture, deliberate and separate per host:

- **nixvm** — `wireguard-tools` + `boot.kernelModules = [ "wireguard" ]`, both inside
  `virtualisation.vmVariant` in `hosts/nixvm.nix` (NOT `modules/nixos/desktop-vm.nix`, which is
  scoped "XFCE desktop + guest integration"). Nothing autostarts; operator runs
  `sudo wg-quick up <name>` by hand.
- **macos** — GUI-only (`masApps.WireGuard`), **no `wg`/`wg-quick` CLI on PATH, on purpose**:
  a botched tunnel on the sole client Mac means no internet. `hosts/macos.nix` § Brews says so.
  Leave it alone.

Unproven and still unproven: that the mount actually succeeds in the guest and the 7 confs are
visible at `/etc/wireguard`. That needs a boot; the gates only prove eval, the VM build, the
`-virtfs` arg, and the closure.

See [[nixvm-9p-shares-work-on-darwin]].
