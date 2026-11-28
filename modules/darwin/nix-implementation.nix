# `local.nixImplementation` — which Nix runs a darwin host: "determinate" (today,
# every host) or "upstream" (ADR-018, PROPOSED; rehearsed in a Tart guest only).
#
# The DAEMON settings live once, in modules/parts/compose.nix: Determinate
# renders them to /etc/nix/nix.custom.conf, upstream to `nix.settings`. This
# module owns what only the upstream lane needs — nix-darwin's own GC and Linux
# builder, both of which assert `nix.enable` and so cannot run under Determinate.
#
# Flipping the flag on a live Mac is NOT a rebuild: the daemon changes owner and
# the store volume needs a new boot-time mount. scripts/nix-impl-switch.sh does
# that (ADR-018 § 4a); a bare `activate` with "upstream" set stops at nix-darwin's
# "Determinate detected, aborting activation" check, which is the safe failure.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local;
  retention = import ../_lib/store-retention.nix;
  upstream = cfg.nixImplementation == "upstream";
in
{
  options.local = {
    nixImplementation = lib.mkOption {
      type = lib.types.enum [
        "determinate"
        "upstream"
      ];
      default = "determinate";
      description = "Which Nix implementation manages this darwin host (ADR-017 / ADR-018).";
    };
    upstreamLinuxBuilder = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        On the upstream lane, run nixpkgs' `darwin.linux-builder-vz` through
        nix-darwin's `nix.linux-builder`. Off only where no Linux VM can run,
        such as a macOS guest (a guest cannot nest one).
      '';
    };
  };

  config = lib.mkIf upstream {
    # The Determinate lane's `launchd.daemons.nix-store-clean`, done the upstream
    # way: nix-darwin's own nh module, same policy (../_lib/store-retention.nix).
    programs.nh = {
      enable = true;
      clean = {
        enable = true;
        interval = [ retention.launchdCalendar ];
        extraArgs = "--keep ${toString retention.keep} --keep-since ${retention.keepSince}";
      };
    };

    # Virtualization.framework + Rosetta, boots on demand, stops after 10 idle
    # minutes. ADR-017 § 3a measured it against Determinate's builder.
    nix.linux-builder = lib.mkIf cfg.upstreamLinuxBuilder {
      enable = true;
      package = pkgs.darwin.linux-builder-vz;
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
    };
  };
}
