# Binary cache (Cachix) consumed by every Nix host — macOS (nix-darwin) and
# NixOS alike. The option shape (`nix.settings.substituters` /
# `trusted-public-keys`) is identical on both, so this lives once here and is
# wired directly into the flake's module lists (darwinConfigurations."nixcon"
# and the shared mkNixos builder in flake.nix).
#
# READ is public: only the substituter URL + public signing key are needed —
# NO auth token on any consumer. The CACHIX_AUTH_TOKEN is a write-only
# credential and lives solely as a GitHub Actions secret (CI push), never in
# Nix or git. See .github/workflows/flake-check.yml.
{
  nix.settings = {
    # Appended to (not replacing) the default cache.nixos.org substituter.
    extra-substituters = [ "https://ismailkattakath.cachix.org" ];
    extra-trusted-public-keys = [
      "ismailkattakath.cachix.org-1:7BbEvLpASY7aNUZfpzRMWir1zjU3nqmllBTl8p7gr2I="
    ];
  };
}
