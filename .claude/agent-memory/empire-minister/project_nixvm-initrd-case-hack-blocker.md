---
name: nixvm-initrd-case-hack-blocker
description: nixvm's initrd died on ncurses terminfo/l/linux because Nix's case-hack mangles it on this case-insensitive store; FIXED 2026-10-06 by disabling that one boot.initrd.systemd.contents entry in hosts/nixvm.nix
metadata:
  type: project
---

**FIXED 2026-10-06.** `hosts/nixvm.nix` now carries
`boot.initrd.systemd.contents."/etc/terminfo/l/linux".enable = false;` and
`nix build .#nixosConfigurations.nixvm.config.system.build.vm` went **exit 1 → exit 0**.
Keep this record for the mechanism — the bug CLASS is still live.

**What broke.** Every build of nixvm — base toplevel AND build-vm — died in
`initrd-linux-*` with `Error: failed to get symlink metadata for
"/nix/store/…-ncurses-6.6/share/terminfo/l/linux"` (makeInitrdNG, `src/main.rs:251`).
Reproduced identically at rev `b5c76b3` (pre-#809), so it predated the input bump.

**Root cause — three facts compose, none a nixpkgs bug:**
1. This Mac's "Nix Store" APFS volume (`/dev/disk3s7`) is **case-insensitive**, so
   ncurses' `terminfo/L/` and `terminfo/l/` are one directory (same inode, `62972765`).
2. Nix's `use-case-hack` resolves it by **renaming** the lowercase tree on disk to
   `l~nix~case~hack~1/` (where the real 38 entries live). Nix un-hacks only at the NAR
   layer, so **`nix store verify` passes** — its own integrity check is blind to this.
3. nixpkgs' `nixos/modules/config/terminfo.nix` adds four
   `boot.initrd.systemd.contents` entries unconditionally (`l/linux`, `v/vt100`,
   `v/vt102`, `v/vt220`) and offers no switch. makeInitrdNG resolves the literal path
   **outside** the NAR layer and finds nothing.

**The hacked names LEAK into the native Linux builder.** An aarch64-linux `runCommand`
probe printed `a~nix~case~hack~1 … l~nix~case~hack~1 …` from **inside the builder's own
store**. So building there does not help, and this is not confined to the initrd: any
aarch64-linux build on this Mac that resolves a mixed-case store path by literal name is
exposed.

**Only `l/linux` collides.** Measured: `v/vt100`, `v/vt102`, `v/vt220` all resolve (there
is no uppercase `V/` tree upstream), so they are deliberately left enabled rather than
disabled for symmetry.

**How to apply:**
- The `contents` submodule has a **per-entry `enable`** — confirmed by evaluating the real
  config (`...contents."/etc/terminfo/l/linux"` → attrs `dlopen enable source target text`),
  not by reading a source tree. Prefer that over `lib.mkForce { }` on the whole attrset,
  which would nuke ~28 entries including `/init` and `/lib`.
- **Never re-point `source` at the hacked path.** `l~nix~case~hack~1/linux` is an artefact
  of this filesystem and would not exist on a case-sensitive store.
- If a future bump adds a colliding entry, the same one-line shape handles it. Durable
  fixes (case-sensitive store volume = reformat; or warming nixvm's closure in CI so the
  Mac substitutes) were **explicitly rejected by the operator 2026-10-06** in favour of the
  targeted override. Do not re-propose them as the primary fix.
- To verify a nixvm change without the full VM build,
  `.#nixosConfigurations.nixvm.config.virtualisation.vmVariant.system.path` is the cheap
  proxy — it is the system profile and needs no initrd.
