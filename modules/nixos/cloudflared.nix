# Cloudflare Tunnel — boot-time, LOGINLESS token connector (remotely-managed).
#
# WHY NOT `services.cloudflared` (upstream)? The NixOS module only drives
# LOCALLY-managed tunnels: it wants a credentials JSON + an in-repo ingress and
# runs `cloudflared tunnel run <uuid>`. It has NO token support. This repo uses
# REMOTELY-managed (token) tunnels so every host's connector comes up at boot
# with zero interactive login (no `cloudflared tunnel login`, no cert.pem) and
# its ingress/DNS live in the Cloudflare account (provisioned by
# scripts/cf-one-provision.sh), not here. So we run our own hardened unit.
#
# TOKEN HANDLING (never in argv / never in the store): the connector token is a
# secret. It is delivered as `TUNNEL_TOKEN=…` via an EnvironmentFile — a file
# placed manually at `tokenFile` (default /etc/secrets/cloudflared-token) after
# provisioning. cloudflared reads `TUNNEL_TOKEN` from the environment, so it
# never appears on the command line (argv is world-readable via /proc) nor in a
# world-readable /nix/store path.
#
# ACTIVATION: hosts opt in explicitly with `services.cloudflared-connector.enable = true`.
# The tokenFile path is configurable. A boot-time activation script warns (but does
# not abort) if the file is missing — the unit will fail at start and systemd will
# retry (Restart=on-failure), so placing the file after first boot self-heals.
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

    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/secrets/cloudflared-token";
      description = ''
        Path to a file containing a single line `TUNNEL_TOKEN=<token>`, fed to
        the unit via systemd EnvironmentFile so the value never appears on the
        command line (argv) nor in the world-readable /nix/store. Place this
        file manually after provisioning the tunnel token — do NOT commit it to
        git. The connector service will retry on failure (Restart=on-failure),
        so placing the file after first boot self-heals without a rebuild.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.cloudflared ];

    # Warn at activation if the token file is missing. The unit itself will
    # fail and retry — this message surfaces the root cause immediately.
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
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run";
        # One line: TUNNEL_TOKEN=… — placed manually at tokenFile after provisioning.
        EnvironmentFile = cfg.tokenFile;

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
