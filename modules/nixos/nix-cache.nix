# Binary caches consumed by the NixOS hosts via standard `nix.settings`.
#
# NixOS-ONLY module. The macOS host (`macos`) runs Determinate Nix's DARWIN
# module, where `nix.*` is unavailable and the Cachix cache is routed through
# `determinateNix.customSettings` in modules/parts/compose.nix instead — so this
# module is wired into mkNixos's module list only, NOT mkDarwin's. (The NixOS
# hosts run Determinate Nix too since 2026-09-21, but its nixosModule keeps
# `nix.settings` live — it only retargets the rendered file to nix.custom.conf.)
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
  ...
}:
{
  nix.settings = {
    # Appended to (not replacing) the default cache.nixos.org substituter.
    #
    # install.determinate.systems is Determinate's PUBLIC cache (no token): it is
    # where the prebuilt Determinate Nix package the nixosModule installs comes
    # from — verified 2026-09-21: the aarch64-linux `determinate-nix-3.22.3`
    # output is a HIT there and a MISS on cache.nixos.org and Cachix. Without it
    # a NixOS host (or the warm-cache runner) would BUILD Nix from C++ source.
    # The key is the one Determinate's own NixOS install guide names
    # (https://docs.determinate.systems/guides/advanced-installation/).
    extra-substituters = [
      cachixUrl
      "https://install.determinate.systems"
    ];
    extra-trusted-public-keys = [
      cachixKey
      "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
    ];
  };
}
