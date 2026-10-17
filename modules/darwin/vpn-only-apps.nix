# Per-app VPN kill switch: chosen apps may reach the network ONLY through a
# WireGuard tunnel, and are refused outright when no tunnel is up.
#
# THE TRICK. macOS pf cannot match packets by application, but it CAN match by
# the unix group that owns the socket. So each listed app runs with its
# effective gid set to `cfg.group`, and one pf anchor says: that group may send
# TCP/UDP from a tunnel address, may use loopback, and is refused everywhere
# else. Prior art: kanishkdan/vpnonly (MIT CLI) uses exactly this pf `group`
# match. Not adopted as a tool: it runs its OWN userspace wireguard-go (NordVPN
# only without a patch), where this fleet's tunnels come from the WireGuard GUI
# app (hosts/macos.nix, masApps.WireGuard) and stay full-tunnel.
#
# MEASURED 2026-10-17, rules loaded into a throwaway anchor, a curl at uid 501
# egid 600 against a normal curl:
#   VPN off            group BLOCKED (refused in 1 ms, block counter +1)  normal OK
#   loopback (ollama)  group OK                                          normal OK
#   BERLIN up (utun4)  group OK, exit IP = the tunnel's                  normal OK
#   BERLIN dropped     group BLOCKED again                                normal OK
# The pass rule keys on SOURCE address, not on `utunN`: the WireGuard app picks
# a different utun index per connect, but every tunnel's Address is inside
# `tunnelSubnets`, and no socket can hold that address while the tunnel is down.
#
# WHAT IT DOES NOT COVER. ICMP (pf has no socket owner to match). DNS: lookups go
# through mDNSResponder, a system process outside the group, so with the VPN off
# a hostname can still be RESOLVED over the ISP's resolver — nothing connects.
# Any app that hands its connections to a system daemon (Safari/WebKit) carries
# no group at all, which is why this lists binaries, not "apps".
#
# A 30 s guard re-asserts pf's enable state and the anchor's rules, because
# something else (a VPN client, `pfctl -d`, an OS update) can flush either, and
# that would fail OPEN silently. Same periodic-root-daemon shape as
# ./clat-guard.nix.
#
# upstream-first: grepped the pinned nix-darwin modules/ for pfctl|pf.conf|
# pf.anchors — no option exists; networking.applicationFirewall is ALF (inbound
# only) → custom anchor. The group is users.groups and the launch permission is
# security.sudo.extraConfig, both nix-darwin's own options.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.vpnOnlyApps;
  user = config.system.primaryUser;

  # Under com.apple/* because Apple's /etc/pf.conf already evaluates that
  # wildcard, so nothing in /etc is edited. The 050 prefix sorts it ahead of
  # Apple's own numbered sub-anchors (200.AirDrop, 250.ApplicationFirewall, …).
  anchor = "com.apple/050.nix-vpn-only";

  rules = pkgs.writeText "nix-vpn-only.pf" ''
    tunnel = "{ ${lib.concatStringsSep ", " cfg.tunnelSubnets} }"
    pass out quick on lo0 all
    pass out quick proto { tcp udp } from $tunnel to any group ${toString cfg.gid} keep state
    block return out quick proto { tcp udp } from any to any group ${toString cfg.gid}
  '';

  guard = pkgs.writeShellApplication {
    name = "nix-vpn-only-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      ANCHOR=${lib.escapeShellArg anchor}
      RULES=${rules}
      log() { echo "$(date -u +%FT%TZ) nix-vpn-only-guard: $*"; }

      if ! /sbin/pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
        log "pf was disabled: enabling"
        /sbin/pfctl -E 2>&1 | grep -v '^$' || true
      fi

      # pfctl normalises rules on load, so compare the normalised forms:
      # `-n` parses the file without loading it.
      want=$(/sbin/pfctl -a "$ANCHOR" -nvf "$RULES" 2>/dev/null | grep -E '^(pass|block)' || true)
      have=$(/sbin/pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -E '^(pass|block)' || true)
      if [ -z "$want" ]; then
        log "rules file did not parse: $RULES"
        exit 1
      fi
      if [ "$want" != "$have" ]; then
        log "anchor $ANCHOR missing or changed: loading"
        /sbin/pfctl -q -a "$ANCHOR" -f "$RULES" 2>&1 | grep -v 'flushing\|present in the main\|See /etc/pf.conf\|^$' || true
      fi
    '';
  };

  # sudoers wants spaces in a command path backslash-escaped.
  sudoersPath = lib.replaceStrings [ " " ] [ "\\ " ];
in
{
  options.local.vpnOnlyApps = {
    enable = lib.mkEnableOption "the per-app VPN kill switch (pf group match + guarded launchers)";
    group = lib.mkOption {
      type = lib.types.str;
      default = "nix-vpn-only";
      description = "Group the guarded apps run under; pf matches on it.";
    };
    gid = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "Its gid. pf rules name the number, so it must stay fixed.";
    };
    tunnelSubnets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "10.34.0.0/16" ];
      description = "CIDRs every tunnel's Address falls in. A guarded app may only send from these.";
    };
    apps = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            executable = lib.mkOption {
              type = lib.types.str;
              description = "Absolute path of the app's Contents/MacOS binary. Children it forks inherit the group.";
            };
            icns = lib.mkOption {
              # str, not path: the usual value is a file inside a package's
              # store path ("${pkgs.x}/…/icon.icns"), which is a string.
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Icon for the Spotlight launcher; null wears the fleet mark.";
            };
          };
        }
      );
      default = { };
      description = "Spotlight name → binary. Each gets a Spotlight launcher, planted by modules/home/spotlight-actions.nix.";
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    users.groups.${cfg.group} = {
      inherit (cfg) gid;
      description = "Apps that may only use the network through a VPN tunnel";
    };
    users.knownGroups = [ cfg.group ];

    # The launchers run `sudo -n -u <self> -g <group> <binary>`: the same user,
    # only the gid changes, which grants nothing — the group's one property is
    # being firewalled. NOPASSWD so a Spotlight click needs no prompt.
    security.sudo.extraConfig = ''
      ${user} ALL = (${user} : ${cfg.group}) NOPASSWD: ${
        lib.concatMapStringsSep ", " (a: sudoersPath a.executable) (lib.attrValues cfg.apps)
      }
    '';

    launchd.daemons.vpn-only-guard = {
      # `command` for the boot-ordering exception (.claude/rules/launchd-naming.md),
      # as ./clat-guard.nix.
      command = "${guard}/bin/nix-vpn-only-guard";
      serviceConfig = {
        RunAtLoad = true;
        StartInterval = 30;
        ProcessType = "Background";
        StandardOutPath = "/var/log/nix-vpn-only-guard.log";
        StandardErrorPath = "/var/log/nix-vpn-only-guard.log";
      };
    };
  };
}
