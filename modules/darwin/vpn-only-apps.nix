# Per-app VPN split tunnel + kill switch: chosen apps reach the network ONLY
# through a WireGuard tunnel, every other app keeps the normal connection, and
# the chosen apps are refused outright when the tunnel is not there.
#
# TWO LAYERS, each covering the other's failure:
#   1. SPLIT — sing-box (nixpkgs) runs a TUN with per-process route rules: a
#      process whose path is inside a listed app bundle goes to a WireGuard
#      endpoint, everything else goes `direct`. One endpoint per `*.conf` in
#      `wireguardDir`, grouped under sing-box's own `urltest`, so it picks a live
#      server and fails over with no config of ours.
#   2. LOCK — pf cannot match an application, but it CAN match the unix group that
#      owns a socket. The listed apps run with egid `cfg.group`, and one anchor
#      lets that group send TCP/UDP only from sing-box's TUN address (or over
#      loopback). If sing-box is down there is no TUN, so the group is refused
#      instead of falling back to the ISP.
# Prior art for the pf `group` match: kanishkdan/vpnonly (MIT CLI). Not adopted:
# it runs its own wireguard-go with pf `route-to`, NordVPN-only without a patch.
#
# MEASURED 2026-10-17 on macos, sing-box 1.14.1, the operator's 7 PrivateVPN confs:
#   matched curl, TCP            exit = tunnel (Berlin, 3 of 3; then WIEN via urltest)
#   matched dig, UDP             exit = tunnel  →  qBittorrent's DHT/uTP/UDP trackers work
#   every other process          exit = ISP, at the same time
#   sing-box stopped, gid locked REFUSED by the pf block (counter +1)
# One gap that measurement found: while sing-box is UP, every packet leaves from
# its TUN address, so pf cannot tell "routed to the VPN" from "routed direct".
# Only the route rule decides — which is why it matches the whole BUNDLE path
# (Tor Browser's `firefox`, `tor`, `plugin-container` are all under it), never a
# single binary.
#
# WHAT IT DOES NOT COVER. ICMP (pf has no socket owner to match). DNS: lookups go
# through mDNSResponder, outside the group and outside the route rule, so a
# hostname is RESOLVED over the normal resolver — Tor does its own DNS, qBittorrent
# leaks tracker hostnames only. IPv6: the TUN is IPv4-only, so the group's IPv6 is
# refused by the pf block (fail-closed, not tunnelled). Apps that hand connections
# to a system daemon (Safari/WebKit) carry neither the group nor a matching path.
#
# KEY HANDLING. A conf's private key goes conf → jq → a pipe → sing-box. It is
# never in the Nix store (the confs live outside git, ./../home/wireguard-configs.nix)
# and never written to a file. Each conf has its own client key, so a conf only
# clashes with the SAME conf brought up in the WireGuard app at the same time.
#
# upstream-first: grepped the pinned nix-darwin modules/ for pfctl|pf.conf|
# pf.anchors|sing-box — no option exists (networking.applicationFirewall is ALF,
# inbound only; services/wg-quick.nix is full-tunnel) → custom daemons. The group
# is users.groups and the launch permission security.sudo.extraConfig, both
# nix-darwin's own. TOOL axis: sing-box owns the split (process_path rules,
# WireGuard endpoints, urltest) — used, not reimplemented. wireproxy was the
# runner-up and lost on UDP: its SOCKS5 is TCP-only (README TODO).
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
    pass out quick on lo0 all
    pass out quick proto { tcp udp } from ${cfg.tunSubnet} to any group ${toString cfg.gid} keep state
    block return out quick proto { tcp udp } from any to any group ${toString cfg.gid}
  '';

  # ".../Foo.app/Contents/MacOS/foo" → "^.../Foo\.app/": every process the app
  # starts lives under its bundle.
  bundleRegex = exe: "^" + lib.escapeRegex (builtins.head (lib.splitString "/Contents/" exe)) + "/";

  # The static part of the sing-box config; the runner splices the endpoints in.
  baseConfig = pkgs.writeText "nix-vpn-only-sing-box.json" (
    builtins.toJSON {
      log = {
        level = "warn";
        timestamp = true;
      };
      inbounds = [
        {
          type = "tun";
          tag = "tun-in";
          address = [ cfg.tunAddress ];
          auto_route = true;
          stack = "system";
        }
      ];
      outbounds = [
        {
          type = "direct";
          tag = "direct";
        }
      ];
      route = {
        auto_detect_interface = true;
        rules = [
          {
            process_path_regex = map (a: bundleRegex a.executable) (lib.attrValues cfg.apps);
            outbound = "vpn";
          }
        ];
        final = "direct";
      };
    }
  );

  singBox = pkgs.writeShellApplication {
    name = "nix-vpn-only-sing-box";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.jq
    ];
    text = ''
      DIR=${lib.escapeShellArg cfg.wireguardDir}

      # Split on the FIRST "=" only: base64 keys end in "=" padding.
      field() {
        awk -v k="$1" '{
          sub(/\r$/, ""); i = index($0, "="); if (!i) next
          n = substr($0, 1, i - 1); gsub(/[ \t]/, "", n)
          if (n == k) { v = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
        }' "$2"
      }

      endpoint() {
        local c=$1 ep
        ep=$(field Endpoint "$c")
        jq -n --arg tag "$(basename "$c" .conf)" \
          --arg pk "$(field PrivateKey "$c")" --arg pub "$(field PublicKey "$c")" \
          --arg addr "$(field Address "$c")" \
          --arg host "''${ep%:*}" --argjson port "''${ep##*:}" \
          '{type: "wireguard", tag: $tag, address: [$addr], private_key: $pk,
            peers: [{address: $host, port: $port, public_key: $pub,
                     allowed_ips: ["0.0.0.0/0", "::/0"]}]}'
      }

      gen() {
        local c
        for c in "$DIR"/*.conf; do endpoint "$c"; done |
          jq -s --slurpfile base ${baseConfig} \
            '. as $eps | $base[0]
             | .endpoints = $eps
             | .outbounds += [{type: "urltest", tag: "vpn", outbounds: [$eps[].tag]}]'
      }

      # Exiting non-zero makes launchd's KeepAlive retry, which covers a boot
      # where the conf directory is not readable yet.
      shopt -s nullglob
      confs=("$DIR"/*.conf)
      if [ ''${#confs[@]} -eq 0 ]; then
        echo "nix-vpn-only-sing-box: no *.conf in $DIR" >&2
        exit 1
      fi

      exec ${pkgs.sing-box}/bin/sing-box run -c <(gen)
    '';
  };

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
    enable = lib.mkEnableOption "the per-app VPN split tunnel and kill switch (sing-box + pf group lock)";
    wireguardDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.users.users.${user}.home}/.config/wireguard";
      defaultText = lib.literalMD "`.config/wireguard` in `system.primaryUser`'s home";
      description = ''
        Directory of WireGuard `*.conf` files; every one becomes a sing-box endpoint
        and sing-box's urltest picks among them. Read by root at daemon start.
        The default is where `local.wireguardConfigs` syncs them.
      '';
    };
    tunAddress = lib.mkOption {
      type = lib.types.str;
      default = "172.19.0.1/30";
      description = "sing-box TUN address. The pf lock lets the group send only from its subnet.";
    };
    tunSubnet = lib.mkOption {
      type = lib.types.str;
      default = "172.19.0.0/30";
      description = "The network of `tunAddress`, as pf writes it.";
    };
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
    apps = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            executable = lib.mkOption {
              type = lib.types.str;
              description = ''
                Absolute path of the app's Contents/MacOS binary. Its whole bundle is
                routed to the VPN, so children it forks are covered too.
              '';
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
      description = "Spotlight name → app. Each gets a Spotlight launcher, planted by modules/home/spotlight-actions.nix.";
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

    # `command` for the boot-ordering exception (.claude/rules/launchd-naming.md),
    # as ./clat-guard.nix.
    launchd.daemons.vpn-only-sing-box = {
      command = "${singBox}/bin/nix-vpn-only-sing-box";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/var/log/nix-vpn-only-sing-box.log";
        StandardErrorPath = "/var/log/nix-vpn-only-sing-box.log";
      };
    };

    launchd.daemons.vpn-only-guard = {
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
