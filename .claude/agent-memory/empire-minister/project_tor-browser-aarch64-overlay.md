---
name: tor-browser-aarch64-overlay
description: nixvm carries tor-browser via an alpha-channel overlay in desktop-vm.nix — why overrideAttrs and not .override, why the buildPhase path rewrite, and that the alpha pin will 404 when upstream rolls
metadata:
  type: project
---

`modules/nixos/desktop-vm.nix` carries a local overlay pinning **tor-browser 16.0a13**
(aarch64 Linux ALPHA) so `nixvm` can ship it. Landed 2026-10-06, operator's explicit
choice over the `tor` + `torsocks` fallback.

**Why:** the pinned nixpkgs' `tor-browser` throws at eval on aarch64-linux (`src =
sources.${system} or (throw …)`); upstream stable ships no aarch64 Linux tarball and
nixpkgs will not package the alpha until 16.0 is stable
(`NixOS/nixpkgs#491286`, open). `tor-browser-bundle-bin` is a hard alias throw.

**Three findings that cost time — do not re-derive:**

1. **`.override { sources = …; }` is IMPOSSIBLE.** `sources` is a `let` binding inside
   `pkgs/by-name/to/tor-browser/package.nix`, not a function argument. The reachable
   surface is `overrideAttrs` replacing `src` — and then `meta.platforms`
   (`= lib.attrNames sources`) must be widened by hand or nixpkgs refuses the host
   platform.
2. **The alpha moved files.** 16.0a13 has `TorBrowser/Tor/torrc-defaults` and
   `TorBrowser/Tor/geoip{,6}`; 15.x had `TorBrowser/Data/Tor/…`. The stock buildPhase's
   `--replace-fail` aborts on the missing file. One
   `builtins.replaceStrings [ "TorBrowser/Data/Tor/" ] [ "TorBrowser/Tor/" ]` over
   `old.buildPhase` fixes all four uses. Everything else in that derivation is
   arch-generic.
3. **It does not substitute.** The derivation sets `preferLocalBuild = true;
   allowSubstitutes = false;`, so it is built on Determinate's native Linux builder every
   time the closure changes.

**How to apply:** the alpha channel keeps only the CURRENT release on
`dist.torproject.org/torbrowser/`, so this pin becomes a **404 fetch** when upstream rolls.
Re-point version + SRI hash from that index (`nix store prefetch-file --json`), and DELETE
the whole overlay once nixpkgs ships 16.0 stable with aarch64.

Scoping is what keeps it safe: the overlay sits inside `mkIf cfg.enable` and
`local.desktopVm.enable` is set only inside `hosts/nixvm.nix`'s
`virtualisation.vmVariant` — so it reaches neither `nixpi` nor `macos`. Keep it there; a
top-level overlay would put a 100 MB binary blob in the live Pi's closure.

Verification is constrained by [[nixvm-initrd-case-hack-blocker]]: the full
`system.build.vm` cannot be built on this Mac, so prove changes with
`.#nixosConfigurations.nixvm.config.virtualisation.vmVariant.system.path` instead.
