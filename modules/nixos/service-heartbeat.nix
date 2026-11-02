# A dead man's switch for "this host is still SERVING", not "this host is powered".
#
# WHY THIS EXISTS, and the measurement that justifies it: the 2026-09-23 -> 10-01
# outage ran EIGHT DAYS. `checks.*.nixpi-security-posture` was green 18/18 the whole
# time — it cannot see reachability and now says so itself. ICMP answered `ttl=64`
# throughout, so anything that merely proved the host was alive would have reported
# healthy for eight days.
#
# WOULD THIS HAVE CAUGHT IT? Yes, by mechanism rather than luck. That outage was
# userspace dead with the kernel up. If userspace is dead, SYSTEMD TIMERS DO NOT
# FIRE, so no ping leaves the host, so absence-of-ping alerts. The absence IS the
# signal; there is nothing for the dying host to successfully do.
#
# THE ASYMMETRY THAT MAKES THIS THE RIGHT SHAPE, and do not "fix" it later by adding
# a retry that papers over a wedge: every failure mode of the PINGER also produces an
# alert. A hung probe, a dead timer, a broken unit, a missing binary — all fail
# toward alerting. Contrast the rejected Bluetooth beacon (ranked 8th of 9 in the
# alternatives study): a BlueZ beacon IS `bluetoothd`, i.e. the userspace layer that
# was already dead, so it would have reported healthy in the exact state needing
# detection. A monitor must fail in the same direction as the thing it watches.
#
# UPSTREAM-FIRST: the pinned nixpkgs `nixos/modules` has no push-style dead man's
# switch (`services/logging/heartbeat.nix` is Elastic Heartbeat, which probes
# OUTWARD; `services/web-apps/healthchecks.nix` is the healthchecks SERVER). Tool
# axis: nixpkgs ships `runitor`, the healthchecks.io-recommended command runner —
# ADOPTED 2026-11-02 (operator decision D3). It wraps the self-test below and sends
# /start, then the success ping on exit 0 or `/<exit code>` on a non-zero exit
# (runitor's `-on-nonzero-exit` default, cmd/runitor/main.go), so a FAILING
# self-test now alerts at once instead of after the 15-min grace. The earlier
# objection ("absence is the signal, there is no exit status to report") still
# holds for a DEAD host — no timer fires, no ping leaves — and runitor does not
# change that; it adds the explicit failure for a host that is up but not serving.
#
# THE URL is `<local.heartbeat.baseUrl>/<ping key>/<slug>` (healthchecks.io's
# project-ping-key form), built by runitor from `-api-url`, `-ping-key file:<path>`
# (read at run time, whitespace stripped, never in argv) and `-slug`. The slug must
# exist in `config.fleet.heartbeats` (modules/parts/heartbeats.nix) — asserted at
# eval, so a typo fails the build instead of pinging a check that does not exist.
#
# WHY A SELF-TEST AND NOT A BARE PING. A bare `curl` on a timer is VACUOUS here:
# every failure that kills userspace also kills `cloudflared`, which the Cloudflare
# `tunnel_health_event` alert already catches from the edge (infra/cloudflare/
# nixpi-tunnel.nix). So the only failures this adds are the ones that leave
# `cloudflared` ALIVE — Caddy dead, rootfs read-only, disk full — and a bare ping
# sails straight through all of them. A success ping only on a passing self-test
# (a failing one sends `/<exit code>`) is what turns "am I powered" into "am I
# actually serving".
#
# THE TESTS ARE DELIBERATELY NARROW. A test that is too strict stops pinging on a
# healthy host, and a monitor that cries wolf gets ignored — this repo already paid
# for that with an acceptance harness that printed REJECTED on every clean run for
# weeks until everyone skipped reading it. So: "does the web server answer at all"
# (any HTTP status, including 404 — a 404 still proves Caddy is up and serving) and
# "can we write to the rootfs". Nothing about content, nothing about correctness.
#
# PRIOR ART, extended rather than reinvented: the unit shape, the
# `writeShellApplication` + `runtimeInputs` idiom and the `curl ... -w '%{http_code}'`
# probe all come from `modules/nixos/uplink-watchdog.nix`. That module tests OUTWARD
# reachability; this one tests INWARD service health, which is why it is a separate
# file rather than an option on that one. Read its note above `probe =` before changing any
# probe here: per-interface probing was TRIED AND REJECTED on this host because
# `curl --interface wlan0` fails whenever wlan0 does not own the default route.
{
  config,
  lib,
  pkgs,
  # The registry, threaded by mkNixos (modules/parts/compose.nix). Defaulted so a
  # template consumer that passes none still evaluates — the slug assertion below
  # then fires only if it actually sets a `slug`.
  fleetHeartbeats ? { },
  ...
}:
let
  cfg = config.local.serviceHeartbeat;
  hb = config.local.heartbeat;

  # toString: null only when the assertions below already fail; keeps eval reaching them.
  keyFile = toString hb.pingKeyFile;

  # The SELF-TEST alone: exit 0 = serving, non-zero = not. It pings nothing — runitor
  # (below) turns its exit status into the ping, so this script stays testable on its
  # own and its stderr lands in both the journal and the ping body.
  selftest = pkgs.writeShellApplication {
    name = "service-heartbeat-selftest";
    # systemd EXPLICITLY, for `systemctl is-active`. `writeShellApplication`
    # prepends runtimeInputs to the inherited PATH rather than replacing it, so a
    # systemd service would probably find systemctl anyway — "probably" is not a
    # dependency declaration, and a missing binary here fails the unit, which (by
    # this module's design) alerts. Correct direction, still worth not relying on.
    runtimeInputs = [
      pkgs.curl
      pkgs.systemd
    ];
    text = ''
      # ---- 1. Is the web server answering at all? ------------------------------
      # Loopback, so this tests the SERVICE and not the network path — the tunnel
      # alert already covers the network path from Cloudflare's side.
      #
      # ANY HTTP status counts as alive, including 4xx and 5xx. A 404 proves Caddy is
      # up, listening and serving; asserting a particular status would make this fire
      # on a content change, which is the over-strict failure named in the header.
      # Only curl's own failure (connection refused, timeout -> code 000) means dead.
      code=$(curl -s --max-time ${toString cfg.probeTimeout} \
                  -o /dev/null -w '%{http_code}' \
                  "http://127.0.0.1:${toString cfg.httpPort}/" || true)
      case "$code" in
        "" | 000)
          echo "service-heartbeat: FAIL — nothing answered on 127.0.0.1:${toString cfg.httpPort} (code '$code')." >&2
          exit 1
          ;;
      esac

      # ---- 2. Is the rootfs writable? ------------------------------------------
      # Catches the SD-card failure this host is actually prone to: the controller
      # flips read-only on wear, the kernel stays up, the tunnel stays up, and
      # everything that needs to write starts failing silently.
      #
      # Its own StateDirectory, so this tests the real rootfs without depending on
      # any other service's paths.
      probe="$STATE_DIRECTORY/writable.probe"
      # The redirection is inside a SUBSHELL so its own failure message is captured
      # by `2>/dev/null`. Measured: with `! : > "$probe" 2>/dev/null` bash reports
      # "Permission denied" itself, BEFORE the command runs, so the redirect never
      # suppresses it and the journal gets two messages for one fault — the second
      # one explaining the first. One fault, one line.
      if ! ( : > "$probe" ) 2>/dev/null; then
        echo "service-heartbeat: FAIL — cannot write $probe; rootfs may be read-only." >&2
        exit 1
      fi
      rm -f "$probe"

      # ---- 2b. Are the units that matter actually running? ---------------------
      # Named units only. `systemctl is-active` per unit rather than
      # `is-system-running`, because the latter reports `degraded` for ANY failed
      # unit on the host — including ones whose failure does not stop it serving.
      # This host currently carries a legitimately-failing `mnt-storage.mount`
      # (two USB sticks, `nofail` by design), and a blanket check would alert on
      # that forever until someone muted the whole heartbeat.
      for unit in ${lib.escapeShellArgs cfg.requireUnits}; do
        if ! systemctl is-active --quiet "$unit"; then
          echo "service-heartbeat: FAIL — $unit is not active." >&2
          exit 1
        fi
      done

      echo "service-heartbeat: self-test passed."
    '';
  };

  heartbeat = pkgs.writeShellApplication {
    name = "service-heartbeat";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.runitor
    ];
    text = ''
      # ---- The ping credential. WARN, DO NOT ABORT, when it is absent. ----------
      # Checked HERE, before runitor, and never inside the self-test: if this exit 0
      # ran under runitor it would be reported as a PASSING self-test, so a Pi with
      # no key would ping success — the opposite of the intent. So runitor is never
      # started without a key.
      #
      # Why warn-and-exit-0 at all: taken from cloudflared-connector/module.nix's
      # boot-time behaviour, and for the same reason — ABORTING WOULD BRICK A LIVE
      # SERVER OVER A MONITORING CREDENTIAL, the inverse of the failure this module
      # exists to prevent. A Pi flashed without the key must boot, serve, and simply
      # not heartbeat. Exit 0, not 1: a missing optional credential is not a service
      # fault, and failing the unit every interval would fill the journal with a
      # condition the operator already knows about. The alert still arrives, because
      # no ping was sent — no heartbeat means NOT VERIFIED HEALTHY, not "down". A
      # fresh flash alerts until the key is planted, and that is correct.
      if [ ! -r "${keyFile}" ]; then
        echo "service-heartbeat: ${keyFile} is absent or unreadable — not heartbeating." >&2
        echo "service-heartbeat: plant it on the FIRMWARE partition; see local.firmwareProvisioning." >&2
        exit 0
      fi
      # An EMPTY file gets the same treatment; runitor would otherwise die on a
      # missing ping key, which reads as a unit fault rather than an unplanted key.
      if [ -z "$(tr -d '[:space:]' < "${keyFile}")" ]; then
        echo "service-heartbeat: ${keyFile} is empty — not heartbeating." >&2
        exit 0
      fi

      # ---- Run the self-test under runitor ---------------------------------------
      # `-ping-key file:` makes runitor read the key itself, so it reaches neither
      # argv nor `ps` (the same argv hygiene the hand-rolled `curl -K -` gave). Its
      # exit status is the self-test's; a ping that fails to send is only logged, and
      # the monitor alerts anyway because no ping arrived.
      exec runitor \
        -api-url ${lib.escapeShellArg hb.baseUrl} \
        -ping-key "file:${keyFile}" \
        -slug ${lib.escapeShellArg (toString cfg.slug)} \
        -- ${selftest}/bin/service-heartbeat-selftest
    '';
  };
in
{
  # heartbeat.nix owns local.heartbeat (baseUrl + ping key). Imported here so this
  # module is self-sufficient; the module system dedupes it by path if a host also
  # imports it.
  imports = [ ./heartbeat.nix ];

  options.local.serviceHeartbeat = {
    enable = lib.mkEnableOption ''
      a dead man's switch that pings an external monitor ONLY when a local
      self-test passes, so the ABSENCE of a ping is the alert.

      Complements the Cloudflare tunnel-health alert rather than duplicating it:
      that one fires when the tunnel dies, which covers every failure that kills
      userspace. This one covers the failures that leave the tunnel UP — a dead web
      server, a read-only rootfs.
    '';

    slug = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nixpi-serving";
      description = ''
        The check this host pings: a key of `config.fleet.heartbeats`
        (modules/parts/heartbeats.nix), asserted at eval. runitor builds the URL
        `''${config.local.heartbeat.baseUrl}/<ping key>/<slug>`, reading the key at run
        time from `config.local.heartbeat.pingKeyFile`.

        No default HERE: which check a host feeds is the host's fact, so it is set in
        hosts/<host>.nix rather than baked into the module.
      '';
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Loopback port the local web server is expected to answer on.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = ''
        `OnUnitActiveSec` between self-tests. Set the monitor's grace period to a
        comfortable MULTIPLE of this — a single missed ping should not page anyone,
        or the switch becomes the over-strict monitor its own header warns against.
      '';
    };

    requireUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "caddy.service"
        "cloudflared-connector.service"
      ];
      description = ''
        Units that must be active for the heartbeat to fire. An ALLOWLIST, never a
        blanket `systemctl is-system-running` check.

        WHY NOT BLANKET, and this is a reversal worth dating: on 2026-10-02 I argued
        against checking system state at all, as over-strict. The same day refuted
        me — this host sat `degraded` for 23 hours with a corrupt rootfs while the
        tunnel stayed healthy and both of this module's other tests passed. So some
        system-state check belongs here.

        But blanket `degraded` is still wrong, and for the reason I originally gave:
        ONE unrelated failed unit silences the whole heartbeat. That is how this
        repo's acceptance harness came to print REJECTED on every clean run until
        everyone stopped reading it. Naming the units that actually matter keeps the
        signal honest in both directions.

        Empty by default: a host that names nothing gets the Caddy and rootfs tests
        only, exactly as before.
      '';
    };

    probeTimeout = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = ''
        Timeout in seconds for the self-test's loopback HTTP probe. The pings are
        runitor's, on its own `-api-timeout` (5 s, 2 retries — runitor's defaults).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.slug != null;
        message = "local.serviceHeartbeat: set `slug` (a key of fleet.heartbeats).";
      }
      {
        assertion = hb.enable && hb.pingKeyFile != null;
        message = "local.serviceHeartbeat needs `local.heartbeat.enable = true` and a `local.heartbeat.pingKeyFile`.";
      }
      {
        # The slug lands on runitor's command line above, so its alphabet is pinned to
        # the provider's own validator (`^[a-z0-9_-]+$`) rather than trusted — which
        # also rules out runitor's `file:` indirection prefix.
        assertion = cfg.slug == null || builtins.match "[a-z0-9_-]+" cfg.slug != null;
        message = "local.serviceHeartbeat.slug must match [a-z0-9_-]+ (healthchecks.io's slug alphabet).";
      }
      {
        assertion = cfg.slug == null || fleetHeartbeats ? ${cfg.slug};
        message = "local.serviceHeartbeat.slug = \"${toString cfg.slug}\" is not in fleet.heartbeats (modules/parts/heartbeats.nix); known: ${lib.concatStringsSep ", " (builtins.attrNames fleetHeartbeats)}.";
      }
    ];

    systemd.services.service-heartbeat = {
      description = "Self-test this host's services under runitor and report the result to an external monitor";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${heartbeat}/bin/service-heartbeat";
        # Short oneshot with a hard timeout, as in uplink-watchdog.nix — a hung probe
        # dies rather than wedging the timer. 90 s, not 60, since runitor: two pings
        # (start + result) x 3 attempts x 5 s = 30 s worst case, plus the probe's
        # `probeTimeout` and the unit checks. A run killed here sends no result ping,
        # so it still fails toward alerting.
        TimeoutStartSec = "90s";
        # Owns the directory it writes its rootfs probe into, so the test depends on
        # no other service's paths.
        StateDirectory = "service-heartbeat";
        StateDirectoryMode = "0700";
      };
    };

    systemd.timers.service-heartbeat = {
      description = "Periodic service self-test and heartbeat";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Late enough that Caddy has started, so the first run does not report a
        # false failure during boot.
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "10s";
      };
    };
  };
}
