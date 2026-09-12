# Cloudflare Tunnel — boot-time, LOGINLESS token connector (remotely-managed).
#
# WHY NOT upstream `services.cloudflared`? That module only drives LOCALLY-managed
# tunnels: it wants a credentials JSON + an in-repo ingress and runs
# `cloudflared tunnel run <uuid>`. It has NO token support. A REMOTELY-managed
# (token) tunnel comes up at boot with zero interactive login (no
# `cloudflared tunnel login`, no cert.pem); its ingress/DNS live in the Cloudflare
# account (managed in the dashboard or via IaC), not in your NixOS config. This is
# a small hardened unit for exactly that.
#
# TOKEN HANDLING (never in argv, never in the store): the connector token is a
# secret, delivered as `TUNNEL_TOKEN=…` via a systemd EnvironmentFile placed at
# `tokenFile` out-of-band (agenix/sops/manual). cloudflared reads TUNNEL_TOKEN
# from the environment, so it never appears on the command line (argv is
# world-readable via /proc) nor in a world-readable /nix/store path.
#
# ACTIVATION: opt in with `services.cloudflared-connector.enable = true`. A
# boot-time activation script warns (does not abort) if `tokenFile` is missing —
# the unit fails at start and systemd retries (Restart=on-failure), so placing the
# file after first boot self-heals without a rebuild.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.cloudflared-connector;
in
{
  options.services.cloudflared-connector = {
    enable = lib.mkEnableOption "Cloudflare Tunnel connector (remotely-managed, token from file)";

    package = lib.mkPackageOption pkgs "cloudflared" { };

    tokenFile = lib.mkOption {
      # str, NOT path. A Nix PATH literal is copied into /nix/store at
      # evaluation, which would put the tunnel token in a world-readable store
      # path — the exact outcome the description below promises to avoid. As a
      # string the value is only ever resolved at runtime by systemd, and a
      # consumer that mistakenly passes a path literal now fails to evaluate
      # instead of silently leaking.
      type = lib.types.str;
      default = "/etc/secrets/cloudflared-token";
      example = "/run/agenix/cloudflared-token";
      description = ''
        Path to a file containing a single line `TUNNEL_TOKEN=<token>`, fed to the
        unit via systemd EnvironmentFile so the value never appears on the command
        line (argv) nor in the world-readable /nix/store. Place this file
        out-of-band (agenix/sops/manual) — do NOT commit the token to git. The
        connector retries on failure (Restart=on-failure), so placing the file
        after first boot self-heals without a rebuild.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--loglevel"
        "debug"
      ];
      description = "Extra arguments appended to `cloudflared tunnel run`.";
    };

    restartSec = lib.mkOption {
      type = lib.types.either lib.types.int lib.types.str;
      default = 5;
      description = "systemd `RestartSec` for the connector unit.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Warn at activation if the token file is missing. The unit itself will fail
    # and retry — this surfaces the root cause immediately.
    system.activationScripts.check-cloudflared-token = lib.stringAfter [ "etc" ] ''
      if [ ! -f "${cfg.tokenFile}" ]; then
        echo "WARNING: cloudflared-connector is enabled but tokenFile '${cfg.tokenFile}' does not exist." >&2
        echo "  Place a file with 'TUNNEL_TOKEN=<token>' at that path after provisioning." >&2
        echo "  The cloudflared-connector.service will keep retrying until it is present." >&2
      fi
    '';

    systemd.services.cloudflared-connector = {
      description = "Cloudflare Tunnel connector (remotely-managed, token from file)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        # Token via env (EnvironmentFile), NOT argv. `tunnel run` with no name/UUID
        # picks up TUNNEL_TOKEN from the environment for a remotely-managed tunnel.
        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/bin/cloudflared"
            "--no-autoupdate"
            "tunnel"
            "run"
          ]
          ++ cfg.extraArgs
        );
        EnvironmentFile = cfg.tokenFile;

        Restart = "on-failure";
        RestartSec = cfg.restartSec;

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
