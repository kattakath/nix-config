# Binary cache (Cachix) consumed by every Nix host — macOS (nix-darwin) and
# NixOS alike. The option shape (`nix.settings.substituters` /
# `trusted-public-keys`) is identical on both, so this lives once here and is
# wired directly into the flake's module lists (darwinConfigurations."nixcon"
# and the shared mkNixos builder in flake.nix).
#
# READ is public: only the substituter URL + public signing key are needed —
# NO auth token on any consumer. The CACHIX_AUTH_TOKEN is a write-only
# credential and lives solely as a GitHub Actions secret, used by the Nix CI
# workflow (cachix/cachix-action in .github/workflows/nix-ci.yml) to push the
# per-system build closures; never in Nix or git.
#
# ismailkattakath.cachix.org is the single public CI cache: once the GitHub
# Actions matrix builds the flake outputs, every host substitutes those paths
# (host toplevels, devShells, images) from it instead of rebuilding. Public-read,
# no token.
{
  nix.settings = {
    # Appended to (not replacing) the default cache.nixos.org substituter.
    extra-substituters = [
      "https://ismailkattakath.cachix.org"
    ];
    extra-trusted-public-keys = [
      "ismailkattakath.cachix.org-1:7BbEvLpASY7aNUZfpzRMWir1zjU3nqmllBTl8p7gr2I="
    ];
  };
}
