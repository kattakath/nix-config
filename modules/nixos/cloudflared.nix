# Cloudflare Tunnel — boot-time, LOGINLESS token connector (remotely-managed).
#
# WHY NOT `services.cloudflared` (upstream)? The NixOS module only drives
# LOCALLY-managed tunnels: it wants a credentials JSON + an in-repo ingress and
# runs `cloudflared tunnel run <uuid>`. It has NO token support. This repo moved
# to REMOTELY-managed (token) tunnels so every host's connector comes up at boot
# with zero interactive login (no `cloudflared tunnel login`, no cert.pem) and
# its ingress/DNS live in the Cloudflare account (provisioned by
# scripts/cf-one-provision.sh), not here. So we run our own hardened unit.
#
# TOKEN HANDLING (never in argv / never in the store): the connector token is a
# secret. It is delivered as `TUNNEL_TOKEN=…` via an agenix-decrypted
# EnvironmentFile — cloudflared reads `TUNNEL_TOKEN` from the environment, so it
# never appears on the command line (argv is world-readable via /proc) nor in a
# world-readable /nix/store path.
#
# NO-OP SAFE: this module is imported for ALL NixOS hosts via flake.nix. It only
# activates the unit when the host has declared its own
# `age.secrets."<hostName>-tunnel-token"` entry (each host does so in
# hosts/<host>.nix). A host without that secret (e.g. an unprovisioned nixamd)
# gets NO service and never expects a missing token file at activation.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  tokenSecretName = "${config.networking.hostName}-tunnel-token";
  # Only wire the unit when the host actually declares the token secret. Guarding
  # on the declared secret (rather than unconditionally) keeps the module a safe
  # no-op on hosts that have no provisioned tunnel yet.
  haveToken = lib.hasAttr tokenSecretName config.age.secrets;
in
{
  config = lib.mkIf haveToken {
    systemd.services.cloudflared-connector = {
      description = "Cloudflare Tunnel connector (remotely-managed, token from agenix)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        # Token via env (EnvironmentFile), NOT argv. `tunnel run` with no name/UUID
        # picks up TUNNEL_TOKEN from the environment for a remotely-managed tunnel.
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run";
        # agenix decrypts this at boot with the host SSH key; one line: TUNNEL_TOKEN=…
        EnvironmentFile = config.age.secrets.${tokenSecretName}.path;

        Restart = "on-failure";
        RestartSec = 5;

        # ---- systemd hardening -------------------------------------------------
        DynamicUser = true;
        RuntimeDirectory = "cloudflared";
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
