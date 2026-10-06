---
name: nixvm-autologin-locker-lockout-trap
description: nixvm has NO password + autologin, so ANY PAM-backed screen locker is a permanent lockout whose only exit is killing QEMU. xfce enableScreensaver defaults TRUE upstream — keep it false.
metadata:
  type: project
---

**Never enable a screen locker in `nixvm`.** `services.xserver.desktopManager.xfce.enableScreensaver
= false` in `modules/nixos/desktop-vm.nix` (landed `c7b57b4`, 2026-10-06).

**Why:** three things compose into a one-way door.

1. `services.displayManager.autoLogin` logs the guest in with no prompt.
2. Nothing in `modules/nixos/` sets `hashedPassword`, `initialPassword` or `mutableUsers`
   for the account — **there is no password**.
3. Upstream defaults the XFCE screensaver **ON** (`xfce.nix:79-83`, `default = true`), which
   installs `xfce4-screensaver` (`:166`) **and** sets
   `security.pam.services.xfce4-screensaver.unixAuth = cfg.enableScreensaver` (`:249`). That
   PAM line is what makes the unlock prompt demand a Unix password.

Result measured 2026-10-06: a lock screen with `ismail` prefilled and a password field that
**cannot** be satisfied. The only exit was SIGTERM to QEMU from the Mac — a power-pull for a
guest whose root qcow2 is **durable**.

**How to apply:** if a locker is ever wanted, **set a password first**. A locker without a
credential is not security, it is a lockout. Do not flip `enableScreensaver` back on to "fix"
anything.

`security.sudo.wheelNeedsPassword = false` (`modules/nixos/core.nix`) is unrelated and must
stay — it is how the operator works in the guest.

**Locker sweep, 2026-10-06** (closure of `system.build.vm`, 1539 paths) — all negative except
one, which is not a locker:

| Package | In closure |
|---|---|
| `xfce4-screensaver`, `light-locker`, `xss-lock`, `xscreensaver`, `xlockmore`, `slock`, `i3lock`, `gnome-screensaver`, `xflock4` | **0** |
| `xfce4-power-manager` | 1 — from `powerManagement.enable = true` (`xfce.nix:149`); it is a power daemon, not a locker, and delegates locking to a binary that is absent |

**A trap in the verification, not the config:** `security.pam.services` still contains the
NAMES `xfce4-screensaver`, `xscreensaver`, `xlock`, `i3lock`, `vlock` (30 services total).
Those are nixpkgs stock declarations (`pam.nix:2748-2752`), gated on unrelated options, and the
last four keep `unixAuth = true`. **The absence of a locker is proved by the CLOSURE, not by the
PAM list** — a pam stanza with no binary to invoke it is inert. `xfce4-screensaver.unixAuth` is
now `false`, which is the one that mattered.

**Second trap:** forcing the whole `security.pam.services` attrset with `nix eval --json`
**throws** — `'kanidm' alias has been removed`. It is **pre-existing** (reproduces on `nixpi`,
untouched) and `nix flake check` passes, because the real build never forces that path. Use
`--apply builtins.attrNames`, or query one service at a time.
