# Binary cache (Cachix) consumed by every Nix host — macOS and NixOS alike.
# The option shape is identical on both, so it lives once here and is wired into
# the flake's module lists.
#
# ismailkattakath.cachix.org is the single public CI cache: GitHub Actions
# (cachix/cachix-action in .github/workflows/nix-ci.yml) builds the flake outputs
# and pushes their closures, then every host substitutes them instead of
# rebuilding. READ is public (only the URL + public key below — NO token on any
# consumer); the write credential CACHIX_AUTH_TOKEN is a GitHub Actions secret
# only, never in Nix or git.
{ handleName, ... }:
{
  nix.settings = {
    # Appended to (not replacing) the default cache.nixos.org substituter.
    extra-substituters = [
      "https://${handleName}.cachix.org"
    ];
    extra-trusted-public-keys = [
      "${handleName}.cachix.org-1:7BbEvLpASY7aNUZfpzRMWir1zjU3nqmllBTl8p7gr2I="
    ];
  };
}
