# ---- The fleet's heartbeat (dead man's switch) REGISTRY ---------------------
#
# ONE place that names every check the fleet expects to hear from. Its readers:
#
#   infra/healthchecks/checks.nix   renders one `healthchecksio_check` per entry
#   modules/nixos/service-heartbeat.nix   asserts, at eval time, that the slug it
#                                         pings exists here (mkNixos threads this
#                                         attrset in as the `heartbeats` specialArg)
#   checks.<system>.heartbeat-workflow-parity   asserts the two workflow pingers
#                                         below carry the same slug + cron as here,
#                                         and that each Mac-side pinger names its slug
#
# EVERY ENTRY IS WIRED (2026-11-02): nixpi-serving by the host's service-heartbeat;
# the workflow nix-config-* checks by a ping step in their workflow (scheduled runs
# only, #1032); nix-config-terranix-drift by the Mac's drift agent; evidence-discover by the agentic-jobseek cloud routine — a
# DIFFERENT repo, so nothing here can check that pinger. The one exception, from
# 2026-11-04: nix-config-doctors-weekly is pinged by `doctor-report weekly`, but only
# once the operator creates its Desktop task; until the first run it reads `new`.
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
# DECLARED ≠ WIRED, for any FUTURE entry. An entry here makes the check EXIST at
# the monitor, but its clock starts at the FIRST PING: a never-pinged check stays
# `new` and never alerts (healthchecks hc/api/models.py `Check.get_status`, read
# 2026-11-02). So the alarm arms when the pinger lands, not when the entry does.
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
      # WIRED: modules/nixos/service-heartbeat.nix on nixpi (under runitor).
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

      # WIRED in ANOTHER repo: agentic-jobseek's evidence-discover cloud routine pings
      # it. Monday 14:00 UTC.
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

      # WIRED: the workflow's "Heartbeat ping" step (scheduled runs only). Cron must
      # equal .github/workflows/update-flake-lock.yml's (`23 4 * * 1`, Monday 04:23
      # UTC) — checks.<system>.heartbeat-workflow-parity asserts it. grace 1 day because that workflow's own header
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

      # WIRED: the operator Mac's daily `nix-terranix-drift` agent
      # (modules/home/terranix-drift.nix, under runitor). Success = every terranix stack
      # planned clean; /fail = a stack drifted or could not plan (an auth failure too).
      # A `period`, not a cron: the agent fires at 06:00 LOCAL, and launchd runs a
      # calendar job missed during sleep on wake, so the ping time follows the Mac,
      # not a zone this repo would have to name. grace 1 day: a Mac asleep or away for
      # a day is not drift; two silent days is worth an email.
      nix-config-terranix-drift = {
        period = 86400;
        grace = 86400;
        tags = [
          "nix-config"
          "macos"
          "daily"
        ];
        desc = "Daily terranix drift check from the operator Mac. Silence = the agent did not run; /fail = a stack drifted or could not plan.";
      };

      # WIRED by a Claude Desktop local task the operator creates by hand (its prompt:
      # docs/doctors-coverage-adr.md § 6). The task runs /fleet-doctor, then /hygiene, then
      # `doctor-report weekly`, which pings through runitor: success when both runs are
      # valid and fresh (findings included), /fail when one is missing, stale or invalid.
      # The schedule lives in the app, not in Nix (ADR-010 § 4), so THIS entry is the
      # declared half: a lost or disabled task goes silent and alerts.
      # A `period`, not a cron, for terranix-drift's reason: the task fires at a LOCAL time
      # and runs late after sleep. grace 1 day: one missed Monday alerts on Tuesday.
      nix-config-doctors-weekly = {
        period = 604800;
        grace = 86400;
        tags = [
          "nix-config"
          "macos"
          "weekly"
        ];
        desc = "Weekly /fleet-doctor + /hygiene audit (Desktop task on the operator Mac). Silence = the task did not run; /fail = a doctor run was missing, stale or invalid.";
      };

      # WIRED: the workflow's "Heartbeat ping" step (scheduled runs only). Cron must
      # equal .github/workflows/gitleaks.yml's (`41 2 * * 0`, Sunday 02:41 UTC) —
      # same parity check. Same 1-day grace and for the same reason.
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

      # WIRED: .github/workflows/grafana-rollup.yml's "Heartbeat ping" step (scheduled
      # runs only); same parity check. grace 12 h, not the weekly checks' 1 day: GitHub
      # has started schedules up to 6 h late (update-flake-lock's entry above), so 12 h
      # absorbs that, while a DROPPED daily run still pages the same day it is missed
      # (a missed day is backfilled with the workflow's `date` input).
      nix-config-grafana-rollup = {
        schedule = "17 6 * * *";
        timezone = "UTC";
        grace = 43200;
        tags = [
          "nix-config"
          "ci"
          "daily"
        ];
        desc = "Daily Grafana KPI rollup into the history Sheet. Silence = the schedule did not fire or the job died.";
      };
    };
  };
}
