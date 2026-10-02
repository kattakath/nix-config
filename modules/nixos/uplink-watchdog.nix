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
#
# NO FIELD EVIDENCE OF THIS LADDER ACTING EXISTS — do not read one into the comments
# below. Forensics on the dead card, 2026-10-01: `nixos-rebuild list-generations` showed
# GENERATION 1 ONLY, nixpkgs dated 09-07, while this module was born 2026-09-22 (#558).
# No generation carrying it was ever deployed, so it cannot have run during the 8-day
# 09-23 → 10-01 outage, and every symptom then attributed to it came from HAND EDITS made
# over SSH to /boot/firmware/wpa_supplicant.conf. Host OBSERVATIONS below (dhcpcd's two
# metrics, the hotspot subnet, wpa_cli's dead control socket) are real and stand; claims
# about what this ladder DID in the field are unavailable, and none are made.
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
      PREVMETRIC=/run/uplink-watchdog.prevmetric
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
        # The mirror of the demotion: put the preferred metric back, again ADD before
        # DELETE. The metric comes from what was actually observed at demote time, so a
        # host whose DHCP hands out a different value is restored to ITS value rather
        # than to a number hardcoded here.
        rgw=$(ip -4 route show default dev ${cfg.wiredInterface} | awk '{print $3; exit}')
        rmet=$(cat "$PREVMETRIC" 2>/dev/null || echo 1002)
        if [ -n "$rgw" ]; then
          if ip route add default via "$rgw" dev ${cfg.wiredInterface} metric "$rmet" 2>/dev/null; then
            ip route del default via "$rgw" dev ${cfg.wiredInterface} metric ${toString cfg.demotedMetric} 2>/dev/null || true
          fi
        fi
        # WHY THE GUARD — and what the old form ACTUALLY cost. The record here was
        # OVERSTATED by #717 and is corrected (2026-10-02).
        #
        # `writeShellApplication` bakes `set -euo pipefail`, so before this guard a failing
        # `cmp` or `install` aborted restore() BEFORE `set_state normal`. That is the whole
        # casualty, and it is serious on its own: the state file stayed `wired-demoted`,
        # every later cycle re-entered step 3 and aborted at the same line, and the LADDER
        # FROZE in that state — so step 1, the hotspot grab that is the only way back to this
        # host once the house uplink is dead, never ran again.
        #
        # IT DID NOT STRAND THE HOST WITH NO DEFAULT ROUTE, which #717's title and body
        # claimed. Two reasons, both readable in the pre-#717 revision:
        #   * the route re-add was restore()'s FIRST statement and ended in `|| true`, so it
        #     was always reached and could not abort the function. Never the casualty.
        #   * step 2 deleted only the WIRED leg. dhcpcd's wlan0 default route (metric 3003,
        #     § MEASURED below) was untouched, so a default route remained.
        #
        # What is genuinely only best-effort is restoring a WORKING route. That re-add was —
        # and the `-n "$rgw"` test above still is — CONDITIONAL: the old form ran it only
        # where `ip route show default dev <iface> | grep -q .` found NOTHING, so a route
        # that is PRESENT BUT BLACK-HOLED skips the re-add precisely when it would help.
        # Ending the demotion is guaranteed; a usable path out is not.
        #
        # Measured 2026-10-01, standalone, both directions: the old form exits 1 with no
        # `set_state` reached when $WPA_CARD is absent; this form reaches `STATE=normal`,
        # exit 0 — and still copies the card when it IS readable, so the restore it exists
        # for is not weakened. That measurement holds; only its consequence was mis-stated.
        #
        # `cmp -s` is the second trap, not just `install`: an unreadable source makes cmp
        # ERROR, which makes `! cmp` TRUE, so it entered the branch precisely when it
        # could not complete it. Hence the `-r` test leads the condition.
        #
        # Losing the wifi conf restore is the lesser harm either way — a reboot re-reads the
        # card anyway, whereas a frozen ladder waits for the operator to notice.
        if [ -r "$WPA_CARD" ] && ! cmp -s "$WPA_CARD" "$WPA_LIVE"; then
          install -m 0600 "$WPA_CARD" "$WPA_LIVE" \
            || echo "uplink-watchdog: could not restore $WPA_LIVE from the card" >&2
          systemctl restart ${cfg.supplicantUnit} || true
        fi
        # Reached unconditionally now. Ending the demotion matters more than any step
        # above succeeding.
        set_state normal
      }


      if ${probe}/bin/uplink-probe; then
        clear_fails
        # Healthy. If we are degraded, try the normal configuration again — that
        # is the whole recovery path, and it costs one probe cycle to find out.
        if [ "$(state)" != "normal" ]; then
          echo "uplink-watchdog: uplink healthy while degraded — restoring normal routing/Wi-Fi"
          restore
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
          # STEP 1: RE-SCAN THE AIR. Restarting the supplicant makes wpa_supplicant
          # re-evaluate every network in the card and associate with the highest
          # `priority=` one that is ACTUALLY IN RANGE.
          #
          # This is step 1 and not step 2 because of what the fallback network IS on
          # this host: it is a PHONE HOTSPOT on mobile data, brought up BY HAND when
          # the house link dies. Its appearance is therefore not a spare AP, it is an
          # emergency beacon — the operator turning it on IS the signal, and the only
          # remaining way to reach this host at all (sshd is loopback-bound and the
          # Cloudflare tunnel needs working internet, so a dead uplink means no LAN
          # path either). Grabbing it must be the FIRST thing tried, not the second.
          #
          # WHY A RESTART IS REQUIRED AND A PRIORITY IS NOT ENOUGH: `priority=` is
          # consulted at (RE)ASSOCIATION time only. A supplicant already associated to
          # the lower-priority house AP will NOT roam to a higher-priority SSID that
          # appears later — there is no bgscan configured, and bgscan governs BSS
          # roaming within one ESS anyway, not switching between SSIDs. So when the
          # house AP keeps beaconing but its uplink is dead — the common case here —
          # nothing moves until something forces re-association. This is that force.
          echo "uplink-watchdog: uplink down — re-scanning for a higher-priority network"
          systemctl restart ${cfg.supplicantUnit}
          set_state wifi-rescanned
          ;;
        wifi-rescanned)
          # STEP 2: still down, so the best Wi-Fi in range does not help either.
          # Stop preferring the wired path, in case it is the wired router that is
          # black-holing while something else on Wi-Fi could carry traffic.
          echo "uplink-watchdog: still down — demoting ${cfg.wiredInterface} default route"
          # DEMOTE BY METRIC, NEVER BY DELETION — and ADD BEFORE DELETE, so there is no
          # instant with no default route at all.
          #
          # MEASURED on the live host: dhcpcd already installs BOTH legs with distinct
          # metrics and no configuration from us —
          #   default via 10.0.0.1 dev end0  metric 1002
          #   default via 10.0.0.1 dev wlan0 metric 3003
          # (dhcpcd 10.3.2 uses 1000 + if_nametoindex, +100 for wireless.) So routing
          # ALREADY expresses the preference this step wants to change. `ip route del`
          # did not merely demote the wired leg, it DESTROYED a working primitive and
          # made the restore path the only way back — which is the strand that froze the
          # ladder in `wired-demoted`.
          #
          # Raising end0 above wlan0's 3003 hands the wireless leg the traffic without
          # touching wlan0 at all. `metric` is part of a route's KEY, so `ip route
          # replace ... metric N` would ADD a second route rather than change the first;
          # add-then-delete is the only pair that is correct in both orders. If the add
          # fails the delete never runs and we keep the preferred route; if the delete
          # fails we hold two routes and the preferred one still wins. Neither branch
          # can leave the host with none.
          #
          # The gateway is READ FROM THE LIVE ROUTE at the moment of use, not configured:
          # a hardcoded hint is wrong in the hotspot subnet (the host was observed at
          # 10.57.169.163 there), and a route added via a wrong gateway is worse than no
          # route added.
          dgw=$(ip -4 route show default dev ${cfg.wiredInterface} | awk '{print $3; exit}')
          dmet=$(ip -4 route show default dev ${cfg.wiredInterface} \
            | awk '{for (i = 1; i < NF; i++) if ($i == "metric") print $(i + 1); exit}')
          if [ -n "$dgw" ]; then
            printf '%s' "''${dmet:-1002}" > "$PREVMETRIC"
            if ip route add default via "$dgw" dev ${cfg.wiredInterface} metric ${toString cfg.demotedMetric} 2>/dev/null; then
              ip route del default via "$dgw" dev ${cfg.wiredInterface} metric "''${dmet:-1002}" 2>/dev/null || true
            else
              echo "uplink-watchdog: could not add the demoted route; leaving the wired leg preferred" >&2
            fi
          else
            echo "uplink-watchdog: no wired default route to demote" >&2
          fi
          set_state wired-demoted
          ;;
        wired-demoted)
          # STEP 3: nothing worked. Put everything back rather than sit in a
          # half-changed state, and let the next cycle start the ladder again.
          echo "uplink-watchdog: nothing helped — restoring shipped configuration"
          restore
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

    demotedMetric = lib.mkOption {
      type = lib.types.int;
      default = 4000;
      description = ''
        Metric the wired default route is raised to while demoted. Must be HIGHER than
        the wireless leg's metric or the demotion changes nothing — dhcpcd gives the
        wireless leg `1000 + if_nametoindex + 100`, observed as 3003 on this host, so
        4000 clears it with room to spare.

        This REPLACED a `wiredGatewayHint` holding a hardcoded "10.0.0.1". That option
        existed only because the old code DELETED the route, leaving nothing to read a
        gateway from; demoting by metric keeps a route present, so the gateway is read
        live at the moment of use and the hardcoded value — wrong in the hotspot subnet,
        where the host was seen at 10.57.169.163 — is gone rather than corrected.
      '';
    };

    wpaRuntimeConf = lib.mkOption {
      type = lib.types.path;
      default = "/run/wpa_supplicant-firmware.conf";
      description = ''
        The RUNTIME wpa_supplicant config. Since 2026-09-23 the watchdog no longer
        REWRITES this file at all — it only restores it from the card. The priority
        inversion that used to edit it was removed: inverting is correct for two peer
        APs, and WRONG here, where the second network is an on-demand phone hotspot
        that must always be preferred when present.
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
    # THE DIAGNOSTIC TOOL THIS LADDER CANNOT BE DEBUGGED WITHOUT.
    #
    # Measured 2026-10-01, three times in one session: nothing on this host could
    # answer "what networks can you see?" or "what are you associated to?".
    # `wpa_cli` IS already on PATH (the supplicant package ships it) and is UNUSABLE
    # — it fails to create its client socket even as root:
    #   /run/wpa_supplicant/client: No such file or directory
    #   Failed to connect to non-global ctrl_ifname: wlan0  error: Invalid argument
    # while the server socket /run/wpa_supplicant/wlan0 plainly exists and root can
    # write that directory. Not chased further; `iw` talks to nl80211 directly and
    # needs no control socket, so it sidesteps the problem rather than fighting it.
    #
    # WHAT IT COST TO NOT HAVE THIS: an association failure could not be told apart
    # from "the AP was not broadcasting" (the hotspot had idle-timed-off and nothing
    # on the Pi could say so), and confirming which AP serves an SSID took reading
    # BSSIDs out of the supplicant journal. One of those answers needed the operator
    # to power-cycle household Wi-Fi twice, for a question `iw dev wlan0 scan` answers
    # in two seconds.
    #
    # Scoped to this module rather than core.nix on purpose: it is here BECAUSE the
    # failover ladder exists, so `local.uplinkWatchdog.enable = false` should take it
    # away too. nixvm has no radio and gains nothing from carrying it.
    environment.systemPackages = [ pkgs.iw ];

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
