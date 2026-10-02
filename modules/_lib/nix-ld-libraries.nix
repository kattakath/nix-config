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
# Widening it also FIRES CI: `modules/_lib/**` is a path filter in
# build-devcontainer.yml, warm-nixpi-cache.yml and build-installers.yml. It was
# missing from the first of those all along (ADR-009 §9b, fixed 2026-10-02).
#
# WHY `modules/_lib/` — A PINNED-INPUT CONVENTION, not a judgement call. It lived
# in `modules/shared/` until 2026-10-02 and was wrong there twice over: it is not a
# home-manager module, and it is not a module at all. It then spent one commit at a
# top-level `lib/`, which WAS a judgement call — and the correction is that a
# convention for exactly this case is present in an input this flake actually pins.
# `import-tree`'s own dendritic guide (docs/src/content/docs/guides/dendritic.mdx,
# § "The `/_` Convention"): *"Use underscore-prefixed directories for helper code
# that shouldn't be auto-imported"*, with `modules/_lib/helpers.nix` as the worked
# example. Rejected alternatives and why they lost:
#   top-level `lib/`     — no pin backs it. `blueprint` is NOT an input (0 hits in
#                          flake.lock), so ADR-009 §7's citation of its `lib/` key is
#                          prior art, not an option surface; flake-parts has a `lib/`
#                          in its OWN repo but declares none for consumers.
#   `modules/nixos/`     — the second consumer is `packages/`, and
#                          `packages/ → modules/nixos/` is a layer crossing this repo
#                          fences in the other direction (ast-grep/rules/).
#
# NOT auto-imported, and the underscore is MECHANICAL here, not decorative. The
# flake's `.match` regex does NOT replace import-tree's default filter — it
# ACCUMULATES with it: `.match` sets `filterf` (pinned default.nix:234) and only the
# unused `.initFilter` sets `initf` (`:245`), so `initialFilter` stays `nixFilter`
# (`:66`) and `:68` conjoins the two — `pathFilter = compose (and filterf
# initialFilter) toString`. Two independent exclusions therefore apply, either alone
# sufficient:
#   1. `nixFilter = andNot (hasInfix "/_") (hasSuffix ".nix")` (pinned
#      default.nix:64). The path relative to the walked root (`:84`) is
#      `/_lib/nix-ld-libraries.nix`, which `hasInfix "/_"` matches — excluded.
#   2. flake.nix's `.match ".*/(parts/[^/]+|features/[^/]+/flake-module)\\.nix"`
#      needs a `parts/<file>` or `features/<name>/flake-module` component, and
#      `builtins.match` must match the WHOLE string. `/_lib/nix-ld-libraries.nix` has
#      neither — excluded.
#
# MEASURED, not reasoned — because "the regex is what excludes it, so the underscore
# is decorative" is the plausible wrong answer. A probe file at
# `modules/_lib/parts/probe.nix` setting `flake.probeMarker` DOES satisfy the regex
# (`builtins.match … "/_lib/parts/probe.nix"` → `[ "parts/probe" ]`, non-null) and was
# still NOT loaded: `nix eval .#probeMarker` errored with no such attribute. Only
# mechanism 1 can account for that. 2026-10-02.
#
# So it is imported by hand, by the two consumers above, and that is the point.
# treefmt still formats it (its walk is the whole tree from flake.nix) and
# `ast-grep scan` still lints it (sgconfig.yml scopes rules, not scanned paths).
pkgs: with pkgs; [
  stdenv.cc.cc # libstdc++.so.6, libgcc_s.so.1
  glibc
  zlib
  openssl
  curl
  util-linux
  libGL
]
