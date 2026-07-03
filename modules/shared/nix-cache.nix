# Binary cache (Cachix) consumed by every Nix host — macOS (nix-darwin) and
# NixOS alike. The option shape (`nix.settings.substituters` /
# `trusted-public-keys`) is identical on both, so this lives once here and is
# wired directly into the flake's module lists (darwinConfigurations."nixcon"
# and the shared mkNixos builder in flake.nix).
#
# READ is public: only the substituter URL + public signing key are needed —
# NO auth token on any consumer. The CACHIX_AUTH_TOKEN is a write-only
# credential and lives solely as a GitHub Actions secret, used by the remaining
# workflows (cachix/cachix-action in build-devcontainer.yml) to push build
# closures; never in Nix or git. Garnix pushes its own builds to cache.garnix.io.
#
# cache.garnix.io is Garnix's public CI cache (see garnix.yaml): once Garnix
# builds the flake outputs, every host substitutes those paths (host toplevels,
# devShells, images) from it instead of rebuilding. Also public-read, no token.
{
  nix.settings = {
    # Appended to (not replacing) the default cache.nixos.org substituter.
    extra-substituters = [
      "https://ismailkattakath.cachix.org"
      "https://cache.garnix.io"
    ];
    extra-trusted-public-keys = [
      "ismailkattakath.cachix.org-1:7BbEvLpASY7aNUZfpzRMWir1zjU3nqmllBTl8p7gr2I="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
    ];
  };
}
