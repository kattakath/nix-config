---
name: project-nixvm-wireguard-mount-not-wg-quick-option
description: nixvm gets wireguard-tools ONLY — a conf share was built 2026-10-06 and reverted the same day at the operator's request. The wg-quick.interfaces rejection (public repo, peer topology in git) still stands.
metadata:
  type: project
---

**Current state (2026-10-06, final):** `nixvm` has `wireguard-tools` + `boot.kernelModules =
[ "wireguard" ]` inside `virtualisation.vmVariant` in `hosts/nixvm.nix`. **No conf is
provisioned** — no share, no `environment.etc`, nothing in `/etc/wireguard`, nothing
autostarting. The operator brings his own file and runs
`sudo wg-quick up /path/to/conf.conf` **by full path**; the bare-name form does not work,
because wg-quick resolves a bare name against `/etc/wireguard` and nothing populates it.

**A conf share was built and then reverted the same day.** `c28e746` added one read-only 9p
`sharedDirectories` entry mounting `~/.local/share/wireguard-configs` at the guest's
`/etc/wireguard` (plus a `nofail` boot-stall guard). It evaluated, built and passed every
gate. The operator then changed the requirement: **wireguard installed, no conf
provisioning.** Removed by forward edit in `bc0bcb5` — deliberately **not** `git revert`,
because the revert would have restored a comment whose central claim is measurably false.

**Why:** the operator's call, not a technical failure. Do not re-propose provisioning confs
into this VM unless he asks.

**The `networking.wg-quick.interfaces` rejection still stands, and is the half worth keeping.**
The two objections usually raised against that option do **not** hold — the pinned nixpkgs'
`nixos/modules/services/networking/wg-quick.nix` has an `autostart` toggle (`:53`) and a
`privateKeyFile` escape hatch (`:88`). The real disqualifier: it re-expresses each conf as Nix
**attributes** (`publicKey`, `endpoint`, `allowedIPs`), and **kattakath/nix-config is public**,
so the operator's VPN peer topology would be in git history permanently. The private overlay
flake that could once have hidden such values was retired 2026-09-15. Same argument kills
`environment.etc."wireguard/…"` — it symlinks a world-readable `/nix/store` path.

**How to apply:** if conf provisioning is ever wanted again, it is a **mount of opaque files**,
never Nix-declared peer attributes. The mechanics are recorded in
[[nixvm-9p-shares-work-on-darwin]] (shell-variable `source`, the `mkForce` necessity, the
`neededForBoot`/`nofail` guard, the `mkVMOverride` priority trap) — that note is a fact about
the host and stays true regardless of this feature.

**macos is a separate, deliberate posture:** GUI-only (`masApps.WireGuard`), **no `wg`/`wg-quick`
CLI on PATH** — a botched tunnel on the sole client Mac means no internet.
`hosts/macos.nix` § Brews says so. Leave it alone.
