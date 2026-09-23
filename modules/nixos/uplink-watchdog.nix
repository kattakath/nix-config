# ---- Uplink watchdog: keep the host reachable when the ROUTER lies ----------
#
# THE FAILURE THIS EXISTS FOR, measured 2026-09-22. nixpi is dual-homed onto the
# SAME router (end0 10.0.0.37 wired, wlan0 10.0.0.38 on that router's SSID), and
# the only route in is the Cloudflare tunnel, which needs working INTERNET rather
# than merely a LAN. When that router keeps its LAN alive but loses its UPLINK:
#
#   * end0 keeps carrier, so dhcpcd keeps its default route at metric 1002 and the
#     kernel keeps preferring it — a metric is a queue position, not a pulse check;
#   * wlan0 stays associated, because the AP is beaconing perfectly well and
#     wpa_supplicant cannot see that the internet behind it is gone;
#   * so BOTH paths are dead and nothing in the stack notices.
#
# A route-metric change does NOT fix this and was the first thing tried on paper:
# reordering the two default routes just picks a different dead path, because both
# terminate on the same router.
#
# UPSTREAM FIRST (grepped the pinned nixpkgs 2026-09-22): `dhcpcd.nix` exposes no
# metric/nogateway option at all (only raw extraConfig); `RouteMetric` exists but
# lives in networkd.nix, and this host runs dhcpcd/scripted networking, so using it
# means migrating the whole network stack; and NOTHING under
# nixos/modules/services/networking/ does connectivity-based failover — the only
# "connectivity" hits are unrelated services (cloudflared, nebula, i2pd, veilid).
# So the probe-and-escalate loop below is genuinely ours, and deliberately small.
#
# WHAT IT DOES NOT DO. It cannot conjure an uplink. The fallback AP is only useful
# while it is actually broadcasting — a phone hotspot that sleeps with no client
# attached is not an unattended backup, and this module cannot make it one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.uplinkWatchdog;

  # Probes bind to nothing: they test whatever the DEFAULT ROUTE currently is.
  # Per-interface probing was tried and REJECTED — `curl --interface wlan0` fails
  # on this host whenever wlan0 does not own the default route (asymmetric return
  # path), so a per-interface probe reports a healthy link as dead. Testing the
  # default route and then escalating needs no policy routing at all, and each
  # escalation step is verified by the next probe rather than assumed.
  probe = pkgs.writeShellApplication {
    name = "uplink-probe";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      # Two targets, because one provider having a bad minute is not an outage.
      # -k: we are proving reachability, not identity; a captive portal that
      # answers with its own cert should still count as NOT having internet, so
      # the status code is checked too.
      for t in ${lib.concatStringsSep " " cfg.probeTargets}; do
        code=$(curl -sk --max-time ${toString cfg.probeTimeout} -o /dev/null -w '%{http_code}' "https://$t/" || true)
        case "$code" in
          2* | 3*) exit 0 ;;
        esac
      done
      exit 1
    '';
  };

  watchdog = pkgs.writeShellApplication {
    name = "uplink-watchdog";
    runtimeInputs = with pkgs; [
      iproute2
      systemd
      gnused
      gnugrep
      gawk
      coreutils
    ];
    text = ''
      STATE=/run/uplink-watchdog.state
      FAILS=/run/uplink-watchdog.fails
      WPA_LIVE=${cfg.wpaRuntimeConf}
      WPA_CARD=${cfg.wpaSourceConf}

      state() { cat "$STATE" 2>/dev/null || echo normal; }
      set_state() { printf '%s' "$1" > "$STATE"; }
      bump() { n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$FAILS"; echo "$n"; }
      clear_fails() { printf '0' > "$FAILS"; }

      # Restoring is ALWAYS safe and always available: the card's copy is the
      # source of truth, so the worst case of any escalation is one supplicant
      # restart back to the shipped configuration. A reboot does the same thing
      # on its own, which is why nothing here ever writes to the card.
      restore() {
        ip route show default dev ${cfg.wiredInterface} | grep -q . || \
          ip route add default via "$1" dev ${cfg.wiredInterface} metric 1002 2>/dev/null || true
        if ! cmp -s "$WPA_CARD" "$WPA_LIVE"; then
          install -m 0600 "$WPA_CARD" "$WPA_LIVE"
          systemctl restart ${cfg.supplicantUnit}
        fi
        set_state normal
      }

      gw=$(ip route show default dev ${cfg.wiredInterface} | awk '{print $3; exit}')
      [ -n "$gw" ] || gw=${cfg.wiredGatewayHint}

      if ${probe}/bin/uplink-probe; then
        clear_fails
        # Healthy. If we are degraded, try the normal configuration again — that
        # is the whole recovery path, and it costs one probe cycle to find out.
        if [ "$(state)" != "normal" ]; then
          echo "uplink-watchdog: uplink healthy while degraded — restoring normal routing/Wi-Fi"
          restore "$gw"
        fi
        exit 0
      fi

      n=$(bump)
      if [ "$n" -lt ${toString cfg.failuresBeforeAction} ]; then
        echo "uplink-watchdog: probe failed ($n/${toString cfg.failuresBeforeAction}) — not acting yet"
        exit 0
      fi

      case "$(state)" in
        normal)
          # Step 1: stop preferring the wired path. If the router is merely a dead
          # uplink this changes nothing on its own, but it is the cheap, reversible
          # move and it is what makes step 2's probe meaningful.
          echo "uplink-watchdog: demoting ${cfg.wiredInterface} default route"
          ip route del default dev ${cfg.wiredInterface} 2>/dev/null || true
          set_state wired-demoted
          ;;
        wired-demoted)
          # Step 2: the router itself is the problem — leave its SSID for the
          # fallback by inverting the priorities in the RUNTIME copy only.
          echo "uplink-watchdog: still down — moving wlan0 to the fallback network"
          # The two priority VALUES are READ OFF THE CARD, never hardcoded. The
          # card is written by nixpi-wifi-creds, which ranks n networks as
          # priority=n..1 — so a two-AP card carries 2/1, while a hand-written
          # conf may use any pair. Hardcoding one pair meant the sed silently
          # matched NOTHING against the other, leaving this step a no-op that
          # restarted the supplicant with an identical config. Measured
          # 2026-09-23 on the live card. Extraction is sed/sort/head only, so
          # it adds no runtimeInputs.
          hi=$(sed -n 's/.*priority=\([0-9]\{1,\}\).*/\1/p' "$WPA_CARD" | sort -rn | head -1)
          lo=$(sed -n 's/.*priority=\([0-9]\{1,\}\).*/\1/p' "$WPA_CARD" | sort -n  | head -1)
          if [ -n "$hi" ] && [ "$hi" != "$lo" ]; then
            sed -e "s/priority=$hi$/priority=__T__/" \
                -e "s/priority=$lo$/priority=$hi/" \
                -e "s/priority=__T__/priority=$lo/" \
                "$WPA_CARD" > "$WPA_LIVE.new"
          else
            # One network, or an unranked conf: there is nothing to invert, and
            # pretending otherwise would restart the supplicant for no reason.
            echo "uplink-watchdog: only one ranked network — nothing to invert"
            cp "$WPA_CARD" "$WPA_LIVE.new"
          fi
          install -m 0600 "$WPA_LIVE.new" "$WPA_LIVE" && rm -f "$WPA_LIVE.new"
          systemctl restart ${cfg.supplicantUnit}
          set_state fallback
          ;;
        fallback)
          # Step 3: nothing worked. Put everything back rather than sit in a
          # half-changed state, and let the next cycle start the ladder again.
          echo "uplink-watchdog: fallback did not help — restoring shipped configuration"
          restore "$gw"
          clear_fails
          ;;
      esac
    '';
  };
in
{
  options.local.uplinkWatchdog = {
    enable = lib.mkEnableOption "probe the uplink and fail over when the router stops reaching the internet";

    wiredInterface = lib.mkOption {
      type = lib.types.str;
      default = "end0";
      description = "Wired interface whose default route is demoted first.";
    };

    wiredGatewayHint = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.1";
      description = "Gateway used to restore the wired default route when the live route is already gone.";
    };

    wpaRuntimeConf = lib.mkOption {
      type = lib.types.path;
      default = "/run/wpa_supplicant-firmware.conf";
      description = ''
        The RUNTIME wpa_supplicant config. The watchdog edits only this copy, never
        the card's, so any reboot returns to the shipped network ranking.
      '';
    };

    wpaSourceConf = lib.mkOption {
      type = lib.types.path;
      default = "/boot/firmware/wpa_supplicant.conf";
      description = "The card's copy — source of truth, read-only to this module.";
    };

    supplicantUnit = lib.mkOption {
      type = lib.types.str;
      default = "supplicant-wlan0.service";
      description = "Unit restarted after rewriting the runtime config.";
    };

    probeTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "1.1.1.1"
        "8.8.8.8"
      ];
      description = "Addresses (not names — DNS may be the thing that is broken) probed over HTTPS.";
    };

    probeTimeout = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "Per-target probe timeout in seconds.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "60s";
      description = "How often to probe.";
    };

    failuresBeforeAction = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = ''
        Consecutive failures before the ladder starts. Three at a 60s interval
        means a real outage acts within ~3 minutes while a single bad probe — a
        reboot of something upstream, a transient loss — never touches routing.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.uplink-watchdog = {
      description = "Probe the uplink and fail over when the router stops reaching the internet";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${watchdog}/bin/uplink-watchdog";
        # A watchdog that cannot be cancelled is worse than none: this one is a
        # short oneshot, so a hung probe dies rather than wedging the timer.
        TimeoutStartSec = "90s";
      };
    };

    systemd.timers.uplink-watchdog = {
      description = "Periodic uplink probe";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "10s";
      };
    };
  };
}
