# nix-darwin's own Nix services on every darwin host: the store GC and the
# Linux builder. Both assert `nix.enable`, so neither could run while
# Determinate Nix owned the daemon (until 2026-11-27, ADR-018); the daemon
# settings themselves live in modules/parts/compose.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  retention = import ../_lib/store-retention.nix;
in
{
  options.local.linuxBuilder.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Run nixpkgs' `darwin.linux-builder-vz` through nix-darwin's
      `nix.linux-builder`. Off only where no Linux VM can run, such as a macOS
      guest (a guest cannot nest one).
    '';
  };

  config = {
    # Flakes only: no `nix-channel` command or channel state (nix-darwin
    # modules/nix/default.nix `nix.channel.enable`, default true). Every host
    # resolves `nixpkgs` through the flake registry instead.
    nix.channel.enable = false;

    # The fleet retention policy (../_lib/store-retention.nix), the same
    # `nh clean all` NixOS hosts run through nixpkgs' programs.nh.clean.
    programs.nh = {
      enable = true;
      clean = {
        enable = true;
        interval = [ retention.launchdCalendar ];
        extraArgs = "--keep ${toString retention.keep} --keep-since ${retention.keepSince}";
      };
    };

    # Virtualization.framework + Rosetta, boots on demand, stops after 10 idle
    # minutes. ADR-017 § 3a and ADR-018 G2 measured it against Determinate's
    # builder; its size is set per host (hosts/macos.nix).
    nix.linux-builder = lib.mkIf config.local.linuxBuilder.enable {
      enable = true;
      package = pkgs.darwin.linux-builder-vz;
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
    };
  };
}
