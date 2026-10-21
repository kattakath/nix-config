# CLAT46 guard: undo macOS turning on 464XLAT where no NAT64 exists.
#
# WHAT HAPPENS. On a dual-stack Wi-Fi (native IPv4 via DHCP + native IPv6), macOS
# 27.0.1 sometimes activates CLAT46 on its own: the Wi-Fi service's IPv4 becomes
# `192.0.0.2` with router `192.0.0.1` and `CLAT46 : TRUE`, and the RTADV side
# UNPUBLISHES the DHCPv4 service. Every IPv4 packet then goes into a translator
# with no NAT64 behind it, so IPv4-only hosts (GitHub, AWS, 1.1.1.1) time out while
# IPv6 hosts (Google) work. Diagnosed 2026-10-16 on the home network, where:
#   - DHCPv4 was BOUND (router 10.0.0.1, ARP-verified),
#   - the RA carried no PREF64 option (RFC 8781), DHCP no option 108 (RFC 8925),
#   - the ISP resolvers returned no AAAA for ipv4only.arpa (RFC 7050),
#   - `State:/Network/Interface/en0/NAT64` showed PLAT discovery complete with NO
#     NAT64Prefix,
#   - no persisted CLAT flag existed in /Library/Preferences/SystemConfiguration.
# Nothing asked for CLAT, and it cannot work without a NAT64 prefix.
#
# WHAT FIXES IT, MEASURED. IPv4-side resets do not (DHCP re-init, Wi-Fi power cycle,
# `-setdhcp`): the cause is on the IPv6 side. `networksetup -setv6off` restored IPv4
# in ~6 s; `-setv6automatic` then brought IPv6 back and CLAT did NOT re-assert.
# DNS flushes are irrelevant.
#
# WHAT THIS DOES. Every 30 s, two scutil reads. It acts ONLY when the global IPv4
# router is the CLAT gateway 192.0.0.1 AND the service interface has no NAT64
# prefix — on a genuinely IPv6-only network with NAT64 (a phone hotspot) CLAT is
# correct and this does nothing. A 10-minute cooldown stops it from flapping on a
# network where CLAT re-asserts immediately; each action is logged.
#
# upstream-first: nix-darwin has no option for CLAT or for IPv6 toggling (grepped
# the pinned modules/ for clat/nat64/setv6), and macOS exposes no supported switch
# to disable CLAT46 on Wi-Fi. Built on nix-darwin's `launchd.daemons` like the
# ollama metal guard (./ollama-daemon.nix), whose shape this copies.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.clatGuard;

  guard = pkgs.writeShellApplication {
    name = "nix-clat-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
    ];
    text = ''
      SVC=${lib.escapeShellArg cfg.service}
      STAMP=/var/db/nix-clat-guard.stamp
      COOLDOWN=${toString cfg.cooldownSeconds}
      log() { echo "$(date -u +%FT%TZ) nix-clat-guard: $*"; }

      router=$(printf 'show State:/Network/Global/IPv4\n' | /usr/sbin/scutil | awk '$1=="Router"{print $3}')
      [ "$router" = 192.0.0.1 ] || exit 0

      dev=$(/usr/sbin/networksetup -listallhardwareports |
        awk -v s="Hardware Port: $SVC" '$0==s{getline; print $2; exit}')
      [ -n "$dev" ] || { log "no device for service $SVC"; exit 0; }

      # A real NAT64 prefix means CLAT is legitimate (IPv6-only network): leave it.
      if printf 'show State:/Network/Interface/%s/NAT64\n' "$dev" | /usr/sbin/scutil | grep -q NAT64Prefix; then
        exit 0
      fi

      if [ -f "$STAMP" ] && [ $(( $(date +%s) - $(/usr/bin/stat -f %m "$STAMP") )) -lt "$COOLDOWN" ]; then
        log "CLAT46 on $dev with no NAT64 prefix, but within cooldown; not acting"
        exit 0
      fi
      touch "$STAMP"

      log "CLAT46 active on $dev (router 192.0.0.1) with no NAT64 prefix: toggling IPv6 on $SVC"
      /usr/sbin/networksetup -setv6off "$SVC"
      sleep 5
      /usr/sbin/networksetup -setv6automatic "$SVC"
      sleep 10
      after=$(printf 'show State:/Network/Global/IPv4\n' | /usr/sbin/scutil | awk '$1=="Router"{print $3}')
      log "IPv4 router after toggle: ''${after:-none}"
    '';
  };
in
{
  options.local.clatGuard = {
    enable = lib.mkEnableOption "the CLAT46 guard (undo spurious 464XLAT on dual-stack Wi-Fi)";
    service = lib.mkOption {
      type = lib.types.str;
      default = "Wi-Fi";
      description = "Network service name whose IPv6 is toggled (as `networksetup -listallnetworkservices` prints it).";
    };
    cooldownSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Minimum seconds between two toggles, so a network where CLAT re-asserts at once cannot make it flap.";
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    launchd.daemons.clat-guard = {
      # `command` with a store path that execs the named binary, same boot-ordering
      # reason as ./ollama-daemon.nix's metal guard.
      command = "${guard}/bin/nix-clat-guard";
      serviceConfig = {
        RunAtLoad = true;
        StartInterval = 30;
        # A periodic one-shot that exits 0, NOT KeepAlive.
        ProcessType = "Background";
        StandardOutPath = "/var/log/nix-clat-guard.log";
        StandardErrorPath = "/var/log/nix-clat-guard.log";
      };
    };
  };
}
