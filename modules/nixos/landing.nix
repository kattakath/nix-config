# modules/nixos/landing.nix — public landing page: Caddy serves the static
# `landing` package (packages/landing.nix) on loopback, fronted by a DEDICATED
# Cloudflare Tunnel (infra/cloudflare/landing.nix, mirroring the litellm tunnel).
# TLS terminates at the Cloudflare edge, so Caddy speaks plain HTTP on localhost;
# the connector reaches it over the loopback origin the tunnel ingress points at.
#
# NO-OP SAFE: imported for ALL NixOS hosts via flake.nix, but everything is gated
# behind `services.landing-page.enable` (default false). Enabling it starts Caddy;
# the tunnel connector additionally requires the host to declare the
# `landing-tunnel-token` agenix secret (see the runbook in the CF infra file) —
# until then the page is served locally but not exposed (a graceful partial
# bring-up, same guard style as modules/nixos/cloudflared.nix's haveToken).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.landing-page;
  # A DEDICATED tunnel token, distinct from the host connector's
  # "<hostname>-tunnel-token". Only wire the connector once the host provides it.
  tokenSecretName = "landing-tunnel-token";
  haveToken = lib.hasAttr tokenSecretName config.age.secrets;
in
{
  options.services.landing-page = {
    enable = lib.mkEnableOption "public landing page (Caddy static site behind a dedicated Cloudflare Tunnel)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../packages/landing.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../../packages/landing.nix { }";
      description = "The built static site served at the web root (default: packages/landing.nix).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = ''
        Loopback TCP port Caddy serves plain HTTP on. MUST match the tunnel
        ingress origin in infra/cloudflare/landing.nix (http://localhost:<port>).
        Bound to 127.0.0.1/::1 only — never exposed on the LAN; the Cloudflare
        connector (same host) is the sole client.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy = {
      enable = true;
      # Port-only site address: HTTP (no hostname ⇒ no auto-HTTPS/cert, TLS is at
      # the CF edge) AND host-agnostic — cloudflared forwards the original
      # `Host: kattakath.com`, so a `localhost`-keyed site would 404. `bind`
      # restricts the listener to loopback (connector-only; never on the LAN).
      virtualHosts.":${toString cfg.port}".extraConfig = ''
        bind 127.0.0.1 ::1
        root * ${cfg.package}
        encode zstd gzip
        file_server

        # Hardening headers (safe/enforced — none of these change app behaviour).
        header {
          -Server
          X-Content-Type-Options nosniff
          Referrer-Policy strict-origin-when-cross-origin
          X-Frame-Options DENY
          Permissions-Policy "fullscreen=(self), autoplay=(self), geolocation=(), camera=(), microphone=(), payment=()"
        }

        # CSP in REPORT-ONLY: it cannot break the page — it only logs violations to
        # the browser console. This app is WebGPU + workers + blob/data URIs +
        # cross-origin media + a lazy esm.sh import, which are easy to over-restrict;
        # verify a clean console in a real browser, then rename this header to
        # `Content-Security-Policy` to enforce.
        header Content-Security-Policy-Report-Only "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' https://esm.sh; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com data:; img-src 'self' data: blob: https://image.civitai.com https://*.civitai.com; media-src 'self' blob: data: https://image.civitai.com https://*.civitai.com; connect-src 'self' https://civitai.com https://civitai.red https://image.civitai.com https://esm.sh; worker-src 'self' blob:; child-src blob:; frame-ancestors 'none'; base-uri 'self'"

        # Long-cache the content-addressed vendored libs; keep the entry HTML fresh.
        header /vendor/* Cache-Control "public, max-age=31536000, immutable"
        header /index.html Cache-Control "no-cache"
      '';
    };

    # Dedicated connector for the landing tunnel (coexists with the per-host
    # connector in modules/nixos/cloudflared.nix — separate unit, separate token).
    # Hardening mirrors that module; the token arrives via an agenix EnvironmentFile
    # (TUNNEL_TOKEN=…) so it never hits argv or the world-readable /nix/store.
    systemd.services.cloudflared-landing = lib.mkIf haveToken {
      description = "Cloudflare Tunnel connector for the landing page (remotely-managed, token from agenix)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run";
        EnvironmentFile = config.age.secrets.${tokenSecretName}.path;

        Restart = "on-failure";
        RestartSec = 5;

        # ---- systemd hardening (from modules/nixos/cloudflared.nix) -------------
        DynamicUser = true;
        RuntimeDirectory = "cloudflared-landing";
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        SystemCallArchitectures = "native";
      };
    };
  };
}
