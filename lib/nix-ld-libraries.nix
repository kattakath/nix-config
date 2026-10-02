# Single source of truth for the nix-ld runtime library set — the shared
# libraries that dynamically-linked, NON-Nix binaries (VS Code Server, prebuilt
# language servers, downloaded toolchains) expect to find at runtime.
#
# A `pkgs`-taking function so every consumer imports the SAME list and they
# never drift. Two consumers:
#   modules/nixos/core.nix          → programs.nix-ld.libraries (NixOS hosts)
#   packages/devcontainer-image.nix → NIX_LD_LIBRARY_PATH / LD_LIBRARY_PATH (distroless image)
#
# Widen HERE and both follow — this is the one place that grows if a future
# foreign binary needs a new library, instead of a per-soname shim in any consumer.
# Widening it also now FIRES CI: `lib/**` is a path filter in
# build-devcontainer.yml, warm-nixpi-cache.yml and build-installers.yml. It was
# missing from the first of those all along (ADR-009 §9b, fixed 2026-10-02).
#
# WHY TOP-LEVEL `lib/` AND NOT `modules/`. It lived in `modules/shared/` until
# 2026-10-02 and was wrong there twice over: it is not a home-manager module, and
# it is not a module at all. `modules/nixos/` would be wrong too — the second
# consumer is `packages/`, and `packages/ → modules/nixos/` is a layer crossing
# this repo fences in the other direction (ast-grep/rules/*-must-not-cross-*.yml).
# A `lib/` layer is one ANY layer may reach into, so neither consumer crosses.
#
# JUDGEMENT CALL, NOT A GREPPED PRECEDENT — stated plainly because the motto
# requires it. Measured 2026-10-02 against the pins: `blueprint` is NOT an input
# of this flake (0 hits in flake.lock), so ADR-009's citation of its `lib/` key is
# precedent, not an option surface. flake-parts has a `lib/` in its OWN repo but
# declares no such option for consumers, and the closest grepped convention —
# import-tree's dendritic guide — prescribes an underscore-prefixed `modules/_lib/`,
# not this. So: the layering reason above is the whole argument.
#
# NOT auto-imported. flake.nix's import-tree is `.addPath ./modules` with
# `.match ".*/(parts/[^/]+|features/[^/]+/flake-module)\\.nix"` (flake.nix:447), so
# nothing under `lib/` is ever loaded as a flake module — it is imported by hand,
# by the two consumers above, and that is the point. treefmt still formats it
# (its walk is the whole tree from flake.nix) and `ast-grep scan` still lints it.
pkgs: with pkgs; [
  stdenv.cc.cc # libstdc++.so.6, libgcc_s.so.1
  glibc
  zlib
  openssl
  curl
  util-linux
  libGL
]
