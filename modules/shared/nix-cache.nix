# Binary cache (Cachix) consumed by the NixOS hosts via standard `nix.settings`.
#
# NixOS-ONLY module. The macOS host (`macos`) runs Determinate Nix, where
# `nix.*` is unavailable and the Cachix cache is routed through
# `determinateNix.customSettings` in flake.nix instead — so this module is wired
# into mkNixos's module list only, NOT mkDarwin's.
#
# kattakath.cachix.org is the single public CI cache: GitHub Actions
# (cachix/cachix-action in .github/workflows/nix-ci.yml) builds the flake outputs
# and pushes their closures, then every host substitutes them instead of
# rebuilding. READ is public (only the URL + trusted-PUBLIC-key — NO token on any
# consumer); the write credential CACHIX_AUTH_TOKEN is a GitHub Actions secret
# only, never in Nix or git.
#
# `cachixUrl`/`cachixKey` are threaded in via mkNixos's specialArgs (defined once
# in flake.nix's top-level let), so the URL/key literal is single-sourced across
# the NixOS hosts and the macOS Determinate customSettings.
{
  cachixUrl,
  cachixKey,
  legacyCachixUrl,
  legacyCachixKey,
  ...
}:
{
  nix.settings = {
    # Appended to (not replacing) the default cache.nixos.org substituter.
    # legacy* is the retired personal cache: READ-ONLY, kept only so the new org
    # cache does not have to be warmed from cold. Nothing pushes to it any more.
    extra-substituters = [
      cachixUrl
      legacyCachixUrl
    ];
    extra-trusted-public-keys = [
      cachixKey
      legacyCachixKey
    ];
  };
}
