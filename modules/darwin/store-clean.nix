# Scheduled Nix store GC on darwin: `nh clean all`, under the fleet policy in
# ../_lib/store-retention.nix (keep 3 generations, 3-day window, daily) — the
# same command NixOS hosts run through nixpkgs' `programs.nh.clean`
# (../nixos/core.nix).
#
# WHY CUSTOM — upstream-first, cited (pinned inputs, 2026-11-27):
#   nix-darwin programs.nh.clean  asserts `cfg.clean.enable -> config.nix.enable`
#                                 (modules/programs/nh.nix) — and the Determinate
#                                 darwin module forces `nix.enable = mkForce false`.
#   nix-darwin nix.gc / optimise  the same `nix.enable` assertion.
#   home-manager programs.nh.clean runs `nh clean USER` as a login agent, so it
#                                 can never prune root's system generations.
#   determinate-nixd's collector  space-triggered ("keep >= 30 GB free"); its docs
#                                 do not say it prunes generations — 15 system
#                                 generations sat on this Mac on 2026-11-27 — and
#                                 its best-practices page says not to pair it with
#                                 a timer. So it is set to "disabled"
#                                 (modules/parts/compose.nix), as on NixOS.
# So this is nix-darwin's OWN `launchd.daemons.nh-clean` body (same Background
# QoS, low-priority IO, /var/root working dir) without the one assertion that
# cannot hold under Determinate. Retire it if nix-darwin drops that assertion.
#
# DIFFERENCES from upstream's body, each forced:
#   arg0  `nix-store-clean` via ProgramArguments, not `command` (which renders
#         `/bin/sh -c "wait4path … && exec …"`) — .claude/rules/launchd-naming.md.
#         No boot-ordering exception is needed: there is no RunAtLoad, so launchd
#         first execs it at 03:15, long after /nix is mounted.
#   PATH  Determinate's own `nix` (/nix/var/nix/profiles/default/bin), not
#         `config.nix.package`: with nix.enable = false that is a stock pkgs.nix
#         client talking to the Determinate daemon.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  retention = import ../_lib/store-retention.nix;
  log = "/var/log/nix-store-clean.log";

  clean = pkgs.writeShellScriptBin "nix-store-clean" ''
    export PATH=/nix/var/nix/profiles/default/bin:${lib.makeBinPath [ pkgs.nh ]}:/usr/bin:/bin:/usr/sbin:/sbin
    echo "nix-store-clean: $(date -u +%FT%TZ) keep=${toString retention.keep} keep-since=${retention.keepSince}"
    exec nh clean all --keep ${toString retention.keep} --keep-since ${retention.keepSince}
  '';
in
{
  # Determinate lane only: the upstream lane uses nix-darwin's own
  # programs.nh.clean instead (./nix-implementation.nix).
  config =
    lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin && config.local.nixImplementation == "determinate")
      {
        launchd.daemons.nix-store-clean.serviceConfig = {
          ProgramArguments = [ "${clean}/bin/nix-store-clean" ];
          RunAtLoad = false;
          StartCalendarInterval = [ retention.launchdCalendar ];
          WorkingDirectory = "/var/root";
          EnvironmentVariables.HOME = "/var/root";
          LowPriorityIO = true;
          LowPriorityBackgroundIO = true;
          ProcessType = "Background";
          StandardOutPath = log;
          StandardErrorPath = log;
        };
      };
}
