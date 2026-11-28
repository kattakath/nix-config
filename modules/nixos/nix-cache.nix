# Binary caches consumed by the NixOS hosts via standard `nix.settings`.
#
# NixOS-ONLY module. The macOS host sets the same Cachix substituter and key in
# modules/parts/compose.nix's `nix.settings`.
#
# kattakath.cachix.org is the single public CI cache: GitHub Actions
# (cachix/cachix-action in .github/workflows/nix-ci-impl.yml, the reusable
# workflow nix-ci.yml calls) builds the flake outputs
# and pushes their closures, then every host substitutes them instead of
# rebuilding. READ is public (only the URL + trusted-PUBLIC-key — NO token on any
# consumer); the write credential CACHIX_AUTH_TOKEN is a GitHub Actions secret
# only, never in Nix or git.
#
# `cachixUrl`/`cachixKey` are threaded in via mkNixos's specialArgs (defined once
# in modules/parts/identity.nix), so the URL/key literal is single-sourced across
# the NixOS hosts and the macOS Determinate customSettings.
{
  cachixUrl,
  cachixKey,
  ...
}:
{
  nix.settings = {
    # Appended to (not replacing) the default cache.nixos.org substituter.
    extra-substituters = [ cachixUrl ];
    extra-trusted-public-keys = [ cachixKey ];
  };
}
