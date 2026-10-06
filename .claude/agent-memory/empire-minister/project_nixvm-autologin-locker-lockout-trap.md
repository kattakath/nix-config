---
name: nixvm-autologin-locker-lockout-trap
description: nixvm has NO password + autologin, so ANY locker/keyring/auth-agent prompts for a credential that cannot exist. Two instances fixed (xfce4-screensaver, gnome-keyring); polkit-gnome still live.
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

## It is a CLASS — treat every new desktop package as a suspect

**Rule:** autologin + no password means any component that stores a secret, unlocks a keyring,
or authenticates an action will prompt for a credential that **cannot exist**, and a modal with
no valid answer is a dead end whose only exit is killing QEMU.

**Instance 2, 2026-10-06 (`ac714b4`):** XFCE pulls gnome-keyring in
(`services.gnome.gnome-keyring.enable = mkDefault true`, `xfce.nix:230`), Chromium found the
Secret Service and demanded **"Choose password for new keyring"**. Fixed with **both** halves,
which are complementary not redundant:

- `services.gnome.gnome-keyring.enable = false` — a plain `false` **beats** the upstream
  `mkDefault`; verified by evaluating it, so **no `mkForce` needed**.
- `chromium.override { commandLineArgs = "--password-store=basic"; }` — Chromium
  **auto-detects** its backend, so the dialog returns the moment anything re-provides a Secret
  Service. No upstream option owns this: `programs.chromium` is **policy-only**
  (`extraOpts`/`initialPrefs` write JSON, `chromium.nix:166-188`) and `commandLineArgs` exists
  only on `programs.google-chrome` (`:26`), a different package. `.override` **is** reachable
  here — `commandLineArgs ? ""` is a real arg of chromium's `default.nix:34`, appended via
  `--add-flags` (`:142`). Contrast tor-browser in the same file, which needed `overrideAttrs`.

Closure effect, measured (1539 → 1534 paths): `gnome-keyring-50.0`, its setuid
`security-wrapper-gnome-keyring-daemon`, `gcr-3.41.2` and both `gcr-ssh-agent` units all left.

## Class sweep, 2026-10-06 — the LIVE positive nobody has decided yet

**`polkit-gnome-0.105` is still in the closure** (XFCE installs it as the polkit authentication
agent, `xfce.nix:126-127`) and **will ask for a password on a privileged desktop action.**
Deliberately NOT disabled — polkit is a different path from sudo (covered by
`security.sudo.wheelNeedsPassword = false`) and killing the agent could break desktop actions
silently. **Operator's call, still open.**

Lesser, conditional positives — present but cannot prompt for a credential that does not exist:
`libsecret` (client lib only), `gcr-4` (library, the gcr-3 prompter is gone),
`gnome-online-accounts` (web/OAuth dialog, not a Unix password), `x11-ssh-askpass` + `gnupg`
(prompt only for a key/passphrase the operator chose to create; `pinentry` is absent).

Negative, confirmed absent: `seahorse`, `kwallet`, `kwalletmanager`, `pam_kwallet`,
`xfce-polkit`, `lxqt-policykit`, `mate-polkit`, `polkit_gnome` (the underscore spelling),
`gnome-shell`, `plasma-workspace`, `pinentry`.
