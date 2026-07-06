# Generic, opt-in local reverse-proxy/router — a thin wrapper around upstream
# `services.caddy` exposing a declarative `services.caddy-proxy.virtualHosts`
# attrset. Each virtual host is EITHER a reverse proxy to an upstream URL OR a
# static-file root; both forms are supported by the same submodule so a single
# Caddy instance can front several services.
#
# TOPOLOGY: Caddy sits BEHIND the Cloudflare Tunnel, not in front of it. A
# `cloudflared` connector (modules/nixos/cloudflared.nix, or a dedicated
# per-service connector) terminates the tunnel and forwards to Caddy on
# loopback; Caddy then routes to the right local service by Host header. This
# means:
#   - no public IP / no port-forward is ever required on the LAN;
#   - Cloudflare Access (Google SSO, service tokens, …) can front any vhost
#     independently, entirely in the Cloudflare account — this module has no
#     opinion about Access;
#   - HTTPS to the browser is handled by Cloudflare's edge; Caddy talks plain
#     HTTP to the tunnel and to upstreams, so `email`/ACME is not exercised in
#     this topology (kept as an option for a future direct-exposure vhost).
#
# NO-OP SAFE: gated behind `services.caddy-proxy.enable` (default false). Opens
# firewall 80/443 only when enabled — harmless when nothing binds to them
# (Caddy itself is the only local listener), and only needed if a vhost is
# ever exposed directly rather than via the tunnel.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.caddy-proxy;

  virtualHostSubmodule = lib.types.submodule (
    { name, ... }:
    {
      options = {
        reverseProxyTo = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Upstream URL to reverse-proxy this vhost to (e.g.
            "http://127.0.0.1:4000"). Mutually exclusive with `root` — set
            exactly one per virtual host.
          '';
        };

        root = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            Directory of static files to serve for this vhost (via
            `file_server`). Mutually exclusive with `reverseProxyTo` — set
            exactly one per virtual host.
          '';
        };

        extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Extra Caddyfile directives appended inside this vhost's block.";
        };
      };

    }
  );
in
{
  options.services.caddy-proxy = {
    enable = lib.mkEnableOption "a local Caddy reverse-proxy/router, sitting behind the Cloudflare Tunnel";

    email = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        ACME contact email, forwarded to `services.caddy.email`. Not exercised
        by the tunnel-backed topology (Cloudflare terminates TLS at the edge)
        but kept for a future vhost exposed directly.
      '';
    };

    virtualHosts = lib.mkOption {
      type = lib.types.attrsOf virtualHostSubmodule;
      default = { };
      description = ''
        Attrset of hostname -> vhost config. Each entry sets exactly one of
        `reverseProxyTo` (upstream URL) or `root` (static-file directory).
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.mapAttrsToList (name: vhost: {
        assertion = (vhost.reverseProxyTo != null) != (vhost.root != null);
        message = "services.caddy-proxy.virtualHosts.${name}: set exactly one of `reverseProxyTo` or `root`.";
      }) cfg.virtualHosts;
    }
    (lib.mkIf cfg.enable {
      networking.firewall.allowedTCPPorts = [
        80
        443
      ];

      services.caddy = {
        enable = true;
        inherit (cfg) email;

        virtualHosts = lib.mapAttrs (_hostname: vhost: {
          extraConfig =
            (
              if vhost.reverseProxyTo != null then
                "reverse_proxy ${vhost.reverseProxyTo}"
              else
                ''
                  root * ${vhost.root}
                  file_server
                ''
            )
            + "\n"
            + vhost.extraConfig;
        }) cfg.virtualHosts;
      };
    })
  ];
}
