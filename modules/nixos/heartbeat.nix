# The HOST-SIDE half of the fleet heartbeat abstraction: where to ping, and the
# credential to ping with. It owns no timer and pings nothing itself — pingers
# (modules/nixos/service-heartbeat.nix today, through runitor) read these two values
# and add their own slug. The registry of WHICH checks exist is `config.fleet.heartbeats`
# (modules/parts/heartbeats.nix); this file is deliberately only the shared
# endpoint + key, so a second pinger on the same host cannot grow a second copy.
#
# URL SHAPE (healthchecks.io "project ping key" form):
#   <baseUrl>/<ping-key>/<slug>            success
#   <baseUrl>/<ping-key>/<slug>/start      begin        (runitor, before the job)
#   <baseUrl>/<ping-key>/<slug>/fail       failure      (runitor, if the job cannot exec)
#   <baseUrl>/<ping-key>/<slug>/<exit>     exit status  (runitor, on a non-zero exit)
# One key per PROJECT, so a host holds one credential however many checks it feeds.
# `?create=1` is not used — see modules/parts/heartbeats.nix.
#
# WHY `baseUrl` IS AN OPTION AND NOT A LITERAL: the same `<base>/<key>/<slug>` wire
# format is spoken by self-hosted Healthchecks and by drop-in receivers, so moving
# off the hosted free plan is a one-line change here rather than a grep.
{ lib, ... }:
{
  options.local.heartbeat = {
    enable = lib.mkEnableOption ''
      the shared heartbeat endpoint and ping-key location that dead-man's-switch
      pingers on this host (`local.serviceHeartbeat`) build their URLs from
    '';

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://hc-ping.com";
      description = "Ping endpoint, without a trailing slash. healthchecks.io's hosted ping host.";
    };

    pingKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/heartbeat-ping-key";
      description = ''
        Path to a root-only file containing the project ping key and nothing else.
        It is read at RUN time by the pinger, never at eval, so the key reaches
        neither the Nix store nor argv.

        Plant it with `local.firmwareProvisioning` (hosts/nixpi.nix) — NOT agenix,
        for the reason that module's header gives: agenix encrypts to the SSH host
        key, and a fresh SD flash mints a new one.

        A pinger tolerates the file being ABSENT (warns, exits 0): a host flashed
        without it must still boot and serve.
      '';
    };
  };
}
