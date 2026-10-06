---
name: nixvm-initrd-case-hack-blocker
description: nixvm's toplevel/VM cannot be built on this Mac — Nix's case-hack renames leak into the native Linux builder's store, so ncurses' terminfo/l/linux is MISSING and makeInitrdNG dies. Pre-existing, not caused by any config change
metadata:
  type: project
---

**`nix build .#nixosConfigurations.nixvm.config.system.build.vm` FAILS on this Mac**, and
has for at least two input generations. It is **not** caused by any nix-config change.

Measured 2026-10-06:

| Target | Result |
|---|---|
| `...nixvm.config.system.build.vm` | ❌ `initrd-linux-6.18.52.drv` |
| `...nixvm.config.system.build.toplevel` (no vmVariant, no desktop, no overlay) | ❌ **identical** error |
| same toplevel at rev `b5c76b3` (pre-#809, nixpkgs `ef34387`, kernel 6.18.51) | ❌ **identical** error |

Error: `Error: failed to get symlink metadata for
"/nix/store/…-ncurses-6.6/share/terminfo/l/linux"` from makeInitrdNG's Rust binary
(`src/main.rs:251`).

**Root cause — PROVEN, not inferred.** This Mac's "Nix Store" APFS volume is
**case-insensitive**, so Nix's `use-case-hack` renames colliding names on disk: the
terminfo tree holds `L/` plus `l~nix~case~hack~1/`, and the path `terminfo/l` resolves to
the **uppercase** directory (same inode for `l` and `L`). `nix store verify` passes,
because Nix un-hacks at the NAR layer — so the corruption is invisible to Nix's own
integrity check.

**The hacked names LEAK into the native Linux builder.** An aarch64-linux
`runCommand` probe run through Determinate's Linux builder printed
`a~nix~case~hack~1 … l~nix~case~hack~1 …` **inside the builder's own store**, and
`terminfo/l/linux` → `No such file or directory`. So any aarch64-linux build on this Mac
that resolves a literal mixed-case store path outside Nix's NAR layer is broken, not just
the initrd.

**Why:** this is the same family as the documented `cp --no-preserve=mode` EPERM trap in
CLAUDE.md § "Building aarch64-linux on the Mac" — host-side artefacts of building Linux
closures from macOS. It is NOT a nixpkgs bug and NOT fixable in this repo's Nix.

**How to apply:**
- Do **not** chase this as a regression of whatever you just changed. Reproduce on
  `system.build.toplevel` first — if that fails too, it is this.
- To prove a nixvm-scoped change instead, build
  `.#nixosConfigurations.nixvm.config.virtualisation.vmVariant.system.path`. That is the
  system profile (all `environment.systemPackages`, `/etc/xdg/autostart`, …), it needs no
  initrd, and it **does** build green.
- Real fixes, none of them this repo's: (a) warm nixvm's closure in CI like
  `warm-nixpi-cache.yml` does for the Pi, so the Mac substitutes the initrd instead of
  building it; (b) recreate the Nix Store volume case-sensitive (reformat, whole-store
  rebuild). Not attempted — operator decision.
- Consequence today: **`nix run .#nixvm` cannot boot from this Mac.** Nobody had noticed
  because `nix flake check --all-systems --no-build` reports nixvm as
  "build skipped" and CI never builds its toplevel.
