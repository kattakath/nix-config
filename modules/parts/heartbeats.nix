# ---- The fleet's heartbeat (dead man's switch) REGISTRY ---------------------
#
# ONE place that names every check the fleet expects to hear from. Three readers,
# none of which re-types a slug:
#
#   infra/healthchecks/checks.nix   renders one `healthchecksio_check` per entry
#   modules/nixos/service-heartbeat.nix   asserts, at eval time, that the slug it
#                                         pings exists here (mkNixos threads this
#                                         attrset in as the `heartbeats` specialArg)
#   (later phases)                  other pingers: workflows, launchd agents
#
# PURE DATA, NO SECRETS. A slug names a check; it does not authorise a ping. The
# ping KEY (the project secret in `https://hc-ping.com/<ping-key>/<slug>`) is
# planted per host and never appears in this repo — modules/nixos/heartbeat.nix.
#
# PROVIDER, and why the slug is the identity: healthchecks.io free plan, one
# project ping key + a per-check slug. The slug is an explicit attribute of the
# pinned provider's `healthchecksio_check` (kristofferahl/healthchecksio 2.3.0,
# resource_check.go: `slug`, validated `^[a-z0-9_-]+$`), so the attribute name here
# IS the URL path segment and the resource label — renaming an entry is a
# destroy+create at the monitor, which is also what it means for the pinger.
# `?create=1` (auto-create on first ping) is deliberately NOT used: a typo'd slug
# would silently mint a stray check instead of failing, and the registry would stop
# being the source of truth.
#
# DECLARED ≠ WIRED. An entry here makes the check EXIST at the monitor; it starts
# the clock, so a declared-but-unpinged check alerts when its first deadline lapses.
# Entries therefore land with (or just ahead of) the pinger that feeds them.
#
# Typed in its own file rather than in identity.nix: `options.fleet` is a freeform
# submodule there, and a second declaration of the same option merges at the
# submodule level (nixpkgs `lib/options.nix` `mergeOptionDecls` + the submodule
# type's `typeMerge`) — so this file adds `fleet.heartbeats` without touching the
# file that owns the identity.
{ lib, ... }:
let
  inherit (lib) types mkOption;

  heartbeatType = types.submodule {
    options = {
      schedule = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "0 14 * * 1";
        description = ''
          Five-field cron expression for a job that runs on a calendar. Set EXACTLY
          ONE of `schedule` and `period` — the provider takes `schedule` and
          `timeout` as alternatives, and infra/healthchecks/checks.nix refuses a
          render that sets both or neither.
        '';
      };
      period = mkOption {
        type = types.nullOr (types.ints.between 60 31536000);
        default = null;
        example = 300;
        description = ''
          Expected seconds between pings, for a job that runs on an interval.
          Rendered as the provider's `timeout`. Bounds are the provider's own
          `IntBetween(60, 31536000)`.
        '';
      };
      timezone = mkOption {
        type = types.str;
        default = "UTC";
        description = "IANA zone the `schedule` is evaluated in. Meaningless with `period`.";
      };
      grace = mkOption {
        type = types.ints.between 60 31536000;
        description = ''
          Seconds the monitor waits AFTER a missed deadline before it alerts. No
          default, on purpose: it is the one number that decides crying-wolf versus
          late news, so every entry must state its reasoning. Rule of thumb used
          here: 3x the interval for a frequent pinger; the worst measured schedule
          delay plus margin for a GitHub cron.
        '';
      };
      tags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Free-form labels shown in the dashboard.";
      };
      desc = mkOption {
        type = types.str;
        default = "";
        description = "One line saying what silence from this check means.";
      };
    };
  };
in
{
  options.fleet = lib.mkOption {
    type = types.submodule {
      options = {
        heartbeats = mkOption {
          type = types.attrsOf heartbeatType;
          default = { };
          description = ''
            The heartbeat registry: attribute name = healthchecks.io slug.
            Lowercase letters, digits, `-` and `_` only (the provider's validator).
          '';
        };

        heartbeatChannels = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            healthchecks.io integration (channel) UUIDs every check notifies.
            EMPTY BY DEFAULT, and empty means "the project's email integration",
            found at plan time by a guarded `data "healthchecksio_channel"` lookup
            (infra/healthchecks/checks.nix § ALERT CHANNELS) — so this public repo
            carries no per-account UUID. Set it only to OVERRIDE that default (e.g.
            to add ntfy or Telegram); the provider validates the list as UUIDs.
          '';
        };
      };
    };
  };

  config.fleet = {
    heartbeats = {
      # WIRED in this phase: modules/nixos/service-heartbeat.nix on nixpi.
      #
      # period 300 = `local.serviceHeartbeat.interval` (5min). grace 900 = 3x that,
      # per the interval option's own advice: a single missed ping must not page
      # anyone. Silence means nixpi is not SERVING — see the module header for why
      # absence is the signal.
      nixpi-serving = {
        period = 300;
        grace = 900;
        tags = [
          "nixpi"
          "fleet"
        ];
        desc = "nixpi self-test passes (Caddy answers, rootfs writable, required units active). Silence = not verified healthy.";
      };

      # DECLARED, NOT YET WIRED (agentic-jobseek's evidence-discover job). Monday 14:00 UTC.
      # grace 1 day: a weekly job that is a few hours late is not an incident.
      evidence-discover = {
        schedule = "0 14 * * 1";
        timezone = "UTC";
        grace = 86400;
        tags = [
          "jobseek"
          "weekly"
        ];
        desc = "Weekly career-evidence discovery run. Silence = the run did not complete.";
      };

      # DECLARED, NOT YET WIRED. Cron copied from .github/workflows/update-flake-lock.yml
      # (`23 4 * * 1`, Monday 04:23 UTC). grace 1 day because that workflow's own header
      # measured GitHub starting :00-adjacent schedules 0.5-6 h late and DROPPING one
      # outright (2026-09-21) — a tighter grace would page on GitHub's queueing.
      nix-config-update-flake-lock = {
        schedule = "23 4 * * 1";
        timezone = "UTC";
        grace = 86400;
        tags = [
          "nix-config"
          "ci"
          "weekly"
        ];
        desc = "Weekly flake.lock update workflow. Silence = the schedule did not fire or the job died.";
      };

      # DECLARED, NOT YET WIRED. Cron copied from .github/workflows/gitleaks.yml
      # (`41 2 * * 0`, Sunday 02:41 UTC). Same 1-day grace and for the same reason.
      nix-config-gitleaks = {
        schedule = "41 2 * * 0";
        timezone = "UTC";
        grace = 86400;
        tags = [
          "nix-config"
          "ci"
          "weekly"
        ];
        desc = "Weekly full-history secret scan. Silence = the schedule did not fire or the job died.";
      };
    };
  };
}
