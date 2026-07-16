# Single source of truth for the nix-ld runtime library set — the shared
# libraries that dynamically-linked, NON-Nix binaries (VS Code Server, prebuilt
# language servers, downloaded toolchains) expect to find at runtime.
#
# A `pkgs`-taking function so every consumer imports the SAME list and they
# never drift. Two consumers:
#   modules/nixos/core.nix          → programs.nix-ld.libraries (NixOS hosts)
#   packages/devcontainer-image.nix → NIX_LD_LIBRARY_PATH / LD_LIBRARY_PATH (distroless image)
#
# Widen HERE and all three follow — this is the one place that grows if a future
# foreign binary needs a new library, instead of a per-soname shim in any consumer.
pkgs: with pkgs; [
  stdenv.cc.cc # libstdc++.so.6, libgcc_s.so.1
  glibc
  zlib
  openssl
  curl
  util-linux
  libGL
]
