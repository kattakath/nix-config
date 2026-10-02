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
# WHY A SELF-TEST AND NOT A BARE PING. A bare `curl` on a timer is VACUOUS here:
# every failure that kills userspace also kills `cloudflared`, which the Cloudflare
# `tunnel_health_event` alert already catches from the edge (infra/cloudflare/
# nixpi-tunnel.nix). So the only failures this adds are the ones that leave
# `cloudflared` ALIVE — Caddy dead, rootfs read-only, disk full — and a bare ping
# sails straight through all of them. Pinging only on a passing self-test is what
# turns "am I powered" into "am I actually serving".
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
# file rather than an option on that one. Read its `:48` note before changing any
# probe here: per-interface probing was TRIED AND REJECTED on this host because
# `curl --interface wlan0` fails whenever wlan0 does not own the default route.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.serviceHeartbeat;

  heartbeat = pkgs.writeShellApplication {
    name = "service-heartbeat";
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
      # ---- 0. The ping URL. WARN, DO NOT ABORT, when it is absent. -------------
      # Taken from cloudflared-connector/module.nix's boot-time behaviour, and for
      # the same reason: ABORTING WOULD BRICK A LIVE SERVER OVER A MONITORING
      # CREDENTIAL — the inverse of the failure this module exists to prevent. A Pi
      # flashed without the URL must boot, serve, and simply not heartbeat.
      #
      # Exit 0, not 1: a missing optional credential is not a service fault, and
      # failing the unit every interval would fill the journal with a condition the
      # operator already knows about. The alert still arrives, because no ping was
      # sent — which gives the honest semantics: no heartbeat means NOT VERIFIED
      # HEALTHY, not "down". A fresh flash alerts until the URL is planted, and that
      # is correct rather than a bug.
      if [ ! -r "${cfg.urlFile}" ]; then
        echo "service-heartbeat: ${cfg.urlFile} is absent or unreadable — not heartbeating." >&2
        echo "service-heartbeat: plant it on the FIRMWARE partition; see local.firmwareProvisioning." >&2
        exit 0
      fi

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

      # ---- 3. Everything passed. Ping. -----------------------------------------
      # `-K -` reads the URL from curl's own config on STDIN, so the URL never
      # reaches argv and never appears in `ps`. The file is root-only in /run; this
      # keeps it out of the process table as well, which is the same argv-hygiene
      # rule the rest of this fleet follows for secrets.
      #
      # A failed ping exits non-zero so the journal records it, and the monitor
      # alerts anyway because no ping arrived. Both directions covered.
      url=$(tr -d '[:space:]' < "${cfg.urlFile}")
      if [ -z "$url" ]; then
        echo "service-heartbeat: ${cfg.urlFile} is empty — not heartbeating." >&2
        exit 0
      fi
      printf 'url = "%s"\n' "$url" \
        | curl -sS --max-time ${toString cfg.probeTimeout} -o /dev/null -K - \
        || { echo "service-heartbeat: self-test PASSED but the ping failed to send." >&2; exit 1; }
    '';
  };
in
{
  options.local.serviceHeartbeat = {
    enable = lib.mkEnableOption ''
      a dead man's switch that pings an external monitor ONLY when a local
      self-test passes, so the ABSENCE of a ping is the alert.

      Complements the Cloudflare tunnel-health alert rather than duplicating it:
      that one fires when the tunnel dies, which covers every failure that kills
      userspace. This one covers the failures that leave the tunnel UP — a dead web
      server, a read-only rootfs.
    '';

    urlFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/heartbeat-url";
      description = ''
        Path to a root-only file containing the monitor's ping URL and nothing else.

        Plant it with `local.firmwareProvisioning` — the generic firmware-partition
        mechanism, whose own header describes it as exactly this: an operator-planted
        file copied into a root-only /run path at boot. NOT agenix: that encrypts to
        the SSH host key, and a fresh SD flash mints a new one.

        Absence is tolerated by design — the unit warns and does not heartbeat, so a
        host flashed without it still boots and serves.
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
        "cloudflared.service"
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
      description = "Per-request timeout in seconds, for both the self-test and the ping.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.service-heartbeat = {
      description = "Self-test this host's services and heartbeat an external monitor on success";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${heartbeat}/bin/service-heartbeat";
        # Short oneshot with a hard timeout, matching uplink-watchdog.nix:366 — a
        # hung probe dies rather than wedging the timer. It would fail toward
        # alerting anyway, but a wedged unit is worse to diagnose than a dead one.
        TimeoutStartSec = "60s";
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
