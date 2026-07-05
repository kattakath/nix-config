# modules/nixos/litellm-host.nix — the full LiteLLM STACK as a native NixOS
# appliance (distinct from modules/nixos/litellm.nix, which runs the nixpkgs
# `litellm` binary directly and CANNOT do DB mode — no Prisma engines).
#
# TOPOLOGY on a single host (nixrpi):
#   - services.postgresql (NATIVE, not a container): owns the `litellm` DB, listens
#     on loopback only, loopback `trust` auth. Backs the Admin UI, virtual keys,
#     spend tracking and the SSO user table.
#   - litellm as an oci-container (podman backend): the OFFICIAL digest-pinned
#     ghcr.io/berriai/litellm-database image (bundles Prisma + engines, runs
#     `prisma migrate deploy` at boot). `--network=host` so it reaches native
#     Postgres on 127.0.0.1:5432 and binds the proxy on 127.0.0.1:4000. Config is
#     nix-generated and mounted read-only; secrets arrive via a manually-placed
#     EnvironmentFile (never argv, never the store).
#   - a DEDICATED cloudflared connector for the `litellm` tunnel — a hardened
#     systemd unit mirroring modules/nixos/cloudflared.nix, token from a
#     manually-placed file. Reaches the proxy over the loopback origin the tunnel
#     ingress points at (http://localhost:4000).
#
# NO-OP SAFE: gated behind `services.litellm-host.enable` (default false).
#
# SECRET HANDLING (never in argv / never in the store): the /nix/store is
# world-readable, so real keys must never appear in `settings` or inline env. The
# nix-generated config.yaml uses `os.environ/VAR` placeholders; the actual
# OPENAI_API_KEY / LITELLM_MASTER_KEY / GOOGLE_CLIENT_SECRET arrive via an
# EnvironmentFile read from `envFile` (default /etc/secrets/litellm-env). Non-secret
# env (PROXY_BASE_URL, DATABASE_URL with no password, GOOGLE_CLIENT_ID, …) is
# inline — harmless in the store.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.litellm-host;

  # LiteLLM proxy config — nix-generated, mounted read-only into the official
  # image. Only `os.environ/VAR` placeholders; real keys arrive from the env.
  format = pkgs.formats.yaml { };
  configFile = format.generate "litellm-config.yaml" {
    model_list = [
      {
        model_name = "gpt-4o";
        litellm_params = {
          model = "openai/gpt-4o";
          api_key = "os.environ/OPENAI_API_KEY";
        };
      }
    ];
    general_settings = {
      master_key = "os.environ/LITELLM_MASTER_KEY";
      database_url = "os.environ/DATABASE_URL";
    };
  };
in
{
  options.services.litellm-host = {
    enable = lib.mkEnableOption "the full LiteLLM stack (native Postgres + LiteLLM oci-container + dedicated Cloudflare tunnel)";

    image = lib.mkOption {
      type = lib.types.str;
      # OFFICIAL DB-capable arm64 image. The nixpkgs litellm closure ships no
      # Prisma query engines, so in DB mode it crash-loops at startup; this
      # official image bundles Prisma + engines and runs `prisma migrate deploy`.
      default = "ghcr.io/berriai/litellm-database@sha256:ade02ef3dc6db262df99781b7ee696d4a13c8fd443069f2d6f2f941a82f5427b";
      description = "The digest-pinned LiteLLM DB-capable OCI image to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4000;
      description = ''
        Loopback TCP port the proxy binds on (via --network=host). MUST match the
        tunnel ingress origin in infra/cloudflare/litellm.nix
        (http://localhost:<port>). Never published on the LAN — the dedicated
        Cloudflare connector on this same host is the sole client.
      '';
    };

    database = lib.mkOption {
      type = lib.types.str;
      default = "litellm";
      description = "Name of the native Postgres database (and its owning role).";
    };

    tunnelTokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/secrets/litellm-tunnel-token";
      description = ''
        Path to a file containing `TUNNEL_TOKEN=<token>` for the dedicated LiteLLM
        Cloudflare tunnel connector. Place manually after provisioning — do NOT commit
        to git. The unit retries on failure so placing the file after first boot
        self-heals without a rebuild.
      '';
    };

    envFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = "/etc/secrets/litellm-env";
      description = ''
        Path to a KEY=VALUE environment file supplying secret env vars
        (OPENAI_API_KEY, LITELLM_MASTER_KEY, GOOGLE_CLIENT_SECRET). Place
        manually after provisioning — do NOT commit to git. If null, the
        container starts without secret env (partial bring-up only).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Warn at activation if secret files are missing.
    system.activationScripts.check-litellm-secrets = lib.stringAfter [ "etc" ] ''
      if [ ! -f "${cfg.tunnelTokenFile}" ]; then
        echo "WARNING: litellm-host: tunnelTokenFile '${cfg.tunnelTokenFile}' does not exist." >&2
        echo "  Place a file with 'TUNNEL_TOKEN=<token>' at that path after provisioning." >&2
      fi
      ${lib.optionalString (cfg.envFile != null) ''
        if [ ! -f "${cfg.envFile}" ]; then
          echo "WARNING: litellm-host: envFile '${cfg.envFile}' does not exist." >&2
          echo "  Place a KEY=VALUE env file (OPENAI_API_KEY, LITELLM_MASTER_KEY, GOOGLE_CLIENT_SECRET) there." >&2
        fi
      ''}
    '';

    # ---- Native Postgres --------------------------------------------------------
    # Loopback-only listener with `trust` auth on 127.0.0.1/32 + ::1 ONLY.
    # TRADEOFF: `trust` means any local process connecting over loopback as the
    # `litellm` role is accepted with NO password. On this single-purpose
    # appliance that is acceptable — the DB is not exposed off-host (listen_addresses
    # is loopback, no firewall port is opened) and the only local consumer is the
    # litellm container (via --network=host → 127.0.0.1). It lets DATABASE_URL omit
    # a password (postgresql://litellm@localhost:5432/litellm), so no DB credential
    # lives in the store or an env file. If this host ever gains other local users,
    # switch this to scram-sha-256 + a password in the env file.
    services.postgresql = {
      enable = true;
      enableTCPIP = true; # listen on TCP loopback so the container reaches 127.0.0.1:5432
      settings.listen_addresses = lib.mkForce "127.0.0.1";
      ensureDatabases = [ cfg.database ];
      ensureUsers = [
        {
          name = cfg.database;
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkForce ''
        # TYPE  DATABASE  USER  ADDRESS       METHOD
        local   all       all                 trust
        host    all       all   127.0.0.1/32  trust
        host    all       all   ::1/128       trust
      '';
    };

    # ---- Podman as the OCI backend ---------------------------------------------
    virtualisation.podman = {
      enable = true;
      # Let `docker`-style tooling and the oci-containers module drive podman.
      dockerCompat = true;
    };
    virtualisation.oci-containers.backend = "podman";

    # ---- LiteLLM container ------------------------------------------------------
    virtualisation.oci-containers.containers.litellm = {
      inherit (cfg) image;
      # Host networking so the container reaches native Postgres on 127.0.0.1:5432
      # and binds the proxy on 127.0.0.1:<port> for the loopback tunnel origin.
      extraOptions = [ "--network=host" ];
      volumes = [ "${configFile}:/etc/litellm/config.yaml:ro" ];
      cmd = [
        "--config"
        "/etc/litellm/config.yaml"
        "--host"
        "127.0.0.1"
        "--port"
        (toString cfg.port)
      ];
      # NON-SECRET env inline (harmless in the store). DATABASE_URL carries NO
      # password (loopback trust auth). Secret env (OPENAI_API_KEY,
      # LITELLM_MASTER_KEY, GOOGLE_CLIENT_SECRET) comes from the env file.
      environment = {
        DATABASE_URL = "postgresql://${cfg.database}@localhost:5432/${cfg.database}";
        PROXY_BASE_URL = "https://litellm.kattakath.com";
        ALLOWED_EMAIL_DOMAINS = "kattakath.com";
        STORE_MODEL_IN_DB = "True";
        GOOGLE_CLIENT_ID = "305924238191-fdluaucv5603t0o2pb57elgf6dnu35r8.apps.googleusercontent.com";
      };
      # KEY=VALUE file with the SECRET env only. Placed manually at envFile path
      # after provisioning — never committed to git.
      environmentFiles = lib.optional (cfg.envFile != null) cfg.envFile;
    };

    # The container waits for Postgres to be up (prisma migrate deploy runs at
    # boot). Both are systemd units; order the container after postgresql.
    #
    # BOOT-SAFETY (root cause of the earlier Pi boot wedge): the upstream
    # oci-containers unit ships `TimeoutStartSec = 0` (INFINITE) with `Type=notify`,
    # and is `wantedBy = multi-user.target`. `podman run` pulls the (large, official
    # arm64) image inline; on the Pi that pull stalled, so the notify-typed start job
    # never completed and — with no start timeout — `multi-user.target` waited on it
    # forever. Two overrides make it impossible to wedge boot again:
    #   1. FINITE TimeoutStartSec (120s): a stalled pull/migrate now FAILS the job
    #      instead of blocking indefinitely; the boot transaction proceeds.
    #   2. DefaultDependencies-preserving Restart with a delay + a start-limit so a
    #      failing container backs off instead of hot-looping the boot transaction.
    # We deliberately do NOT keep any `Before=<boot target>` ordering (upstream adds
    # none; we add none) — the container is a leaf service that must never gate the
    # rest of userspace. Postgres ordering (after/requires) is kept: correct and
    # bounded because postgresql itself starts quickly.
    systemd.services."podman-litellm" = {
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      # Never let this leaf service block the boot transaction.
      before = lib.mkForce [ ];
      serviceConfig = {
        # Finite start timeout — a stalled image pull / prisma migrate now fails the
        # job (releasing multi-user.target) instead of hanging boot forever.
        TimeoutStartSec = lib.mkForce 120;
        # Back off on failure instead of hot-looping; the start-limit trips the unit
        # into `failed` after repeated fast failures rather than churning at boot.
        Restart = lib.mkForce "on-failure";
        RestartSec = 15;
      };
      startLimitIntervalSec = 300;
      startLimitBurst = 5;
    };

    # ---- Dedicated cloudflared connector for the litellm tunnel ----------------
    # Mirrors modules/nixos/cloudflared.nix. Coexists with the per-host connector
    # (separate unit, separate token). Token read from tunnelTokenFile (manually
    # placed, one line TUNNEL_TOKEN=…).
    systemd.services.cloudflared-litellm = {
      description = "Cloudflare Tunnel connector for LiteLLM (remotely-managed, token from file)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run";
        EnvironmentFile = cfg.tunnelTokenFile;

        Restart = "on-failure";
        RestartSec = 5;

        # ---- systemd hardening (from modules/nixos/cloudflared.nix) -------------
        DynamicUser = true;
        RuntimeDirectory = "cloudflared-litellm";
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
